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
// Created on 2026/4/6.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#include "peer.h"
#include <algorithm>
#include "WGException.h"

namespace WireGuard {
    Peer::Peer(const ContentKey &content_key, const PeerConfig &config)
        : content_key(content_key), config(config), endpoint(config.endpoint) {
    }

    Peer::~Peer() = default;

    Endpoint Peer::getEndpoint() const {
        std::lock_guard<std::mutex> guard(handshakeMutex_);
        return endpoint;
    }

    void Peer::updateEndpoint(Endpoint ep) { endpoint = ep; }

    bool Peer::isCanSendData(const bool &iAmInitiator) {
        if (iAmInitiator) {
            return noiseSend.canSendData();
        } else {
            return noiseReceive.canSendData();
        }
    }

    void Peer::updateHeartbeatPacketSendTime() { this->lastKeepaliveSent_ = Clock::now(); }

    std::chrono::milliseconds Peer::heartbeatPacketSendWaitTime() const {
        // 计算等待时间
        const auto wait = std::chrono::seconds(config.keepaliveInterval) - (Clock::now() - lastKeepaliveSent_);
        const auto wait_ms = std::chrono::duration_cast<std::chrono::milliseconds>(wait);
        return std::max(wait_ms, std::chrono::milliseconds(0));
    }

    std::vector<uint8_t> Peer::encryptPacketToMessageData(const uint8_t *data, const size_t &len) {
        std::lock_guard<std::mutex> guard(mutex_);
        auto kp = keyPairs_.getCurrent();
        if (!kp || !kp->sending.isValid) {
            throw WGException("密钥失效"); // 无有效密钥或发送方向失效
        }

        // 构造 加密Data 消息
        auto msg = kp->encryptToMessageBytes(data, len);

        addTxBytes(len);
        return msg;
    }

    std::vector<uint8_t> Peer::decryptPacket(const MessageData *msg, const size_t &len) const {
        std::lock_guard<std::mutex> guard(mutex_);
        const auto kp = keyPairs_.getCurrent();
        if (!kp || !kp->sending.isValid) {
            throw WGException("密钥失效"); // 无有效密钥或发送方向失效
        }

        const size_t cipherLen = len - sizeof(MessageData);
        const uint8_t *data = msg->encryptedData;
        const auto nonce = msg->counter;
        std::vector<uint8_t> plaintext;
        kp->decrypt(plaintext, data, cipherLen, nonce);
        return plaintext;
    }

    std::shared_ptr<KeyPair> Peer::beginSession(const bool &iAmInitiator) {
        std::lock_guard<std::mutex> guard(handshakeMutex_);
        // 创建 keyPair
        auto keyPair = iAmInitiator ? noiseSend.makeKeyPair(true) : noiseReceive.makeKeyPair(false);
        // 设置当前Peer的 keyPair
        const auto currentKp = keyPairs_.getCurrent();
        if (currentKp) {
            keyPairs_.setPrevious(currentKp);
        }
        setCurrentKeypair(keyPair);
        return keyPair; // 从握手状态机派生密钥
    }

    void Peer::setCurrentKeypair(std::shared_ptr<KeyPair> kp) {
        std::lock_guard<std::mutex> lock(mutex_);
        LOG_DEBUG("peer 更新KeyPairs");
        keyPairs_.setCurrent(kp);
    }

    void Peer::addRxBytes(uint64_t bytes) {
        rxBytes_ += bytes; // 累加接收字节数
        lastDataReceived_ = Clock::now(); // 更新最后接收时间
    }

    void Peer::addTxBytes(uint64_t bytes) {
        txBytes_ += bytes; // 累加接收字节数
        lastDataReceived_ = Clock::now(); // 更新最后接收时间
    }

    void Peer::needsReKey() const {
        std::lock_guard<std::mutex> guard(mutex_);

        const auto kp = keyPairs_.getCurrent();
        if (!kp) {
            throw WGException("当前没有密钥");
        }
        kp->needsReKey(); // 检查密钥对是否过期
    }

    std::shared_ptr<KeyPair> Peer::getCurrentKeypair() const {
        std::lock_guard<std::mutex> guard(mutex_);
        return keyPairs_.getCurrent(); // 从密钥对管理器获取当前密钥
    }

    void Peer::queuePacket(std::vector<uint8_t> packet) {
        std::lock_guard<std::mutex> guard(mutex_);
        stagedPackets_.push(std::move(packet)); // 加入等待队列
    }

    std::queue<std::vector<uint8_t> > Peer::consumeStagedPackets() {
        std::lock_guard<std::mutex> guard(mutex_);
        std::queue<std::vector<uint8_t> > result;
        std::swap(stagedPackets_, result); // 交换队列，清空 stagedPackets_
        return result;
    }

    void Peer::clear() {
    }

    void Peer::init() {
        if (std::all_of(content_key.local_private_key.begin(), content_key.local_private_key.end(), [](uint8_t it) {
            return it == 0;
        })) {
            throw WGException(
                "无效的本地私钥：不能为全零: key=%s",
                crypto::bin32Array2Base64(content_key.local_private_key).c_str()
            );
        }
        if (std::all_of(config.public_key.begin(), config.public_key.end(), [](uint8_t it) { return it == 0; })) {
            throw WGException(
                "无效的Peer公钥：不能为全零: key=%s",
                crypto::bin32Array2Base64(config.public_key).c_str()
            );
        }

        noiseSend.init(content_key.local_private_key, config.public_key);
        noiseReceive.init(content_key.local_private_key);
        if (config.pre_share_key) {
            std::memcpy(noiseSend.pre_shared_key.data(), config.pre_share_key->data(), SYMMETRIC_KEY_LEN);
            std::memcpy(noiseReceive.pre_shared_key.data(), config.pre_share_key->data(), SYMMETRIC_KEY_LEN);
        }
        initialized = true;
    }

    MessageInitiation Peer::createHandshakeInitiation(const uint32_t &senderIndex, const bool &force) {
        std::lock_guard<std::mutex> lock(handshakeMutex_);

        const auto now = Clock::now();
        if (!force) {
            // 如果不是强制，就需要检查间隔时间，防止发送太多
            const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(now - lastSentHandshake_).count();

            if (elapsed < REKEY_TIMEOUT) {
                throw WGException("创建太频繁"); // 速率限制：防止频繁发送握手（最小间隔 5 秒）
            }
        }

        const auto msg = noiseSend.encodeHandshakeInitiation(senderIndex);

        lastSentHandshake_ = now; // 更新最后发送时间
        ++handshakeAttempts_; // 增加尝试次数
        return msg;
    }

    void Peer::verifyHandshakeInitiationResponse(const MessageResponse &msg) {
        std::lock_guard<std::mutex> lock(handshakeMutex_);
        noiseSend.verifyHandshakeInitiationResponse(msg);
        lastReceivedHandshake_ = Clock::now();
    }

    bool Peer::handleHandshakeInitiation(const MessageInitiation &msg) {
        std::lock_guard<std::mutex> guard(handshakeMutex_);
        noiseReceive.decodeCheckHandshakeInitiation(msg);
        lastReceivedHandshake_ = Clock::now();
        return true;
    }

    MessageResponse Peer::createHandshakeResponse(const uint32_t &senderIndex) {
        std::lock_guard<std::mutex> guard(handshakeMutex_);
        const auto msg = noiseReceive.createHandshakeResponse(senderIndex);
        lastSentHandshake_ = Clock::now(); // 更新最后发送时间
        return msg;
    }

    void Peer::handleCookie(const MessageCookie &msg) const {
        std::lock_guard<std::mutex> guard(handshakeMutex_);
        noiseSend.decryptCookie(msg);
    }
}; // namespace WireGuard
