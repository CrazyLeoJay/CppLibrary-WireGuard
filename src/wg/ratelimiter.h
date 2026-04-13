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

#ifndef WIREGUARD_RATELIMITER_H
#define WIREGUARD_RATELIMITER_H


#include <cstdint>
#include <unordered_map>
#include <mutex>
#include "version.h"

/**
 * @namespace WireGuard
 * @brief WireGuard协议的速率限制模块
 * 
 * 速率限制器（Rate Limiter）是WireGuard DoS防护机制的重要组成部分，
 * 用于限制来自单个IP地址的请求频率，防止资源耗尽攻击。
 * 
 * 实现原理：
 * - 使用令牌桶算法（Token Bucket Algorithm）
 * - 每个IP地址维护独立的令牌桶
 * - 定期向桶中添加令牌
 * - 处理请求时消耗令牌
 * - 无令牌时拒绝请求
 */
namespace WireGuard {
    /**
     * @brief 速率限制器类
     * 
     * 实现基于令牌桶算法的速率限制功能，
     * 用于控制来自单个IP地址的请求频率。
     * 
     * 令牌桶算法特点：
     * - 允许突发流量（桶中有足够令牌时）
     * - 长期平均速率受限制
     * - 实现简单且高效
     * 
     * 在WireGuard中的用途：
     * - 限制握手请求频率
     * - 防止Cookie请求滥用
     * - 保护服务器资源免受DoS攻击
     */
    class RateLimiter {
    public:
        /**
         * @brief 构造函数
         * 
         * 初始化速率限制器，默认配置：
         * - 最大令牌数：10
         * - 令牌生成速率：5个/秒
         * - 令牌间隔：200毫秒
         */
        RateLimiter();

        /**
         * @brief 析构函数
         * 
         * 自动清理所有IP地址的速率限制状态。
         */
        ~RateLimiter();

        /**
         * @brief 检查是否允许请求
         * @param ip IPv4地址（网络字节序）
         * @return 如果允许请求返回true，否则返回false
         * 
         * 执行令牌桶算法：
         * 1. 计算自上次更新以来的时间
         * 2. 根据时间添加相应数量的令牌
         * 3. 如果有可用令牌，消耗一个并允许请求
         * 4. 否则拒绝请求
         * 
         * 注意：此函数是线程安全的。
         */
        bool allow(uint32_t ip);

        /**
         * @brief 清空所有速率限制状态
         * 
         * 移除所有IP地址的速率限制条目，
         * 重置为初始状态。
         */
        void clear();

        /**
         * @brief 设置速率限制参数
         * @param packets_per_second 每秒允许的数据包数量
         * 
         * 动态调整速率限制参数：
         * - 更新令牌生成速率
         * - 调整最大令牌数（至少10个）
         * - 重新计算令牌间隔
         * 
         * 注意：此函数是线程安全的。
         */
        void setRateLimit(int packets_per_second);

    private:
        /**
         * @brief 速率限制条目结构体
         * 
         * 为每个IP地址维护的速率限制状态。
         */
        struct Entry {
            uint64_t last_time; ///< 上次更新时间（纳秒）
            int tokens; ///< 当前可用令牌数
        };

        mutable std::mutex limiter_mutex; ///< 保护哈希表的互斥锁
        std::unordered_map<uint32_t, Entry> entries; ///< IP地址到速率限制状态的映射
        int max_tokens; ///< 令牌桶最大容量
        int tokens_per_second; ///< 每秒生成的令牌数
        uint64_t token_interval_ns; ///< 令牌生成间隔（纳秒）
    };

    // ==================== 全局速率限制器函数 ====================

    /**
     * @brief 初始化全局速率限制器
     * @return 成功返回0，失败返回负错误码
     * 
     * 创建全局速率限制器实例，
     * 在程序启动时调用一次。
     */
    int initRateLimiter();

    /**
     * @brief 清理全局速率限制器
     * 
     * 释放全局速率限制器资源，
     * 在程序退出时调用。
     */
    void cleanupRateLimiter();

    /**
     * @brief 全局速率限制检查
     * @param ip IPv4地址（网络字节序）
     * @return 如果允许请求返回true，否则返回false
     * 
     * 使用全局速率限制器检查请求是否被允许。
     * 如果全局限制器未初始化，则默认允许所有请求。
     */
    bool ratelimiterAllow(uint32_t ip);
}


#endif //WIREGUARD_RATELIMITER_H