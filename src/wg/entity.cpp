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
// Created on 2026/4/2.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#include "entity.h"
#include "crypto/crypto.h"
#include "tools.h"
#include <arpa/inet.h>

namespace WireGuard {
    bool WireGuard::IPAddress::operator==(const IPAddress &other) const {
        if (family != other.family)
            return false;
        if (family == IPv4)
            return ip.ipv4 == other.ip.ipv4;
        return std::memcmp(ip.ipv6, other.ip.ipv6, 16) == 0;
    }

    std::string WireGuard::IPAddress::toIpHex() const {
        if (family == IPv4) {
            return crypto::bin2Hex(ip.ipv4);
        } else {
            return crypto::bin2Hex(ip.ipv6, 16);
        }
    }

    std::string WireGuard::IPAddress::toIpStr() const {
        if (family == IPv4) {
            char buf[INET_ADDRSTRLEN];
            if (inet_ntop(AF_INET, &ip.ipv4, buf, INET_ADDRSTRLEN) == nullptr) {
                return "";
            }
            return std::string(buf);
        } else {
            char buf[INET6_ADDRSTRLEN];
            if (inet_ntop(AF_INET6, &ip.ipv6, buf, INET6_ADDRSTRLEN) == nullptr) {
                return "";
            }
            return std::string(buf);
        }
    }


    std::string WireGuard::PacketHeader::toIpLog() const {
        std::string result;
        if (src.address.family == IPAddress::IPv4) {
            result.append("from src (ipv4):");
            result.append(Tools::ipv4_to_string(src.address.ip.ipv4));
        } else {
            result.append("from src (ipv6):");
            result.append(Tools::ipv6_to_string(src.address.ip.ipv6));
        }
        result.append("\t");
        if (dst.address.family == IPAddress::IPv4) {
            result.append("to   dst (ipv4):");
            result.append(Tools::ipv4_to_string(dst.address.ip.ipv4));
        } else {
            result.append("to   dst (ipv6):");
            result.append(Tools::ipv6_to_string(dst.address.ip.ipv6));
        }
        return result;
    }
};