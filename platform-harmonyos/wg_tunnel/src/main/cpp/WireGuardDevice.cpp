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
// Created on 2026/3/21.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#include "logs/logs.h"
#include "napi_tools.h"
#include <mutex>
#include <napi/native_api.h>

#include "WireGuardDevice.h"

#include <cstdint>
#include <cstdio>
#include <hilog/log.h>
#include <iostream>
#include <memory>
#include <netinet/in.h>
#include <regex>
#include "device.h"
#include "arpa/inet.h"
#include "entity.h"
#include "WGException.h"
#include "crypto/crypto.h"

#include <sys/stat.h>
#include <unistd.h>
#include <sys/syscall.h>

const std::string TAG = "WG-napi";
DevicePeerHelper::DevicePeerHelper() = default;
DevicePeerHelper::~DevicePeerHelper() {
    close();
    if (_wrapper) {
        LOG_DEBUG("销毁Device！！！");
//        napi_reference_unref(_env, _wrapper, uint32_t *result)
        napi_delete_reference(_env, _wrapper);
    }
};

bool isMainThread() {
    pid_t pid = getpid();            // 获取进程ID
    pid_t tid = syscall(SYS_gettid); // 获取线程ID
    return (pid == tid);             // 相等则为主线程
}

void DevicePeerHelper::close() {
    std::lock_guard<std::mutex> lock(_deviceMutex);
    LOG_DEBUG("close begin");
    if (device) {
        device->close();
    }
    // 释放线程安全函数
    if (_currentSocketFdListener) {
        LOG_DEBUG("释放 _currentSocketFdListener");
        napi_release_threadsafe_function(_currentSocketFdListener, napi_tsfn_abort);
        _currentSocketFdListener = nullptr;
    }
    LOG_DEBUG("close end");
}

void DevicePeerHelper::callbackOnSocketChangeListener(int socketFd) {
    std::lock_guard<std::mutex> lock(_deviceMutex);
    if (isMainThread()) {
        LOG_DEBUG("callbackOnSocketChangeListener main");
        if (!_currentListenerContext.callbackRef) {
            LOG_ERROR("callbackRef 为空，无法执行回调");
            return;
        }
        napi_value result;
        napi_get_reference_value(_env, _currentListenerContext.callbackRef, &result);
        napi_value arg[1];
        napi_create_int32(_env, socketFd, &arg[0]);

        // 3. 执行回调（必须在JS线程）
        napi_value global;
        napi_get_global(_env, &global);
        napi_call_function(_env, global, result, 1, arg, nullptr);
    } else if (_currentSocketFdListener) {
        LOG_DEBUG("callbackOnSocketChangeListener newthread");
        auto func = _currentSocketFdListener;
        LOG_DEBUG("读取 _currentSocketFdListener");
        // 非阻塞方式触发回调
        auto status = napi_acquire_threadsafe_function(func);
        if (status != napi_ok) {
            throw WireGuard::WGException("napi_acquire_threadsafe_function failed with status: %d", status);
        }

        int32_t *data = new int32_t(static_cast<int32_t>(socketFd));
        status = napi_call_threadsafe_function(func, data, napi_tsfn_nonblocking);
        if (status != napi_ok) {
            delete data; // 如果调用失败，需要手动释放数据
            throw WireGuard::WGException("napi_call_threadsafe_function failed with status: %d", status);
        }
        napi_release_threadsafe_function(func, napi_tsfn_release);
        if (status != napi_ok) {
            throw WireGuard::WGException("napi_release_threadsafe_function failed with status: %d", status);
        }
    } else {
        LOG_DEBUG("callbackOnSocketChangeListener no exe");
    }
}

namespace wg_napi {
    napi_value Init(napi_env env, napi_value exports) {
        napi_property_descriptor properties[] = {
            {"initVpn", nullptr, InitVpn, nullptr, nullptr, nullptr, napi_default, nullptr},
            {  "start", nullptr,   Start, nullptr, nullptr, nullptr, napi_default, nullptr},
            {  "close", nullptr,   Close, nullptr, nullptr, nullptr, napi_default, nullptr},
        };

        napi_value value;
        auto status = napi_define_class(env, "WireGuardDevice", NAPI_AUTO_LENGTH, New, nullptr, 3, properties, &value);
        if (status != napi_ok) {
            napi_throw_error(env, nullptr, "Node-API napi_define_class fail");
            return nullptr;
        }
        status = napi_set_named_property(env, exports, "WireGuardDevice", value);
        if (status != napi_ok) {
            napi_throw_error(env, nullptr, "Node-API napi_set_named_property fail");
            return nullptr;
        }
        return exports;
    }

    napi_value New(napi_env env, napi_callback_info info) {
        napi_value isNewTarget = nullptr;
        napi_get_new_target(env, info, &isNewTarget);
        napi_value jsThis;
        napi_get_cb_info(env, info, nullptr, nullptr, &jsThis, nullptr);
        if (isNewTarget != nullptr) {
            try {
                DevicePeerHelper *device = new DevicePeerHelper();
                device->_env = env;
                device->tag = 2;
                napi_status status = napi_wrap(
                    env, jsThis, reinterpret_cast<void *>(device),
                    [](napi_env env, void *finalize_data, void *finalize_hint) {
                        LOG_DEBUG("DevicePeerHelper 销毁");
                        delete reinterpret_cast<DevicePeerHelper *>(finalize_data);
                    },
                    nullptr, &device->_wrapper
                );
                // napi_wrap失败时，必须手动释放已分配的内存，以防止内存泄漏
                if (status != napi_ok) {
                    delete device;
                    LOG_ERROR("napi wrap 保存对象失败, return code: %{public}d", status);
                    throw WireGuard::WGException("wrap 报错 device 异常");
                }

                // 从napi_wrap接口的result获取napi_ref的行为，将会为jsThis创建强引用，
                // 若开发者不需要主动管理jsThis的生命周期，可直接在napi_wrap最后一个参数中传入nullptr，
                // 或者使用napi_reference_unref方法将napi_ref转为弱引用。
        
//        uint32_t refCount = 0;
//        napi_reference_unref(env, client->wrapper_, &refCount);

            } catch (const std::exception &e) {
                napi_throw_error(env, TAG.c_str(), "Node-API napi_wrap fail");
            }
            return jsThis;

        } else {
            // 使用`MyObject(...)`调用方式
            napi_value cons;
            const char *constructorName = "WireGuardDevice";
            napi_get_named_property(env, jsThis, constructorName, &cons);
            napi_value instance;
            napi_new_instance(env, cons, 0, nullptr, &instance);
            return instance;
        }
    }

    napi_value InitVpn(napi_env env, napi_callback_info info) {
        napi_value jsThis;
        size_t argc = 2;
        napi_value args[argc];
        napi_get_cb_info(env, info, &argc, args, &jsThis, nullptr);
        LOG_DEBUG("NAPI InitVpn");
        try {
            // 通过napi_unwrap将jsThis之前绑定的C++对象取出，并对其进行操作
            DevicePeerHelper *deviceHelper = nullptr;
            auto state = napi_unwrap(env, jsThis, reinterpret_cast<void **>(&deviceHelper));
            if (state != napi_ok || deviceHelper == nullptr) {
                throw WireGuard::WGException("对象获取失败");
            }

            napi_value connectConfig = args[0];
            // 解析 config数据
            deviceHelper->configPtr = std::make_shared<WireGuard::DeviceRegisterConfig>();
            LOG_DEBUG("NAPI InitVpn get Config");
            GetConnectConfig(env, connectConfig, *deviceHelper->configPtr);
            LOG_DEBUG("NAPI InitVpn invoke listener");


            napi_value method_value = args[1];
            NapiTools::TsfnContext context;
            napi_create_reference(env, method_value, 1, &context.callbackRef);
            deviceHelper->_currentListenerContext = context;

            // 创建异步资源名称（必需，不能为 nullptr）
            napi_value async_resource_name;
            napi_status nameStatus =
                napi_create_string_utf8(env, "SocketFdListener", NAPI_AUTO_LENGTH, &async_resource_name);
            if (nameStatus != napi_ok) {
                throw WireGuard::WGException("创建异步资源名称失败，status=%d", nameStatus);
            }

            // 创建线程安全函数
            napi_status tsfnStatus = napi_create_threadsafe_function(
                env,
                method_value,                           // ArkTS回调函数
                nullptr,                                // 异步资源对象（可以为 nullptr）
                async_resource_name,                    // 异步资源名称（必需，不能为 nullptr）
                0,                                      // 无限队列
                1,                                      // 初始线程数
                &deviceHelper->_currentListenerContext, // 上下文
                [](napi_env env, void *finalize_data, void *finalize_hint) {
                    NapiTools::TsfnContext *ctx = static_cast<NapiTools::TsfnContext *>(finalize_data);
                    if (ctx && ctx->callbackRef) {
                        napi_delete_reference(env, ctx->callbackRef);
                        LOG_DEBUG("回收Ref");
                        ctx->callbackRef = nullptr;
                        delete ctx;
                    }
                },                                                       // 最终化回调
                nullptr,                                                 // 最终化hint
                [](napi_env env, napi_value js_cb, void *, void *data) { // 主线程执行回调
                    napi_value argv[1];
                    int32_t *socketFd = static_cast<int32_t *>(data);
                    LOG_DEBUG("调用 socket fd callback fd=%{public}d", *socketFd);
                    auto status = napi_create_int32(env, *socketFd, &argv[0]);
                    status = napi_call_function(env, nullptr, js_cb, 1, argv, nullptr);
                    delete socketFd; // 释放数据
                    if (status != napi_ok) {
                        throw WireGuard::WGException("调用异常！status=%d", status);
                    }

                },
                &deviceHelper->_currentSocketFdListener
            );

            // 检查线程安全函数是否创建成功
            if (tsfnStatus != napi_ok || deviceHelper->_currentSocketFdListener == nullptr) {
                throw WireGuard::WGException("创建线程安全函数失败，status=%d", tsfnStatus);
            }
            LOG_DEBUG("线程安全函数创建成功");
            std::function<void(int &)> onChange{[deviceHelper](int fd) {
                try {
                    LOG_DEBUG("接口接收到SocketFD更换 fd=%{public}d", fd);
                    deviceHelper->callbackOnSocketChangeListener(fd);
                    LOG_DEBUG("接口接收到SocketFD更换 fd=%{public}d finish", fd);
                } catch (const std::exception &e) {
                    LOG_ERROR("回调异常：%s", e.what());
                    napi_throw_error(deviceHelper->_env, TAG.c_str(), e.what());
                }
            }};
            LOG_INFO("wireGuard initSocket");
            if (deviceHelper) {
                LOG_INFO("wireGuard initSocket invoke client create");
                WireGuard::Logs::print_space([&]() {
                    auto privateKey = deviceHelper->configPtr.get()->client.private_key;
                    auto ipStr = WireGuard::crypto::bin2B64(privateKey.data(), privateKey.size());
                    LOG_DEBUG("private key=%{public}s", ipStr.c_str());
                });
                deviceHelper->device = std::make_shared<WireGuard::Device>(*deviceHelper->configPtr);
                uint32_t sockFd = deviceHelper->device->initSocket(onChange);
                LOG_INFO("wireGuard initSocket invoke socket_fd: %{public}d", sockFd);
                napi_value tunnelFd;
                napi_create_int64(env, sockFd, &tunnelFd);
                return tunnelFd;
            } else {
                throw WireGuard::WGException("client unwrap failure");
            }
        } catch (const std::exception &e) {
            std::string error("初始化异常: ");
            error += (e.what());
            LOG_ERROR("%{public}s", error.data());
            napi_throw_error(env, TAG.data(), error.data());
            return nullptr;
        }
        // 返回 undefined
        napi_value result;
        napi_get_undefined(env, &result);
        return result;
    }

    napi_value Start(napi_env env, napi_callback_info info) {
        napi_value jsThis;
        size_t argc = 1;
        napi_value args[argc];
        napi_get_cb_info(env, info, &argc, args, &jsThis, nullptr);

        // 获取网卡 fd
        napi_value nvFd = args[0];
        uint32_t fd{};
        napi_get_value_uint32(env, nvFd, &fd);

        DevicePeerHelper *device;
        auto state = napi_unwrap(env, jsThis, reinterpret_cast<void **>(&device));
        if (state != napi_ok || device == nullptr) {
            throw WireGuard::WGException("对象获取失败");
        }
        try {
            LOG_INFO("wireGuard start fd=%{public}d", fd);
            if (device) {
                LOG_INFO("wireGuard start getClient");
                auto currentDevice = device->device;
                if (currentDevice) {
                    currentDevice->start(fd);
                    LOG_INFO("wireGuard start invoke");
                } else {
                    throw WireGuard::WGException("currentClient 客户端对象为获取到");
                }
            } else {
                throw WireGuard::WGException("client 客户端对象为获取到");
            }
        } catch (const std::exception &e) {
            std::string error("start 异常: ");
            error += (e.what());
            LOG_ERROR("%{public}s", error.data());
            napi_throw_error(env, TAG.data(), error.data());
            return nullptr;
        }
        napi_value result;
        napi_get_undefined(env, &result);
        return result;
    }

    napi_value Close(napi_env env, napi_callback_info info) {
        napi_value jsThis;
        napi_get_cb_info(env, info, nullptr, nullptr, &jsThis, nullptr);

        DevicePeerHelper *device;
        auto state = napi_unwrap(env, jsThis, reinterpret_cast<void **>(&device));
        if (state != napi_ok || device == nullptr) {
            throw WireGuard::WGException("对象获取失败");
        }
        try {
            if (!device) {
                throw WireGuard::WGException("client 客户端对象为获取到");
            }
            device->close();
            LOG_INFO("wireGuard close invoke");
        } catch (const std::exception &e) {
            std::string error("close 异常: ");
            error += (e.what());
            LOG_ERROR("%{public}s", error.data());
            napi_throw_error(env, TAG.data(), error.data());
            return nullptr;
        }
        napi_value result;
        napi_get_undefined(env, &result);
        return result;
    }


    /*
     * Struct结构体、Class类获取
     */

    int64_t getPropInt64_t(napi_env env, napi_value obj, const std::string propertyName) {
        napi_status status;
        napi_value listenerPort;
        status = napi_get_named_property(env, obj, propertyName.c_str(), &listenerPort);
        int64_t result;
        napi_get_value_int64(env, listenerPort, &result);
        return result;
    }
    uint32_t getPropUint32_t(napi_env env, napi_value obj, const std::string propertyName) {
        napi_status status;
        napi_value listenerPort;
        status = napi_get_named_property(env, obj, propertyName.c_str(), &listenerPort);
        uint32_t result;
        napi_get_value_uint32(env, listenerPort, &result);
        return result;
    }

    bool isHasProp(napi_env env, napi_value arg, const std::string propertyName) {
        bool result = false;
        napi_has_named_property(env, arg, propertyName.c_str(), &result);
        return result;
    }

    std::string getPropString(napi_env env, napi_value obj, const std::string propertyName) {
        napi_status status;
        napi_value nValue;
        status = napi_get_named_property(env, obj, propertyName.c_str(), &nValue);
        // 2. 获取字符串长度
        size_t len = 0;
        napi_get_value_string_utf8(env, nValue, nullptr, 0, &len);
        // 3. 分配内存并读取内容
        char *buf = new char[len + 1];
        napi_get_value_string_utf8(env, nValue, buf, len + 1, &len);
        return std::string(buf, len);
    }

    bool getPropBool(napi_env env, napi_value obj, const std::string propertyName) {
        napi_status status;
        napi_value listenerPort;
        status = napi_get_named_property(env, obj, propertyName.c_str(), &listenerPort);
        bool result;
        napi_get_value_bool(env, listenerPort, &result);
        return result;
    }

    void GetConnectConfig(napi_env env, napi_value arg, WireGuard::DeviceRegisterConfig &config) {
        napi_value nvDevice;
        napi_get_named_property(env, arg, "device", &nvDevice);
        GetDeviceConfig(env, nvDevice, config.client);

        // 获取 peers
        std::vector<WireGuard::PeerConfig> peers{};
        auto findItemCallback = [](napi_env env, napi_value nvItem, uint32_t index) {
            WireGuard::PeerConfig peer{};
            GetPeer(env, nvItem, peer);
            return peer;
        };
        getForArray<WireGuard::PeerConfig>(env, arg, "peers", peers, findItemCallback);
        if (peers.size() == 0) {
            throw WireGuard::WGException("没有Peer无法通信，至少有一个Peer");
        }
        config.peers = std::move(peers);
    }

    void GetDeviceConfig(napi_env env, napi_value arg, WireGuard::DeviceConfig &device) {
        // 获取 privateKey
        device.device_name = getPropString(env, arg, "deviceName");
        device.private_key = getPropToDecodeBase64WGKey(env, arg, "privateKey");
        // 获取 publicKey
        device.public_key = getPropToDecodeBase64WGKey(env, arg, "publicKey");

        if (isHasProp(env, arg, "listenerPort")) {
            // 获取 listenerPort
            auto port = getPropUint32_t(env, arg, "listenerPort");
            if (port > 0 && port < 65535) {
                device.listener_port = std::make_shared<uint32_t>(port);
            }
        }

        if (isHasProp(env, arg, "bindAddress")) {
            napi_value nvIp;
            napi_get_named_property(env, arg, "bindAddress", &nvIp);
            device.bind_address = std::make_shared<WireGuard::IPAddress>();
            GetIPAddress(env, nvIp, *device.bind_address);
        }
    }
    void GetPeer(napi_env env, napi_value arg, WireGuard::PeerConfig &peer) {
        // publicKey
        peer.public_key = getPropToDecodeBase64WGKey(env, arg, "publicKey");

        // allowedIps - ✅ 使用局部变量
        std::vector<WireGuard::IpAddressArea> allowedIps;
        auto findItemCallback = [](napi_env env, napi_value nvItem, uint32_t index) {
            WireGuard::IpAddressArea allowedIP;
            GetIpAddressArea(env, nvItem, allowedIP);
            return allowedIP;
        };
        getForArray<WireGuard::IpAddressArea>(env, arg, "allowedIps", allowedIps, findItemCallback);
        peer.allowedIps = std::move(allowedIps);

        // endpoint
        napi_value nvEndpoint;
        napi_get_named_property(env, arg, "endpoint", &nvEndpoint);
        GetEndpoint(env, nvEndpoint, peer.endpoint);

        // preSharedKey
        if (isHasProp(env, arg, "preSharedKey")) {
            auto result = getPropToDecodeBase64WGKey(env, arg, "preSharedKey");
            peer.pre_share_key = std::make_shared<WireGuard::SymmetricKey>(result);
        } else {
            LOG_DEBUG("preSharedKey 未获取到");
        }
        // keepaliveInterval
        if (isHasProp(env, arg, "keepaliveInterval")) {
            peer.keepaliveInterval = getPropUint32_t(env, arg, "keepaliveInterval");
        }
    }

    void GetEndpoint(napi_env env, napi_value arg, WireGuard::Endpoint &endpoint) {
        // 获取地址
        napi_value nvAddress;
        napi_get_named_property(env, arg, "address", &nvAddress);
        GetIPAddress(env, nvAddress, endpoint.address);
        // 获取端口
        endpoint.port = getPropInt64_t(env, arg, "port");
    }

// std::regex pattern_is_ipv4(R"(^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(\/\d{1,2})?$)");
    std::regex
        pattern_is_ipv4(R"(^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$)"
        );
    std::regex pattern_is_ipv4_cidr(
        R"(^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\/(?:[0-9]|[12][0-9]|3[0-2])$)"
    );
    std::regex pattern_is_ipv6(
        R"(^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$|^::1$|^::$|^(?:[0-9a-fA-F]{1,4}:)*::(?:[0-9a-fA-F]{1,4}:)*[0-9a-fA-F]{1,4}$|^(?:[0-9a-fA-F]{1,4}:)*::$)"
    );
    std::regex pattern_is_ipv6_cidr(
        R"(^(?:([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|::1|::$|(?:[0-9a-fA-F]{1,4}:)*::(?:[0-9a-fA-F]{1,4}:)*[0-9a-fA-F]{1,4}|(?:[0-9a-fA-F]{1,4}:)*::)\/(?:[0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$)"
    );


    void setIp(WireGuard::IPAddress &ipAddress, bool isIpv4, std::string ip) {
        if (isIpv4) {
            ipAddress.family = WireGuard::IPAddress::IPv4;
            if (std::regex_match(ip, pattern_is_ipv4)) {
                // 大端序方式保存
                if (inet_pton(AF_INET, ip.c_str(), &ipAddress.ip.ipv4) <= 0) {
                    throw std::invalid_argument("Invalid IPv4 address");
                }
            } else {
                throw std::invalid_argument("Ipv4地址不合法：" + ip);
            }
        } else {
            ipAddress.family = WireGuard::IPAddress::IPv6;
            if (std::regex_match(ip, pattern_is_ipv6)) {
                if (inet_pton(AF_INET6, ip.c_str(), &ipAddress.ip.ipv6) <= 0) {
                    throw std::invalid_argument("Invalid IPv6 address");
                }
            } else {
                throw std::invalid_argument("Ipv6地址不合法：" + ip);
            }
        }
    }
    void GetIpAddressArea(napi_env env, napi_value arg, WireGuard::IpAddressArea &ipArea) {
        napi_value nvIpAddress;
        napi_get_named_property(env, arg, "address", &nvIpAddress);
        GetIPAddress(env, nvIpAddress, ipArea.address);

        bool hasCidr;
        napi_has_named_property(env, arg, "cidr", &hasCidr);
        if (hasCidr) {
            auto cidr = getPropUint32_t(env, arg, "cidr");
            if (cidr > 255) {
                throw WireGuard::WGException("cidr超出 uint8_t 精度");
            }
            ipArea.cidr = cidr;
        } else {
            // 有/ 有掩码
            // 表示没有 /
//            ipArea.cidr = -1;
            throw WireGuard::WGException("ip 域必须指定掩码");
        }
    }

    void GetIPAddress(napi_env env, napi_value arg, WireGuard::IPAddress &ipAddress) {
        auto ip = getPropString(env, arg, "ip");
        auto isIpv4 = getPropBool(env, arg, "isIpv4");
        ipAddress.family = isIpv4 ? WireGuard::IPAddress::IPv4 : WireGuard::IPAddress::IPv6;
        if (ip.empty()) {
            throw std::invalid_argument("ip地址不能为空");
        }


        LOG_DEBUG("设置ip： %{public}s", ip.c_str());
        setIp(ipAddress, isIpv4, ip);
    }


    template <typename T>
    void getForArray(
        napi_env env, napi_value obj, const std::string propertyName, std::vector<T> &data,
        std::function<T(napi_env env, napi_value nvItem, uint32_t index)> findItemCallback
    ) {

        napi_value nvPeers;
        auto status = napi_get_named_property(env, obj, propertyName.c_str(), &nvPeers);
        if (status != napi_ok) {
            throw WireGuard::WGException("获取属性 %s 失败", propertyName.c_str());
        }
        bool isArray;
        napi_is_array(env, nvPeers, &isArray);
        if (isArray) {
            uint32_t peerSize;
            napi_get_array_length(env, nvPeers, &peerSize);
            data.clear();
            data.reserve(peerSize);
            for (uint32_t index = 0; index < peerSize; ++index) {
                napi_value nvItem;
                napi_get_element(env, nvPeers, index, &nvItem);
                auto item = findItemCallback(env, nvItem, index);
                data.push_back(item);
            }
        } else {
            LOG_INFO("%{}s,不是一个 array ", propertyName.c_str());
        }
    }

    std::array<uint8_t, 32> getPropToDecodeBase64WGKey(napi_env env, napi_value obj, const std::string propertyName) {
        auto str = getPropString(env, obj, propertyName);
        try {
            return WireGuard::crypto::base642Bin32Array(str);
        } catch (const WireGuard::WGException &e) {
            throw WireGuard::WGException(propertyName + " 格式异常，无法转换为32位bin");
        }
    }

};