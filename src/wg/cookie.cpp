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

namespace WireGuard {
    CookieChecker::CookieChecker(const ContentKey &content_key) : content_key_(content_key) {
    }

    CookieData CookieChecker::getCookie(const Endpoint &endpoint) {
        std::lock_guard<std::mutex> lock(secret_lock_);

        // 验证 cookie密钥是否可用
        if (!verifySecretValid()) {
            // 无效就生成新cookie
            fillSecretHash2SecureRandom();
        }

        if (cookieIndex.find(endpoint) == cookieIndex.end()) {
            cookieIndex[endpoint] = makeCookie(endpoint);
        }
        return cookieIndex[endpoint];
    }

    std::unique_ptr<CookieData> CookieChecker::getCookieNoMake(const Endpoint &endpoint) const {
        if (cookieIndex.find(endpoint) == cookieIndex.end()) {
            return nullptr;
        }
        return std::make_unique<CookieData>(cookieIndex[endpoint]);
    }

    MacData CookieChecker::computeMac1(const MessageInitiation &msg, const PublicKey &public_key) {
        constexpr size_t mac1_input_length = sizeof(MessageInitiation) - COOKIE_LEN * 2;
        // 转为 const uint8_t*（只读）
        const auto *bytes = reinterpret_cast<const uint8_t *>(&msg);
        return crypto::MAC(crypto::mixHash(crypto::LABEL_MAC1, public_key), bytes, mac1_input_length);
    }

    MacData CookieChecker::computeMac1(const MessageResponse &msg, const PrivateKey &public_key) {
        constexpr size_t mac1_input_length = sizeof(MessageResponse) - COOKIE_LEN * 2;
        // 转为 const uint8_t*（只读）
        const auto *bytes = reinterpret_cast<const uint8_t *>(&msg);
        return crypto::MAC(crypto::mixHash(crypto::LABEL_MAC1, public_key), bytes, mac1_input_length);
    }

    CookieData CookieChecker::computeMac2(const MessageInitiation &msg, const Endpoint &endpoint) {
        // 计算 cookie
        const CookieData cookie = getCookie(endpoint);
        constexpr auto len = sizeof(MessageInitiation) - COOKIE_LEN;
        const auto mac2 = crypto::MAC(cookie.data(), COOKIE_LEN, reinterpret_cast<const uint8_t *>(&msg), len);
        return mac2;
    }

    void CookieChecker::messageAddMac2(const Endpoint &endpoint, MessageResponse &response) {
        const auto cookie = getCookie(endpoint);
        const auto mac2 = computeMac2(response, cookie);
        std::memcpy(response.mac2, mac2.data(), COOKIE_LEN);
    }

    CookieData CookieChecker::computeMac2(const MessageInitiation &msg, const CookieData &cookie_data) {
        constexpr auto len = sizeof(MessageInitiation) - COOKIE_LEN;
        return crypto::MAC(cookie_data.data(), COOKIE_LEN, reinterpret_cast<const uint8_t *>(&msg), len);
    }

    CookieData CookieChecker::computeMac2(const MessageResponse &msg, const CookieData &last_cookie) {
        constexpr auto len = sizeof(MessageResponse) - COOKIE_LEN;
        return crypto::MAC(last_cookie.data(), COOKIE_LEN, reinterpret_cast<const uint8_t *>(&msg), len);
    }

    MessageCookie CookieChecker::createCookieReply(const MessageInitiation &msg, const Endpoint &endpoint,
                                                   const PublicKey &public_key) {
        verifyMac1(msg, public_key);
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
        const CookieData cookie = getCookie(endpoint);

        crypto::encodeXAEAD(
            crypto::mixHash(crypto::LABEL_COOKIE, public_key).data(),
            cookieMsg.nonce,
            cookie.data(), COOKIE_LEN,
            msg.mac1, COOKIE_LEN
        );
        return cookieMsg;
    }

    bool CookieChecker::verifySecretValid() const {
        const auto now = Clock::now();
        if (now - secret_birthdate_ > secret_valid_duration) {
            return false;
        }
        if (std::all_of(secret_.begin(), secret_.end(), [&](const uint8_t it) { return it == 0; })) {
            // secret 为空，需要生成
            return false;
        }
        return true;
    }

    void CookieChecker::verifyMac1(const MessageInitiation &msg, const PublicKey &sendPointPublicKey) {
        if (cookie::isEmpty(msg.mac1)) {
            throw WGException("Mac1 不存在");
        }
        const auto verifyCookie = computeMac1(msg, sendPointPublicKey);
        // 判断两个 cookie 是否一致 一致表示有效
        // return std::memcmp(verifyCookie.data(), msg.mac1, COOKIE_LEN) == 0;
        if (crypto_verify_16(msg.mac1, verifyCookie.data()) != 0) {
            throw WGException(
                "mac1 验证失败 \nmsg.mac1=%s \nc_mac1  =%s",
                crypto::bin2B64(msg.mac1, COOKIE_LEN).c_str(),
                crypto::bin2B64(verifyCookie.data(), COOKIE_LEN).c_str()
            );
        }
    }

    void CookieChecker::verifyMac1(const MessageResponse &msg, const PrivateKey &public_key) {
        if (cookie::isEmpty(msg.mac1)) {
            throw WGException("Mac1 不存在");
        }
        const auto verifyCookie = computeMac1(msg, public_key);
        // 判断两个 cookie 是否一致 一致表示有效
        // return std::memcmp(verifyCookie.data(), msg.mac1, COOKIE_LEN) == 0;
        if (crypto_verify_16(msg.mac1, verifyCookie.data()) != 0) {
            throw WGException(
                "mac1 验证失败 \nmsg.mac1=%s \nc_mac1  =%s",
                crypto::bin2B64(msg.mac1, COOKIE_LEN).c_str(),
                crypto::bin2B64(verifyCookie.data(), COOKIE_LEN).c_str()
            );
        }
    }

    void CookieChecker::verifyMac2(const MessageInitiation &msg, const CookieData &last_received_cookie) {
        if (cookie::isEmpty(msg.mac2)) {
            throw WGException("mac2 为空");
        }
        // 转为 const uint8_t*（只读）
        const auto *bytes = reinterpret_cast<const uint8_t *>(&msg);
        constexpr size_t mac2_input_length = sizeof(MessageInitiation) - COOKIE_LEN;
        const auto mac2 = crypto::MAC(last_received_cookie.data(), COOKIE_LEN, bytes, mac2_input_length);
        if (std::memcmp(msg.mac2, mac2.data(), COOKIE_LEN) != 0) {
            throw WGException(
                "mac2 验证失败msg.mac2=%s c_mac2=%s", crypto::bin2B64(msg.mac2, COOKIE_LEN).c_str(),
                crypto::bin2B64(mac2.data(), COOKIE_LEN).c_str()
            );
        }
    }

    void CookieChecker::verifyMac2(const MessageResponse &msg, const CookieData &last_received_cookie) {
        if (cookie::isEmpty(msg.mac2)) {
            throw WGException("mac2 为空");
        }
        // 转为 const uint8_t*（只读）
        const auto *bytes = reinterpret_cast<const uint8_t *>(&msg);
        constexpr size_t mac2_input_length = sizeof(msg) - COOKIE_LEN;
        const auto mac2 = crypto::MAC(last_received_cookie.data(), COOKIE_LEN, bytes, mac2_input_length);
        if (std::memcmp(msg.mac2, mac2.data(), COOKIE_LEN) != 0) {
            throw WGException(
                "mac2 验证失败msg.mac2=%s c_mac2=%s", crypto::bin2B64(msg.mac2, COOKIE_LEN).c_str(),
                crypto::bin2B64(mac2.data(), COOKIE_LEN).c_str()
            );
        }
    }

    void CookieChecker::fillSecretHash2SecureRandom() {
        std::lock_guard<std::mutex> lock(secret_lock_);
        // 清空所有cookie
        cookieIndex.clear();
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
