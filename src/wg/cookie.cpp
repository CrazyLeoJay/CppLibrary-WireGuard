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

#include "WGException.h"
#include "crypto.h"
#include "messages.h"
#include "sodium/crypto_verify_16.h"

#include <cstddef>
#include <cstdint>

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

    CookieData WireGuard::CookieManager::makeAndGetMac1(const MessageInitiation msg, const SymmetricKey &key) {
        const uint8_t *mac = msg.mac1;
        // 如果 mac1 都是 0，表示未设置，去计算。否则直接给mac1赋值
        if (cookie::isEmpty(mac)) {
            mac1 = cookie::computeMac(msg, key);
        } else {
            memcpy(&mac1, mac, COOKIE_LEN);
        }
        return mac1;
    }

    bool CookieManager::verifyMac1(const MessageInitiation *msg, const SymmetricKey key) {
        if (cookie::isEmpty(msg->mac1)) {
            //            throw WGException("Mac1 不存在");
            return false;
        }
        MessageInitiation verifyMsg;
        // 移除所有 mac 的值
        std::memcpy(&verifyMsg, &msg, sizeof(MessageInitiation) - (COOKIE_LEN * 2));

        auto verifyCookie = cookie::computeMac(verifyMsg, key);
        // 判断两个 cookie 是否一致 一致表示有效
        return crypto_verify_16(msg->mac1, verifyCookie.data());
    }

    namespace cookie {
        CookieData computeMac(const MessageInitiation msg, const SymmetricKey &key) {
            size_t mac1_input_length = sizeof(MessageInitiation) - COOKIE_LEN;

            // 转为 const uint8_t*（只读）
            const uint8_t *bytes = reinterpret_cast<const uint8_t *>(&msg);
            return Crypto::blake2bCookie(key, bytes, mac1_input_length);
        }

        bool isEmpty(const CookieData &cookie) {
            return std::all_of(cookie.begin(), cookie.end(), [](uint8_t it) { return it == 0; });
        }

        bool isEmpty(const uint8_t *mac) {
            return std::all_of(mac, mac + COOKIE_LEN, [](uint8_t it) { return it == 0; });
        }

        /**
         * @brief 从设备公钥派生密钥
         */
        SymmetricKey deriveKey(const PublicKey &public_key, const char *label) {
            SymmetricKey out_key;
            //            unsigned char prk[crypto_kdf_hkdf_sha256_KEYBYTES];

            // Extract
            //            crypto_kdf_hkdf_sha256_extract(prk, nullptr, 0, public_key.data(), public_key.size());
            //
            //            // Expand
            //            crypto_kdf_hkdf_sha256_expand(out_key.data(), SYMMETRIC_KEY_LEN, label, strlen(label), prk);
            //
            //            sodium_memzero(prk, sizeof(prk));
            return out_key;
        }
    } // namespace cookie
};