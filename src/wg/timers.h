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
// Created on 2026/3/20.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef WIREGUARD_TIMERS_H
#define WIREGUARD_TIMERS_H


#include <chrono>
#include <functional>
#include <memory>
#include <thread>
#include <atomic>
#include "version.h"

/**
 * @namespace WireGuard
 * @brief WireGuard协议的定时器管理模块
 * 
 * 定时器是WireGuard协议的重要组成部分，用于：
 * - 维护连接保活（keepalive）
 * - 处理握手超时和重试
 * - 执行密钥轮换
 * - 管理各种协议相关的定时任务
 * 
 * 在VPN场景中，由于NAT路由器会清除长时间不活动的连接状态，
 * 定时器通过定期发送数据包来保持连接活跃，确保通信的连续性。
 */
namespace WireGuard {
    /**
     * @brief 定时器类
     * 
     * 提供跨平台的定时器功能，用于执行周期性或延迟任务。
     * 在WireGuard中主要用于：
     * - 发送保活包（keepalive packets）
     * - 重试失败的握手
     * - 超时检测不活跃的连接
     * - 触发密钥轮换
     * 
     * 实现原理：
     * 使用独立线程配合休眠机制实现定时功能。当调用start()方法时，
     * 创建一个新线程，该线程会循环执行：休眠指定间隔 -> 检查是否仍在运行 ->
     * 执行回调函数。这种设计避免了阻塞主线程，同时保证了定时精度。
     */
    class Timer {
    public:
        // 定义回调函数类型，用于在定时器触发时执行特定操作
        using Callback = std::function<void()>;

        /**
         * @brief 构造函数
         * @param callback 定时器触发时要执行的回调函数
         * @param interval 定时器间隔（毫秒）
         * 
         * 创建一个定时器实例，但不会立即启动。
         * 需要调用start()方法来启动定时器。
         * 
         * 示例用法：
         * auto timer = std::make_unique<Timer>(
         *     []() { std::cout << "定时器触发!" << std::endl; },
         *     std::chrono::seconds(5)
         * );
         * timer->start(); // 开始每5秒打印一次消息
         */
        Timer(Callback callback, std::chrono::milliseconds interval);

        /**
         * @brief 析构函数
         * 
         * 自动停止定时器并清理相关资源。
         * 确保在对象销毁前正确停止定时器线程。
         * 如果不显式调用stop()，析构函数会自动处理停止逻辑，
         * 避免出现悬挂线程（dangling thread）的问题。
         */
        ~Timer();

        /**
         * @brief 启动定时器
         * 
         * 启动定时器线程，开始按指定间隔执行回调函数。
         * 如果定时器已经在运行，则此函数无效果。
         * 
         * 注意：启动后会在后台创建一个线程专门处理定时任务，
         * 这个线程会持续运行直到被stop()或析构函数终止。
         */
        void start();

        /**
         * @brief 停止定时器
         * 
         * 停止定时器线程，不再执行回调函数。
         * 如果定时器未运行，则此函数无效果。
         * 
         * 实现细节：设置running标志为false，唤醒等待的线程，
         * 然后join()等待线程安全退出。这是典型的"合作式中断"模式。
         */
        void stop();

        /**
         * @brief 重新启动定时器
         * @param new_interval 新的定时器间隔（毫秒）
         * 
         * 停止当前定时器并使用新的间隔重新启动。
         * 用于动态调整定时器频率（如根据网络状况调整保活间隔）。
         * 
         * 典型应用场景：网络质量差时缩短保活间隔；网络稳定时延长间隔以减少流量消耗。
         */
        void restart(std::chrono::milliseconds new_interval);

        /**
         * @brief 检查定时器是否正在运行
         * @return 如果定时器正在运行返回true，否则返回false
         * 
         * 使用原子操作读取运行状态，确保多线程环境下的安全性。
         * 可用于状态监控和调试。
         */
        bool isRunning() const { return running.load(); }

    private:
        /**
         * @brief 内部运行函数
         * 
         * 这是定时器线程的主循环函数，包含核心逻辑：
         * 1. 循环检查running标志
         * 2. 休眠指定的时间间隔
         * 3. 检查是否仍需继续运行
         * 4. 执行用户注册的回调函数
         * 
         * 该函数在线程中被调用，实现了非阻塞的定时机制。
         */
        void run();

        Callback callback_; ///< 定时器回调函数，保存用户定义的操作
        std::chrono::milliseconds interval_; ///< 定时器间隔，决定多久执行一次回调
        std::atomic<bool> running{false}; ///< 运行状态标志（原子操作保证线程安全）
        std::unique_ptr<std::thread> timer_thread_; ///< 定时器工作线程，负责执行定时任务
    };

    // 定时器管理函数
    int initTimers();

    void cleanupTimers();
}

#endif //WIREGUARD_TIMERS_H