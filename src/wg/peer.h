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
// Created on 2026/3/18.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef WIREGUARD_PEER_H
#define WIREGUARD_PEER_H

#include "WGException.h"
#include "cookie.h"
#include "crypto/nonce2.h"
#include "keypair.h"
#include "entity.h"
#include <queue>
#include "version.h"

namespace WireGuard {
    /**
     * @brief Peer 类 - 管理单个 WireGuard 对等体的所有状态和操作
     *
     * Peer 是 WireGuard 协议的核心组件，每个 Peer 代表一个远程的 WireGuard 节点。
     * 主要职责：
     * 1. 维护与远程节点的握手状态
     * 2. 管理多个密钥对（当前、下一个、历史）
     * 3. 加密和解密数据包
     * 4. 维护连接状态（端点、保活、超时）
     * 5. 管理待发送的数据包队列
     */
    class Peer {
    public:
        Peer(const DeviceConfig &clientConfig, const PeerConfig &config);

        virtual ~Peer();

    protected:
        const DeviceConfig &clientConfig;
        const PeerConfig &config;

        bool initialized = false;
        mutable std::mutex handshakeMutex_;
        mutable std::mutex mutex_;
        Endpoint endpoint;

        // ========== 握手和密钥管理 ==========
        // T noise;        // 当前握手状态机
        crypto2::NOISESend noiseSend{}; // 发送端 noise协议
        crypto2::NOISEReceive noiseReceive{}; // 接收端 Noise

        KeyPairs keyPairs_; // 密钥对管理器（当前、下一个、历史密钥对）


        // ========== 时间戳（用于超时和保活检测） ==========
        // 这里会给一些时间的初始值减去一些时间，防止因为时间戳，导致初始信息无法发出
        TimePoint lastSentHandshake_{Clock::now() - std::chrono::seconds(30)}; // 最后一次发送握手消息的时间
        TimePoint lastReceivedHandshake_{Clock::now() - std::chrono::seconds(30)}; // 最后一次接收握手消息的时间
        TimePoint lastDataSent_{Clock::now()}; // 最后一次发送数据的时间
        TimePoint lastDataReceived_{Clock::now()}; // 最后一次接收数据的时间
        TimePoint lastKeepaliveSent_{Clock::now() - std::chrono::seconds(100)}; // 最后一次发送 Keepalive 的时间

        // ========== 状态标志 ==========
        std::atomic<int> handshakeAttempts_{0}; // 握手尝试次数（原子操作）

        // ========== 统计信息 ==========
        uint64_t txBytes_ = 0; // 累计发送字节数
        uint64_t rxBytes_ = 0; // 累计接收字节数

        // ========== 数据包队列 ==========
        std::queue<std::vector<uint8_t> > stagedPackets_; // 等待握手完成后发送的数据包队列

        // ========== Cookie管理 ==========
        CookieManager cookieManager;

    public:
        void init();

        // 发送端
        /**
         * @brief 创建握手 Initiation 消息（主动发起连接）
         *
         * 用途：作为发起方时，创建第一个握手消息发送给远程 Peer
         * 这是 WireGuard 握手的第一个消息（类型 1）
         *
         * 使用clientConfig 获取本地公钥和私钥
         * @return bool 成功返回 true，失败返回 false
         */
        MessageInitiation createHandshakeInitiation(const uint32_t &senderIndex);

        /**
         * 验证握手响应是否合法 不合法会抛出异常需要处理
         *
         * @param msg 握手消息
         * @Throw
         */
        void verifyHandshakeInitiationResponse(const MessageResponse &msg);

    public:
        // 接收端
        /**
         * 作为服务端时，远程客户端发来握手请求进行处理。
         * 验证并解密 Initiation 消息，提取远程节点的静态公钥
         *
         * @param msg 握手信息
         * @param clientConfig 本地客户端配置
         * @return 是否匹配
         */
        bool handleHandshakeInitiation(const MessageInitiation &msg);

        /**
         * @brief 创建握手 Response 消息（响应远程节点）
         *
         * @param msg 输出的 Response 消息结构
         * @return bool 成功返回 true，失败返回 false
         */
        MessageResponse createHandshakeResponse(const uint32_t &senderIndex);

    public:
        PublicKey getPublicKey() const { return config.public_key; }

        std::vector<IPAddress> getAllowedIps() const { return config.allowedIps; }

        /**
         * @brief 获取 Peer 的网络端点
         *
         * @return Endpoint 当前端点
         */
        Endpoint getEndpoint() const;

        void updateEndpoint(Endpoint ep);

        /**
         * 是否可以发送数据
         * @param iAmInitiator 是否为发起者
         * @return 是否可以发送数据
         */
        bool isCanSendData(const bool &iAmInitiator);

        /**
         * 更新发送心跳包的时间为当前时间
         */
        void updateHeartbeatPacketSendTime();

        /**
         * @return  返回还需要等待的心跳时间
         */
        std::chrono::milliseconds heartbeatPacketSendWaitTime();

        /**
         * 加密数据包为要发送的数据 并且打包为 MessageData 格式
         *
         * @param data 数据
         * @param len 长度
         */
        std::vector<uint8_t> encryptPacketToMessageData(const uint8_t *data, const size_t &len);

        /**
         * @brief 解密数据包
         *
         * 用途：使用当前或历史密钥对解密接收到的 IP 数据包
         * 这是 WireGuard 数据平面（Data Plane）的核心操作
         *
         * 变化时机和条件：
         * - 每次接收数据时调用
         * - 验证认证标签（Poly1305 MAC）
         * - 检查重放攻击（counter 必须递增）
         * - 更新 lastDataReceived_ 时间戳
         * - 如果使用"下一个"密钥成功解密，触发 promoteNextKeypair()
         *
         * 失败场景：
         * - 无有效密钥对
         * - 密钥对接收方向失效
         * - 认证标签验证失败（数据被篡改）
         * - Counter 重复或过期（重放攻击）
         */
        std::vector<uint8_t> decryptPacket(const MessageData *msg, const size_t &len) const;

        /**
         * @brief 开始会话（生成密钥对）
         *
         * 用途：握手完成后，从握手状态机派生出会话密钥对
         * 这是 WireGuard 协议的核心输出，用于后续的数据加密/解密
         *
         * @param iAmInitiator true 表示己方是发起方，false 表示响应方
         * @return std::shared_ptr<Keypair> 生成的密钥对
         *
         * 变化时机和条件：
         * - 握手成功完成后（收到 Response 或发送 Response 后）
         * - 根据角色（发起方/响应方）确定密钥的发送/接收方向
         * - 密钥对包含：发送密钥、接收密钥、密钥索引、创建时间
         */
        std::shared_ptr<KeyPair> beginSession(const bool &iAmInitiator);

        /**
         * @brief 设置新的当前密钥对
         *
         * 用途：将握手生成的新密钥对设置为当前使用密钥
         *
         * @param kp 新的密钥对
         *
         * 变化时机和条件：
         * - 握手完成后立即调用
         * - 替换旧的当前密钥对（但不删除，保留用于解密旧数据）
         * - 开始使用新密钥加密发送数据
         */
        void setCurrentKeypair(std::shared_ptr<KeyPair> kp);


        /**
         * @brief 更新接收统计
         *
         * 用途：累加接收字节数，更新最后接收时间
         * 用于流量统计和超时检测
         *
         * @param bytes 接收的字节数
         *
         * 变化时机和条件：
         * - 每次成功接收并解密数据包后调用
         * - rxBytes_ 累加
         * - lastDataReceived_ 更新时间戳
         */
        void addRxBytes(uint64_t bytes);

        /**
         * @brief 更新发送统计
         *
         * 用途：累加发送字节数，更新最后发送时间
         * 用于流量统计和超时检测
         *
         * @param bytes 发送的字节数
         *
         * 变化时机和条件：
         * - 每次成功发送数据包后调用
         * - txBytes_ 累加
         * - lastDataSent_ 更新时间戳
         */
        void addTxBytes(uint64_t bytes);

        uint64_t getTxBytes() const { return txBytes_; } // 获取累计发送字节数
        uint64_t getRxBytes() const { return rxBytes_; } // 获取累计接收字节数


        /**
         * @brief 检查是否需要重新握手
         *
         * 用途：判断当前密钥对是否过期，需要发起新的握手
         *
         * 变化时机和条件（满足任一即返回 true）：
         * - 无当前密钥对（kp == nullptr）
         * - 密钥对发送方向失效（!kp->sending.isValid）
         * - 发送数据量超过阈值（REKEY_AFTER_MESSAGES = 2^60）
         * - 密钥对创建时间超过阈值（REKEY_AFTER_TIME = 120 秒）
         * 
         *  @throw 需要重新握手，没有抛出则不需要
         */
        void needsReKey();

        /**
         * @brief 获取当前使用的密钥对
         *
         * 用途：获取用于当前数据加密/解密的密钥对
         * WireGuard 支持多个密钥对同时存在（平滑切换）
         *
         * @return std::shared_ptr<Keypair> 当前密钥对，如果无有效密钥返回 nullptr
         *
         * 变化时机：
         * - 会话建立后返回新生成的密钥对
         * - 密钥对过期后可能返回 nullptr 或历史密钥对
         */
        std::shared_ptr<KeyPair> getCurrentKeypair() const;

        /**
         * @brief 添加待发送的数据包（握手未完成时的缓存）
         *
         * 用途：在握手完成前缓存需要发送的数据包
         * 避免数据丢失，等待握手完成后批量发送
         *
         * @param packet 要缓存的数据包
         *
         * 变化时机和条件：
         * - 需要发送数据但无有效密钥对时
         * - 正在握手过程中
         * - 数据包进入 stagedPackets_ 队列等待
         */
        void queuePacket(std::vector<uint8_t> packet);

        /**
         * @brief 获取并清空待发送的数据包
         *
         * 用途：握手完成后，取出所有缓存的数据包发送
         *
         * @return std::queue<std::vector<uint8_t>> 所有待发送的数据包
         *
         * 变化时机和条件：
         * - 握手成功完成后立即调用
         * - 清空 stagedPackets_ 队列
         * - 返回的队列包含所有等待的数据包
         */
        std::queue<std::vector<uint8_t> > consumeStagedPackets();

        /**
         * 验证握手消息的cookie
         * @param msg
         * @return
         * @Throw
         */
        void verifyHandshakeInitiationCookie(const MessageInitiation *msg);

        /**
         * 解密Cookie
         * @param cookie
         */
        void decryptCookie(const MessageCookie *cookie);

        void clear();
    };


    /**
     * @brief Trie 树节点 - 用于 AllowedIPs 路由表
     *
     * 设置默认的根节点 cidr =255 特殊标记
     * 由于 0.0.0.0/0(00000000 0 0 0 ）
     *  和 128.0.0.0 (10000000 0 0 0）
     * 会冲突，这两个节点应该是评级，所以设置要给虚拟点，为父节点，但不参与查询
     *  和 192.0.0.0 (11000000 0 0 0）
     *
     *
     * 实现前缀树（Trie）结构，支持高效的最长前缀匹配查找
     * 每个节点代表一个 IP 前缀，叶子节点或中间节点可以关联到 Peer
     */
    struct TrieNode {
        std::weak_ptr<Peer> peer; ///< 关联的 Peer 弱引用（避免循环引用）
        mutable std::unique_ptr<TrieNode> child[2]; ///< 左右子节点（0 和 1）
        uint32_t cidr = 0; ///< 前缀长度（CIDR 值，如 /24, /32）
        std::vector<uint8_t> bits{}; ///< IP 地址的二进制表示

        /**
         * @brief 默认构造函数
         */
        TrieNode() {
            child[0] = nullptr;
            child[1] = nullptr;
        }

        /**
         * @brief 获取指定 IP 在当前节点的位值（0 或 1）
         *
         * 实际计算的是 当前节点的 child未知， 计算下一位
         * 例如：当前是 192.168.1.1/24
         *      那么根据cird = 24
         *      bitAtByte = 24/8 = 3
         *      bitAtShift = 7 - 24%8 = 7
         *      此方法计算的值为ip的第 3 位（第四个）字节的 第一个（右移动7位，则取左边第1位），即第25位（下标24）的值
         *
         *
         * @param ip IP 地址二进制数组
         * @return uint8_t 位值（0 或 1）
         */
        uint8_t chooseBit(const uint8_t *ip, const size_t len) const {
            if (isRoot()) {
                return 0;
            }
            uint8_t bitAtByte = cidr / 8; ///< 当前位所在的字节索引（0-15）
            uint8_t bitAtShift = 7 - (cidr % 8); ///< 位在字节中的偏移（0-7）
            if (bitAtByte > len) {
                throw WGException("掩码过大！cidr=%d ipLen=%d", cidr, len);
            }
            if (bitAtByte == len)
                return 0;
            return (ip[bitAtByte] >> bitAtShift) & 1;
        }

        /**
         * 判断是否为根节点
         */
        bool isRoot() const { return cidr == 255; }

        /**
         * 设置当前节点为根节点
         * @param family
         */
        void setRoot(IPAddress::Family family) {
            peer = {};
            child[0] = nullptr;
            child[1] = nullptr;
            cidr = 255;

            if (family == IPAddress::IPv4) {
                bits.reserve(4);
                bits.assign(4, 0);
            } else {
                bits.reserve(16);
                bits.assign(16, 0);
            }
        }
    };
} // namespace WireGuard

#endif // WIREGUARD_PEER_H