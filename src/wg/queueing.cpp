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

#include "queueing.h"

#include <atomic>
#include <memory>
#include <thread>

/**
 * @namespace WireGuard
 * @brief WireGuard队列管理的实现
 * 
 * 本文件实现了线程安全的数据包队列，
 * 用于在WireGuard的不同组件之间高效传递数据包。
 * 队列设计考虑了高性能、线程安全和内存效率。
 */
namespace WireGuard {
    // 全局队列管理器
    namespace {
        std::vector<std::unique_ptr<std::thread> > worker_threads;
        std::atomic<bool> queueing_active{false};
        std::atomic<size_t> thread_count{0};

        // 工作线程函数
        void worker_thread_func() {
            while (queueing_active.load()) {
                // TODO: 这里应该从全局工作队列中获取任务并执行
                // 由于当前设计是每个组件有自己的队列，这里作为占位符
                // 实际实现中，可以使用无锁队列或条件变量等待任务

                // 短暂休眠以避免忙等待
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        }
    }


    /**
     * @brief PacketQueue构造函数
     * 
     * 使用默认构造函数初始化所有成员变量：
     * - queue_mutex: 初始化为空的互斥锁
     * - queue_cv: 初始化为空的条件变量  
     * - packets: 初始化为空的队列
     * 
     * 初学者注意：= default 表示使用编译器生成的默认构造函数，
     * 这比手动初始化更高效且不易出错。
     */
    PacketQueue::PacketQueue() = default;

    /**
     * @brief PacketQueue析构函数
     * 
     * 自动清理队列中的所有数据包。
     * 由于使用了std::unique_ptr，析构时会自动调用每个Packet的析构函数，
     * 释放相关的内存资源。
     * 
     * 注意：析构函数会隐式获取互斥锁以确保线程安全，
     * 但在此简化实现中，我们假设析构时没有其他线程在访问队列。
     */
    PacketQueue::~PacketQueue() = default;

    /**
     * @brief 入队操作实现
     * 
     * 此函数将数据包添加到队列尾部，步骤如下：
     * 1. 获取互斥锁（lock_guard自动管理锁的获取和释放）
     * 2. 将数据包移动到队列尾部（避免不必要的拷贝）
     * 3. 通知等待的消费者线程（通过条件变量）
     * 
     * 线程安全保证：
     * - lock_guard确保在函数结束时自动释放锁
     * - std::move避免了数据包的深拷贝，提高性能
     * - 条件变量通知确保消费者能及时处理新数据
     * 
     * @param packet 要入队的数据包（通过unique_ptr转移所有权）
     */
    void PacketQueue::enqueue(std::unique_ptr<Packet> packet) {
        // 获取互斥锁，确保线程安全
        std::lock_guard<std::mutex> lock(queue_mutex);

        // 将数据包移动到队列尾部（避免拷贝）
        packets.push(std::move(packet));

        // 通知等待的消费者线程
        queue_cv.notify_one();
    }

    /**
     * @brief 出队操作实现
     * 
     * 此函数从队列头部移除并返回数据包，步骤如下：
     * 1. 获取互斥锁（unique_lock允许更灵活的锁管理）
     * 2. 检查队列是否为空
     * 3. 如果不为空，移除并返回头部数据包
     * 
     * 注意：当前实现是非阻塞的，如果队列为空立即返回nullptr。
     * 在实际生产环境中，可能需要阻塞等待直到有数据可用。
     * 
     * @return 队列头部的数据包，如果队列为空则返回nullptr
     */
    std::unique_ptr<Packet> PacketQueue::dequeue() {
        // 获取互斥锁
        std::unique_lock<std::mutex> lock(queue_mutex);

        // 检查队列是否为空
        if (packets.empty()) {
            return nullptr;
        }

        // 移除并获取队列头部的数据包
        auto packet = std::move(packets.front());
        packets.pop();

        return packet;
    }

    /**
     * @brief 检查队列是否为空
     * 
     * 此函数检查队列中是否还有待处理的数据包。
     * 由于使用了互斥锁保护，此操作是线程安全的。
     * 
     * 注意：返回值可能在函数返回后立即过期，
     * 因为其他线程可能在同时修改队列状态。
     * 
     * @return 如果队列为空返回true，否则返回false
     */
    bool PacketQueue::empty() const {
        // 获取互斥锁（const版本使用mutable修饰的mutex）
        std::lock_guard<std::mutex> lock(queue_mutex);
        return packets.empty();
    }

    /**
     * @brief 获取队列大小
     * 
     * 此函数返回队列中当前的数据包数量。
     * 由于使用了互斥锁保护，此操作是线程安全的。
     * 
     * 注意：返回值可能在函数返回后立即过期，
     * 因为其他线程可能在同时修改队列状态。
     * 
     * @return 队列中数据包的数量
     */
    size_t PacketQueue::size() const {
        // 获取互斥锁（const版本使用mutable修饰的mutex）
        std::lock_guard<std::mutex> lock(queue_mutex);
        return packets.size();
    }

    /**
     * @brief 初始化全局队列子系统
     * 
     * 此函数初始化WireGuard所需的全局队列资源。
     * 在完整的实现中，这应该包括：
     * - 创建工作线程池
     * - 初始化每CPU队列
     * - 设置负载均衡策略
     * 
     * 当前实现是一个简化版本，只返回成功状态。
     * 
     * TODO: 完整的跨平台队列初始化未实现
     * Linux: 使用内核工作队列配合每CPU队列
     * Windows: 使用线程池配合I/O完成端口  
     * 跨平台: 实现线程池配合任务分发
     * 已实现：基本的队列初始化（实际生产环境需要线程池）
     * 
     * @return 成功返回0，失败返回负错误码
     */
    int initQueueing() {
        // 初始化全局队列子系统
        // 避免重复初始化
        if (queueing_active.load()) {
            return 0;
        }

        // 获取硬件并发线程数，至少使用1个线程
        size_t num_threads = std::thread::hardware_concurrency();
        if (num_threads == 0) {
            num_threads = 1; // 如果无法检测，使用1个线程
        }

        // 限制最大线程数以避免资源过度消耗
        num_threads = std::min(num_threads, static_cast<size_t>(8));

        // 标记队列为活跃状态
        queueing_active.store(true);
        thread_count.store(num_threads);

        try {
            // 创建工作线程
            worker_threads.reserve(num_threads);
            for (size_t i = 0; i < num_threads; ++i) {
                worker_threads.push_back(std::make_unique<std::thread>(worker_thread_func));
            }
        } catch (const std::exception &e) {
            // 清理已创建的线程
            cleanupQueueing();
            return -1;
        }

        return 0;
    }

    /**
     * @brief 清理全局队列子系统
     * 
     * 此函数释放所有队列相关的资源。
     * 在完整的实现中，这应该包括：
     * - 停止所有工作线程
     * - 清空所有队列
     * - 释放相关内存
     * 
     * 当前实现是一个简化版本，不做任何操作。
     * 
     * TODO: 完整的跨平台队列清理未实现
     * Linux: 停止内核工作队列，清理每CPU队列
     * Windows: 停止线程池，清理I/O完成端口
     * 跨平台: 停止线程池，清空所有队列
     * 已实现：基本的队列清理占位符
     */
    void cleanupQueueing() {
        // 标记队列为非活跃状态，通知所有工作线程退出
        queueing_active.store(false);

        // 等待所有工作线程安全退出
        for (auto &thread: worker_threads) {
            if (thread && thread->joinable()) {
                thread->join();
            }
        }

        // 清空线程容器
        worker_threads.clear();

        // 重置线程计数
        thread_count.store(0);
    }
}