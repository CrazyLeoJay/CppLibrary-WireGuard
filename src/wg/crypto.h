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
// Created on 2026/3/24.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef WIREGUARD_CRYPTO_H
#define WIREGUARD_CRYPTO_H

#include "entity.h"
#include "messages.h"
#include <array>
#include <cstdint>
#include <string>
#include <cstring>
#include <vector>
#include "version.h"

namespace WireGuard {
    namespace Crypto {
        std::string bin2Hex(const uint8_t *data, const size_t &len);

        std::string bin2Hex(const uint32_t &data);

        std::string bin2B64(const uint8_t *data, const size_t &len);

        std::vector<uint8_t> b642bin(const std::string &b64Str);

        std::vector<uint8_t> hex2Bin(std::string hexStr);

        const std::array<uint8_t, 32> base642Bin32Array(const std::string &hexStr);

        const std::string bin32Array2Base64(const std::array<uint8_t, 32> &bytes);

        /**
         * @brief Curve25519 私钥生成
         *
         * 用途：生成一个随机的 32 字节私钥，并进行 clamping 处理
         * Clamping 操作（Curve25519 要求）：
         *   - 清除最低位的 3 个比特（确保是 8 的倍数）
         *   - 清除最高位（第 255 位）
         *   - 设置第 254 位（确保在正确的子群中）
         *
         * 使用场景：
         *   - 客户端初始化时生成自己的身份私钥
         *   - 临时 ECDH 密钥对的生成
         *
         * @param key 输出的私钥（32 字节）
         */
        void generatePrivateKey(WireGuard::PrivateKey & key);

        /**
         * @brief 从私钥生成对应的公钥
         *
         * 用途：计算 pub = base × priv（Curve25519 标量乘法）
         * 其中 base 是 Curve25519 的标准基点
         *
         * 使用场景：
         *   - 从私钥推导出可公开的公钥
         *   - 在握手阶段生成临时公钥
         *
         * @param pub 输出的公钥（32 字节）
         * @param priv 输入的私钥（32 字节）
         * @return bool 成功返回 true，失败返回 false
         */
        bool generatePublicKey(PublicKey &pub, const PrivateKey &priv);

        /**
         * @brief Curve25519 Diffie-Hellman 密钥交换计算
         *
         * 用途：计算共享密钥 shared = priv × pub
         * 这是 WireGuard 协议的核心，用于双方协商出相同的共享密钥
         *
         * 数学原理：
         *   - 假设 A 有私钥 a 和公钥 A = a×G
         *   - 假设 B 有私钥 b 和公钥 B = b×G
         *   - A 计算：a × B = a × b × G
         *   - B 计算：b × A = b × a × G
         *   - 结果相同：shared = a × b × G
         *
         * 使用场景：
         *   - 握手阶段：结合静态密钥和临时密钥计算共享密钥
         *   - 会话密钥派生：通过 DH 计算得到主密钥
         *
         * @param shared 输出的共享密钥（32 字节）
         * @param priv 己方私钥（32 字节）
         * @param pub 对方公钥（32 字节）
         * @return bool 成功返回 true，失败返回 false（如结果为 0 则无效）
         */
        bool dh(SymmetricKey &shared, const PrivateKey &priv, const PublicKey &pub);

        /**
         * @brief BLAKE2s 哈希函数
         *
         * 用途：计算数据的 256 位哈希值
         * BLAKE2s 比 SHA-256 更快，且安全性相当
         *
         * 使用场景：
         *   - 计算消息摘要（如握手消息的哈希）
         *   - 密钥派生过程中的哈希操作
         *   - 构造 HMAC 的基础组件
         *   - 数据完整性校验
         *
         * @param data 输入数据
         * @param len 数据长度
         * @return Hash 256 位哈希值
         */
        Hash blake2s(const uint8_t *data, size_t len);

        /**
         * @brief BLAKE2s 哈希函数（vector 重载）
         *
         * @param data 输入数据
         * @return Hash 256 位哈希值
         */
        Hash blake2s(const std::vector<uint8_t> &data);

        /**
         * @brief blake2b 哈希函數
         *
         * 使用对称密钥生成 mac Cookie
         *
         * @param key 对称密钥
         * @param data 输入数据
         * @param len 输入数据长度
         * @return
         */
        CookieData blake2bCookie(const SymmetricKey &key, const uint8_t *data, const size_t len);

        /**
         * @brief HMAC-BLAKE2s 消息认证码
         *
         * 用途：使用密钥对数据进行认证，生成固定长度的 MAC
         * 构造方式：HMAC(K, data) = H((K' ⊕ opad) || H((K' ⊕ ipad) || data))
         *
         * 实现细节：
         *   - 如果密钥长度超过块大小（64 字节），先进行哈希压缩
         *   - 使用标准的 HMAC 双层结构（内层和外层）
         *   - ipad = 0x36, opad = 0x5c
         *
         * 使用场景：
         *   - 握手消息的完整性保护（防止篡改）
         *   - Cookie 机制中的 IP 验证
         *   - HKDF 密钥派生的基础组件
         *   - 重放攻击防护
         *
         * @param data 输入数据
         * @param dataLen 数据长度
         * @param key HMAC 密钥（32 字节）
         * @return SymmetricKey 256 位 HMAC 值
         */
        SymmetricKey hmacBLAKE2s(const uint8_t *data, size_t dataLen, const SymmetricKey &key);

        /**
         * @brief HKDF 密钥派生函数（RFC 5869）- 派生 2 个子密钥
         *
         * 用途：从一个主密钥（chainKey）和输入数据派生出多个独立的子密钥
         * HKDF 分为两个阶段：Extract（提取）和 Expand（扩展）
         *
         * 算法流程：
         *   1. Extract: PRK = HMAC-Hash(chainKey, data)
         *   2. Expand:
         *      - T(1) = HMAC(PRK, 0x01)
         *      - T(2) = HMAC(PRK, T(1) || 0x02)
         *
         * 使用场景：
         *   - 握手阶段：从共享密钥派生出加密密钥和链式密钥
         *   - 密钥轮换：定期更新会话密钥
         *   - 多密钥生成：一次性生成加密和解密所需的多个密钥
         *
         * @param out1 输出的第一个子密钥（32 字节）
         * @param out2 输出的第二个子密钥（32 字节）
         * @param data 输入数据（如 DH 共享密钥）
         * @param dataLen 输入数据长度
         * @param chainKey 链式密钥（用于密钥派生序列）
         */
        void kdf(SymmetricKey &out1, SymmetricKey &out2, const uint8_t *data, size_t dataLen,
                 const SymmetricKey &chainKey);

        /**
         * @brief HKDF 密钥派生函数（RFC 5869）- 派生 3 个子密钥
         *
         * 用途：与 kdf 类似，但一次派生出 3 个独立的子密钥
         * 用于需要更多密钥材料的场景
         *
         * 算法流程：
         *   1. Extract: PRK = HMAC-Hash(chainKey, data)
         *   2. Expand:
         *      - T(1) = HMAC(PRK, 0x01)
         *      - T(2) = HMAC(PRK, T(1) || 0x02)
         *      - T(3) = HMAC(PRK, T(2) || 0x03)
         *
         * 使用场景：
         *   - 完整的密钥派生：同时生成发送密钥、接收密钥和链式密钥
         *   - 前向安全密钥轮换：保留旧密钥用于解密历史数据
         *
         * @param out1 输出的第一个子密钥（32 字节）
         * @param out2 输出的第二个子密钥（32 字节）
         * @param out3 输出的第三个子密钥（32 字节）
         * @param data 输入数据
         * @param dataLen 输入数据长度
         * @param chainKey 链式密钥
         */
        void kdf3(SymmetricKey &out1, SymmetricKey &out2, SymmetricKey &out3, const uint8_t *data, size_t dataLen,
                  const SymmetricKey &chainKey);

        /**
         * @brief ChaCha20-Poly1305 AEAD 加密（RFC 8439）
         *
         * 用途：对数据进行加密并提供完整性保护
         * ChaCha20 是流加密，Poly1305 是 MAC，组合成 AEAD 模式
         *
         * 输出格式：[密文 (plainLen 字节) | 认证标签 (16 字节)]
         *
         * 参数说明：
         *   - plaintext: 待加密的明文数据
         *   - aad (Additional Authenticated Data): 附加认证数据
         *     - 这部分数据不加密，但会包含在认证计算中
         *     - 用于保护不需要保密但需要防篡改的字段（如消息头）
         *   - nonce: 12 字节的数字一次性值
         *     - 必须唯一，重复使用会破坏安全性
         *     - 通常使用计数器或随机数
         *
         * 使用场景：
         *   - 加密握手消息中的敏感字段（公钥、时间戳等）
         *   - 加密传输的 IP 数据包
         *   - 保护 Cookie 值
         *
         * @param ciphertext 输出的密文（包含认证标签）
         * @param plaintext 输入的明文
         * @param plainLen 明文长度
         * @param aad 附加认证数据
         * @param aadLen AAD 长度
         * @param nonce 12 字节 Nonce（作为 64 位整数传递）
         * @param key 加密密钥（32 字节）
         * @return bool 成功返回 true
         */
        bool encrypt(std::vector<uint8_t> &ciphertext, const uint8_t *plaintext, const size_t plainLen,
                     const uint8_t *aad, const size_t aadLen, const Nonce nonce, const SymmetricKey &key);

        bool encrypt(std::vector<uint8_t> &ciphertext, const uint8_t *plaintext, const size_t plainLen,
                     const uint8_t *aad, const size_t aadLen, const uint64_t nonce, const SymmetricKey &key);

        /**
         * @brief ChaCha20-Poly1305 AEAD 解密（RFC 8439）
         *
         * 用途：解密数据并验证完整性
         * 如果认证失败（数据被篡改或密钥错误），返回 false
         *
         * 安全性：
         *   - 自动检测密文是否被篡改
         *   - 验证认证标签的正确性
         *   - 失败时不会泄露任何明文信息
         *
         * 使用场景：
         *   - 解密收到的握手消息
         *   - 解密收到的 IP 数据包
         *   - 验证并解密 Cookie
         *
         * @param plaintext 输出的明文
         * @param ciphertext 输入的密文（包含认证标签）
         * @param cipherLen 密文长度
         * @param aad 附加认证数据（必须与加密时相同）
         * @param aadLen AAD 长度
         * @param nonce 12 字节 Nonce（必须与加密时相同）
         * @param key 解密密钥（32 字节）
         * @return bool 解密成功且认证通过返回 true，否则返回 false
         */
        bool decrypt(std::vector<uint8_t> &plaintext, const uint8_t *ciphertext, const size_t cipherLen,
                     const uint8_t *aad, const size_t aadLen, const Nonce nonce, const SymmetricKey &key);

        bool decrypt(std::vector<uint8_t> &plaintext, const uint8_t *ciphertext, const size_t cipherLen,
                     const uint8_t *aad, const size_t aadLen, const uint64_t nonce, const SymmetricKey &key);

        /**
         * @brief 生成密码学安全的随机数
         *
         * 用途：生成不可预测的随机数据
         * 使用操作系统的熵源（如 /dev/urandom 或 CryptGenRandom）
         *
         * 使用场景：
         *   - 生成临时私钥（ECDH 临时密钥）
         *   - 生成 Nonce（虽然通常用计数器，但也可用随机数）
         *   - 生成 Cookie 的随机成分
         *   - 任何需要随机性的地方
         *
         * @param buf 输出缓冲区
         * @param len 随机数长度
         */
        void randomBytes(void *buf, size_t len);

        /**
         * @brief 生成密码学安全的随机数（array 重载）
         *
         * @tparam N 数组大小
         * @param arr 输出数组
         */
        template<size_t N>
        void randomBytes(std::array<uint8_t, N> & arr);

        /**
         * @brief 安全地清除敏感数据
         *
         * 用途：将敏感数据（如私钥、共享密钥）从内存中彻底清除
         * 使用 sodium_memzero 而不是 memset，因为：
         *   - 编译器不会优化掉 sodium_memzero 调用
         *   - 确保数据真正被覆盖，即使在不优化的编译模式下
         *
         * 使用场景：
         *   - 程序退出前清除所有密钥材料
         *   - 临时密钥使用完毕后立即清除
         *   - 密钥派生完成后清除中间变量
         *   - 防止敏感数据残留在内存中被窃取
         *
         * @param data 要清除的数据（任意类型）
         */
        template<typename T>
        void secureZero(T &data);

        namespace Message {
            // ========== 静态常量 ==========
            static constexpr const char *NOISE_NAME = "Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s";
            static constexpr const char *IDENTIFIER_NAME = "WireGuard v1 zx2c4 Jason@zx2c4.com";
            /**
             * 从握手消息中获取 PublicKey
             * @param msg
             * @param local_private_key
             * @return
             */
            PublicKey getPublicKey(const MessageInitiation &msg, const PrivateKey &local_private_key);

            /**
             * 辅助方法：从 Hash 初始化链式密钥（不修改成员变量）
             */
            void initializeChainingKeyFromHash(Hash & outChainKey);

            /**
             * 辅助方法：混合数据到临时 Hash（不修改成员变量）
             */
            void mixHash(Hash &hash, const uint8_t *data, size_t len);

            /**
             * @brief 消息解密（ChaCha20-Poly1305）
             *
             * 用途：解密消息并混合到哈希中
             * plaintext = ChaCha20-Poly1305^{-1}(ciphertext, key)
             * hash = BLAKE2s(hash || ciphertext)
             *
             * @param plaintext 输出的明文
             * @param ciphertext 输入的密文
             * @param cipherLen 密文长度
             * @param key 解密密钥
             * @return bool 成功返回 true
             */
            bool messageDecrypt(uint8_t *plaintext, const uint8_t *ciphertext, size_t cipherLen,
                                const SymmetricKey &key);

            bool messageDecrypt(uint8_t *plaintext, const uint8_t *ciphertext, size_t cipherLen,
                                const uint8_t *aad, size_t aadLen,
                                const SymmetricKey &key);

            /**
             * @brief DH 密钥交换并混合到链式密钥
             *
             * 用途：执行 DH 计算并将结果混合到链式密钥
             * outKey = KDF(chain_key, DH(priv, pub))
             *
             * @param chainKey 链式密钥（输入/输出）
             * @param outKey 输出的派生密钥
             * @param priv 私钥
             * @param pub 公钥
             * @return bool 成功返回 true
             */
            bool mixDH(SymmetricKey &chainKey, SymmetricKey &outKey, const PrivateKey &priv, const PublicKey &pub);

            /**
             * @brief KDF 单密钥派生
             *
             * 用途：从链式密钥派生一个输出密钥
             * chainKey, out = KDF(chainKey, data)
             *
             * @param chainKey 链式密钥（输入/输出）
             * @param out 输出的密钥
             * @param data 输入数据
             * @param dataLen 数据长度
             */
            void kdfSingle(SymmetricKey &chainKey, SymmetricKey &out, const uint8_t *data, size_t dataLen);
        }; // namespace Message


        /**
         * Noise 协议中用到的一些方法封装
         */
        namespace Noise {
            /**
             * @brief KDF 双密钥派生
             *
             * 用途：从链式密钥派生两个输出密钥
             * chainKey, out1, out2 = KDF(chainKey)
             *
             * @param chainKey 链式密钥（输入/输出）
             * @param out1 输出的第一个密钥
             * @param out2 输出的第二个密钥
             */
            void kdfDual(SymmetricKey & chainKey, SymmetricKey & out1, SymmetricKey & out2);
        }; // namespace Noise
    } // namespace Crypto
} // namespace WireGuard

#endif // WIREGUARD_CRYPTO_H