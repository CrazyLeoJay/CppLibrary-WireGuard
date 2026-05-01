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
