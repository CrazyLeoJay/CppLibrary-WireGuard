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

#ifndef WIREGUARD_COOKIE_H
#define WIREGUARD_COOKIE_H
#include "entity.h"
#include "messages.h"
#include <mutex>
#include <unordered_map>

#include "version.h"

namespace WireGuard {
    struct ContentKey;
    // ========== Cookie 相关常量 ==========
    //    constexpr size_t COOKIE_LEN = 16;               // Cookie 长度（字节）
    //    constexpr size_t COOKIE_NONCE_LEN = 24;         // Cookie 加密使用的 nonce 长度
    constexpr uint64_t COOKIE_SECRET_MAX_AGE = 120; // Cookie 密钥最大有效期（秒）
    constexpr uint64_t COOKIE_SECRET_LATENCY = 5; // Cookie 密钥延迟时间（秒）

    /**
     * @brief MAC 验证状态枚举
     *
     * 表示接收到的数据包中 MAC 验证的不同状态
     */
    enum class CookieMacState {
        INVALID_MAC, ///< MAC1 验证失败，数据包无效
        VALID_MAC_BUT_NO_COOKIE, ///< MAC1 成功但无有效 Cookie
        VALID_MAC_WITH_COOKIE_BUT_RATELIMITED, ///< MAC1 和 MAC2 都成功但被速率限制
        VALID_MAC_WITH_COOKIE ///< 完全验证成功，可以处理数据包
    };

    /**
     * @brief Cookie 验证器 - 设备级别的 Cookie 管理和验证
     *
     * 每个 WireGuard 设备维护一个 CookieChecker 实例，负责：
     * 1. 生成和管理设备的 Secret 密钥（每 2 分钟轮换）
     * 2. 验证接收到的数据包中的 MAC1 和 MAC2
     * 3. 为需要 Cookie 的客户端生成 Cookie Reply
     * 4. 为发送的数据包添加 MAC1 和 MAC2
     *
     * 线程安全：所有公共方法都是线程安全的
     */
    class CookieChecker {
    private:
        // ========== 成员变量 ==========
        const ContentKey &content_key_; // 用于计算的设备公钥

        Hash secret_{}; ///< 主密钥（随机生成，每 2 分钟轮换）
        std::chrono::steady_clock::time_point secret_birthdate_; /// < Secret 创建时间
        const std::chrono::steady_clock::duration secret_valid_duration{std::chrono::minutes(2)}; // 有效时长

        mutable std::unordered_map<Endpoint, CookieData, EndpointHash> cookieIndex{}; // 保存每个站点的cookie
        mutable std::mutex secret_lock_; ///< 保护密钥的互斥锁
    public:
        /**
         * @brief 构造函数 - 初始化为全零状态
         */
        explicit CookieChecker(const ContentKey &content_key);

        CookieData getCookie(const Endpoint &endpoint);

        /**
         * 获取 cookie 但不自动生成
         *
         * @param endpoint 站点
         */
        std::unique_ptr<CookieData> getCookieNoMake(const Endpoint &endpoint) const;

        /**
         * @brief 计算 MAC1
         *
         * 用途：计算消息的 MAC1（使用 MAC1 字段为零的状态）
         * 公式：MAC1 = BLAKE2s(message[0..len-16], Key=MAC1_Key)
         *
         * @param msg 握手消息
         * @return
         */
        static MacData computeMac1(const MessageInitiation &msg, const PublicKey &public_key);
        static MacData computeMac1(const MessageResponse & msg, const PrivateKey &public_key);

        CookieData computeMac2(const MessageInitiation &msg, const Endpoint &endpoint);

        /**
         * 给消息添加mac2
         * @param endpoint 针对的端点
         * @param response 握手响应消息
         */
        void messageAddMac2(const Endpoint &endpoint, MessageResponse &response);


        static CookieData computeMac2(const MessageInitiation &msg, const CookieData &cookie_data);

        static CookieData computeMac2(const MessageResponse &msg, const CookieData &last_cookie);

        /**
         * @brief 创建 Cookie Reply 消息（类型 3）
         */
        MessageCookie createCookieReply(const MessageInitiation &msg, const Endpoint &endpoint, const PublicKey &public_key);

        /**
         * @return 判断cookie密钥是否有效
         */
        bool verifySecretValid() const;

        /**
         * 服务端 握手请求验证 mac1
         * @param msg
         * @param sendPointPublicKey
         * @return
         */
        static void verifyMac1(const MessageInitiation &msg, const PublicKey &sendPointPublicKey);

        static void verifyMac1(const MessageResponse & msg, const PrivateKey &public_key);

        static void verifyMac2(const MessageInitiation &msg, const CookieData &last_received_cookie);

        static void verifyMac2(const MessageResponse &msg, const CookieData &last_received_cookie);

    private:
        /**
         * 使用安全随机数填充哈希密钥
         */
        void fillSecretHash2SecureRandom();

        CookieData makeCookie(const Endpoint &endpoint) const;
    };

    namespace cookie {
        bool isEmpty(const CookieData &cookie);

        bool isEmpty(const uint8_t *mac);
    } // namespace cookie
}; // namespace WireGuard

#endif // WIREGUARD_COOKIE_H
