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

#include "tools.h"
#include "WGException.h"
#include <arpa/inet.h>
#include <cstddef>
#include <cstdint>
#include <cstdint>

namespace WireGuard {
    namespace Tools {
        std::string ipv4_to_string(uint32_t ipv4) {
            char buf[INET_ADDRSTRLEN]; // 至少 16 字节
            // 注意：网络字节序！通常 ipv4 是大端（network byte order）
            // 如果你的 uint32_t 是主机字节序，需先转为网络序
            // 假设输入是网络字节序（如从 socket 获取）
            if (inet_ntop(AF_INET, &ipv4, buf, INET_ADDRSTRLEN)) {
                return std::string(buf);
            }
            return ""; // 转换失败
        }

        std::string ipv4_to_string(const uint8_t *ipv4) {
            char buf[INET_ADDRSTRLEN]; // 至少 16 字节
            // 注意：网络字节序！通常 ipv4 是大端（network byte order）
            // 如果你的 uint32_t 是主机字节序，需先转为网络序
            // 假设输入是网络字节序（如从 socket 获取）
            if (inet_ntop(AF_INET, ipv4, buf, INET_ADDRSTRLEN)) {
                return std::string(buf);
            }
            return ""; // 转换失败
        }

        std::string ipv6_to_string(const uint8_t ipv6[16]) {
            char buf[INET6_ADDRSTRLEN]; // 至少 40 字节
            if (inet_ntop(AF_INET6, ipv6, buf, INET6_ADDRSTRLEN)) {
                return std::string(buf);
            }
            return "";
        }

        std::string printStr(const IPAddress ip) {
            switch (ip.family) {
                case IPAddress::IPv4:
                    return ipv4_to_string(ip.ip.ipv4);
                case IPAddress::IPv6:
                    return ipv6_to_string(ip.ip.ipv6);
                default:
                    break;
            }
            return "";
        }


        /**
         * @brief 获取当前时间（纳秒级）
         *
         * @return uint64_t 从系统启动开始的纳秒数
         *
         * 用途：用于密钥对的创建时间戳
         */
        uint64_t getCurrentTimeNs() {
            auto now = std::chrono::steady_clock::now();
            auto duration = now.time_since_epoch();
            return std::chrono::duration_cast<std::chrono::nanoseconds>(duration).count();
        }


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
        void tai64nNow(Timestamp &timestamp) {
            // TAI64N 格式：64 位 TAI 时间 + 32 位纳秒
            auto now = std::chrono::system_clock::now();
            auto epoch = now.time_since_epoch();
            auto seconds = std::chrono::duration_cast<std::chrono::seconds>(epoch).count();
            auto nanos = std::chrono::duration_cast<std::chrono::nanoseconds>(epoch).count() % 1000000000;

            // TAI offset from Unix epoch (10 + 37 leap seconds as of 2024)
            // 10 seconds initial offset + 37 leap seconds = 47 seconds total
            uint64_t taiSeconds = static_cast<uint64_t>(seconds) + 10ULL + 37ULL;

            // 写入大端格式（网络字节序）
            for (int i = 7; i >= 0; --i) {
                timestamp[i] = taiSeconds & 0xFF;
                taiSeconds >>= 8;
            }
            for (int i = 3; i >= 0; --i) {
                timestamp[8 + i] = (nanos >> ((3 - i) * 8)) & 0xFF;
            }
        }


        PacketHeader readPacketEndpoint(const uint8_t *p, const size_t len) {
            uint8_t ver = (p[0] >> 4) & 0x0F;
            PacketHeader ph{};
            if (ver == 4) {
                // ipv4 头最小20
                if (len < IPv4HeaderLen) {
                    throw WGException("不是合法的Ipv4包");
                }
                // 获取从第2字节开始的两个字节，作为 uint16_t（小端）
                const uint16_t field = *reinterpret_cast<const uint16_t *>(p + IPv4offsetTotalLength);
                const uint16_t length = ntohs(field);
                if (length > len || length < IPv4HeaderLen) {
                    throw WGException("Ipv4包不完整， 数据长度大于数据包总大小，或者小于20。len=%d", length);
                }
                const uint32_t srcIp = *reinterpret_cast<const uint32_t *>(p + IPv4offsetSrc);
                const uint32_t dstIp = *reinterpret_cast<const uint32_t *>(p + IPv4offsetDst);
                // 这里保存的是小端序
                ph.src.address.ip.ipv4 = srcIp;
                ph.dst.address.ip.ipv4 = dstIp;
                ph.src.address.family = IPAddress::IPv4;
                ph.dst.address.family = IPAddress::IPv4;
                return ph;
            } else if (ver == 6) {
                if (len <= (sizeof(IPv6Hdr))) {
                    throw WGException("不是合法的Ipv6包");
                }

                const uint16_t field = *reinterpret_cast<const uint16_t *>(p + IPv6offsetPayloadLength);
                const uint16_t length = ntohs(field);
                if (length > len) {
                    throw WGException("Ipv6包不完整， 数据长度大于数据包总大小。len=%d", length);
                }

                std::memcpy(ph.src.address.ip.ipv6, p + IPv6offsetSrc, 16);
                std::memcpy(ph.dst.address.ip.ipv6, p + IPv6offsetDst, 16);
                ph.src.address.family = IPAddress::IPv6;
                ph.dst.address.family = IPAddress::IPv6;
                return ph;
            } else {
                throw WGException("未知IP协议包 Ipv%d", ver);
            }
        }

        Nonce makeNonce(uint64_t counter) {
            Nonce nonce{0};
            // 前4字节已由 {} 初始化为0
            // 手动转为小端序（适用于任意平台）
            nonce[4] = static_cast<uint8_t>(counter >> 0);
            nonce[5] = static_cast<uint8_t>(counter >> 8);
            nonce[6] = static_cast<uint8_t>(counter >> 16);
            nonce[7] = static_cast<uint8_t>(counter >> 24);
            nonce[8] = static_cast<uint8_t>(counter >> 32);
            nonce[9] = static_cast<uint8_t>(counter >> 40);
            nonce[10] = static_cast<uint8_t>(counter >> 48);
            nonce[11] = static_cast<uint8_t>(counter >> 56);
            return nonce;
        }

        namespace IP {
            /**
             * @brief 计算两个 IP 地址的公共前缀位数
             *
             * 算法说明：
             * - 逐字节异或，找到第一个不同的位
             * - 统计高位连续 0 的个数
             */
            uint8_t commonBits(const uint8_t *ip1, const uint8_t *ip2, size_t len) {
                uint8_t count = 0;

                for (size_t i = 0; i < len && count < len * 8; ++i) {
                    uint8_t xored = ip1[i] ^ ip2[i];

                    if (xored == 0) {
                        // 该字节完全相同，继续下一个
                        count += 8;
                    } else {
                        // 找到不同位，计算高位连续 0 的个数
                        while ((xored & 0x80) == 0) {
                            count++;
                            xored <<= 1; // 左移检查下一位
                        }
                        break;
                    }
                }

                return count;
            }

            /**
             * @brief 检查 IP 是否匹配节点的 CIDR 前缀
             *
             * 原理：
             * - 计算两个 IP 的公共前缀位数
             * - 如果 >= node->cidr，说明前 node->cidr 位相同
             */
            bool prefixMatches(const TrieNode *node, const uint8_t *ip) {
                if (!node || node->bits.empty()) {
                    return false;
                }

                size_t len = node->bits.size();
                uint8_t common = commonBits(node->bits.data(), ip, len);

                return common >= node->cidr;
            }


            Endpoint makeEndpointIpv4(const std::string &ip, const uint16_t &port) {
                Endpoint ep{};
                ep.address.family = IPAddress::IPv4;
                inet_pton(AF_INET, ip.c_str(), &ep.address.ip.ipv4);
                ep.port = htons(port);
                return ep;
            }
        }; // namespace IP
    }; // namespace Tools
}; // namespace WireGuard