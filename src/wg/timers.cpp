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


#include "timers.h"
#include <thread>
#include <chrono>

/**
 * @namespace WireGuard
 * @brief WireGuard定时器的实现
 * 
 * 本文件实现了跨平台的定时器功能，
 * 用于处理WireGuard协议中的各种定时任务。
 */
namespace WireGuard {
    /**
     * @brief Timer构造函数实现
     * 
     * 初始化定时器的基本参数：
     * - 回调函数：定时器触发时要执行的操作
     * - 间隔时间：定时器的触发间隔
     * 
     * 注意：使用std::move转移回调函数的所有权，避免不必要的拷贝。
     * 
     * @param callback 定时器回调函数
     * @param interval 定时器间隔（毫秒）
     */
    Timer::Timer(Callback callback, std::chrono::milliseconds interval)
        : callback_(std::move(callback)), interval_(interval) {
        // 初始化成员变量
        // running默认为false（未运行状态）
        // timer_thread_默认为空（无工作线程）
    }

    /**
     * @brief Timer析构函数实现
     * 
     * 确保在对象销毁前正确停止定时器。
     * 调用stop()方法来安全地停止工作线程。
     */
    Timer::~Timer() {
        stop();
    }

    /**
     * @brief 启动定时器实现
     * 
     * 创建并启动定时器工作线程。
     * 工作线程会按指定间隔重复执行回调函数。
     * 
     * 线程安全保证：
     * - 检查running状态避免重复启动
     * - 使用原子操作确保状态一致性
     */
    void Timer::start() {
        // 死代码缺陷修复：加锁保护 timer_thread_ / running 的状态迁移，
        // 避免 start 与 stop 跨线程并发时 stop 读到尚未 make_unique 的空指针而跳过 join
        std::lock_guard<std::mutex> lock(mutex_);
        // stopping_ 期间禁止启动：旧线程可能尚未 join 完成，若此时拉起新线程，
        // 旧线程会因 running 复为 true 而继续运行，形成两条定时线程
        if (running.load() || stopping_) {
            return;
        }

        // 标记为运行状态
        running.store(true);

        // 世代号自增：使旧的（含 detach 后尚未退出的）线程在下一轮循环判定失效而退出。
        // 单靠 running 无法区分"新 start() 置回 true"与"旧线程仍在跑"，会并存两条线程
        const uint64_t gen = generation_.fetch_add(1, std::memory_order_acq_rel) + 1;

        // 创建并启动工作线程
        timer_thread_ = std::make_unique<std::thread>(&Timer::run, this, gen);
    }

    /**
     * @brief 停止定时器实现
     * 
     * 安全地停止定时器工作线程。
     * 等待工作线程完成当前操作后退出。
     * 
     * 线程安全保证：
     * - 检查running状态避免重复停止
     * - 使用join()等待线程安全退出
     */
    void Timer::stop() {
        // 死代码缺陷修复：与 start() 共用 mutex_，保证 stop 一定读到已创建的线程句柄
        // （原实现无锁，stop 可能在 make_unique 完成前读到空指针而跳过 join，
        //  最终析构 joinable 线程触发 std::terminate）
        std::unique_ptr<std::thread> toJoin;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            // 检查是否已经停止，避免重复操作
            if (!running.load()) {
                return;
            }
            // 先置停止/进行中标志，再取走句柄
            running.store(false);
            stopping_ = true;
            toJoin = std::move(timer_thread_);
        }

        // 在锁外 join：若回调内部再调用 stop()/restart()，持锁 join 会造成自死锁
        if (toJoin && toJoin->joinable()) {
            if (toJoin->get_id() == std::this_thread::get_id()) {
                // 从定时器线程内部停止自身：join 自己会 std::terminate，改为 detach
                // （running 已置 false，run() 循环会在当前回调返回后自然退出）
                toJoin->detach();
            } else {
                toJoin->join();
            }
        }

        // 清除进行中标志，允许后续 start()
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = false;
    }

    /**
     * @brief 重新启动定时器实现
     * 
     * 停止当前定时器并使用新的间隔重新启动。
     * 用于动态调整定时器频率。
     * 
     * @param new_interval 新的定时器间隔（毫秒）
     */
    void Timer::restart(std::chrono::milliseconds new_interval) {
        // 停止当前定时器
        stop();

        // 更新间隔时间
        interval_ = new_interval;

        // 重新启动定时器
        start();
    }

    /**
     * @brief 定时器工作线程主函数
     * 
     * 这是工作线程的主循环，执行以下步骤：
     * 1. 睡眠指定的间隔时间
     * 2. 检查是否仍处于运行状态
     * 3. 如果仍在运行，执行回调函数
     * 4. 重复上述过程
     * 
     * 注意：在睡眠后再次检查running状态，
     * 以确保在stop()被调用时不会执行回调函数。
     */
    void Timer::run(uint64_t generation) {
        // 循环条件同时校验 running 与世代号：
        // 世代号被新 start() 刷新后，本线程（含 stop() 从回调内自停而 detach 的残留线程）
        // 立即退出，不会因 running 复为 true 而继续运行形成双线程。
        while (running.load() && generation_.load(std::memory_order_acquire) == generation) {
            // 睡眠指定的间隔时间
            std::this_thread::sleep_for(interval_);

            // 再次检查运行状态与世代号（防止在睡眠期间被停止/被新线程取代）
            if (running.load() && generation_.load(std::memory_order_acquire) == generation) {
                // 执行回调函数
                callback_();
            }
        }
    }

    int initTimers() {
        // TODO: 高精度定时器和高效定时器管理未实现
        // Linux: 使用内核hrtimers配合正确的调度
        // Windows: 使用可等待定时器对象或CreateTimerQueueTimer
        // 跨平台: 使用std::chrono配合high_resolution_clock，但生产环境考虑boost::asio::steady_timer
        // 已实现：基本的定时器功能（实际生产环境应使用boost::asio）

        // 初始化全局定时器子系统
        return 0;
    }

    void cleanupTimers() {
        // 清理全局定时器子系统
    }
}
