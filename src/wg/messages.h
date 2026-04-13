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
// Created on 2026/3/20.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef WIREGUARD_MESSAGES_H
#define WIREGUARD_MESSAGES_H

#include <cstdint>
#include "entity.h"
#include "version.h"

/**
 * @namespace WireGuard
 * @brief WireGuard协议相关的消息定义和处理函数
 *
 * WireGuard是一种现代、安全、高效的VPN协议，使用加密隧道保护网络通信。
 * 本文件定义了WireGuard协议中使用的各种消息格式和验证函数。
 */
namespace WireGuard {
    //
    //    // ==================== 消息类型定义 ====================
    //    // WireGuard协议定义了4种不同类型的消息，每种消息都有特定的用途
    //
    //    /**
    //     * @brief 握手初始化消息类型
    //     *
    //     * 当客户端想要与服务器建立安全连接时，首先发送此消息。
    //     * 这是Noise_IK握手协议的第一步，包含发起方的临时公钥。
    //     */
    //    constexpr uint8_t MESSAGE_TYPE_HANDSHAKE_INITIATION = 1;
    //
    //    /**
    //     * @brief 握手响应消息类型
    //     *
    //     * 服务器收到握手初始化消息后，回复此消息。
    //     * 这是Noise_IK握手协议的第二步，包含响应方的临时公钥。
    //     */
    //    constexpr uint8_t MESSAGE_TYPE_HANDSHAKE_RESPONSE = 2;
    //
    //    /**
    //     * @brief Cookie回复消息类型
    //     *
    //     * 用于DoS防护机制。当检测到潜在的DoS攻击时，
    //     * 服务器会要求客户端提供一个有效的Cookie来证明其合法性。
    //     */
    //    constexpr uint8_t MESSAGE_TYPE_COOKIE_REPLY = 3;
    //
    //    /**
    //     * @brief 传输数据消息类型
    //     *
    //     * 握手完成后，所有加密的用户数据都通过此消息类型传输。
    //     * 这是最常见的消息类型，承载实际的网络流量。
    //     */
    //    constexpr uint8_t MESSAGE_TYPE_TRANSPORT_DATA = 4;
    //
    //    // ==================== 消息大小限制 ====================
    //
    //    /**
    //     * @brief 最大消息大小（64KB）
    //     *
    //     * WireGuard消息的最大长度限制，防止内存溢出攻击。
    //     * 实际应用中，大多数消息远小于此限制。
    //     */
    //    constexpr size_t MAX_MESSAGE_SIZE = 65536;
    //
    //    /**
    //     * @brief 最小消息大小（32字节）
    //     *
    //     * WireGuard消息的最小长度，确保消息至少包含基本的头部信息。
    //     * 小于此长度的消息被视为无效。
    //     */
    //    constexpr size_t MIN_MESSAGE_SIZE = 32;
    //
    //    // ==================== 消息结构体定义 ====================
    //
    //    /**
    //     * @brief 握手初始化消息结构
    //     *
    //     * 这是WireGuard握手过程的第一条消息，由发起方（通常是客户端）发送。
    //     * 包含以下关键组件：
    //     * - 发起方的索引（用于快速查找对等体）
    //     * - 发起方的临时公钥（用于密钥交换）
    //     * - 加密的静态公钥（用于身份验证）
    //     * - 加密的时间戳（防止重放攻击）
    //     * - 两个MAC值（用于DoS防护）
    //     */
    //    struct HandshakeInitiation {
    //        uint8_t type;                                  ///< 消息类型，应为 MESSAGE_TYPE_HANDSHAKE_INITIATION (1)
    //        uint8_t reserved[3];                           ///< 保留字段，必须为0，用于对齐
    //        std::array<uint8_t, 32> sender_index;          ///< 发送方索引，32字节，用于快速查找对等体
    //        std::array<uint8_t, 32> unencrypted_ephemeral; ///< 未加密的临时公钥，32字节，Curve25519公钥
    //        std::array<uint8_t, 48> encrypted_static; ///< 加密的静态公钥，48字节（32字节数据+16字节认证标签）
    //        std::array<uint8_t, 48> encrypted_timestamp; ///< 加密的时间戳，48字节（12字节时间戳+32字节填充+16字节认证标签）
    //        std::array<uint8_t, 16> mac1; ///< MAC1，16字节，用于DoS防护的第一层验证
    //        std::array<uint8_t, 16> mac2; ///< MAC2，16字节，用于DoS防护的第二层验证（包含Cookie）
    //    };
    //
    //    /**
    //     * @brief 握手响应消息结构
    //     *
    //     * 这是WireGuard握手过程的第二条消息，由响应方（通常是服务器）发送。
    //     * 包含以下关键组件：
    //     * - 响应方的索引和接收方的索引
    //     * - 响应方的临时公钥
    //     * - 空加密数据（用于完成密钥交换）
    //     * - MAC值（用于DoS防护）
    //     */
    //    struct HandshakeResponse {
    //        uint8_t type;                                  ///< 消息类型，应为 MESSAGE_TYPE_HANDSHAKE_RESPONSE (2)
    //        uint8_t reserved[3];                           ///< 保留字段，必须为0，用于对齐
    //        std::array<uint8_t, 32> sender_index;          ///< 发送方索引，32字节
    //        std::array<uint8_t, 32> receiver_index;        ///< 接收方索引，32字节
    //        std::array<uint8_t, 32> unencrypted_ephemeral; ///< 未加密的临时公钥，32字节
    //        std::array<uint8_t, 48> encrypted_nothing; ///< 加密的空数据，48字节（16字节零填充+32字节填充+16字节认证标签）
    //        std::array<uint8_t, 16> mac; ///< MAC，16字节，用于DoS防护
    //    };
    //
    //    /**
    //     * @brief Cookie回复消息结构
    //     *
    //     * 当服务器检测到潜在的DoS攻击时，会向客户端发送Cookie挑战。
    //     * 客户端需要回复此消息来证明其合法性。
    //     */
    //    struct CookieReply {
    //        uint8_t type;                           ///< 消息类型，应为 MESSAGE_TYPE_COOKIE_REPLY (3)
    //        uint8_t reserved[3];                    ///< 保留字段，必须为0，用于对齐
    //        std::array<uint8_t, 32> receiver_index; ///< 接收方索引，32字节
    //        uint8_t nonce[24];                      ///< 随机数，24字节，用于加密Cookie
    //        std::array<uint8_t, 48> encrypted_cookie; ///< 加密的Cookie，48字节（16字节Cookie+32字节填充+16字节认证标签）
    //    };
    //
    //    /**
    //     * @brief 传输数据消息结构
    //     *
    //     * 握手完成后，所有用户数据都通过此消息传输。
    //     * 数据被加密并带有序列号以防止重放攻击。
    //     */
    //    struct TransportData {
    //        uint8_t type;                           ///< 消息类型，应为 MESSAGE_TYPE_TRANSPORT_DATA (4)
    //        uint8_t reserved[3];                    ///< 保留字段，必须为0，用于对齐
    //        std::array<uint8_t, 32> receiver_index; ///< 接收方索引，32字节
    //        uint64_t counter;         ///< 序列号，8字节，用于防止重放攻击和确保数据包顺序
    //        uint8_t encrypted_data[]; ///< 加密的用户数据，可变长度，实际数据在此字段之后
    //    };
    //

    // 消息头结构
#pragma pack(push, 1)
    struct MessageHeader {
        uint8_t type; // little-endian
    };

    /**
     * @brief Initiation 握手消息（类型 1，148 字节）
     *
     * 用途：发起方发送的第一个握手消息
     * 包含：临时公钥、加密的静态公钥、加密的时间戳
     *
     * 结构说明：
     * - header: 消息类型（HANDSHAKE_INITIATION）
     * - senderIndex: 发起方选择的临时索引（用于标识会话）
     * - ephemeral: 临时公钥（32 字节，明文）
     * - encryptedStatic: 加密的静态公钥（32 字节 + 16 字节认证标签）
     * - encryptedTimestamp: 加密的时间戳（12 字节 + 16 字节认证标签）
     * - mac1: 基于 Cookie 的 MAC（16 字节，防 DoS）
     * - mac2: 预留字段（16 字节，目前固定为 0）
     */
    struct MessageInitiation {
        MessageHeader header = {static_cast<uint8_t>(MessageType::HANDSHAKE_INITIATION)};
        uint8_t reserved_zero[3]{0};
        uint32_t senderIndex = 0;
        uint8_t ephemeral[PUBLIC_KEY_LEN]{};
        uint8_t encryptedStatic[PUBLIC_KEY_LEN + AUTHTAG_LEN]{};
        uint8_t encryptedTimestamp[TIMESTAMP_LEN + AUTHTAG_LEN]{};
        uint8_t mac1[COOKIE_LEN]{};
        uint8_t mac2[COOKIE_LEN]{};
    };

    /**
     * @brief Response 握手消息（类型 2，92 字节）
     *
     * 用途：响应方发送的第二个握手消息
     * 包含：临时公钥、空加密数据（仅填充）
     *
     * 结构说明：
     * - header: 消息类型（HANDSHAKE_RESPONSE）
     * - senderIndex: 响应方选择的临时索引
     * - receiverIndex: 复制自 Initiation 的 senderIndex（用于关联会话）
     * - ephemeral: 临时公钥（32 字节，明文）
     * - encryptedNothing: 空加密（0 字节 + 16 字节认证标签，仅填充）
     * - mac1: 基于 Cookie 的 MAC（16 字节）
     * - mac2: 预留字段（16 字节）
     */
    struct MessageResponse {
        MessageHeader header = {static_cast<uint8_t>(MessageType::HANDSHAKE_RESPONSE)};
        uint8_t reserved_zero[3]{0};
        uint32_t senderIndex = 0;
        uint32_t receiverIndex = 0;
        uint8_t ephemeral[PUBLIC_KEY_LEN]{};
        uint8_t encryptedNothing[AUTHTAG_LEN]{};
        uint8_t mac1[COOKIE_LEN]{};
        uint8_t mac2[COOKIE_LEN]{};
    };


    /**
     * @brief Cookie 握手消息（类型 3，64 字节）
     *
     * 用途：用于防止 DoS 攻击的 Cookie 机制
     * 当服务器负载过高时，要求客户端先解决 Cookie 挑战
     *
     * 结构说明：
     * - header: 消息类型（HANDSHAKE_COOKIE）
     * - receiverIndex: 复制自 Initiation 的 senderIndex
     * - nonce: ChaCha20 加密的 Nonce（24 字节）
     * - encryptedCookie: 加密的 Cookie 值（16 字节 + 16 字节认证标签）
     */
    struct MessageCookie {
        MessageHeader header = {static_cast<uint8_t>(MessageType::HANDSHAKE_COOKIE)};
        uint8_t reserved_zero[3]{0};
        uint32_t receiverIndex = 0;
        uint8_t nonce[NONCE_LEN]{};
        uint8_t encryptedCookie[COOKIE_LEN + AUTHTAG_LEN]{};
    };

    /**
     * 客户端-->服务端 Cookie Request（请求 Cookie）
     */
    struct MessageCookieRequest {
        MessageHeader header = {static_cast<uint8_t>(MessageType::HANDSHAKE_COOKIE)}; // ← Type=3
        uint8_t reserved_zero[3]{0};
        uint8_t reserved = 0;
        uint32_t receiverIndex{}; // 接收方的索引
    };

    // 总大小：8 字节（非常简单）

    /**
     * 服务端-->客户端 Cookie Reply（回复 Cookie）
     */
    struct MessageCookieReply {
        MessageHeader header = {static_cast<uint8_t>(MessageType::HANDSHAKE_COOKIE)}; // ← 也是 Type=3
        uint8_t reserved_zero[3]{0};
        uint8_t reserved = 0;
        uint32_t receiverIndex{}; // 接收方的索引
        uint8_t nonce[24]{}; // ChaCha20 的 nonce
        uint8_t encryptedCookie[16 + 16]{}; // 加密的 Cookie + MAC
    };

    // 总大小：56 字节

    /**
     * @brief Data 数据传输消息（类型 4，变长）
     *
     * 用途：传输加密的 IP 数据包
     *
     * 结构说明：
     * - header: 消息类型（DATA）
     * - keyIndex: 接收方密钥对的索引（用于快速查找解密密钥）
     * - counter: 单调递增计数器（8 字节，防重放攻击）
     * - encryptedData: 加密的数据负载（变长，包含 16 字节认证标签）
     */
    struct MessageData {
        MessageHeader header = {static_cast<uint8_t>(MessageType::DATA)};
        uint8_t reserved_zero[3]{0};
        uint32_t keyIndex = 0;
        uint64_t counter = 0;
        uint8_t encryptedData[];
    };


    struct IPv4Hdr {
        uint8_t ver_ihl;
        uint8_t _[9];
        uint32_t src, dst;
    };

    struct IPv6Hdr {
        uint32_t _;
        uint8_t src[16];
        uint8_t dst[16];
    };

    struct Ports {
        uint16_t src, dst;
    };
#pragma pack(pop)
} // namespace WireGuard

#endif // WIREGUARD_MESSAGES_H