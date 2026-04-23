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

#include "entity.h"

#ifdef _WIN32
#include <ws2tcpip.h>
#else
#include <sys/socket.h>
#include <netdb.h>
#include <arpa/inet.h>
#endif

namespace WireGuard {
    namespace DNS {
        IPAddress readDomainToIp(const std::string &domain) {
            addrinfo hints{};
            addrinfo *result = nullptr;

            hints.ai_family = AF_UNSPEC;
            hints.ai_socktype = SOCK_STREAM;
            hints.ai_protocol = IPPROTO_TCP;

            const int iResult = getaddrinfo(domain.c_str(), nullptr, &hints, &result);
            if (iResult != 0) {
                throw std::runtime_error("get addrinfo failed: " + std::string(gai_strerror(iResult)));
            }

            IPAddress ipAddress{};

            for (auto ptr = result; ptr != nullptr; ptr = ptr->ai_next) {
                if (ptr->ai_family == AF_INET) {
                    const auto ipv4 = reinterpret_cast<struct sockaddr_in *>(ptr->ai_addr);
                    ipAddress.family = IPAddress::IPv4;
                    ipAddress.ip.ipv4 = ipv4->sin_addr.s_addr;
                    break;
                } else if (ptr->ai_family == AF_INET6) {
                    auto ipv6 = reinterpret_cast<struct sockaddr_in6 *>(ptr->ai_addr);
                    ipAddress.family = IPAddress::IPv6;
                    memcpy(ipAddress.ip.ipv6, ipv6->sin6_addr.s6_addr, sizeof(ipAddress.ip.ipv6));
                    break;
                }
            }

            freeaddrinfo(result);

            return ipAddress;
        }
    }
} // WireGuardTools