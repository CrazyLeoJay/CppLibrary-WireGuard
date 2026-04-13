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

#ifndef WIREGUARD_QUEUEING_H
#define WIREGUARD_QUEUEING_H


#include <cstdint>
#include <memory>
#include <queue>
#include <mutex>
#include <condition_variable>
#include "version.h"

/**
 * @namespace WireGuard
 * @brief WireGuard协议的队列管理模块
 * 
 * 队列管理是WireGuard高性能实现的关键组件。
 * 它负责在不同线程/组件之间安全地传递数据包，
 * 确保加密、解密、网络I/O等操作能够并行处理。
 */
namespace WireGuard {
    /**
     * @brief 数据包结构体
     * 
     * 表示一个待处理的网络数据包，包含原始数据和元信息。
     * 这个结构体用于在队列中传递数据包，避免频繁的内存拷贝。
     */
    struct Packet {
        uint8_t *data; ///< 指向数据包原始数据的指针
        size_t len; ///< 数据包长度（字节）
        bool is_ipv4; ///< 协议类型：true表示IPv4，false表示IPv6

        /**
         * @brief 构造函数
         * @param data 数据包原始数据指针
         * @param len 数据包长度
         * @param is_ipv4 协议类型标识
         * 
         * 注意：此构造函数不复制数据，只存储指针。
         * 调用者必须确保数据在Packet对象生命周期内有效。
         */
        Packet(uint8_t *data, size_t len, bool is_ipv4)
            : data(data), len(len), is_ipv4(is_ipv4) {
        }
    };

    /**
     * @brief 线程安全的数据包队列
     * 
     * 这是一个线程安全的先进先出（FIFO）队列，
     * 用于在生产者线程（如网络接收线程）和消费者线程（如加密处理线程）之间传递数据包。
     * 
     * 关键特性：
     * - 线程安全：使用互斥锁保护内部状态
     * - 高效：避免不必要的内存拷贝
     * - 灵活：支持动态内存管理
     */
    class PacketQueue {
    public:
        /**
         * @brief 构造函数
         * 
         * 初始化空队列，所有成员变量设置为默认值。
         */
        PacketQueue();

        /**
         * @brief 析构函数
         * 
         * 自动清理队列中的所有数据包。
         * 注意：析构函数会等待所有操作完成，确保线程安全。
         */
        ~PacketQueue();

        /**
         * @brief 入队操作
         * @param packet 要添加到队列的数据包（通过unique_ptr转移所有权）
         * 
         * 将数据包添加到队列尾部，并通知等待的消费者线程。
         * 此操作是线程安全的，可以在多个生产者线程中同时调用。
         */
        void enqueue(std::unique_ptr<Packet> packet);

        /**
         * @brief 出队操作
         * @return 队列头部的数据包，如果队列为空则返回nullptr
         * 
         * 从队列头部移除并返回数据包。
         * 此操作是线程安全的，可以在多个消费者线程中同时调用。
         * 注意：当前实现是非阻塞的，如果队列为空立即返回nullptr。
         */
        std::unique_ptr<Packet> dequeue();

        /**
         * @brief 检查队列是否为空
         * @return 如果队列为空返回true，否则返回false
         * 
         * 此操作是线程安全的，但返回值可能在调用后立即过期（因为其他线程可能修改队列）。
         */
        bool empty() const;

        /**
         * @brief 获取队列大小
         * @return 队列中数据包的数量
         * 
         * 此操作是线程安全的，但返回值可能在调用后立即过期。
         */
        size_t size() const;

    private:
        mutable std::mutex queue_mutex; ///< 保护队列的互斥锁
        std::condition_variable queue_cv; ///< 条件变量，用于线程间通信
        std::queue<std::unique_ptr<Packet> > packets; ///< 实际存储数据包的队列
    };

    /**
     * @brief 初始化全局队列子系统
     * @return 成功返回0，失败返回负错误码
     * 
     * 初始化WireGuard所需的全局队列资源，
     * 包括工作线程池、每CPU队列等。
     * 在程序启动时调用一次。
     */
    int initQueueing();

    /**
     * @brief 清理全局队列子系统
     * 
     * 释放所有队列相关的资源，
     * 停止所有工作线程，清空所有队列。
     * 在程序退出时调用。
     */
    void cleanupQueueing();
}

#endif //WIREGUARD_QUEUEING_H