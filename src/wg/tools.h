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
// Created on 2026/3/25.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".
#pragma once
#ifndef WIREGUARD_TOOLS_H
#define WIREGUARD_TOOLS_H

#include "allowedips.h"
#include "entity.h"
#include <cstddef>
#include <cstdint>
#include <string>
#include "version.h"

namespace WireGuard {
    namespace Tools {
        std::string ipv4_to_string(uint32_t ipv4);

        std::string ipv4_to_string(const uint8_t *ipv4);

        std::string ipv6_to_string(const uint8_t ipv6[16]);

        std::string printStr(const IPAddress ip);


        /**
         * @brief 获取当前时间（纳秒级）
         *
         * @return uint64_t 从系统启动开始的纳秒数
         *
         * 用途：用于密钥对的创建时间戳
         */
        uint64_t getCurrentTimeNs();


        /**
         * @brief 生成 TAI64N 格式的时间戳
         *
         * 用途：生成用于防重放攻击的时间戳
         * TAI64N = 64 位 TAI 时间 + 32 位纳秒
         *
         * @param timestamp 输出的时间戳（12 字节）
         *
         * 时间格式说明：
         * - TAI（International Atomic Time）：国际原子时
         * - Unix epoch 偏移：+10 秒（TAI-UTC offset as of 2024: 37 leap seconds）
         * - 大端格式存储（网络字节序）
         */
        void tai64nNow(Timestamp & timestamp);


        PacketHeader readPacketEndpoint(const uint8_t *p, const size_t len);

        Nonce makeNonce(uint64_t counter);

        namespace IP {
            /**
             * @brief 计算两个 IP 地址的公共前缀位数
             *
             * 算法说明：
             * - 逐字节异或，找到第一个不同的位
             * - 统计高位连续 0 的个数
             */
            uint8_t commonBits(const uint8_t *ip1, const uint8_t *ip2, size_t len);

            /**
             * @brief 检查 IP 是否匹配节点的 CIDR 前缀
             *
             * 原理：
             * - 计算两个 IP 的公共前缀位数
             * - 如果 >= node->cidr，说明前 node->cidr 位相同
             */
            bool prefixMatches(const TrieNode *node, const uint8_t *ip);

            Endpoint makeEndpointIpv4(const std::string &ip, const uint16_t &port);
        }; // namespace IP
        bool isEmpty(const uint8_t * str, size_t size);
    }; // namespace Tools
}; // namespace WireGuard

#endif // WIREGUARD_TOOLS_H