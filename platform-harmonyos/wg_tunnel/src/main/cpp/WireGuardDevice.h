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
#pragma once

#include "device.h"
#include "entity.h"
#include "napi/native_api.h"
#include "napi_tools.h"
#include <cstdint>
#include <memory>
#include <mutex>

#ifndef WIREGUARD_WIREGUARDDEVICE_H
    #define WIREGUARD_WIREGUARDDEVICE_H

/**
 * @author leojay`fu
 */

class DevicePeerHelper {
public:
    DevicePeerHelper();
    ~DevicePeerHelper();

private:
    mutable std::mutex _deviceMutex;

public:
    napi_threadsafe_function _currentSocketFdListener{};
    NapiTools::TsfnContext _currentListenerContext;

    int32_t tag{0};
    napi_env _env;
    napi_ref _wrapper; // 主动管理生命周期
    std::shared_ptr<WireGuard::DeviceRegisterConfig> configPtr{nullptr};
    std::shared_ptr<WireGuard::Device> device{nullptr};

    /**
     * 通过 Socket fd 来关闭一个客户端，并且移除队列
     *
     * @param socketFd
     */
    void close();

    void callbackOnSocketChangeListener(int socketFd);
//    void callbackOnSocketChangeListener(int socketFd, napi_threadsafe_function _currentSocketFdListener);
};


namespace wg_napi {
    napi_value Init(napi_env env, napi_value exports);

    napi_value New(napi_env env, napi_callback_info info);
    napi_value InitVpn(napi_env env, napi_callback_info info);
    napi_value Start(napi_env env, napi_callback_info info);
    napi_value Close(napi_env env, napi_callback_info info);

    void GetConnectConfig(napi_env env, napi_value arg, WireGuard::DeviceRegisterConfig &config);
    void GetDeviceConfig(napi_env env, napi_value arg, WireGuard::DeviceConfig &peer);
    void GetPeer(napi_env env, napi_value arg, WireGuard::PeerConfig &peer);
    void GetIpAddressArea(napi_env env, napi_value arg, WireGuard::IpAddressArea &ipAddress);
    void GetIPAddress(napi_env env, napi_value arg, WireGuard::IPAddress &ipAddress);
    void GetEndpoint(napi_env env, napi_value arg, WireGuard::Endpoint &endpoint);

    bool isHasProp(napi_env env, napi_value arg, const std::string propertyName);
    std::string getPropString(napi_env env, napi_value obj, const std::string propertyName);
    uint32_t getPropUint32_t(napi_env env, napi_value obj, const std::string propertyName);
    int64_t getPropInt64_t(napi_env env, napi_value obj, const std::string propertyName);
    bool getPropBool(napi_env env, napi_value obj, const std::string propertyName);
    std::array<uint8_t, 32> getPropToDecodeBase64WGKey(napi_env env, napi_value obj, const std::string propertyName);


    template <typename T>
    inline void getForArray(
        napi_env env, napi_value obj, const std::string propertyName, std::vector<T> &data,
        std::function<T(napi_env env, napi_value nvItem, uint32_t index)> findItemCallback
    );

}; // namespace wg_napi


#endif // WIREGUARD_WIREGUARDDEVICE_H
