/**
 * Created by Leojay on 2026/4/22.
 *
 * @author leojay`fu
 * @email crazyleojay@163.com
 * @url https://github.com/CrazyLeoJay
 */

#include "conf_file.h"
#include "../crypto/crypto.h"
#include <sstream>
#include <algorithm>
#include <cstring>
#include <stdexcept>
#include <regex>

#include "WGException.h"

#ifdef _WIN32
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#endif

namespace WireGuard {
    namespace Tools {
        std::string trim(const std::string &str) {
            auto start = str.find_first_not_of(" \t\n\r");
            auto end = str.find_last_not_of(" \t\n\r");
            if (start == std::string::npos || end == std::string::npos) {
                return "";
            }
            return str.substr(start, end - start + 1);
        }

        std::vector<std::string> split(const std::string &str, char delimiter) {
            std::vector<std::string> tokens;
            std::string token;
            std::istringstream tokenStream(str);
            while (std::getline(tokenStream, token, delimiter)) {
                token = trim(token);
                if (!token.empty()) {
                    tokens.push_back(token);
                }
            }
            return tokens;
        }

        bool isIPv4(const std::string &str) {
            struct sockaddr_in sa;
            return inet_pton(AF_INET, str.c_str(), &(sa.sin_addr)) != 0;
        }

        bool isIPv6(const std::string &str) {
            struct sockaddr_in6 sa;
            return inet_pton(AF_INET6, str.c_str(), &(sa.sin6_addr)) != 0;
        }

        bool isValidIPAddress(const std::string &str) {
            return isIPv4(str) || isIPv6(str);
        }

        bool isValidDomain(const std::string &str) {
            if (str.empty() || str.length() > 253) {
                return false;
            }
            std::regex domainRegex(
                R"(^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$)"
            );
            return std::regex_match(str, domainRegex);
        }

        bool isValidBase64Key(const std::string &str) {
            if (str.length() != 44) {
                return false;
            }
            std::regex base64Regex(R"(^[A-Za-z0-9+/]{43}[A-Za-z0-9+/=]$)");
            return std::regex_match(str, base64Regex);
        }

        bool isValidCIDR(uint32_t cidr, IPAddress::Family family) {
            if (family == IPAddress::Family::IPv4) {
                return cidr >= 0 && cidr <= 32;
            } else {
                return cidr >= 0 && cidr <= 128;
            }
        }

        bool isValidPort(uint32_t port) {
            return port > 0 && port <= 65535;
        }

        IPAddress parseIPAddress(const std::string &ipStr) {
            IPAddress addr{};
            if (isIPv4(ipStr)) {
                addr.family = IPAddress::IPv4;
                inet_pton(AF_INET, ipStr.c_str(), &addr.ip.ipv4);
            } else if (isIPv6(ipStr)) {
                addr.family = IPAddress::IPv6;
                inet_pton(AF_INET6, ipStr.c_str(), addr.ip.ipv6);
            }
            return addr;
        }

        std::string ipToStr(const IPAddress &ip) {
            char buffer[INET6_ADDRSTRLEN];
            if (ip.family == IPAddress::IPv4) {
                inet_ntop(AF_INET, &ip.ip.ipv4, buffer, sizeof(buffer));
            } else {
                inet_ntop(AF_INET6, ip.ip.ipv6, buffer, sizeof(buffer));
            }
            return std::string(buffer);
        }

        void validateConf(const WGConf &conf) {
            if (conf.inter.privateKey[0] == 0) {
                throw WGException("Interface PrivateKey 不能为空");
            }

            if (conf.inter.ipArea.cidr == static_cast<uint32_t>(-1)) {
                throw WGException("Interface Address 不能为空");
            }

            if (!isValidCIDR(conf.inter.ipArea.cidr, conf.inter.ipArea.address.family)) {
                throw WGException("Interface Address CIDR 无效，IPv4 范围应为 0-32，IPv6 范围应为 0-128");
            }

            for (const auto &dns: conf.inter.dns) {
                if (!isValidIPAddress(ipToStr(dns))) {
                    throw WGException("Interface DNS 地址格式无效: " + ipToStr(dns));
                }
            }

            if (conf.peers.empty()) {
                throw WGException("必须至少配置一个 Peer");
            }

            for (const auto &peer: conf.peers) {
                if (peer.publicKey[0] == 0) {
                    throw WGException("Peer PublicKey 不能为空");
                }

                if (peer.endpoint.ipStrOrDomain.empty()) {
                    throw WGException("Peer Endpoint 地址不能为空");
                }

                if (!isValidIPAddress(peer.endpoint.ipStrOrDomain) &&
                    !isValidDomain(peer.endpoint.ipStrOrDomain)) {
                    throw WGException("Peer Endpoint 地址格式无效: " + peer.endpoint.ipStrOrDomain);
                }

                if (!isValidPort(peer.endpoint.port)) {
                    throw WGException("Peer Endpoint 端口无效，范围应为 1-65535");
                }

                if (peer.allowedIPs.empty()) {
                    throw WGException("Peer AllowedIPs 不能为空");
                }

                for (const auto &ip: peer.allowedIPs) {
                    if (ip.cidr == static_cast<uint32_t>(-1)) {
                        throw WGException("Peer AllowedIPs CIDR 不能为空");
                    }
                    if (!isValidCIDR(ip.cidr, ip.address.family)) {
                        throw WGException("Peer AllowedIPs CIDR 无效，IPv4 范围应为 0-32，IPv6 范围应为 0-128");
                    }
                }

                if (peer.persistentKeepalive > 65535) {
                    throw WGException("Peer PersistentKeepalive 无效，最大值应为 65535");
                }
            }
        }

        WGConf readConfFileToEntity(const std::string &content) {
            WGConf conf{};
            std::vector<std::shared_ptr<WGConfPeer> > peerPtrs;
            std::shared_ptr<WGConfPeer> currentPeer;
            bool inInterface = false;
            bool inPeer = false;

            std::istringstream stream(content);
            std::string line;

            auto addCurrentPeer = [&]() {
                if (currentPeer && currentPeer->publicKey[0] != 0) {
                    bool found = false;
                    for (const auto &peer: peerPtrs) {
                        if (peer->publicKey == currentPeer->publicKey) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        peerPtrs.push_back(currentPeer);
                    }
                }
                currentPeer.reset();
            };

            while (std::getline(stream, line)) {
                line = trim(line);

                if (line.empty() || line[0] == '#') {
                    continue;
                }

                if (line == "[Interface]") {
                    addCurrentPeer();
                    inInterface = true;
                    inPeer = false;
                    continue;
                }

                if (line == "[Peer]") {
                    addCurrentPeer();
                    inInterface = false;
                    inPeer = true;
                    currentPeer = std::make_shared<WGConfPeer>();
                    continue;
                }

                size_t eqPos = line.find('=');
                if (eqPos == std::string::npos) {
                    continue;
                }

                std::string key = trim(line.substr(0, eqPos));
                std::string value = trim(line.substr(eqPos + 1));

                if (inInterface) {
                    if (key == "PrivateKey") {
                        conf.inter.privateKey = crypto::base642Bin32Array(value);
                    } else if (key == "Address") {
                        size_t slashPos = value.find('/');
                        if (slashPos != std::string::npos) {
                            std::string ipStr = value.substr(0, slashPos);
                            conf.inter.ipArea.address = parseIPAddress(ipStr);
                            conf.inter.ipArea.cidr = static_cast<uint32_t>(std::stoi(value.substr(slashPos + 1)));
                        }
                    } else if (key == "DNS") {
                        std::vector<std::string> dnsList = split(value, ',');
                        for (const auto &dns: dnsList) {
                            conf.inter.dns.push_back(parseIPAddress(dns));
                        }
                    }
                } else if (inPeer && currentPeer) {
                    if (key == "PublicKey") {
                        currentPeer->publicKey = crypto::base642Bin32Array(value);
                    } else if (key == "Endpoint") {
                        size_t colonPos = value.rfind(':');
                        if (colonPos != std::string::npos) {
                            currentPeer->endpoint.ipStrOrDomain = value.substr(0, colonPos);
                            currentPeer->endpoint.port = static_cast<uint32_t>(std::stoi(value.substr(colonPos + 1)));
                        } else {
                            currentPeer->endpoint.ipStrOrDomain = value;
                            currentPeer->endpoint.port = 80;
                        }
                    } else if (key == "AllowedIPs") {
                        std::vector<std::string> ipList = split(value, ',');
                        for (const auto &ipStr: ipList) {
                            IpAddressArea area{};
                            size_t slashPos = ipStr.find('/');
                            if (slashPos != std::string::npos) {
                                area.address = parseIPAddress(ipStr.substr(0, slashPos));
                                area.cidr = static_cast<uint32_t>(std::stoi(ipStr.substr(slashPos + 1)));
                            }
                            currentPeer->allowedIPs.push_back(area);
                        }
                    } else if (key == "PersistentKeepalive") {
                        currentPeer->persistentKeepalive = static_cast<uint32_t>(std::stoi(value));
                    } else if (key == "PreSharedKey") {
                        currentPeer->preSharedKey = std::make_shared<WGKey>(crypto::base642Bin32Array(value));
                    }
                }
            }

            addCurrentPeer();

            for (const auto &peer: peerPtrs) {
                conf.peers.push_back(*peer);
            }

            peerPtrs.clear();

            validateConf(conf);

            return conf;
        }

        std::string readConfFileToJson(const std::string &content) {
            const WGConf conf = readConfFileToEntity(content);
            return wgConfToJson(conf);
        }

        std::string wgConfToJson(const WGConf &conf) {
            std::ostringstream json;
            json << "{";

            json << "\"interface\":{";
            json << R"("privateKey":")" << crypto::bin32Array2Base64(conf.inter.privateKey) << "\",";
            json << "\"address\":{";
            json << R"("ip":")" << ipToStr(conf.inter.ipArea.address) << "\",";
            json << "\"cidr\":" << std::to_string(conf.inter.ipArea.cidr);
            json << "},";
            json << "\"dns\":[";
            for (size_t i = 0; i < conf.inter.dns.size(); i++) {
                if (i > 0) json << ",";
                json << "\"" << ipToStr(conf.inter.dns[i]) << "\"";
            }
            json << "]";
            json << "},";

            json << "\"peers\":[";
            for (size_t i = 0; i < conf.peers.size(); i++) {
                if (i > 0) json << ",";
                const auto &peer = conf.peers[i];
                json << "{";
                json << R"("publicKey":")" << crypto::bin32Array2Base64(peer.publicKey) << "\",";
                json << "\"endpoint\":{";
                json << R"("ipStrOrDomain":")" << peer.endpoint.ipStrOrDomain << "\",";
                json << "\"port\":" << peer.endpoint.port;
                json << "},";
                json << "\"allowedIPs\":[";
                for (size_t j = 0; j < peer.allowedIPs.size(); j++) {
                    if (j > 0) json << ",";
                    const auto &ip = peer.allowedIPs[j];
                    json << R"({"ip":")" << ipToStr(ip.address) << R"(","cidr":)" << std::to_string(ip.cidr) << "}";
                }
                json << "],";
                json << "\"persistentKeepalive\":" << peer.persistentKeepalive;
                if (peer.preSharedKey) {
                    json << R"(,"preSharedKey":")" << crypto::bin32Array2Base64(peer.publicKey) << "\"";
                }
                json << "}";
            }
            json << "]";

            json << "}";

            return json.str();
        }
    }
} // WireGuardTools
