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

// Created on 2026/3/24.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef WIREGUARD_ENTITY_H
#define WIREGUARD_ENTITY_H

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <vector>
#include <string>
#include "version.h"

/**
 * 这个文件定义公共使用的 结构体或者数据类
 */
namespace WireGuard {
    // ============ 常量定义 ============
    constexpr size_t WG_KEY_LEN = 32;
    constexpr size_t PUBLIC_KEY_LEN = 32;
    constexpr size_t PRIVATE_KEY_LEN = 32;
    constexpr size_t SYMMETRIC_KEY_LEN = 32;
    constexpr size_t TIMESTAMP_LEN = 12;
    constexpr size_t HASH_LEN = 32;
    constexpr size_t AUTHTAG_LEN = 16;
    constexpr size_t COOKIE_LEN = 16;
    constexpr size_t NONCE_LEN = 24;
    constexpr size_t COOKIE_NONCE_LEN = 12;
    constexpr size_t BLAKE2S_BLOCK_SIZE = 64;
    constexpr size_t BLAKE2S_HASH_SIZE = 32;

    constexpr int TUN_READ_BUFFER_SIZE = 65535; // 65kb
    // tun读取硬错误（非EAGAIN/EINTR）判定：必须"窗口内连续达到阈值"才判定fd失效并退出线程。
    // 只看次数会把网络切换等瞬时EIO/ENETDOWN误判为fd失效，白白杀掉本可自愈的读取线程。
    constexpr int32_t TUN_READ_ERROR_EXIT_THRESHOLD = 50;
    constexpr int64_t TUN_READ_ERROR_WINDOW_MS = 1000; // 1秒内连续50次硬错误才判定fd失效

    // tun读取线程连续重启失败上限：fd真失效时重启线程无法恢复（重启的是同一个坏fd），
    // 达上限后不再空转重启，改为主动向上层上报失效信号（见TUN_DEAD_NOTIFY_INTERVAL_MS）
    constexpr int32_t TUN_RESTART_MAX_FAILS = 3;

    // tun fd失效信号向上层重发的间隔（毫秒）。
    // fd失效后UDP keepalive/握手照常收发、流日志心跳持续刷新，上层既有的
    // "进程消失"与"数据心跳超时"两条判据全部失明，必须由本信号兜底触发恢复。
    // 限频重发而非只发一次：上报时刻上层可能正处在恢复流程中（信号会被丢弃），
    // 周期性重发保证恢复链路最终一定能被触发；60s 远低于用户可感知的"断网"阈值。
    constexpr int64_t TUN_DEAD_NOTIFY_INTERVAL_MS = 60 * 1000;

    constexpr uint64_t REKEY_AFTER_MESSAGES = 1ULL << 60; // 表示最大发送的消息数量，超过需要重新握手或者更新密钥
    constexpr uint64_t RECEIVING_WINDOW_LEN = 8192ULL; // 接收的重放计数器中，window的长度
    constexpr uint64_t REJECT_AFTER_MESSAGES = UINT64_MAX - RECEIVING_WINDOW_LEN - 1;
    // 时间常量（纳秒）
    constexpr uint64_t REKEY_TIMEOUT = 5000000000ULL; // 5 秒
    constexpr uint64_t REKEY_AFTER_TIME = 120000000000ULL; // 120 秒
    constexpr uint64_t REJECT_AFTER_TIME = 180000000000ULL; // 180 秒
    constexpr uint64_t KEEPALIVE_TIMEOUT = 10000000000ULL; // 10 秒

    // 看门狗：持续发送中但超过该时长未收到任何远端数据，判定通路故障，触发 Socket 重建
    constexpr int64_t WATCHDOG_RECV_TIMEOUT_MS = 90000; // 90 秒
    // 连续发送失败次数达到该阈值时，触发 Socket 重建
    constexpr int32_t SEND_FAIL_REBUILD_THRESHOLD = 8;
    // 发送失败"静默重建"的升级窗口（毫秒）。
    // 达到 SEND_FAIL_REBUILD_THRESHOLD 时先做静默重建（不发布 SOCKET_REBUILT 哨兵）：
    // 承载切换场景下上层已有 P0-b 快速通道，抢先发布哨兵只会让上层白做一次域名重解析
    // （真机实测：native 早于承载检测 4 秒发哨兵，触发了一次无用的自愈流程）。
    // 只有当"距上次成功发送"超过本窗口仍持续失败时，才判定为真故障并升级为故障上报。
    // 取值需大于上层承载切换检测耗时（通常 1~5 秒），10 秒留足余量。
    constexpr int64_t SEND_FAIL_ESCALATE_MS = 10000; // 10 秒
    // 两次 Socket 重建请求之间的最小间隔（防抖，避免异常场景下频繁重建）
    constexpr int64_t WATCHDOG_REBUILD_MIN_INTERVAL_MS = 15000; // 15 秒

    // 承载切换（WiFi↔蜂窝）后快速重建 Socket 的最小间隔（防抖）。
    // 弱信号下系统可能在两种承载间反复抖动，若每次都重建会引入额外握手流量与抖动，
    // 故限制同向 3 秒内只重建一次；该防抖独立于 WATCHDOG_REBUILD_MIN_INTERVAL_MS
    // （后者服务于"故障判定"语义，间隔更长）。
    constexpr int64_t CARRIER_REBIND_MIN_INTERVAL_MS = 3000; // 3 秒

    // 发送失败"静默重建"的最小间隔（毫秒）。
    // 与请求哨兵重建的 WATCHDOG_REBUILD_MIN_INTERVAL_MS（15 秒）相互独立：
    // 静默重建要足够快（承载切换后立刻自愈），又不能无限频发，故另设较短间隔；
    // 二者独立可使"静默重建 → 持续失败 → 升级上报"不被对方的防抖挡住。
    constexpr int64_t QUIET_REBUILD_MIN_INTERVAL_MS = 3000; // 3 秒

    // 承载切换会话内的看门狗接收超时（毫秒）。
    // 网络切换后若"重建 Socket + 强制重握手"仍未恢复，说明问题不只是本地 fd：
    // 此时不应再等 90 秒才进入探针阶段，改用短阈值把兜底路径压缩到 15s+15s。
    // 首个有效接收到达后自动恢复为 WATCHDOG_RECV_TIMEOUT_MS（仅在切换窗口内加速，
    // 不影响健康空闲隧道的正常判据）。
    constexpr int64_t WATCHDOG_SWITCH_RECV_TIMEOUT_MS = 15000; // 15 秒

    // 域名解析超时（毫秒）。
    // getaddrinfo 本身无超时参数，域名服务器不可达/丢包时会阻塞很久（历史实测 5 分 8 秒），
    // 由于该调用位于 VEA 主线程（同步 NAPI），会把整个串行重连链一起饿死。
    // 这里给解析加硬上限，超时即快速失败，把"最长数分钟"压到"最长数秒"。
    constexpr int32_t DNS_RESOLVE_TIMEOUT_MS = 5000; // 5 秒

    // "peer 未准备好"期间，由 TUN 数据路径触发握手的节流间隔（毫秒）。
    // 背景（真机实证）：换网导致 peer 迟迟握不上手时，每个出站数据包都会走
    // consumeTunData 的"未准备好"分支去发握手；而 REKEY_TIMEOUT(5s) 内的重复请求
    // 必被速率限制拒绝（抛"创建太频繁"），于是变成纯粹的无效调用 + 日志刷屏
    // （实测 8 秒 320 条），既淹掉真正有用的日志，也空转 CPU。
    // 数据包本身不丢（仍全部入队），仅把"握手尝试 + 日志"节流到本间隔一次。
    constexpr int64_t PEER_NOT_READY_THROTTLE_MS = 1000; // 1 秒

    /**
     * 消息类型
     * WireGuard 协议规范
     * 消息类型（WireGuard 协议定义）
     * 参考：RFC 9047 - WireGuard: A Modern Secure Network Tunnel Protocol
     * 所有 WireGuard 消息都以 32 位的消息类型开头，采用小端字节序
     */
    enum class MessageType : uint8_t {
        // 无效消息类型，用于初始化或错误处理
        INVALID = 0,

        /** 握手发起消息（Handshake Initiation）
         * 用途：当客户端想要建立新的 WireGuard 会话时发送的第一个消息
         * 方向：发起方 -> 响应方
         * 包含内容：
         *   - senderIndex（4 字节）：发起方选择的临时索引，用于标识此会话
         *   - unencryptedMac（16 字节）：未加密的 MAC，用于速率限制和 DoS 防护
         *   - encryptedStaticPublic（32 字节 + 16 字节）：加密的静态公钥
         *   - encryptedTimestamp（12 字节 + 16 字节）：加密的时间戳（防止重放攻击）
         *   - mac1（16 字节）：基于 Cookie 的 MAC，用于验证发起方的 IP 地址
         *   - mac2（16 字节）：预留字段，目前固定为 0
         * 说明：这是 WireGuard 握手协议的第一步，用于安全地交换身份信息和建立共享密钥
         * */
        HANDSHAKE_INITIATION = 1,

        /**
         * 握手响应消息（Handshake Response）
         * 用途：响应收到的 Handshake Initiation 消息，完成握手过程
         * 方向：响应方 -> 发起方
         * 包含内容：
         *   - senderIndex（4 字节）：响应方选择的临时索引
         *   - receiverIndex（4 字节）：复制自 Initiation 消息的 senderIndex
         *   - unencryptedMac（16 字节）：未加密的 MAC
         *   - encryptedStaticPublic（32 字节 + 16 字节）：加密的静态公钥（可选）
         *   - encryptedNothing（0 字节 + 16 字节）：加密的空数据（仅用于填充）
         *   - mac1（16 字节）：基于 Cookie 的 MAC
         *   - mac2（16 字节）：预留字段
         * 说明：收到此消息后，双方都已拥有足够的信息来派生会话密钥，可以开始加密通信
         */
        HANDSHAKE_RESPONSE = 2,
        /**
         * Cookie 响应消息（Handshake Cookie）
         * 用途：用于防止 DoS 攻击的 Cookie 机制，当服务器负载过高时触发
         * 方向：响应方 -> 发起方
         * 场景：
         *   - 当服务器在短时间内收到大量握手请求时，会要求客户端先解决 Cookie 挑战
         *   - 客户端需要在下一次握手请求中包含有效的 Cookie
         * 包含内容：
         *   - receiverIndex（4 字节）：复制自 Initiation 消息的 senderIndex
         *   - nonce（24 字节）：用于 ChaCha20 加密的 Nonce
         *   - encryptedCookie（16 字节 + 16 字节）：加密的 Cookie 值
         * 说明：
         *   - Cookie 是服务器基于客户端 IP 地址生成的一个秘密值
         *   - 有效期为 2 分钟
         *   - 用于验证客户端 IP 地址的真实性，防止 IP 欺骗攻击
         */
        HANDSHAKE_COOKIE = 3,

        /**
         * 数据传输消息（Data）
         * 用途：传输加密的 IP 数据包（IPv4 或 IPv6）
         * 方向：双向（发起方 <-> 响应方）
         * 包含内容：
         *   - keyIndex（4 字节）：接收方密钥对的索引，用于快速查找解密所需的密钥
         *   - counter（8 字节）：单调递增的计数器，用于防止重放攻击
         *   - encryptedData（变长）：加密的 IP 数据包 + 16 字节的认证标签
         * 特点：
         *   - 最小尺寸：4 + 8 + 20 + 16 = 48 字节（空 IP 数据包）
         *   - 最大尺寸：65535 字节的 IP 数据包 + 28 字节的头部和尾部
         *   - 支持 Keepalive：通过发送空的加密数据包来保持连接活跃
         * 说明：这是 WireGuard 隧道中实际传输数据的消息格式，所有上层协议数据都封装在此消息中
         */
        DATA = 4
    };

    enum PacketIpType : uint32_t {
        IPV4 = 4,
        IPV6 = 6,
    };


    // ============ 基础数据结构 ============
    using WGKey = std::array<uint8_t, WG_KEY_LEN>;
    using PublicKey = std::array<uint8_t, PUBLIC_KEY_LEN>;
    using PrivateKey = std::array<uint8_t, PRIVATE_KEY_LEN>;
    using SymmetricKey = std::array<uint8_t, SYMMETRIC_KEY_LEN>;
    using Timestamp = std::array<uint8_t, TIMESTAMP_LEN>;
    using Hash = std::array<uint8_t, HASH_LEN>;
    using ChainKey = std::array<uint8_t, HASH_LEN>;
    using Nonce = std::array<uint8_t, NONCE_LEN>;
    using CookieData = std::array<uint8_t, COOKIE_LEN>; // Cookie 数据类型
    using CookieNonce = std::array<uint8_t, COOKIE_NONCE_LEN>; // Cookie Nonce 类型
    using MacData = std::array<uint8_t, COOKIE_LEN>; // MAC 数据类型

    using Clock = std::chrono::system_clock;
    using TimePoint = Clock::time_point;

    struct Key32Hash {
        size_t operator()(const std::array<uint8_t, 32> &arr) const {
            size_t result = 0;
            for (size_t i = 0; i < arr.size(); ++i) {
                result = result * 31 + arr[i];
            }
            return result;
        }
    };

    /**
     * ip地址
     * 全部按照网络字节序大端序存储 uint32_t 的值（即右边是高位，左边是低位）
     * ipv6值转换时，右边第一位是0，所以debug时，顺序又是对的
     * 类如：
     * 存入ip 10.0.0.0
     * uint32_t 记录 197386 转hex为 0x0003030A
     * ipv6 显示 "\n\U00000003\U00000003\0\xa0\U0000000e+\x9a\U0000007f\0\0\0\xd0aE\xf3"
     */
    struct IPAddress {
        enum Family { IPv4, IPv6 } family = IPv4;

        union {
            uint32_t ipv4;
            uint8_t ipv6[16];
        } ip;

        bool operator==(const IPAddress &other) const;

        std::string toIpStr() const;

        /**
         *
         * @return 输出IP 16 进制字符串
         */
        std::string toIpHex() const;
    };

    // 端点
    struct Endpoint {
        IPAddress address;
        uint16_t port = 0;

        bool operator==(const Endpoint &other) const { return address == other.address && port == other.port; }

        std::string toIpStr() const {
            return address.toIpStr() + ":" + std::to_string(port);
        }
    };

    struct IPAddressHash {
        size_t operator()(const IPAddress &addr) const {
            if (addr.family == IPAddress::IPv4) {
                // IPv4: hash the 32-bit value
                return std::hash<uint32_t>{}(addr.ip.ipv4);
            } else {
                size_t h = 0;
                for (const unsigned char i: addr.ip.ipv6) {
                    h = h * 31 + i;
                }
                return h;
            }
        }
    };

    struct EndpointHash {
        size_t operator()(const Endpoint &ep) const {
            const size_t h1 = IPAddressHash{}(ep.address);
            const size_t h2 = std::hash<uint16_t>{}(ep.port);
            // return h1 ^ (h2 << 1); // 或者 h1 * 31 + h2
            return h1 * 31 + h2;
        }
    };


    /**
     * 地址区域，有掩码
     */
    struct IpAddressArea {
        IPAddress address;
        int cidr = -1; // -1表示没有掩码

        std::string toIpStr() const {
            if (cidr >= 0) {
                return address.toIpStr() + "/" + std::to_string(cidr);
            }
            if (address.family == IPAddress::IPv4) {
                return address.toIpStr() + "/32";
            }
            return address.toIpStr() + "/128";
        }
    };

    constexpr uint8_t IPv4HeaderLen = 20;
    constexpr uint8_t IPv4offsetTotalLength = 2;
    constexpr uint8_t IPv4offsetSrc = 12;
    constexpr uint8_t IPv4offsetDst = IPv4offsetSrc + 4;

    constexpr uint8_t IPv6offsetPayloadLength = 4;
    constexpr uint8_t IPv6offsetSrc = 8;
    constexpr uint8_t IPv6offsetDst = IPv6offsetSrc + 16;

    /**
     * 数据包头，用于获取请求地址和源地址ip
     */
    struct PacketHeader {
        Endpoint src;
        Endpoint dst;

    public:
        std::string toIpLog() const;
    };

    // 可空值使用 shared 可以支持多次start启动，防止空指针
    struct PeerConfig {
        PublicKey public_key{};
        Endpoint endpoint{};
        std::vector<IpAddressArea> allowedIps{};
        std::shared_ptr<SymmetricKey> pre_share_key{}; // 预共享密钥。可选，用于提升安全性
        uint32_t keepaliveInterval{25}; // 我们默认是需要心跳包的
    };


    struct DeviceConfig {
        std::string device_name;
        PrivateKey private_key{};
        std::shared_ptr<uint32_t> listener_port{nullptr}; // 监听端口默认没有，这样socket可以随机选择一个端口进行绑定
        std::shared_ptr<IPAddress> bind_address{nullptr};
        std::vector<std::string> excludedApplications; // 排除的应用包名列表
        std::vector<std::string> includedApplications; // 包含的应用包名列表
    };

    /**
     * 设备链接配置
     */
    struct DeviceRegisterConfig {
        DeviceConfig client{};
        std::vector<PeerConfig> peers{};
    };


    // 数据包回调
    using PacketCallback = std::function<void(const uint8_t *data, size_t len, const PublicKey &peerPublicKey)>;


    struct ContentKey {
        PrivateKey local_private_key{};
        PublicKey local_public_key{};
        /**
         * @param private_key 本地私钥，根据发送端和接收端不同
         */
        explicit ContentKey(const PrivateKey &private_key);
    };
} // namespace WireGuard
#endif // WIREGUARD_ENTITY_H
