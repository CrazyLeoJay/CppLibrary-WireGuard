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
 */

/**
 * Created by Leojay on 2026/4/22.
 *
 * @author leojay`fu
 * @email crazyleojay@163.com
 * @url https://github.com/CrazyLeoJay
 */

#include "wg_dns.h"
#include <stdexcept>
#include <cstring>
#include <chrono>
#include <vector>

#include "entity.h"
#include "WGException.h"

#ifdef _WIN32
#include <ws2tcpip.h>
#else
#include <sys/socket.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <sys/time.h>
#endif

namespace WireGuard {
    namespace DNS {
        namespace {
            /**
             * 跳过RR中的Name字段：标签长度前缀逐段跳过；
             * 压缩指针（高两位为11）固定占2字节
             */
            bool skipDnsName(const std::vector<uint8_t> &buf, size_t &off) {
                while (off < buf.size()) {
                    const uint8_t len = buf[off];
                    if (len == 0) {
                        off += 1;
                        return true;
                    }
                    if ((len & 0xC0) != 0) {
                        if (off + 2 > buf.size()) {
                            return false;
                        }
                        off += 2;
                        return true;
                    }
                    off += len + 1;
                }
                return false;
            }
        } // namespace
    } // DNS
} // WireGuard

namespace WireGuard {
    namespace DNS {
        IPAddress readDomainToIp(const std::string &domain, const IPType &type) {
            addrinfo hints{};
            addrinfo *result = nullptr;

            if (type == IPV4) {
                hints.ai_family = AF_INET;
            } else {
                hints.ai_family = AF_INET6;
            }
            // hints.ai_family = AF_UNSPEC; // 所有类型

            hints.ai_socktype = SOCK_STREAM;
            hints.ai_protocol = IPPROTO_TCP;

            const int iResult = getaddrinfo(domain.c_str(), nullptr, &hints, &result);
            if (iResult != 0) {
                throw std::runtime_error("域名解析失败: " + std::string(gai_strerror(iResult)));
            }

            IPAddress ipAddress{};

            for (auto ptr = result; ptr != nullptr; ptr = ptr->ai_next) {
                if (ptr->ai_family == AF_INET) {
                    const auto ipv4 = reinterpret_cast<struct sockaddr_in *>(ptr->ai_addr);
                    ipAddress.family = IPAddress::IPv4;
                    ipAddress.ip.ipv4 = ipv4->sin_addr.s_addr;
                    break;
                } else if (ptr->ai_family == AF_INET6) {
                    const auto ipv6 = reinterpret_cast<struct sockaddr_in6 *>(ptr->ai_addr);
                    ipAddress.family = IPAddress::IPv6;
                    memcpy(ipAddress.ip.ipv6, ipv6->sin6_addr.s6_addr, sizeof(ipAddress.ip.ipv6));
                    break;
                }
            }

            freeaddrinfo(result);

            return ipAddress;
        }

        IPAddress readDomainToIpPreferIpv4(const std::string &domain) {
            addrinfo hints{};
            addrinfo *result = nullptr;
            hints.ai_family = AF_UNSPEC;
            hints.ai_socktype = SOCK_STREAM;
            hints.ai_protocol = IPPROTO_TCP;

            const int iResult = getaddrinfo(domain.c_str(), nullptr, &hints, &result);
            if (iResult != 0) {
                throw std::runtime_error("域名解析失败: " + std::string(gai_strerror(iResult)));
            }

            IPAddress ipAddress{};
            IPAddress ipv6Address{};
            bool foundIpv6 = false;

            for (auto ptr = result; ptr != nullptr; ptr = ptr->ai_next) {
                if (ptr->ai_family == AF_INET) {
                    const auto ipv4 = reinterpret_cast<struct sockaddr_in *>(ptr->ai_addr);
                    ipAddress.family = IPAddress::IPv4;
                    ipAddress.ip.ipv4 = ipv4->sin_addr.s_addr;
                    freeaddrinfo(result);
                    return ipAddress;
                } else if (ptr->ai_family == AF_INET6 && !foundIpv6) {
                    const auto ipv6 = reinterpret_cast<struct sockaddr_in6 *>(ptr->ai_addr);
                    ipv6Address.family = IPAddress::IPv6;
                    memcpy(ipv6Address.ip.ipv6, ipv6->sin6_addr.s6_addr, sizeof(ipv6Address.ip.ipv6));
                    foundIpv6 = true;
                }
            }

            freeaddrinfo(result);

            if (foundIpv6) {
                return ipv6Address;
            }

            throw std::runtime_error("域名解析失败: 未找到可用的IP地址");
        }

        std::vector<IPAddress> readDomainToIpAll(const std::string &domain) {
            addrinfo hints{};
            addrinfo *result = nullptr;
            hints.ai_family = AF_UNSPEC; // 所有类型
            hints.ai_socktype = SOCK_STREAM;
            hints.ai_protocol = IPPROTO_TCP;

            const int iResult = getaddrinfo(domain.c_str(), nullptr, &hints, &result);
            if (iResult != 0) {
                throw std::runtime_error("域名解析失败: " + std::string(gai_strerror(iResult)));
            }

            std::vector<IPAddress> addresses{};
            for (auto ptr = result; ptr != nullptr; ptr = ptr->ai_next) {
                if (ptr->ai_family == AF_INET) {
                    IPAddress ipAddress{};
                    const auto ipv4 = reinterpret_cast<struct sockaddr_in *>(ptr->ai_addr);
                    ipAddress.family = IPAddress::IPv4;
                    ipAddress.ip.ipv4 = ipv4->sin_addr.s_addr;
                    addresses.push_back(ipAddress);
                } else if (ptr->ai_family == AF_INET6) {
                    IPAddress ipAddress{};
                    const auto ipv6 = reinterpret_cast<struct sockaddr_in6 *>(ptr->ai_addr);
                    ipAddress.family = IPAddress::IPv6;
                    memcpy(ipAddress.ip.ipv6, ipv6->sin6_addr.s6_addr, sizeof(ipAddress.ip.ipv6));
                    addresses.push_back(ipAddress);
                }
            }

            freeaddrinfo(result);
            return addresses;
        }

        std::vector<uint8_t> buildDnsQuery(const uint16_t queryId, const std::string &domain, const uint16_t qtype) {
            std::vector<uint8_t> query;
            query.reserve(12 + domain.size() + 2 + 4 + 4);
            // Header：ID，FLAGS(RD=1)，QDCOUNT=1，ANCOUNT/NSCOUNT/ARCOUNT=0
            query.push_back(static_cast<uint8_t>(queryId >> 8));
            query.push_back(static_cast<uint8_t>(queryId & 0xFF));
            query.push_back(0x01);
            query.push_back(0x00);
            query.push_back(0x00);
            query.push_back(0x01);
            query.push_back(0x00);
            query.push_back(0x00);
            query.push_back(0x00);
            query.push_back(0x00);
            query.push_back(0x00);
            query.push_back(0x00);
            // QNAME：标签长度前缀
            std::string label;
            for (size_t i = 0; i <= domain.size(); ++i) {
                if (i == domain.size() || domain[i] == '.') {
                    if (!label.empty()) {
                        query.push_back(static_cast<uint8_t>(label.size()));
                        query.insert(query.end(), label.begin(), label.end());
                        label.clear();
                    }
                } else {
                    label += domain[i];
                }
            }
            query.push_back(0x00); // QNAME结束符
            // QTYPE / QCLASS=IN
            query.push_back(static_cast<uint8_t>(qtype >> 8));
            query.push_back(static_cast<uint8_t>(qtype & 0xFF));
            query.push_back(0x00);
            query.push_back(0x01);
            return query;
        }

        bool parseDnsResponse(const std::vector<uint8_t> &response, const uint16_t queryId, const uint16_t qtype,
                              IPAddress &out) {
            if (response.size() < 12) {
                return false;
            }
            const auto rd16 = [&response](const size_t off) -> uint16_t {
                if (off + 2 > response.size()) {
                    return 0;
                }
                return static_cast<uint16_t>((response[off] << 8) | response[off + 1]);
            };
            if (rd16(0) != queryId) {
                return false; // 事务ID不匹配
            }
            if ((rd16(2) & 0x8000) == 0) {
                return false; // QR=0，不是响应
            }
            if ((rd16(2) & 0x000F) != 0) {
                return false; // RCODE非0（NXDOMAIN等）
            }
            const uint16_t qdCount = rd16(4);
            const uint16_t anCount = rd16(6);

            size_t off = 12;
            // 跳过Question段
            for (uint16_t q = 0; q < qdCount; ++q) {
                if (!skipDnsName(response, off)) {
                    return false;
                }
                off += 4; // QTYPE + QCLASS
            }
            // 遍历Answer记录，取第一条匹配qtype的
            for (uint16_t a = 0; a < anCount; ++a) {
                if (!skipDnsName(response, off)) {
                    return false;
                }
                if (off + 10 > response.size()) {
                    return false;
                }
                const uint16_t type = rd16(off);
                const uint16_t rdLength = rd16(off + 8);
                off += 10; // TYPE(2) CLASS(2) TTL(4) RDLENGTH(2)
                if (off + rdLength > response.size()) {
                    return false;
                }
                if (type == qtype && qtype == 1 && rdLength == 4) {
                    out.family = IPAddress::IPv4;
                    memcpy(&out.ip.ipv4, &response[off], 4); // 网络字节序，与sin_addr一致
                    return true;
                }
                if (type == qtype && qtype == 28 && rdLength == 16) {
                    out.family = IPAddress::IPv6;
                    memcpy(out.ip.ipv6, &response[off], 16);
                    return true;
                }
                off += rdLength; // CNAME等其他记录，继续找下一条
            }
            return false;
        }

        IPAddress readDomainToIpFromDnsServer(const std::string &domain, const IPType &type,
                                              const std::string &dnsServer) {
            const uint16_t qtype = (type == IPV4) ? 1 : 28;
            const auto queryId = static_cast<uint16_t>(
                std::chrono::steady_clock::now().time_since_epoch().count() & 0xFFFF);
            const std::vector<uint8_t> query = buildDnsQuery(queryId, domain, qtype);

            addrinfo hints{};
            hints.ai_family = AF_INET; // DNS服务器地址按IPv4处理
            hints.ai_socktype = SOCK_DGRAM;
            addrinfo *serverAddr = nullptr;
            if (getaddrinfo(dnsServer.c_str(), "53", &hints, &serverAddr) != 0 || serverAddr == nullptr) {
                throw WGException("DNS服务器地址解析失败: %s", dnsServer.c_str());
            }

            IPAddress out{};
            bool got = false;
            const int fd = socket(AF_INET, SOCK_DGRAM, 0);
            if (fd >= 0) {
                timeval tv{};
                tv.tv_sec = 2; // 单次等待2秒
                tv.tv_usec = 0;
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
                // 重试一次，防单包丢失
                for (int attempt = 0; attempt < 2 && !got; ++attempt) {
                    if (sendto(fd, query.data(), static_cast<size_t>(query.size()), 0,
                               serverAddr->ai_addr, serverAddr->ai_addrlen) ==
                        static_cast<ssize_t>(query.size())) {
                        uint8_t resp[1500];
                        const ssize_t n = recv(fd, resp, sizeof(resp), 0);
                        if (n > 12) {
                            const std::vector<uint8_t> respVec(resp, resp + n);
                            got = parseDnsResponse(respVec, queryId, qtype, out);
                        }
                    }
                }
                ::close(fd);
            }
            freeaddrinfo(serverAddr);
            if (!got) {
                throw WGException("DNS服务器%s未返回%s记录", dnsServer.c_str(), type == IPV4 ? "A" : "AAAA");
            }
            return out;
        }
    }
} // WireGuardTools
