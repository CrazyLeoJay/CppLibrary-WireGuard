/*
* Copyright [2026] @github-crazyleojay (crazyleojay@163.com/gmail.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */
//
// Created on 2026/3/25.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#include "keypair.h"
#include "WGException.h"
#include "crypto/nonce2.h"
#include <chrono>
#include <cstdint>
#include <cstring>

namespace WireGuard {
    // ============================================================================
    // ReplayCounter 实现
    // ============================================================================

    bool ReplayCounter::validate(uint64_t theirCounter) {
        std::lock_guard<std::mutex> guard(lock_);

        // 拒绝超过最大值的消息（防止计数器回绕）
        if (theirCounter >= REJECT_AFTER_MESSAGES) {
            // 防止超过 uint64_t 最大值导致程序上的异常，这时应该重新握手，初始化值，从1开始
            return false;
        }
        /**
         * 一对
         * std::memory_order_release
         * std::memory_order_acquire
         * 保证 store(theirCounter, std::memory_order_release) 后，它之前的修改
         * load(std::memory_order_acquire) 之后，当前线程可以获取到 store 之前所有的内存修改。
         */
        uint64_t currentCounter = counter_.load(std::memory_order_acquire);

        // 检查是否在窗口之外（太旧的消息）
        // 如果 theirCounter + 8192 < currentCounter，说明 theirCounter 落后太多
        // 如果使用 currentCounter-8192，如果currentCounter小于8192 负数会导致uint64_t 回绕，所以改用加法。
        // 已经限定 currentCounter 最大值不能超过 (UINT64_MAX-8193)
        if (theirCounter + RECEIVING_WINDOW_LEN <= (currentCounter)) {
            // 这个计数太旧了，直接抛弃
            return false;
        }
        size_t index;
        // 如果是新的最大值，需要滑动窗口
        if (theirCounter > currentCounter) {
            uint64_t diff = theirCounter - currentCounter;
            // 右移窗口，丢弃旧的数据
            window_ <<= static_cast<size_t>(diff);
            // 更新基准计数器
            counter_.store(theirCounter, std::memory_order_release);
            index = 0;
        } else {
            // 如果不比当前值大，则计算距离
            index = currentCounter - theirCounter;
        }

        // 检查是否重复（该位已设置）
        if (window_.test(index)) {
            return false;
        }

        // 标记为已收到
        window_.set(index);
        return true;
    }

    uint64_t ReplayCounter::getCounter() const { return counter_.load(std::memory_order_acquire); }

    // ============================================================================
    // Keypair 实现
    // ============================================================================

    std::unique_ptr<uint64_t> KeyPair::allocateNonce() {
        if (!sending.isValid)
            return nullptr;

        // 原子递增计数器
        uint64_t nonce = sendingCounter.fetch_add(1, std::memory_order_relaxed);

        // 检查是否达到上限（WireGuard 限制：2^64 - 1）
        if (nonce >= REJECT_AFTER_MESSAGES) {
            sending.markExpired();
            return nullptr;
        }
        return std::make_unique<uint64_t>(nonce);
    }

    bool KeyPair::encrypt(std::vector<uint8_t> &ciphertext, const uint8_t *plaintext, size_t plainLen, uint64_t nonce) {
        if (!sending.isValid) {
            return false;
        }

        // 计算填充长度（16 字节对齐，ChaCha20 的要求）
        size_t paddedLen = ((plainLen + 15) / 16) * 16;
        std::vector<uint8_t> padded(paddedLen, 0);
        if (plaintext && plainLen > 0) {
            // 如果有数据就写入
            std::memcpy(padded.data(), plaintext, plainLen);
        }

        // ChaCha20-Poly1305 加密
        // AAD=nullptr（不需要额外的认证数据）
        //        return Crypto::encrypt(ciphertext, padded.data(), paddedLen, nullptr, 0, nonce, sending.key);
        crypto_static::encodeAEAD(ciphertext, sending.key, nonce, padded.data(), paddedLen, nullptr);
        return true;
    }

    std::vector<uint8_t> KeyPair::encrypt(const uint8_t *plaintext, size_t plainLen, uint64_t nonce) {
        std::vector<uint8_t> result{};
        encrypt(result, plaintext, plainLen, nonce);
        return result;
    }

    std::vector<uint8_t> WireGuard::KeyPair::encryptToMessageBytes(const uint8_t *data, const size_t len) {
        auto nonceOpt = allocateNonce();
        if (!nonceOpt) {
            throw WGException("nonce 达到最大值，需要重新握手"); // Nonce 用尽，需要重新握手
        }
        std::vector<uint8_t> result;
        encrypt(result, data, len, *nonceOpt); // ChaCha20-Poly1305 加密

        //        auto encryptLen = result.size();
        //        if (encryptLen > 16 && encryptLen % 16 != 0) {
        //            throw WGException("加密后的消息长度不是16倍数 len=%d", encryptLen);
        //        }

        // 构造 Data 消息
        std::vector<uint8_t> message(sizeof(MessageData) + result.size());
        auto *msg = reinterpret_cast<MessageData *>(message.data());
        //        MessageData msg;
        msg->header.type = static_cast<uint8_t>(MessageType::DATA);
        memset(msg->reserved_zero, 0, 3);
        // 设置正确的 keyIndex
        msg->keyIndex = remoteIndex;
        msg->counter = *nonceOpt.get(); // 从密钥对获取
        memcpy(msg->encryptedData, result.data(), result.size());
        return message;
    }

    bool KeyPair::decrypt(std::vector<uint8_t> &plaintext, const uint8_t *ciphertext, size_t cipherLen,
                          uint64_t nonce) {
        if (!receiving.isValid) {
            return false;
        }

        // 验证重放计数器（防止重放攻击）
        if (!receivingCounter.validate(nonce)) {
            return false;
        }
        if (cipherLen <= 0) {
            LOG_DEBUG("解密字段长度为0");
            return false;
        }

        // ChaCha20-Poly1305 解密
        // AAD=nullptr（不需要额外的认证数据）
        // return Crypto::decrypt(plaintext, ciphertext, cipherLen, nullptr, 0, nonce, receiving.key);
        crypto_static::decodeAEAD(plaintext, receiving.key, nonce, ciphertext, cipherLen, nullptr);
        // 加密时填充了0 解密时进行移除

        auto plainTextLen = plaintext.size();
        if (plainTextLen > 0) {
            for (size_t i = plaintext.size() - 1; true; i--) {
                if (plaintext[i] == 0) {
                    plainTextLen = i;
                    continue;
                }
                if (i == 0)
                    break;
                break;
            }
            if (plainTextLen != plaintext.size()) {
                plaintext.resize(plainTextLen);
            }
        }
        return true;
    }

    std::vector<uint8_t> KeyPair::decrypt(const uint8_t *ciphertext, size_t cipherLen, uint64_t nonce) {
        std::vector<uint8_t> result{};
        decrypt(result, ciphertext, cipherLen, nonce);
        return result;
    }

    std::vector<uint8_t> WireGuard::KeyPair::decrypt(const MessageData *msg, const size_t len) {
        size_t cipherLen = len - sizeof(MessageData);
        const uint8_t *data = msg->encryptedData;
        auto nonce = msg->counter;
        std::vector<uint8_t> plaintext;
        decrypt(plaintext, data, cipherLen, nonce);
        return plaintext;
    }

    void KeyPair::needsReKey() const {
        if (!sending.isValid) {
            // 密钥失效，需要重新握手
            throw WGException("密钥失效");
        }

        // 检查已发送的消息数
        uint64_t sentMessages = sendingCounter.load(std::memory_order_relaxed);
        if (sentMessages >= REKEY_AFTER_MESSAGES) {
            throw WGException("超过最大消息数量");
        }

        // 检查密钥生存时间
        uint64_t now = getCurrentTimeNs();
        if (sending.isExpired(now, REKEY_AFTER_TIME)) {
            throw WGException("当密钥已过期");
        }
    }

    bool KeyPair::isExpired() const {
        // 如果两个密钥都无效，则已过期
        if (!sending.isValid && !receiving.isValid)
            return true;

        uint64_t now = getCurrentTimeNs();

        // 检查发送密钥是否超过最大生存期
        bool sendingExpired = sending.isValid && sending.isExpired(now, REJECT_AFTER_TIME);

        // 检查接收密钥是否超过最大生存期
        bool receivingExpired = receiving.isValid && receiving.isExpired(now, REJECT_AFTER_TIME);

        // 只有两个密钥都过期了，整个密钥对才算过期
        return sendingExpired && receivingExpired;
    }

    uint64_t KeyPair::getCurrentTimeNs() {
        auto now = std::chrono::steady_clock::now();
        auto duration = now.time_since_epoch();
        return std::chrono::duration_cast<std::chrono::nanoseconds>(duration).count();
    }

    // ============================================================================
    // Keypairs 实现
    // ============================================================================

    std::shared_ptr<KeyPair> KeyPairs::getCurrent() const {
        std::lock_guard<std::mutex> guard(updateLock_);
        return current_;
    }

    std::shared_ptr<KeyPair> KeyPairs::getPrevious() const {
        std::lock_guard<std::mutex> guard(updateLock_);
        return previous_;
    }

    std::shared_ptr<KeyPair> KeyPairs::getNext() const {
        std::lock_guard<std::mutex> guard(updateLock_);
        return next_;
    }

    void KeyPairs::setCurrent(std::shared_ptr<KeyPair> kp) {
        std::lock_guard<std::mutex> guard(updateLock_);
        current_ = std::move(kp);
    }

    void KeyPairs::setNext(std::shared_ptr<KeyPair> kp) {
        std::lock_guard<std::mutex> guard(updateLock_);
        next_ = std::move(kp);
    }

    void KeyPairs::setPrevious(std::shared_ptr<KeyPair> kp) {
        std::lock_guard<std::mutex> guard(updateLock_);
        previous_ = std::move(kp);
    }

    bool KeyPairs::receivedWithNextKey() {
        std::lock_guard<std::mutex> guard(updateLock_);
        if (!next_)
            return false;

        // 密钥轮换：current → previous, next → current
        previous_ = current_;
        current_ = next_;
        next_.reset();
        return true;
    }

    void KeyPairs::clear() {
        std::lock_guard<std::mutex> guard(updateLock_);
        current_.reset();
        previous_.reset();
        next_.reset();
    }
} // namespace WireGuard