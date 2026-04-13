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


#include "ratelimiter.h"
#include <chrono>
#include <memory>

/**
 * @namespace WireGuard
 * @brief WireGuard速率限制器的实现
 * 
 * 本文件实现了基于令牌桶算法的速率限制功能，
 * 用于WireGuard的DoS防护机制。
 * 
 * 令牌桶算法原理：
 * - 桶中有固定容量的令牌
 * - 令牌以固定速率生成并添加到桶中
 * - 处理请求时消耗一个令牌
 * - 如果桶中没有令牌，则拒绝请求
 * - 允许突发流量（只要桶中有足够令牌）
 */
namespace WireGuard {
    /**
     * @brief RateLimiter构造函数实现
     * 
     * 初始化速率限制器的默认参数：
     * - max_tokens: 10（最大令牌数，允许突发流量）
     * - tokens_per_second: 5（每秒生成5个令牌）
     * - token_interval_ns: 200,000,000纳秒（200毫秒，即每200ms生成1个令牌）
     * 
     * 这些默认值提供了合理的DoS防护：
     * - 允许短时间内的突发握手请求（最多10个）
     * - 长期平均速率限制为5次/秒
     */
    RateLimiter::RateLimiter()
        : max_tokens(10)
          , tokens_per_second(5)
          , token_interval_ns(1000000000ULL / tokens_per_second) {
        // token_interval_ns = 1秒 / tokens_per_second = 1000000000纳秒 / 5 = 200000000纳秒
    }

    /**
     * @brief RateLimiter析构函数实现
     * 
     * 自动清理所有IP地址的速率限制状态。
     * 调用clear()方法确保正确释放资源。
     */
    RateLimiter::~RateLimiter() {
        clear();
    }

    /**
     * @brief 检查是否允许请求实现
     * 
     * 执行令牌桶算法的核心逻辑：
     * 1. 获取当前时间（纳秒精度）
     * 2. 获取互斥锁保护共享状态
     * 3. 查找或创建IP地址对应的速率限制条目
     * 4. 计算自上次更新以来经过的时间
     * 5. 根据经过的时间添加相应数量的令牌
     * 6. 更新最后更新时间（考虑余数时间）
     * 7. 检查是否有可用令牌
     * 8. 如果有令牌，消耗一个并允许请求
     * 
     * 时间计算细节：
     * - time_passed: 自上次更新以来经过的纳秒数
     * - tokens_to_add: 应该添加的令牌数 = time_passed / token_interval_ns
     * - 余数时间: time_passed % token_interval_ns 会被保留到下次计算
     * 
     * 线程安全保证：
     * - 使用互斥锁保护共享的entries哈希表
     * - 所有状态修改都在锁保护下进行
     * 
     * @param ip IPv4地址（网络字节序）
     * @return 如果允许请求返回true，否则返回false
     */
    bool RateLimiter::allow(uint32_t ip) {
        // 获取当前时间（纳秒精度）
        auto now = std::chrono::steady_clock::now().time_since_epoch();
        uint64_t now_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(now).count();

        // 获取互斥锁保护共享状态
        std::lock_guard<std::mutex> lock(limiter_mutex);

        // 查找或创建IP地址对应的速率限制条目
        // operator[]会自动创建不存在的条目（初始化为零）
        auto &entry = entries[ip];

        // 计算自上次更新以来经过的时间
        uint64_t time_passed = now_ns - entry.last_time;

        // 添加令牌基于经过的时间
        int tokens_to_add = static_cast<int>(time_passed / token_interval_ns);
        if (tokens_to_add > 0) {
            // 添加令牌，但不超过最大容量
            entry.tokens = std::min(entry.tokens + tokens_to_add, max_tokens);

            // 更新最后更新时间，保留余数时间到下次计算
            entry.last_time = now_ns - (time_passed % token_interval_ns);
        }

        // 检查是否有令牌可用
        if (entry.tokens > 0) {
            // 消耗一个令牌
            entry.tokens--;
            return true;
        }

        // 无令牌可用，拒绝请求
        return false;
    }

    /**
     * @brief 清空所有速率限制状态实现
     * 
     * 移除所有IP地址的速率限制条目，
     * 重置为初始状态。
     * 
     * 线程安全保证：
     * - 使用互斥锁保护共享的entries哈希表
     */
    void RateLimiter::clear() {
        std::lock_guard<std::mutex> lock(limiter_mutex);
        entries.clear();
    }

    /**
     * @brief 设置速率限制参数实现
     * 
     * 动态调整速率限制参数：
     * 1. 更新每秒令牌生成速率
     * 2. 重新计算令牌生成间隔
     * 3. 调整最大令牌数（至少10个，确保允许合理突发流量）
     * 
     * 参数验证：
     * - tokens_per_second 必须大于0
     * - max_tokens 至少为10，防止过于严格的限制
     * 
     * 线程安全保证：
     * - 使用互斥锁保护共享状态
     * 
     * @param packets_per_second 每秒允许的数据包数量
     */
    void RateLimiter::setRateLimit(int packets_per_second) {
        // 参数验证
        if (packets_per_second <= 0) {
            return;
        }

        std::lock_guard<std::mutex> lock(limiter_mutex);

        // 更新令牌生成速率
        tokens_per_second = packets_per_second;

        // 重新计算令牌生成间隔（纳秒）
        token_interval_ns = 1000000000ULL / tokens_per_second;

        // 调整最大令牌数（至少10个）
        max_tokens = std::max(10, tokens_per_second);
    }

    // ==================== 全局速率限制器实现 ====================

    // 全局速率限制器实例（单例模式）
    static std::unique_ptr<RateLimiter> global_ratelimiter;

    /**
     * @brief 初始化全局速率限制器实现
     * 
     * 创建全局速率限制器实例。
     * 使用std::make_unique确保异常安全。
     * 
     * @return 成功返回0
     */
    int initRateLimiter() {
        global_ratelimiter = std::make_unique<RateLimiter>();
        return 0;
    }

    /**
     * @brief 清理全局速率限制器实现
     * 
     * 释放全局速率限制器资源。
     * 使用reset()方法安全地销毁对象。
     */
    void cleanupRateLimiter() {
        global_ratelimiter.reset();
    }

    /**
     * @brief 全局速率限制检查实现
     * 
     * 使用全局速率限制器检查请求是否被允许。
     * 如果全局限制器未初始化，则默认允许所有请求（安全降级）。
     * 
     * @param ip IPv4地址（网络字节序）
     * @return 如果允许请求返回true，否则返回false
     */
    bool ratelimiterAllow(uint32_t ip) {
        // 安全降级：如果未初始化，允许所有请求
        if (!global_ratelimiter) {
            return true; // Allow if not initialized
        }

        // 使用全局速率限制器进行检查
        return global_ratelimiter->allow(ip);
    }
}