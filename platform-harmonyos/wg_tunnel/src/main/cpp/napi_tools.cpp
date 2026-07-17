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
    namespace {
        napi_value napiString(napi_env &env, std::string str) {
            napi_value nvStr;
            napi_status ns = napi_create_string_utf8(env, str.c_str(), str.length(), &nvStr);
            if (ns != napi_ok) {
                throw WireGuard::WGException("napi调用异常");
            }
            return nvStr;
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
};