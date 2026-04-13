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
#include "version.h"

namespace WireGuard {
    // ========== Cookie 相关常量 ==========
    //    constexpr size_t COOKIE_LEN = 16;               // Cookie 长度（字节）
    //    constexpr size_t COOKIE_NONCE_LEN = 24;         // Cookie 加密使用的 nonce 长度
    constexpr uint64_t COOKIE_SECRET_MAX_AGE = 120; // Cookie 密钥最大有效期（秒）
    constexpr uint64_t COOKIE_SECRET_LATENCY = 5; // Cookie 密钥延迟时间（秒）
    /**
     * @brief Cookie 管理器 - 管理单个 Peer 的 Cookie 状态
     *
     * 每个 Peer 对象维护一个 Cookie 实例，用于：
     * 1. 保存从对端收到的有效 Cookie
     * 2. 管理 Cookie 的生命周期（有效期检查）
     * 3. 保存用于计算 MAC1/MAC2 的密钥
     * 4. 保存最近发送的 MAC1（用于解密 Cookie Reply）
     *
     * 线程安全：所有公共方法都是线程安全的
     */
    class Cookie {
    public:
        /**
         * @brief 构造函数 - 初始化为全零状态
         */
        Cookie();

        /**
         * @brief 获取 Cookie 的创建时间
         * @return Cookie 创建时间点
         */
        std::chrono::steady_clock::time_point getBirthdate() const;

        /**
         * @brief 检查 Cookie 是否有效
         * @return true 如果 Cookie 存在且未过期
         */
        bool isValid() const;

        /**
         * @brief 获取存储的 Cookie 值
         * @return Cookie 数据（16 字节）
         */
        const CookieData &getCookie() const;

        /**
         * @brief 设置新的 Cookie 值
         * @param newCookie 新的 Cookie 数据
         */
        void setCookie(const CookieData &newCookie);

        /**
         * @brief 标记已发送 MAC1 并保存
         * @param mac1 计算出的 MAC1 值
         */
        void markMac1Sent(const MacData &mac1);

        /**
         * @brief 检查是否有已发送的 MAC1
         * @return true 如果已保存 MAC1
         */
        bool hasSentMac1() const;

        /**
         * @brief 获取最后发送的 MAC1
         * @return 最后发送的 MAC1 值
         */
        const MacData &getLastMac1Sent() const;

        /**
         * @brief 设置 Cookie 解密密钥
         * @param key 32 字节的解密密钥
         */
        void setDecryptionKey(const SymmetricKey &key);

        /**
         * @brief 获取 Cookie 解密密钥
         * @return 32 字节的解密密钥
         */
        const SymmetricKey &getDecryptionKey() const;

        /**
         * @brief 设置 MAC1 计算密钥
         * @param key 32 字节的 MAC1 密钥
         */
        void setMac1Key(const SymmetricKey &key);

        /**
         * @brief 获取 MAC1 计算密钥
         * @return 32 字节的 MAC1 密钥
         */
        const SymmetricKey &getMac1Key() const;

    private:
        std::chrono::steady_clock::time_point birthdate_; ///< Cookie 创建时间
        bool is_valid_ = false; ///< Cookie 是否有效标志
        CookieData cookie_{}; ///< 存储的 Cookie 值
        bool have_sent_mac1_ = false; ///< 是否已发送 MAC1
        MacData last_mac1_sent_{}; ///< 最后发送的 MAC1 值
        SymmetricKey cookie_decryption_key_{}; ///< Cookie 解密密钥
        SymmetricKey message_mac1_key_{}; ///< MAC1 计算密钥
        mutable std::mutex lock_; ///< 互斥锁保护并发访问
    };


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
    public:
        /**
         * @brief 构造函数 - 初始化为全零状态
         */
        CookieChecker(const PublicKey &device_public_key);

        /**
         * @brief 初始化 CookieChecker
         *
         * 用途：从设备公钥派生 MAC1 密钥和 Cookie 加密密钥
         * 这是设备启动时必须调用的初始化函数
         *
         * @param device_public_key 设备的静态公钥（32 字节）
         * @return true 如果初始化成功
         */
        bool init(const PublicKey &device_public_key);

        /**
         * @brief 验证数据包中的 MAC
         *
         * 用途：作为服务端，验证收到的数据包中的 MAC1 和 MAC2
         *
         * @param message 数据包内容指针
         * @param len 数据包总长度
         * @param check_cookie 是否检查 MAC2（true=需要验证 Cookie）
         * @param source_ip 源 IP 地址（4 字节 IPv4 或 16 字节 IPv6）
         * @param source_port 源端口（网络字节序）
         * @param is_ipv6 是否为 IPv6 地址
         * @return CookieMacState 验证状态
         */
        CookieMacState validatePacket(const uint8_t *message, size_t len, bool check_cookie, const uint8_t *source_ip,
                                      uint16_t source_port, bool is_ipv6 = false);

        /**
         * @brief 为数据包添加 MAC1 和 MAC2
         *
         * 用途：作为客户端，为发送的数据包计算并添加 MAC
         *
         * @param message 数据包缓冲区（末尾预留 32 字节给 MACs）
         * @param len 数据包总长度（包括 MACs 的空间）
         * @param peer_cookie Peer 的 Cookie 对象引用
         */
        void addMacToPacket(uint8_t *message, size_t len, Cookie &peer_cookie);

        /**
         * @brief 创建 Cookie Reply 消息（类型 3）
         *
         * 用途：当收到没有有效 MAC2 的握手请求时，生成 Cookie Reply
         *
         * @param out_message 输出的 Cookie Reply 消息结构
         * @param received_mac1 收到的 MAC1 值（作为附加数据）
         * @param source_ip 源 IP 地址
         * @param source_port 源端口
         * @param receiver_index 接收者索引（来自 Initiation 的 sender_index）
         * @param is_ipv6 是否为 IPv6
         */
        void createCookieReply(MessageCookie &out_message, const MacData &received_mac1, const uint8_t *source_ip,
                               uint16_t source_port, uint32_t receiver_index, bool is_ipv6 = false);

        /**
         * @brief 处理收到的 Cookie Reply 消息
         *
         * 用途：作为客户端，解密并保存服务端返回的 Cookie
         *
         * @param msg 收到的 Cookie Reply 消息
         * @param peer_cookie Peer 的 Cookie 对象引用
         * @return true 如果解密成功并保存
         */
        bool consumeCookieReply(const MessageCookie &msg, Cookie &peer_cookie);

    private:
        /**
         * @brief 预计算设备密钥
         *
         * 用途：从设备公钥派生 MAC1 密钥和 Cookie 加密密钥
         *
         * @param public_key 设备公钥
         */
        void precomputeKeys(const PublicKey &public_key);

        /**
         * @brief 生成 Cookie
         *
         * 用途：基于源 IP 和端口生成唯一的 Cookie
         * 公式：Cookie = BLAKE2s(IP + Port, Key=Secret)
         *
         * @param out_cookie 输出的 Cookie
         * @param source_ip 源 IP 地址
         * @param source_port 源端口
         * @param is_ipv6 是否为 IPv6
         */
        void makeCookie(CookieData &out_cookie, const uint8_t *source_ip, uint16_t source_port, bool is_ipv6);

        /**
         * @brief 计算 MAC1
         *
         * 用途：计算消息的 MAC1（使用 MAC1 字段为零的状态）
         * 公式：MAC1 = BLAKE2s(message[0..len-16], Key=MAC1_Key)
         *
         * @param out_mac1 输出的 MAC1
         * @param message 完整消息指针
         * @param len 消息总长度
         * @param key MAC1 密钥
         */
        void computeMac1(MacData &out_mac1, const uint8_t *message, size_t len, const SymmetricKey &key);

        /**
         * @brief 计算 MAC2
         *
         * 用途：计算消息的 MAC2（使用 Cookie 作为密钥）
         * 公式：MAC2 = BLAKE2s(message[0..len-16], Key=Cookies)
         *
         * @param out_mac2 输出的 MAC2
         * @param message 完整消息指针
         * @param len 消息总长度
         * @param cookie_key Cookie 值（用作密钥）
         */
        void computeMac2(MacData &out_mac2, const uint8_t *message, size_t len, const CookieData &cookie_key);

        // ========== 成员变量 ==========
        const PublicKey &device_public_key; // 用于计算的设备公钥
        Hash secret_; ///< 主密钥（随机生成，每 2 分钟轮换）
        SymmetricKey cookie_encryption_key_; ///< Cookie 加密密钥（从设备公钥派生）
        SymmetricKey message_mac1_key_; ///< MAC1 计算密钥（从设备公钥派生）
        std::chrono::steady_clock::time_point secret_birthdate_; ///< Secret 创建时间
        bool initialized_ = false; ///< 是否已初始化
        mutable std::mutex secret_lock_; ///< 保护密钥的互斥锁
    };


    class CookieManager {
    private:
    public:
        CookieData mac1{0};
        CookieData mac2{0};
        /**
         * 客户端 生成mac1
         * @param msg
         * @param key
         * @return
         */
        CookieData makeAndGetMac1(const MessageInitiation msg, const SymmetricKey &key);

        /**
         * 服务端 握手请求验证 mac1
         * @param msg
         * @param key
         * @return
         */
        bool verifyMac1(const MessageInitiation *msg, const SymmetricKey key);
    };

    namespace cookie {
        CookieData computeMac(const MessageInitiation msg, const SymmetricKey &key);

        bool isEmpty(const CookieData &cookie);

        bool isEmpty(const uint8_t *mac);
    } // namespace cookie
}; // namespace WireGuard

#endif // WIREGUARD_COOKIE_H