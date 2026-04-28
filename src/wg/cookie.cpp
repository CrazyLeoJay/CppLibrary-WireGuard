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
// Created on 2026/3/27.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#include "cookie.h"

#include <algorithm>
#include <unistd.h>

#include "WGException.h"
#include "crypto/crypto.h"
#include "messages.h"
#include "sodium/crypto_verify_16.h"
#include <sys/syscall.h>

namespace WireGuard {
    // ========== Cookie 类实现 ==========

    Cookie::Cookie() {
        cookie_.fill(0);
        last_mac1_sent_.fill(0);
        cookie_decryption_key_.fill(0);
        message_mac1_key_.fill(0);
        birthdate_ = std::chrono::steady_clock::now();
    }

    std::chrono::steady_clock::time_point Cookie::getBirthdate() const {
        std::lock_guard<std::mutex> lock(lock_);
        return birthdate_;
    }

    bool Cookie::isValid() const {
        std::lock_guard<std::mutex> lock(lock_);
        if (!is_valid_) {
            return false;
        }
        // 检查 Cookie 是否过期（考虑延迟时间）
        auto now = std::chrono::steady_clock::now();
        auto age = std::chrono::duration_cast<std::chrono::seconds>(now - birthdate_).count();
        return age <= static_cast<int64_t>(COOKIE_SECRET_MAX_AGE - COOKIE_SECRET_LATENCY);
    }

    const CookieData &Cookie::getCookie() const {
        std::lock_guard<std::mutex> lock(lock_);
        return cookie_;
    }

    void Cookie::setCookie(const CookieData &newCookie) {
        std::lock_guard<std::mutex> lock(lock_);
        cookie_ = newCookie;
        birthdate_ = std::chrono::steady_clock::now();
        is_valid_ = true;
    }

    const MacData &Cookie::getLastMac1Sent() const {
        std::lock_guard<std::mutex> lock(lock_);
        return last_mac1_sent_;
    }

    bool Cookie::hasSentMac1() const {
        std::lock_guard<std::mutex> lock(lock_);
        return have_sent_mac1_;
    }

    void Cookie::markMac1Sent(const MacData &mac1) {
        std::lock_guard<std::mutex> lock(lock_);
        last_mac1_sent_ = mac1;
        have_sent_mac1_ = true;
    }

    const SymmetricKey &Cookie::getDecryptionKey() const {
        std::lock_guard<std::mutex> lock(lock_);
        return cookie_decryption_key_;
    }

    void Cookie::setDecryptionKey(const SymmetricKey &key) {
        std::lock_guard<std::mutex> lock(lock_);
        cookie_decryption_key_ = key;
    }

    const SymmetricKey &Cookie::getMac1Key() const {
        std::lock_guard<std::mutex> lock(lock_);
        return message_mac1_key_;
    }

    void Cookie::setMac1Key(const SymmetricKey &key) {
        std::lock_guard<std::mutex> lock(lock_);
        message_mac1_key_ = key;
    }

    CookieChecker::CookieChecker(const PublicKey &device_public_key) : device_public_key(device_public_key) {
    }

    void CookieChecker::init() {
        message_mac1_key_ = crypto::mixHash(crypto::LABEL_MAC1, device_public_key);
        cookie_encryption_key_ = crypto::mixHash(crypto::LABEL_COOKIE, device_public_key);
        initialized_ = true;
    }

    CookieData CookieChecker::computeMac1(const MessageInitiation &msg) const {
        constexpr size_t mac1_input_length = sizeof(MessageInitiation) - COOKIE_LEN * 2;
        // 转为 const uint8_t*（只读）
        const auto *bytes = reinterpret_cast<const uint8_t *>(&msg);
        return crypto::MAC(message_mac1_key_, bytes, mac1_input_length);
    }

    CookieData CookieChecker::computeMac2(const MessageInitiation &msg, const Endpoint &endpoint) const {
        // 计算 cookie
        const CookieData cookie = makeCookie(endpoint);
        constexpr auto len = sizeof(MessageInitiation) - COOKIE_LEN ;
        const auto mac2 = crypto::MAC(cookie.data(), COOKIE_LEN,  reinterpret_cast<const uint8_t *>(&msg), len);
        return mac2;
    }

    bool CookieChecker::verifyMac1(const MessageInitiation *msg) const {
        if (cookie::isEmpty(msg->mac1)) {
            //            throw WGException("Mac1 不存在");
            return false;
        }
        const MessageInitiation verifyMsg = *msg;
        const auto verifyCookie = computeMac1(verifyMsg);
        // 判断两个 cookie 是否一致 一致表示有效
        return crypto_verify_16(msg->mac1, verifyCookie.data());
    }

    bool CookieChecker::verifyMac2(const MessageInitiation &msg, const Endpoint &endpoint) const {
        if (cookie::isEmpty(msg.mac2)) {
            return false;
        }
        // 计算 cookie
        const auto mac2 = computeMac2(msg, endpoint);
        return crypto_verify_16(msg.mac2, mac2.data());
    }

    MessageCookie CookieChecker::createCookieReply(const MessageInitiation &msg, const Endpoint &endpoint) {
        if (!verifyMac1(&msg)) {
            throw WGException("mac1 验证异常");
        }
        // 验证 cookie密钥是否可用
        if (!verifySecretValid()) {
            // 无效就生成新cookie
            fillSecretHash2SecureRandom();
        }
        // 生成cookie消息
        MessageCookie cookieMsg{};
        cookieMsg.receiverIndex = msg.senderIndex;
        // cookieMsg.nonce
        crypto::randombytes(cookieMsg.nonce, NONCE_LEN);

        // 计算 cookie
        const CookieData cookie = makeCookie(endpoint);

        crypto::encodeXAEAD(
            cookie_encryption_key_.data(),
            cookieMsg.nonce,
            cookie.data(), COOKIE_LEN,
            msg.mac1, COOKIE_LEN
        );
        return cookieMsg;
    }

    bool CookieChecker::verifySecretValid() {
        const auto now = Clock::now();
        if (now - secret_birthdate_ > secret_valid_duration) {
            return false;
        }
        if (std::all_of(secret_.begin(), secret_.end(), [&](uint8_t it) { return it == 0; })) {
            // secret 为空，需要生成
            return false;
        }
        return true;
    }



    void CookieChecker::fillSecretHash2SecureRandom() {
        crypto::randombytes(secret_.data(), HASH_LEN);
        // 更新Cookie密钥生成时间
        secret_birthdate_ = Clock::now();
    }

    CookieData CookieChecker::makeCookie(const Endpoint &endpoint) const {
        // 计算 cookie
        CookieData cookie;
        if (endpoint.address.family == IPAddress::IPv4) {
            // 构造输入：peer_addr || port
            std::vector<uint8_t> input(4 + sizeof(endpoint.port));
            memcpy(input.data(), reinterpret_cast<uint8_t *>(endpoint.address.ip.ipv4), 4);
            memcpy(input.data() + 4, &endpoint.port, sizeof(endpoint.port));
            cookie = crypto::MAC(secret_, input.data(), input.size());
        } else {
            std::vector<uint8_t> input(16 + sizeof(endpoint.port));
            memcpy(input.data(), endpoint.address.ip.ipv6, 16);
            memcpy(input.data() + 4, &endpoint.port, sizeof(endpoint.port));
            cookie = crypto::MAC(secret_, input.data(), input.size());
        }
        return cookie;
    }

    namespace cookie {
        bool isEmpty(const CookieData &cookie) {
            return std::all_of(cookie.begin(), cookie.end(), [](uint8_t it) { return it == 0; });
        }

        bool isEmpty(const uint8_t *mac) {
            return std::all_of(mac, mac + COOKIE_LEN, [](uint8_t it) { return it == 0; });
        }
    } // namespace cookie
};
