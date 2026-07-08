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
 * Created by Leojay on 2026/7/6.
 *
 * @author leojay`fu
 * @email crazyleojay@163.com
 * @url https://github.com/CrazyLeoJay
 */

#include <arpa/inet.h>

#include "device.h"
#include "../test_params.h"
#include "tools.h"
#include "gtest/gtest.h"

#include <iostream>
#include <atomic>
#include <thread>
#include <chrono>

// ---------- 跨平台信号处理 ----------
#ifdef _WIN32
#include <windows.h>
std::atomic<bool> g_running{true};

BOOL WINAPI console_handler(DWORD ctrl_type) {
    if (ctrl_type == CTRL_C_EVENT) {
        g_running = false;
        return TRUE; // 表示已处理
    }
    return FALSE;
}

void install_signal_handler() {
    SetConsoleCtrlHandler(console_handler, TRUE);
}
#else
#include <csignal>
#include <unistd.h>
std::atomic<bool> g_running{true};

void signal_handler(int signum) {
    if (signum == SIGINT) {
        g_running = false;
    }
}

void install_signal_handler() {
    struct sigaction sa;
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGINT, &sa, nullptr);
    // 也可用 signal(SIGINT, signal_handler)，但 sigaction 更可靠
}
#endif
// -------------------------------------

constexpr auto server_port = 51823;

WireGuard::DeviceRegisterConfig makeConfig() {
    WireGuard::DeviceRegisterConfig config{};
    config.client.device_name = "server";
    config.client.private_key = WireGuard::server_private;
    config.client.listener_port = std::make_shared<uint32_t>(server_port);

    WireGuard::PeerConfig pc{};

    pc.public_key = WireGuard::client_public;

    WireGuard::IpAddressArea iaa{};
    iaa.address = WireGuard::Tools::ipAddressForIpv4("10.3.3.1");
    iaa.cidr = 24;

    pc.allowedIps.push_back(iaa);
    config.peers.push_back(pc);
    return config;
}

void startServer() {
    const auto config = makeConfig();
    WireGuard::Device device{config};

    // 启动socket
    auto socket_fd = device.initSocketStart([](int fd) {
        LOG_INFO("server init for fd=%d", fd);
    });
    // 启动读取线程
    device.start(0);
    LOG_INFO("server start", socket_fd);
}

WireGuard::DeviceRegisterConfig makeClientConfig() {
    WireGuard::DeviceRegisterConfig config{};
    config.client.device_name = "server";
    config.client.private_key = WireGuard::client_private;

    WireGuard::PeerConfig pc{};

    pc.public_key = WireGuard::server_public;

    // 指定目标服务器和端口
    auto targetIp = WireGuard::Tools::ipAddressForIpv6("::1");
    pc.endpoint.address = targetIp;
    pc.endpoint.port = server_port;

    // 指定流量
    WireGuard::IpAddressArea iaa{};
    iaa.address = targetIp;
    iaa.cidr = 128;
    pc.allowedIps.push_back(iaa);

    config.peers.push_back(pc);
    return config;
}

void startClient() {
    const auto config = makeClientConfig();
    WireGuard::Device device{config};

    // 启动socket
    auto socket_fd = device.initSocketStart([](int fd) {
        LOG_INFO("client init for fd=%d", fd);
    });

    // 启动读取线程
    device.start(0);
    LOG_INFO("client start", socket_fd);
}

TEST(SOCKET, serverStart) {
    install_signal_handler();

    try {
        startServer();
    } catch (const std::exception &e) {
        LOG_ERROR("server start: %s", e.what());
    }

    std::cout << "Begin Working..." << std::endl;
    // 主循环，不断检查运行标志
    while (g_running) {
        // 执行你的任务（例如 VPN 数据收发）
        // std::cout << "Working..." << std::endl;
        sleep(2); // 模拟工作
    }

    std::cout << "Cleanup and exit." << std::endl;
    // 在这里释放 VPN 适配器、关闭套接字等
}

TEST(SOCKET, clientStart) {
    install_signal_handler();

    try {
        startClient();
    } catch (const std::exception &e) {
        LOG_ERROR("client start %s", e.what());
    }

    std::cout << "Begin Working..." << std::endl;
    // 主循环，不断检查运行标志
    while (g_running) {
        // 执行你的任务（例如 VPN 数据收发）
        // std::cout << "Working..." << std::endl;
        sleep(2); // 模拟工作
    }

    std::cout << "Cleanup and exit." << std::endl;
    // 在这里释放 VPN 适配器、关闭套接字等
}

TEST(network, ipv6) {
    WireGuard::IPAddress result;
    try {
        result = WireGuard::Tools::ipAddressForIpv6("[fd6e:627:ac0e:0:9167:135:56bc:3098]");
        std::cout << "ipv6 addresses:" << result.toIpStr() << std::endl;
    } catch (const std::exception &e) {
        LOG_ERROR("ipv6 addresses: %s", e.what());
    }
    try {
        result = WireGuard::Tools::ipAddressForIpv6("fd6e:627:ac0e:0:9167:135:56bc:3098");
        std::cout << "ipv6 addresses:" << result.toIpStr() << std::endl;
    } catch (const std::exception &e) {
        LOG_ERROR("ipv6 addresses: %s", e.what());
    }
}
