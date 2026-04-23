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
// Created on 2026/3/25.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef WIREGUARD_KEYPAIR_H
#define WIREGUARD_KEYPAIR_H

#include "crypto/crypto.h"
#include <bitset>
#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <vector>
#include "version.h"

namespace WireGuard {
    /**
     * @brief 带出生时间的对称密钥
     *
     * 用途：封装对称密钥及其元数据（创建时间、有效性状态）
     * 用于实现密钥的生命周期管理和自动过期机制
     *
     * 生命周期管理：
     *   - birthdate: 密钥创建的纳秒时间戳
     *   - isValid: 标记密钥是否仍然有效
     *   - isExpired(): 检查密钥是否超过生存期
     *
     * 使用场景：
     *   - 会话密钥的发送和接收密钥
     *   - 需要定时轮换的短期密钥
     */
    struct SymmetricKeyWithBirthdate {
        SymmetricKey key{}; ///< 32 字节的对称密钥
        uint64_t birthdate = 0; ///< 密钥创建时间（纳秒时间戳）
        bool isValid = false; ///< 密钥是否有效

        /**
         * @brief 检查密钥是否已过期
         *
         * @param now 当前时间（纳秒）
         * @param lifetime 密钥的生存期（纳秒）
         * @return true 如果密钥无效或超过生存期，否则返回 false
         */
        bool isExpired(uint64_t now, uint64_t lifetime) const { return !isValid || (now - birthdate) > lifetime; }

        /**
         * @brief 标记密钥为失效状态
         *
         * 用途：
         *   - 密钥轮换时主动使旧密钥失效
         *   - 检测到安全事件时立即禁用密钥
         *   - Nonce 耗尽后标记密钥不可用
         */
        void markExpired() { isValid = false; }
    };

    /**
     * @brief 重放计数器（滑动窗口位图算法）
     *
     * 用途：检测和防止重放攻击
     * 维护一个滑动窗口，记录最近收到的消息计数器值
     *
     * 算法原理：
     *   1. 滑动窗口：8192 位的位图，覆盖最近的 8192 个计数器值
     *   2. 拒绝策略：
     *      - 超过 REJECT_AFTER_MESSAGES 的消息直接拒绝
     *      - 落在窗口之外的旧消息（counter 太小）拒绝
     *      - 已经在窗口中标记为收到的消息（重复）拒绝
     *   3. 窗口滑动：当收到更大的 counter 时，窗口向右滑动
     *
     * 线程安全：使用互斥锁保护所有操作
     *
     * 使用场景：
     *   - 每个密钥对的接收方向都需要一个重放计数器
     *   - 验证收到的每个数据包的 nonce（计数器）
     */
    class ReplayCounter {
    private:
        std::atomic<uint64_t> counter_{0}; ///< 当前窗口的基准计数器
        std::bitset<RECEIVING_WINDOW_LEN> window_; ///< 滑动窗口位图
        mutable std::mutex lock_; ///< 保护计数器的互斥锁

    public:
        /**
         * @brief 验证收到的计数器值
         * 定义
         * RECEIVING_WINDOW_LEN = 8192 // 下面默认使用 8192 实际可以修改
         * std::atomic<uint64_t> counter_{0}; ///< 当前窗口的基准计数器
         * std::bitset<8192> window_;         ///< 滑动窗口位图
         * 实现逻辑：
         *  1、window 是一个长度为 8192，计数从右往左，从0到8191的一个位图，下标为[8191 ~ 0]。
         *  2、现在规定，新增的 id 表示一个数据包的值。counter表示输入的 id 的最大值. id始终大于等于0
         *  3、window的下标表示当前数据距离 counter 的长度（counter - id）。即，右边的表示的数值是最大最新的，
         * 左边是最小最旧的的。
         *      - 当 id >= REJECT_AFTER_MESSAGES 时，值可能会超过 uint64_t 的上限，需要拒绝重新握手。
         *      - 当 id <= (counter - 8192) 时，表示数据太旧，直接抛弃。
         *      - 当 id >  counter时，window需要左移 (id-counter) 位 丢弃左边的数据，右边补0，并且设置当前 counter=id；
         *      - 当 id <= counter时，window不动。 (counter-id) 表示 id的当前值的位数；
         *
         * 验证逻辑：
         *   1. 检查上限：theirCounter >= REJECT_AFTER_MESSAGES → 拒绝
         *   2. 检查下限：(8192 + theirCounter) < currentCounter → 太旧，拒绝
         *   3. 更新窗口：如果 theirCounter > currentCounter，滑动窗口
         *   4. 检查重复：window 中对应位已设置 → 重复，拒绝
         *   5. 标记已收到：设置 window 中对应位
         *
         * @param theirCounter 收到的消息计数器值
         * @return true 如果是新的有效消息，false 如果是重放或无效消息
         */
        bool validate(uint64_t theirCounter);

        /**
         * @brief 获取当前的基准计数器值
         *
         * @return uint64_t 当前窗口的起始计数器
         */
        uint64_t getCounter() const;
    };

    // 前向声明
    class KeyPair;

    /**
     * @brief 密钥对（用于数据加密/解密）
     *
     * 用途：管理一对对称密钥（发送密钥 + 接收密钥）及相关状态
     * 这是 WireGuard 数据传输的核心组件
     *
     * 核心组件：
     *   - sending: 用于加密发出数据的密钥
     *   - receiving: 用于解密收到数据的密钥
     *   - sendingCounter: 本地发出的数据包计数器（用于生成 Nonce）
     *   - receivingCounter: 重放计数器（验证收到的包）
     *   - remoteIndex: 远程端点为该密钥对分配的索引（用于查找）
     *   - iAmTheInitiator: 标记本端是否是握手的发起方
     *
     * 密钥生命周期：
     *   1. 握手成功后创建
     *   2. 用于加密/解密数据包
     *   3. 达到消息数限制或时间限制后需要重新握手
     *   4. 超过最大生存期后完全失效
     *
     * 使用场景：
     *   - 每次成功的 Noise 握手都会产生一个新的 Keypair
     *   - 数据平面使用 Keypair 进行快速的加密/解密操作
     *   - 支持多个 Keypair 并存（上一个、当前、下一个）以实现平滑轮换
     */
    class KeyPair : public std::enable_shared_from_this<KeyPair> {
    public:
        SymmetricKeyWithBirthdate sending{}; ///< 发送密钥（加密外出数据）
        SymmetricKeyWithBirthdate receiving{}; ///< 接收密钥（解密进入数据）
        std::atomic<uint64_t> sendingCounter{0}; ///< 发送计数器（分配给外出包）
        ReplayCounter receivingCounter{}; ///< 接收重放计数器（验证进入包）
        uint32_t remoteIndex = 0; ///< 远程端点的密钥索引
        bool iAmTheInitiator = false; ///< 本端是否是握手发起方

        /**
         * @brief 分配新的 Nonce（用于发送数据包）
         *
         * 流程：
         *   1. 检查发送密钥是否有效
         *   2. 原子递增计数器
         *   3. 检查是否达到上限（REJECT_AFTER_MESSAGES）
         *   4. 如果达到上限，标记密钥失效并返回 null
         */
        std::unique_ptr<uint64_t> allocateNonce();

        /**
         * @brief 加密数据包
         *
         * 流程：
         *   1. 检查发送密钥有效性
         *   2. 对明文进行 16 字节对齐填充
         *   3. 使用 ChaCha20-Poly1305 加密（AAD=nullptr）
         *
         * @param ciphertext 输出的密文（包含认证标签）
         * @param plaintext 输入的明文
         * @param plainLen 明文长度
         * @param nonce 12 字节的 Nonce（由 allocateNonce 提供）
         * @return true 加密成功，false 密钥无效或加密失败
         */
        bool encrypt(std::vector<uint8_t> &ciphertext, const uint8_t *plaintext, size_t plainLen, uint64_t nonce);

        std::vector<uint8_t> encrypt(const uint8_t *plaintext, size_t plainLen, uint64_t nonce);

        std::vector<uint8_t> encryptToMessageBytes(const uint8_t *data, const size_t len);

        /**
         * @brief 解密数据包
         *
         * 流程：
         *   1. 检查接收密钥有效性
         *   2. 通过重放计数器验证 nonce（防重放）
         *   3. 使用 ChaCha20-Poly1305 解密（AAD=nullptr）
         *
         * @param plaintext 输出的明文
         * @param ciphertext 输入的密文（包含认证标签）
         * @param cipherLen 密文长度
         * @param nonce 收到的 Nonce（计数器值）
         * @return true 解密成功且认证通过，false 失败（重放、过期或认证失败）
         */
        bool decrypt(std::vector<uint8_t> &plaintext, const uint8_t *ciphertext, size_t cipherLen, uint64_t nonce);

        std::vector<uint8_t> decrypt(const uint8_t *ciphertext, size_t cipherLen, uint64_t nonce);

        /**
         * 解密消息
         * @param msg
         * @param len
         * @return
         */
        std::vector<uint8_t> decrypt(const MessageData *msg, const size_t len);

        /**
         * @brief 检查是否需要重新握手
         *
         * 触发条件（满足任一即需要）：
         *   1. 发送密钥无效
         *   2. 已发送消息数 >= REKEY_AFTER_MESSAGES（默认约 2^20 条）
         *   3. 发送密钥超过 REKEY_AFTER_TIME（默认 120 秒）
         *
         * @throw 需要重新握手，没有抛出则不需要
         */
        void needsReKey() const;

        /**
         * @brief 检查密钥对是否已完全过期
         *
         * 过期条件：
         *   - 发送和接收密钥都无效，或者
         *   - 两个密钥都超过 REJECT_AFTER_TIME（默认 180 秒）
         *
         * @return true 密钥对已完全过期，false 仍部分有效
         */
        bool isExpired() const;

    private:
        /**
         * @brief 获取当前时间的纳秒级时间戳
         *
         * 使用 std::chrono::steady_clock 确保单调递增
         * 不受系统时钟调整影响
         *
         * @return uint64_t 从某个起点开始的纳秒数
         */
        static uint64_t getCurrentTimeNs();
    };

    /**
     * @brief 密钥对组（管理当前/上一个/下一个密钥对）
     *
     * 用途：支持密钥的平滑轮换，避免通信中断
     * 维护三个位置的密钥对：
     *   - previous: 上一个密钥对（用于解密刚轮换前的旧数据）
     *   - current: 当前使用的密钥对（主要的加密/解密操作）
     *   - next: 下一个密钥对（预先生成，等待切换）
     *
     * 轮换策略：
     *   1. 新握手完成后，设置为 next
     *   2. 第一次使用 next 加密/解密时，切换到 current
     *   3. 原来的 current 降级为 previous
     *   4. previous 在一段时间后清理
     *
     * 线程安全：使用互斥锁保护所有访问操作
     *
     * 使用场景：
     *   - 每个 Peer 对象维护一个 Keypairs 实例
     *   - 支持高频率的密钥轮换而不丢包
     *   - 处理乱序到达的数据包（可能使用旧密钥加密）
     */
    class KeyPairs {
    private:
        std::shared_ptr<KeyPair> current_; ///< 当前使用的密钥对
        std::shared_ptr<KeyPair> previous_; ///< 上一个密钥对（用于兼容过渡）
        std::shared_ptr<KeyPair> next_; ///< 下一个密钥对（预先生成）
        mutable std::mutex updateLock_; ///< 保护更新的互斥锁

    public:
        /**
         * @brief 获取当前密钥对
         *
         * @return std::shared_ptr<Keypair> 当前密钥对，可能为空
         */
        std::shared_ptr<KeyPair> getCurrent() const;

        /**
         * @brief 获取上一个密钥对
         *
         * @return std::shared_ptr<Keypair> 上一个密钥对，可能为空
         */
        std::shared_ptr<KeyPair> getPrevious() const;

        /**
         * @brief 获取下一个密钥对
         *
         * @return std::shared_ptr<Keypair> 下一个密钥对，可能为空
         */
        std::shared_ptr<KeyPair> getNext() const;

        /**
         * @brief 设置当前密钥对
         *
         * @param kp 新的当前密钥对
         */
        void setCurrent(std::shared_ptr<KeyPair> kp);

        /**
         * @brief 设置下一个密钥对
         *
         * 用途：
         *   - 握手完成后保存新生成的密钥对
         *   - 等待第一次使用时切换到 current
         *
         * @param kp 下一个密钥对
         */
        void setNext(std::shared_ptr<KeyPair> kp);

        /**
         * @brief 设置上一个密钥对
         *
         * @param kp 上一个密钥对
         */
        void setPrevious(std::shared_ptr<KeyPair> kp);

        /**
         * @brief 当收到使用下一个密钥对的包时，切换到新密钥
         *
         * 流程：
         *   1. 检查 next 是否存在
         *   2. current → previous
         *   3. next → current
         *   4. 清空 next
         *
         * @return true 发生了切换，false 没有 next 可切换
         */
        bool receivedWithNextKey();

        /**
         * @brief 清空所有密钥对
         *
         * 用途：
         *   - Peer 断开连接时清理
         *   - 发生严重错误时重置状态
         *   - 定期安全清理
         */
        void clear();
    };
} // namespace WireGuard

#endif // WIREGUARD_KEYPAIR_H