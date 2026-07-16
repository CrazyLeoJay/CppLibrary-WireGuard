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

WireGuard::DeviceRegisterConfig makeConfig() {
    std::string configPath = TEST_DATA_DIR;
    configPath += "/wg.内网ipto.61234.conf";

    std::ifstream file(configPath);
    // ASSERT_TRUE(file.is_open()) << "配置文件打开失败: " << configPath;
    std::string content((std::istreambuf_iterator<char>(file)),
                        std::istreambuf_iterator<char>());
    file.close();

    WireGuard::Tools::WGConf conf = WireGuard::Tools::readConfFileToEntity(content);
    return WireGuard::Tools::wgConfToDeviceRegisterConfig(conf);
}


TEST(DEVICE_TEST, default_test) {
    const auto config = makeConfig();
    WireGuard::Device device{config};
    device.initSocketStart([](int fd) {
    });

    device.start(0);
    WireGuard::Tools::runWithDuration(std::chrono::seconds(5), std::chrono::seconds(1), "Device test running");
    LOG_INFO("調用結束");
    // device.close();
}
