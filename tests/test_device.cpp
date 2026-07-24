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
 * Created by Leojay on 2026/7/16.
 *
 * @author leojay`fu
 * @email crazyleojay@163.com
 * @url https://github.com/CrazyLeoJay
 */

#include "device.h"
#include "gtest/gtest.h"
#include "tools/conf_file.h"
#include "tools.h"

WireGuard::DeviceRegisterConfig makeConfig(std::string path = "wg.内网ipto.61234.conf") {
    std::string configPath = TEST_DATA_DIR;
    configPath += "/" + path;

    LOG_INFO("配置文件路径: %s", configPath.c_str());
    std::ifstream file(configPath);
    if (!file.is_open()) {
        LOG_ERROR("配置文件打开失败: %s", configPath.c_str());
        throw std::runtime_error("配置文件打开失败: " + configPath);
    }
    std::string content((std::istreambuf_iterator<char>(file)),
                        std::istreambuf_iterator<char>());
    file.close();

    LOG_INFO("配置文件内容:\n%s", content.c_str());

    WireGuard::Tools::WGConf conf = WireGuard::Tools::readConfFileToEntity(content);

    auto printLog = WireGuard::Tools::wgConfToOfficialConfigStr(conf);
    LOG_INFO("读取内容:\n%s", printLog.c_str());

    auto config = WireGuard::Tools::wgConfToDeviceRegisterConfig(conf);


    return config;
}


TEST(DEVICE_TEST, default_test) {
    // const auto config = makeConfig(); // 连接openwrt服务。握手正常
    // const auto config = makeConfig("test.local.tmp.conf"); // 连接 Ubuntu 的 WireGuard服务，无法获取到返回日志
    const auto config = makeConfig("test.pivpn.tmp.conf"); // 连接 pivpn 的 WireGuard服务，握手响应解密异常，需要处理
    WireGuard::Device device{config};
    device.initSocketStart([](int fd) {
    });

    device.start(0);
    WireGuard::Tools::runWithDuration(std::chrono::seconds(5), std::chrono::seconds(1), "Device test running");
    LOG_INFO("調用結束");
    // device.close();
}
