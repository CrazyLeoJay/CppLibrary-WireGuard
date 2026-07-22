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
// Created on 2026/4/9.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#include "napi_tools.h"
#include "WGException.h"
#include "crypto/crypto.h"
#include <cstdint>
#include <vector>
#include <napi/native_api.h>

/**
 * Napi 实现工具类
 */
namespace NapiTools {
    std::string napiGetString(napi_env &env, napi_value obj);

    namespace {
        napi_value napiString(napi_env &env, std::string str) {
            napi_value nvStr;
            napi_status ns = napi_create_string_utf8(env, str.c_str(), str.length(), &nvStr);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            return nvStr;
        }

        std::string getPropString(napi_env &env, napi_value obj, const std::string &propertyName) {
            napi_status ns;
            napi_value nvProp;
            ns = napi_get_named_property(env, obj, propertyName.c_str(), &nvProp);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取属性 " + propertyName + " 失败");
            }
            return napiGetString(env, nvProp);
        }

        WireGuard::IPAddress readIpAddress(napi_env &env, napi_value obj) {
            auto ipStr = getPropString(env, obj, "ip");
            napi_value nvIsIpv4;
            napi_status ns = napi_get_named_property(env, obj, "isIpv4", &nvIsIpv4);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取属性 isIpv4 失败");
            }
            bool isIpv4;
            ns = napi_get_value_bool(env, nvIsIpv4, &isIpv4);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取 isIpv4 值失败");
            }
            if (isIpv4) {
                return WireGuard::Tools::ipAddressForIpv4(ipStr);
            } else {
                return WireGuard::Tools::ipAddressForIpv6(ipStr);
            }
        }

        WireGuard::IpAddressArea readIpAddressArea(napi_env &env, napi_value obj) {
            WireGuard::IpAddressArea ipArea{};
            napi_value nvAddress;
            napi_status ns = napi_get_named_property(env, obj, "address", &nvAddress);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取属性 address 失败");
            }
            ipArea.address = readIpAddress(env, nvAddress);

            napi_value nvCidr;
            ns = napi_get_named_property(env, obj, "cidr", &nvCidr);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取属性 cidr 失败");
            }
            int32_t cidr;
            ns = napi_get_value_int32(env, nvCidr, &cidr);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取 cidr 值失败");
            }
            ipArea.cidr = static_cast<uint8_t>(cidr);
            return ipArea;
        }

        WireGuard::Tools::WebSitePoint readWebSitePoint(napi_env &env, napi_value obj) {
            WireGuard::Tools::WebSitePoint wsp{};
            wsp.ipStrOrDomain = getPropString(env, obj, "ipStrOrDomain");

            napi_value nvPort;
            napi_status ns = napi_get_named_property(env, obj, "port", &nvPort);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取属性 port 失败");
            }
            int64_t port;
            ns = napi_get_value_int64(env, nvPort, &port);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取 port 值失败");
            }
            wsp.port = static_cast<uint32_t>(port);

            napi_value nvType;
            ns = napi_get_named_property(env, obj, "type", &nvType);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取属性 type 失败");
            }
            int32_t type;
            ns = napi_get_value_int32(env, nvType, &type);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取 type 值失败");
            }
            wsp.type = static_cast<WireGuard::Tools::SiteUrlType>(type);
            return wsp;
        }

        WireGuard::Tools::WGConfInterface readWGConfInterface(napi_env &env, napi_value obj) {
            WireGuard::Tools::WGConfInterface inter{};
            inter.configName = getPropString(env, obj, "deviceName");

            auto privateKeyStr = getPropString(env, obj, "privateKey");
            inter.privateKey = WireGuard::crypto::base642Bin32Array(privateKeyStr);

            napi_value nvIpArea;
            napi_status ns = napi_get_named_property(env, obj, "ipArea", &nvIpArea);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取属性 ipArea 失败");
            }
            inter.ipArea = readIpAddressArea(env, nvIpArea);

            napi_value nvDns;
            ns = napi_get_named_property(env, obj, "dns", &nvDns);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取属性 dns 失败");
            }
            uint32_t dnsLen;
            ns = napi_get_array_length(env, nvDns, &dnsLen);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取 dns 数组长度失败");
            }
            for (uint32_t i = 0; i < dnsLen; ++i) {
                napi_value nvItem;
                ns = napi_get_element(env, nvDns, i, &nvItem);
                if (ns != napi_ok) {
                    throw WireGuard::WGException("获取 dns 元素失败");
                }
                inter.dns.push_back(readIpAddress(env, nvItem));
            }

            bool hasListenerPort;
            ns = napi_has_named_property(env, obj, "listenerPort", &hasListenerPort);
            if (ns != napi_ok) {
                throw WireGuard::WGException("检查属性 listenerPort 失败");
            }
            if (hasListenerPort) {
                napi_value nvListenerPort;
                ns = napi_get_named_property(env, obj, "listenerPort", &nvListenerPort);
                if (ns != napi_ok) {
                    throw WireGuard::WGException("获取属性 listenerPort 失败");
                }
                napi_valuetype type;
                ns = napi_typeof(env, nvListenerPort, &type);
                if (ns != napi_ok) {
                    throw WireGuard::WGException("获取 listenerPort 类型失败");
                }
                if (type != napi_undefined && type != napi_null) {
                    uint32_t listenerPort;
                    ns = napi_get_value_uint32(env, nvListenerPort, &listenerPort);
                    if (ns != napi_ok) {
                        throw WireGuard::WGException("获取 listenerPort 值失败");
                    }
                    inter.ListenPort = std::make_shared<uint32_t>(listenerPort);
                }
            }

            return inter;
        }

        WireGuard::Tools::WGConfPeer readWGConfPeer(napi_env &env, napi_value obj) {
            WireGuard::Tools::WGConfPeer peer{};

            auto publicKeyStr = getPropString(env, obj, "publicKey");
            peer.publicKey = WireGuard::crypto::base642Bin32Array(publicKeyStr);

            napi_value nvEndpoint;
            napi_status ns = napi_get_named_property(env, obj, "endpoint", &nvEndpoint);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取属性 endpoint 失败");
            }
            peer.endpoint = readWebSitePoint(env, nvEndpoint);

            napi_value nvAllowedIPs;
            ns = napi_get_named_property(env, obj, "allowedIPs", &nvAllowedIPs);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取属性 allowedIPs 失败");
            }
            uint32_t allowedIPsLen;
            ns = napi_get_array_length(env, nvAllowedIPs, &allowedIPsLen);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取 allowedIPs 数组长度失败");
            }
            for (uint32_t i = 0; i < allowedIPsLen; ++i) {
                napi_value nvItem;
                ns = napi_get_element(env, nvAllowedIPs, i, &nvItem);
                if (ns != napi_ok) {
                    throw WireGuard::WGException("获取 allowedIPs 元素失败");
                }
                peer.allowedIPs.push_back(readIpAddressArea(env, nvItem));
            }

            napi_value nvKeepalive;
            ns = napi_get_named_property(env, obj, "keepaliveInterval", &nvKeepalive);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取属性 keepaliveInterval 失败");
            }
            int64_t keepalive;
            ns = napi_get_value_int64(env, nvKeepalive, &keepalive);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取 keepaliveInterval 值失败");
            }
            peer.persistentKeepalive = static_cast<uint32_t>(keepalive);

            bool hasPreSharedKey;
            ns = napi_has_named_property(env, obj, "preSharedKey", &hasPreSharedKey);
            if (ns != napi_ok) {
                throw WireGuard::WGException("检查属性 preSharedKey 失败");
            }
            if (hasPreSharedKey) {
                napi_value nvPreSharedKey;
                ns = napi_get_named_property(env, obj, "preSharedKey", &nvPreSharedKey);
                if (ns != napi_ok) {
                    throw WireGuard::WGException("获取属性 preSharedKey 失败");
                }
                napi_valuetype type;
                ns = napi_typeof(env, nvPreSharedKey, &type);
                if (ns != napi_ok) {
                    throw WireGuard::WGException("获取 preSharedKey 类型失败");
                }
                if (type != napi_undefined && type != napi_null) {
                    auto pskStr = napiGetString(env, nvPreSharedKey);
                    auto psk = WireGuard::crypto::base642Bin32Array(pskStr);
                    peer.preSharedKey = std::make_shared<WireGuard::Tools::WGKey>(psk);
                }
            }

            return peer;
        }

        napi_value createIpAddress(napi_env &env, WireGuard::IPAddress &ipAddress) {
            napi_status ns;
            napi_value result;
            ns = napi_create_object(env, &result);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            napi_value nvIp;
            auto ipStr = ipAddress.toIpStr();
            ns = napi_create_string_utf8(env, ipStr.c_str(), ipStr.length(), &nvIp);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            ns = napi_set_named_property(env, result, "ip", nvIp);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            napi_value nvIsIpv4;
            auto isIpv4 = ipAddress.family == WireGuard::IPAddress::IPv4;
            ns = napi_get_boolean(env, isIpv4, &nvIsIpv4);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            ns = napi_set_named_property(env, result, "isIpv4", nvIsIpv4);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            return result;
        }

        napi_value createIpAddressArea(napi_env &env, WireGuard::IpAddressArea &ipArea) {
            napi_status ns;
            napi_value result;
            ns = napi_create_object(env, &result);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            napi_value ipAddress = createIpAddress(env, ipArea.address);
            ns = napi_set_named_property(env, result, "address", ipAddress);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            napi_value nvCidr;
            ns = napi_create_int32(env, ipArea.cidr, &nvCidr);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            ns = napi_set_named_property(env, result, "cidr", nvCidr);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            return result;
        }

        napi_value createWGConfInterface(napi_env &env, WireGuard::Tools::WGConfInterface &inter) {
            napi_status ns;
            napi_value result;
            ns = napi_create_object(env, &result);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            auto deviceName = inter.configName;
            napi_value nvDeviceName;
            ns = napi_create_string_utf8(env, deviceName.c_str(), deviceName.length(), &nvDeviceName);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            ns = napi_set_named_property(env, result, "deviceName", nvDeviceName);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            napi_value nvPrivateKey;
            auto privateKey = WireGuard::crypto::bin32Array2Base64(inter.privateKey);
            ns = napi_create_string_utf8(env, privateKey.c_str(), privateKey.length(), &nvPrivateKey);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            ns = napi_set_named_property(env, result, "privateKey", nvPrivateKey);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            napi_value nvIpArea = createIpAddressArea(env, inter.ipArea);
            ns = napi_set_named_property(env, result, "ipArea", nvIpArea);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            napi_value nvDnses;
            ns = napi_create_array(env, &nvDnses);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            uint32_t index = 0;
            for (auto dns : inter.dns) {
                napi_value nvItem = createIpAddress(env, dns);
                napi_set_element(env, nvDnses, index, nvItem);
                index++;
            }
            ns = napi_set_named_property(env, result, "dns", nvDnses);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            if (inter.ListenPort) {
                napi_value nvListenPort;
                ns = napi_create_uint32(env, *inter.ListenPort, &nvListenPort);
                if (ns != napi_ok) {
                    throw WireGuard::WGException("napi调用异常");
                }
                ns = napi_set_named_property(env, result, "listenerPort", nvListenPort);
                if (ns != napi_ok) {
                    throw WireGuard::WGException("napi调用异常");
                }
            }
            return result;
        }

        napi_value createWebSitePoint(napi_env &env, WireGuard::Tools::WebSitePoint wsp) {
            napi_status ns;
            napi_value result;
            ns = napi_create_object(env, &result);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            // 设置域名或者ip的Str
            napi_value nvIpDomain;
            auto ipStr = wsp.ipStrOrDomain;
            ns = napi_create_string_utf8(env, ipStr.c_str(), ipStr.length(), &nvIpDomain);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            ns = napi_set_named_property(env, result, "ipStrOrDomain", nvIpDomain);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            // 设置端口
            napi_value nvPort;
            auto port = wsp.port;
            ns = napi_create_int64(env, port, &nvPort);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            ns = napi_set_named_property(env, result, "port", nvPort);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            // 设置类型 type
            napi_value nvType;
            auto type = static_cast<uint32_t>(wsp.type);
            ns = napi_create_int32(env, type, &nvType);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            ns = napi_set_named_property(env, result, "type", nvType);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            return result;
        }

        napi_value createWGPeer(napi_env &env, WireGuard::Tools::WGConfPeer &peer) {
            napi_status ns;
            napi_value result;
            ns = napi_create_object(env, &result);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            napi_value nvPubKey;
            auto publicKey = WireGuard::crypto::bin32Array2Base64(peer.publicKey);
            ns = napi_create_string_utf8(env, publicKey.c_str(), publicKey.length(), &nvPubKey);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            ns = napi_set_named_property(env, result, "publicKey", nvPubKey);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }


            napi_value nvWsp = createWebSitePoint(env, peer.endpoint);
            ns = napi_set_named_property(env, result, "endpoint", nvWsp);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }


            napi_value nvIps;
            ns = napi_create_array(env, &nvIps);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            uint32_t index = 0;
            for (auto ip : peer.allowedIPs) {
                napi_value ipArea = createIpAddressArea(env, ip);
                ns = napi_set_element(env, nvIps, index, ipArea);
                if (ns != napi_ok) {
                    throw WireGuard::WGException("napi调用异常");
                }
                index++;
            }
            ns = napi_set_named_property(env, result, "allowedIPs", nvIps);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            napi_value nvKeepalive;
            auto keepalive = peer.persistentKeepalive;
            ns = napi_create_int64(env, keepalive, &nvKeepalive);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            ns = napi_set_named_property(env, result, "keepaliveInterval", nvKeepalive);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }


            if (peer.preSharedKey) {
                napi_value nvPsk;
                auto psk = WireGuard::crypto::bin32Array2Base64(*peer.preSharedKey);
                ns = napi_create_string_utf8(env, psk.c_str(), psk.length(), &nvPsk);
                if (ns != napi_ok) {
                    throw WireGuard::WGException("napi调用异常");
                }
                ns = napi_set_named_property(env, result, "preSharedKey", nvPsk);
                if (ns != napi_ok) {
                    throw WireGuard::WGException("napi调用异常");
                }
            }
            return result;
        }
    } // namespace

    napi_value createNvForWGConf(napi_env &env, WireGuard::Tools::WGConf &conf) {
        napi_status ns;
        napi_value result;
        ns = napi_create_object(env, &result);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        napi_value inter = createWGConfInterface(env, conf.inter);
        ns = napi_set_named_property(env, result, "inter", inter);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        napi_value nvPeers;
        ns = napi_create_array(env, &nvPeers);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        uint32_t index = 0;
        for (auto peer : conf.peers) {
            napi_value item = createWGPeer(env, peer);
            ns = napi_set_element(env, nvPeers, index, item);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            index++;
        }
        ns = napi_set_named_property(env, result, "peers", nvPeers);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        return result;
    }


    std::string napiGetString(napi_env &env, napi_value obj) {
        napi_status ns;
        size_t len;
        ns = napi_get_value_string_utf8(env, obj, nullptr, 0, &len);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        std::vector<char> buf(len + 1);
        ns = napi_get_value_string_utf8(env, obj, buf.data(), len + 1, &len);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        return std::string{buf.data(), len};
    }

    napi_value makeNapiBool(napi_env &env, const bool &value) {
        napi_value nvBool;
        auto ns = napi_get_boolean(env, value, &nvBool);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        return nvBool;
    }

    napi_value makeNapiString(napi_env &env, const std::string &value) {
        napi_value nvValue;
        auto ns = napi_create_string_utf8(env, value.c_str(), value.length(), &nvValue);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        return nvValue;
    }

    namespace {
        napi_value createStreamCalculate(napi_env &env, const WireGuard::StreamLog::StreamCalculate &sc) {
            napi_status ns;
            napi_value result;
            ns = napi_create_object(env, &result);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            napi_value nvLength;
            ns = napi_create_int64(env, static_cast<int64_t>(sc.length), &nvLength);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            ns = napi_set_named_property(env, result, "length", nvLength);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            napi_value nvReceiveTotal;
            ns = napi_create_int64(env, static_cast<int64_t>(sc.receive_total), &nvReceiveTotal);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            ns = napi_set_named_property(env, result, "receiveTotal", nvReceiveTotal);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            napi_value nvSendTotal;
            ns = napi_create_int64(env, static_cast<int64_t>(sc.send_total), &nvSendTotal);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            ns = napi_set_named_property(env, result, "sendTotal", nvSendTotal);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }

            return result;
        }
    } // namespace

    napi_value makeStreamLogMessage(napi_env &env, const WireGuard::StreamLog::Message message) {
        napi_value nvResult;
        napi_status ns;
        ns = napi_create_object(env, &nvResult);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        const auto timestamp = message.timestamp;
        const auto pk = WireGuard::crypto::bin32Array2Base64(message.publicKey);
        const auto peerIndex = message.peerIndex;
        const auto messageType = message.messageType;
        const auto direction = message.direction;
        const auto sc = message.sc;
        const auto success = message.success;
        const auto msg = message.msg;

        napi_value nvTimestamp;
        int64_t ms = std::chrono::duration_cast<std::chrono::milliseconds>(timestamp.time_since_epoch()).count();
        ns = napi_create_int64(env, ms, &nvTimestamp);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        ns = napi_set_named_property(env, nvResult, "timestamp", nvTimestamp);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        napi_value nvPublicKey;
        ns = napi_create_string_utf8(env, pk.c_str(), pk.length(), &nvPublicKey);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        ns = napi_set_named_property(env, nvResult, "publicKey", nvPublicKey);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        napi_value nvPeerIndex;
        ns = napi_create_int64(env, static_cast<int64_t>(peerIndex), &nvPeerIndex);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        ns = napi_set_named_property(env, nvResult, "peerIndex", nvPeerIndex);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        napi_value nvMessageType;
        ns = napi_create_int32(env, static_cast<int32_t>(messageType), &nvMessageType);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        ns = napi_set_named_property(env, nvResult, "messageType", nvMessageType);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        napi_value nvDirection;
        ns = napi_create_int32(env, static_cast<int32_t>(direction), &nvDirection);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        ns = napi_set_named_property(env, nvResult, "direction", nvDirection);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        napi_value nvSc = createStreamCalculate(env, sc);
        ns = napi_set_named_property(env, nvResult, "sc", nvSc);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        napi_value nvSuccess;
        ns = napi_get_boolean(env, success, &nvSuccess);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        ns = napi_set_named_property(env, nvResult, "success", nvSuccess);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        napi_value nvMsg;
        ns = napi_create_string_utf8(env, msg.c_str(), msg.length(), &nvMsg);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }
        ns = napi_set_named_property(env, nvResult, "msg", nvMsg);
        if (ns != napi_ok) {
            throw WireGuard::WGException("napi调用异常");
        }

        return nvResult;
    }

    WireGuard::Tools::WGConf napiGetWGConf2Entity(napi_env &env, napi_value obj) {
        WireGuard::Tools::WGConf config{};

        napi_status ns;

        // 读取 interface 配置
        napi_value nvInter;
        ns = napi_get_named_property(env, obj, "inter", &nvInter);
        if (ns != napi_ok) {
            throw WireGuard::WGException("获取属性 inter 失败");
        }
        config.inter = readWGConfInterface(env, nvInter);

        // 读取 peers 列表
        napi_value nvPeers;
        ns = napi_get_named_property(env, obj, "peers", &nvPeers);
        if (ns != napi_ok) {
            throw WireGuard::WGException("获取属性 peers 失败");
        }
        uint32_t peersLen;
        ns = napi_get_array_length(env, nvPeers, &peersLen);
        if (ns != napi_ok) {
            throw WireGuard::WGException("获取 peers 数组长度失败");
        }
        for (uint32_t i = 0; i < peersLen; ++i) {
            napi_value nvPeer;
            ns = napi_get_element(env, nvPeers, i, &nvPeer);
            if (ns != napi_ok) {
                throw WireGuard::WGException("获取 peers 元素失败");
            }
            config.peers.push_back(readWGConfPeer(env, nvPeer));
        }

        return config;
    }
};