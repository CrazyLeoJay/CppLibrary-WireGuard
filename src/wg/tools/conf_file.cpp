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
#include "wg_dns.h"

#ifdef _WIN32
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#endif

namespace WireGuard {
    namespace Tools {
        std::string trim(const std::string &str) {
            const auto start = str.find_first_not_of(" \t\n\r");
            const auto end = str.find_last_not_of(" \t\n\r");
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
            sockaddr_in sa{};
            return inet_pton(AF_INET, str.c_str(), &(sa.sin_addr)) != 0;
        }

        bool isIPv6(const std::string &str) {
            sockaddr_in6 sa{};
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

        IPAddress ipAddressForIpv4(const std::string &ipStr) {
            IPAddress addr{};
            addr.family = IPAddress::IPv4;
            const auto ret = inet_pton(AF_INET, ipStr.c_str(), &addr.ip.ipv4);
            if (ret != 1) {
                throw WGException("%s，转为Ip4 IP address 失败, ret=%d", ipStr.c_str(), ret);
            }
            return addr;
        }

        IPAddress ipAddressForIpv6(const std::string &ipStr) {
            IPAddress addr{};
            addr.family = IPAddress::IPv6;
            const auto ret = inet_pton(AF_INET6, ipStr.c_str(), addr.ip.ipv6);
            if (ret != 1) {
                throw WGException("%s，转为Ip6 IP address 失败, ret=%d", ipStr.c_str(), ret);
            }
            return addr;
        }

        bool isValidCIDR(const int cidr, const IPAddress::Family family) {
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

        WebSitePoint endpointForDomainOrIpStr(const std::string &endpointStr) {
            WebSitePoint result{};
            result.port = 80;
            const std::string &value = endpointStr;
            std::string host;
            uint32_t port = 80;
            SiteUrlType urlType = ERROR;

            // 判断：输入字符串是否为空
            if (value.empty()) {
                throw WGException("Endpoint 地址不能为空");
            }

            // 判断：是否为 [IPv6]:port 或 [IPv6] 的标准方括号 IPv6 格式
            if (value.front() == '[') {
                size_t closeBracket = value.find(']');
                // 判断：是否找不到闭合 ]，方括号不完整
                if (closeBracket == std::string::npos) {
                    throw WGException("Endpoint 格式错误，IPv6 方括号未闭合，当前值：%s", value.c_str());
                }
                host = value.substr(1, closeBracket - 1);
                // 判断：提取出的方括号内 IPv6 内容 trim 后是否为空
                if (trim(host).empty()) {
                    throw WGException("Endpoint 方括号内的 IPv6 地址为空，当前值：%s", value.c_str());
                }
                // 判断：方括号内的内容是否为合法 IPv6 地址
                if (!isIPv6(host)) {
                    throw WGException(
                        "Endpoint 方括号内的内容不是合法 IPv6 地址，方括号内容：%s，原值：%s",
                        host.c_str(), value.c_str());
                }
                urlType = IPv6;

                size_t afterBracket = closeBracket + 1;
                // 判断：] 之后是否还有内容需要处理（如 :端口）
                if (afterBracket < value.size()) {
                    // 判断：] 之后紧跟的字符是否为端口分隔符 :
                    if (value[afterBracket] != ':') {
                        throw WGException(
                            "Endpoint IPv6 方括号后只允许跟 :端口，当前值：%s", value.c_str());
                    }
                    std::string portStr = value.substr(afterBracket + 1);
                    // 判断：端口字符串是否为空（写了 : 但后面没跟端口号）
                    if (portStr.empty()) {
                        throw WGException("Endpoint 端口不能为空，当前值：%s", value.c_str());
                    }
                    try {
                        int parsedPort = std::stoi(portStr);
                        // 判断：解析出的端口是否在 1-65535 合法范围内
                        if (!isValidPort(static_cast<uint32_t>(parsedPort))) {
                            throw WGException(
                                "Endpoint 端口超出有效范围(1-65535)，当前端口值：%s，原值：%s",
                                portStr.c_str(), value.c_str());
                        }
                        port = static_cast<uint32_t>(parsedPort);
                    } catch (const std::invalid_argument &) {
                        throw WGException(
                            "Endpoint 端口格式非法，必须是数字，当前端口值：%s，原值：%s",
                            portStr.c_str(), value.c_str());
                    } catch (const std::out_of_range &) {
                        throw WGException(
                            "Endpoint 端口超出有效范围(1-65535)，当前端口值：%s，原值：%s",
                            portStr.c_str(), value.c_str());
                    }
                }
            } else {
                size_t colonCount = std::count(value.begin(), value.end(), ':');
                // 判断：冒号数 >= 2，疑似是 IPv6（整体或 IPv6:端口启发式格式）
                if (colonCount >= 2) {
                    // 判断：整个字符串是否本身就是合法的纯 IPv6 地址（无端口）
                    if (isIPv6(value)) {
                        host = value;
                        urlType = IPv6;
                    } else {
                        size_t lastColon = value.rfind(':');
                        std::string beforeColon = value.substr(0, lastColon);
                        std::string afterColon = value.substr(lastColon + 1);
                        bool portParsed = false;
                        // 判断：最后一段冒号后非空，且冒号前是合法 IPv6，尝试按 IPv6:端口 启发式拆分
                        if (!afterColon.empty() && isIPv6(beforeColon)) {
                            try {
                                int parsedPort = std::stoi(afterColon);
                                // 判断：启发式拆分后的端口号是否在 1-65535 合法范围
                                if (isValidPort(static_cast<uint32_t>(parsedPort))) {
                                    host = beforeColon;
                                    port = static_cast<uint32_t>(parsedPort);
                                    urlType = IPv6;
                                    portParsed = true;
                                } else {
                                    throw WGException(
                                        "Endpoint 端口超出有效范围(1-65535)，当前端口值：%s，原值：%s",
                                        afterColon.c_str(), value.c_str());
                                }
                            } catch (const std::invalid_argument &) {
                                throw WGException(
                                    "Endpoint 端口格式非法，必须是数字，当前端口值：%s，原值：%s",
                                    afterColon.c_str(), value.c_str());
                            } catch (const std::out_of_range &) {
                                throw WGException(
                                    "Endpoint 端口超出有效范围(1-65535)，当前端口值：%s，原值：%s",
                                    afterColon.c_str(), value.c_str());
                            }
                        }
                        // 判断：启发式拆分是否成功，否则抛出格式异常
                        if (!portParsed) {
                            throw WGException(
                                "Endpoint 无法解析为合法的 IPv6 地址或 IPv6:端口 格式，请改用 [IPv6]:端口 形式，当前值：%s",
                                value.c_str());
                        }
                    }
                    // 判断：冒号数恰好为 1 个，按 IPv4:端口 或 域名:端口 格式解析
                } else if (colonCount == 1) {
                    size_t colonPos = value.rfind(':');
                    host = value.substr(0, colonPos);
                    // 判断：冒号前的主机(IP/域名)部分 trim 后是否为空
                    if (trim(host).empty()) {
                        throw WGException(
                            "Endpoint 主机(IP/域名)部分为空，当前值：%s", value.c_str());
                    }
                    std::string portStr = value.substr(colonPos + 1);
                    // 判断：冒号后的端口字符串是否为空（写了 : 但无端口号）
                    if (portStr.empty()) {
                        throw WGException("Endpoint 端口不能为空，当前值：%s", value.c_str());
                    }
                    try {
                        int parsedPort = std::stoi(portStr);
                        // 判断：解析出的端口是否在 1-65535 合法范围内
                        if (!isValidPort(static_cast<uint32_t>(parsedPort))) {
                            throw WGException(
                                "Endpoint 端口超出有效范围(1-65535)，当前端口值：%s，原值：%s",
                                portStr.c_str(), value.c_str());
                        }
                        port = static_cast<uint32_t>(parsedPort);
                    } catch (const std::invalid_argument &) {
                        throw WGException(
                            "Endpoint 端口格式非法，必须是数字，当前端口值：%s，原值：%s",
                            portStr.c_str(), value.c_str());
                    } catch (const std::out_of_range &) {
                        throw WGException(
                            "Endpoint 端口超出有效范围(1-65535)，当前端口值：%s，原值：%s",
                            portStr.c_str(), value.c_str());
                    }
                    // 判断：冒号前的主机部分是否是合法 IPv4 地址
                    if (isIPv4(host)) {
                        urlType = IPv4;
                        // 判断：冒号前的主机部分是否是合法域名
                    } else if (isValidDomain(host)) {
                        urlType = Domain;
                    } else {
                        throw WGException(
                            "Endpoint 主机部分既不是合法 IPv4，也不是合法域名，主机值：%s，原值：%s",
                            host.c_str(), value.c_str());
                    }
                    // 冒号数 == 0：按纯 IPv4 或纯域名（无端口，默认 80）解析
                } else {
                    host = value;
                    // 判断：主机字符串 trim 后是否为空
                    if (trim(host).empty()) {
                        throw WGException("Endpoint 主机(IP/域名)部分为空，当前值：%s", value.c_str());
                    }
                    // 判断：主机是否为合法 IPv4 地址
                    if (isIPv4(host)) {
                        urlType = IPv4;
                        // 判断：主机是否为合法域名
                    } else if (isValidDomain(host)) {
                        urlType = Domain;
                    } else {
                        throw WGException(
                            "Endpoint 主机部分既不是合法 IPv4，也不是合法域名，主机值：%s，原值：%s",
                            host.c_str(), value.c_str());
                    }
                }
            }

            // 判断：最终解析出的主机部分 trim 后是否仍为空（防御性兜底）
            if (trim(host).empty()) {
                throw WGException("Endpoint 主机(IP/域名)部分解析为空，当前值：%s", value.c_str());
            }
            // 判断：SiteUrlType 是否仍为 ERROR（防御性兜底，避免所有分支漏赋值）
            if (urlType == ERROR) {
                throw WGException(
                    "Endpoint 无法识别主机类型（IPv4/IPv6/Domain），主机值：%s，原值：%s",
                    host.c_str(), value.c_str());
            }

            result.ipStrOrDomain = host;
            result.port = port;
            result.type = urlType;
            return result;
        }

        void validateConf(const WGConf &conf) {
            if (conf.inter.privateKey[0] == 0) {
                throw WGException("Interface PrivateKey 不能为空");
            }

            if (conf.inter.ipArea.cidr == -1) {
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


            if (conf.inter.ListenPort) {
                if (!isValidPort(*conf.inter.ListenPort)) {
                    throw WGException("Interface ListenerPort 值不合理: %s ", *conf.inter.ListenPort);
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
                    if (ip.cidr == -1) {
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

                size_t commentPos = line.find('#');
                if (commentPos != std::string::npos) {
                    line = line.substr(0, commentPos);
                }
                line = trim(line);

                if (line.empty()) {
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
                            conf.inter.ipArea.cidr = std::stoi(value.substr(slashPos + 1));
                        }
                    } else if (key == "DNS") {
                        std::vector<std::string> dnsList = split(value, ',');
                        for (const auto &dns: dnsList) {
                            conf.inter.dns.push_back(parseIPAddress(dns));
                        }
                    } else if (key == "ListenPort") {
                        conf.inter.ListenPort = std::make_shared<uint32_t>(std::stoi(value));
                    } else if (key == "ConfigName") {
                        conf.inter.configName = value;
                    } else if (key == "MTU") {
                        conf.inter.mtu = std::make_shared<uint32_t>(std::stoi(value));
                    }
                } else if (inPeer && currentPeer) {
                    if (key == "PublicKey") {
                        currentPeer->publicKey = crypto::base642Bin32Array(value);
                    } else if (key == "Endpoint") {
                        const WebSitePoint sitePoint = endpointForDomainOrIpStr(value);
                        currentPeer->endpoint = sitePoint;
                    } else if (key == "AllowedIPs") {
                        std::vector<std::string> ipList = split(value, ',');
                        for (const auto &ipStr: ipList) {
                            IpAddressArea area{};
                            size_t slashPos = ipStr.find('/');
                            if (slashPos != std::string::npos) {
                                area.address = parseIPAddress(ipStr.substr(0, slashPos));
                                area.cidr = std::stoi(ipStr.substr(slashPos + 1));
                            }
                            currentPeer->allowedIPs.push_back(area);
                        }
                    } else if (key == "PersistentKeepalive") {
                        currentPeer->persistentKeepalive = static_cast<uint32_t>(std::stoi(value));
                    } else if (key == "PreSharedKey" || key == "PresharedKey") {
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

        DeviceRegisterConfig wgConfToDeviceRegisterConfig(const WGConf &conf) {
            DeviceRegisterConfig drc{};

            drc.client.device_name = conf.inter.configName;
            std::memcpy(drc.client.private_key.data(), conf.inter.privateKey.data(), PRIVATE_KEY_LEN);
            drc.client.listener_port = conf.inter.ListenPort;
            drc.client.bind_address = std::make_shared<IPAddress>(conf.inter.ipArea.address);

            for (const auto &wgPeer: conf.peers) {
                PeerConfig pc{};
                std::memcpy(pc.public_key.data(), wgPeer.publicKey.data(), PUBLIC_KEY_LEN);

                if (wgPeer.endpoint.type == SiteUrlType::IPv4) {
                    pc.endpoint.address = ipAddressForIpv4(wgPeer.endpoint.ipStrOrDomain);
                } else if (wgPeer.endpoint.type == SiteUrlType::IPv6) {
                    pc.endpoint.address = ipAddressForIpv6(wgPeer.endpoint.ipStrOrDomain);
                } else if (wgPeer.endpoint.type == SiteUrlType::Domain) {
                    auto ips = DNS::readDomainToIpAll(wgPeer.endpoint.ipStrOrDomain);
                    if (!ips.empty()) {
                        pc.endpoint.address = ips[0];
                    }
                }
                pc.endpoint.port = static_cast<uint16_t>(wgPeer.endpoint.port);

                pc.allowedIps = wgPeer.allowedIPs;
                pc.keepaliveInterval = wgPeer.persistentKeepalive;

                if (wgPeer.preSharedKey) {
                    pc.pre_share_key = std::make_shared<SymmetricKey>();
                    std::memcpy(pc.pre_share_key->data(), wgPeer.preSharedKey->data(), SYMMETRIC_KEY_LEN);
                }

                drc.peers.push_back(pc);
            }

            return drc;
        }

        std::string wgConfToOfficialConfigStr(const WGConf &conf) {
            std::string str = "[Interface]";
            const auto inter = conf.inter;
            str += "\nPrivateKey=" + crypto::bin32Array2Base64(inter.privateKey);
            str += "\nAddress=" + inter.ipArea.toIpStr();

            if (!inter.dns.empty()) {
                str += "\nDNS=";
                int i = 0;
                for (auto dn: inter.dns) {
                    if (i > 0) str += ",";
                    str += dn.toIpStr();
                    ++i;
                }
            }
            if (inter.ListenPort) {
                str += "\nListenPort=" + std::to_string(*inter.ListenPort);
            }
            if (inter.mtu) {
                str += "\nMTU=" + std::to_string(*inter.mtu);
            }

            for (const auto &peer: conf.peers) {
                str += "\n\n";
                str += peerToOfficialConfigStr(peer);
            }
            str += "\n";
            return str;
        }

        std::string peerToOfficialConfigStr(const WGConfPeer &peer) {
            std::string str = "[Peer]";

            str += "\nPublicKey=" + crypto::bin32Array2Base64(peer.publicKey);

            if (peer.preSharedKey) {
                str += "\nPresharedKey=" + crypto::bin32Array2Base64(*peer.preSharedKey);
            }

            if (!peer.allowedIPs.empty()) {
                str += "\nAllowedIPs=";
                int i = 0;
                for (const auto &ip: peer.allowedIPs) {
                    if (i > 0) str += ",";
                    str += ip.toIpStr();
                    ++i;
                }
            }

            str += "\nEndpoint=" + peer.endpoint.toIpStr();

            if (peer.persistentKeepalive > 0) {
                str += "\nPersistentKeepalive=" + std::to_string(peer.persistentKeepalive);
            }

            return str;
        }
    }
} // WireGuardTools
