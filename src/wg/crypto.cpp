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

#include "crypto.h"
#include "WGException.h"
#include "encoding.hpp"
#include "crypto/nonce.h"
#include <sodium.h>
#include <stdexcept>

namespace WireGuard {
    namespace Crypto {
        std::string bin2Hex(const uint8_t *data, const size_t &len) {
            std::vector<char> hex_out(len * 2 + 1); // +1 for null terminator
            sodium_bin2hex(hex_out.data(), hex_out.size(), data, len);
            return std::string(hex_out.data(), len * 2);
        }

        std::string bin2Hex(const uint32_t &data) {
            return bin2Hex(reinterpret_cast<const uint8_t *>(&data), sizeof(data));
        }

        std::string bin2B64(const uint8_t *data, const size_t &len) {
            auto resultLen = sodium_base64_ENCODED_LEN(len, sodium_base64_VARIANT_ORIGINAL);
            std::vector<char> hex_out(resultLen); // +1 for null terminator
            sodium_bin2base64(hex_out.data(), resultLen, data, len, sodium_base64_VARIANT_ORIGINAL);
            return std::string(hex_out.data(), resultLen);
        }

        std::vector<uint8_t> b642bin(const std::string &b64Str) {
            auto resultLen = (b64Str.length() + 3) / 4 * 3;
            std::vector<uint8_t> hex_out(resultLen); // +1 for null terminator
            // int sodium_base642bin(
            //     unsigned char *const bin, // 输出：解码后的二进制数据
            //     const size_t bin_maxlen, // 输出缓冲区最大长度（字节）
            //     const char *const b64, // 输入：Base64 字符串
            //     const size_t b64_len, // 输入字符串长度（可含非法字符）
            //     const char *const ignore, // 要忽略的字符（如 "\n\r\t "）
            //     size_t *const bin_len, // 输出：实际解码出的字节数（可为 NULL）
            //     const char **const b64_end, // 输出：解析停止位置（可为 NULL）
            //     const int variant // Base64 变体类型
            // );
            sodium_base642bin(
                hex_out.data(), resultLen,
                b64Str.c_str(), b64Str.size(),
                nullptr,
                nullptr,
                nullptr,
                sodium_base64_VARIANT_ORIGINAL
            );
            return hex_out;
        }

        std::vector<uint8_t> hex2Bin(std::string hexStr) {
            std::vector<uint8_t> bin_out(hexStr.size() / 2 + 1);
            size_t bin_len = 0;
            sodium_hex2bin(
                bin_out.data(), bin_out.size(),
                hexStr.c_str(), hexStr.size(),
                nullptr, &bin_len, nullptr
            );
            bin_out.resize(bin_len);
            return bin_out;
        }

        const std::array<uint8_t, 32> base642Bin32Array(const std::string &b64) { return Base64::key_from_base64(b64); }

        const std::string bin32Array2Base64(const std::array<uint8_t, 32> &bytes) {
            // sodium_bin2base64 的输出缓冲区
            char b64[sodium_base64_ENCODED_LEN(32, sodium_base64_VARIANT_ORIGINAL)];

            // 直接转换二进制到 Base64
            sodium_bin2base64(b64, sizeof(b64), bytes.data(), 32, sodium_base64_VARIANT_ORIGINAL);
            return std::string(b64);
        }


        void generatePrivateKey(PrivateKey &key) {
            // 生成随机私钥（32 字节）
            randombytes_buf(key.data(), PRIVATE_KEY_LEN);

            // Curve25519 clamping 操作（RFC 7748 Section 5）：
            // 1. 清除最低 3 位（确保是 8 的倍数，避免小群攻击）
            // 2. 清除最高位（第 255 位，确保不超过曲线阶）
            // 3. 设置第 254 位（确保在正确的子群中）
            key[0] &= 248; // 清除低 3 位：0b11111000
            key[31] &= 127; // 清除最高位：0b01111111
            key[31] |= 64; // 设置第 254 位：0b01000000
        }

        bool generatePublicKey(PublicKey &pub, const PrivateKey &priv) {
            // 计算公钥：pub = base × priv（Curve25519 标量基乘法）
            // 使用 libsodium 标准 API：crypto_scalarmult_curve25519_base
            // 返回值：0 表示成功，-1 表示失败
            return crypto_scalarmult_curve25519_base(pub.data(), priv.data()) == 0;
        }

        bool dh(SymmetricKey &shared, const PrivateKey &priv, const PublicKey &pub) {
            // Curve25519 Diffie-Hellman 密钥交换
            // 计算共享密钥：shared = priv × pub
            // 使用 libsodium 标准 API：crypto_scalarmult_curve25519
            // 返回值：0 表示成功，-1 表示失败
            return crypto_scalarmult_curve25519(shared.data(), priv.data(), pub.data()) == 0;
        }

        Hash blake2s(const uint8_t *data, size_t len) {
            Hash hash;
            // 使用 BLAKE2b 哈希函数（libsodium 标准 API）
            // crypto_generichash_blake2b 是 libsodium 提供的 BLAKE2b 实现
            // 参数：输出缓冲区，输出长度，输入数据，输入长度，密钥，密钥长度
            crypto_generichash_blake2b(hash.data(), HASH_LEN, data, len, nullptr, 0);
            return hash;
        }

        Hash blake2s(const std::vector<uint8_t> &data) { return blake2s(data.data(), data.size()); }

        CookieData blake2bCookie(const SymmetricKey &key, const uint8_t *data, const size_t len) {
            // ===== 步骤 2: 使用 BLAKE2s 计算带密钥的 MAC =====
            crypto_generichash_blake2b_state state;

            // 初始化状态（带密钥模式）
            int ret =
                    crypto_generichash_blake2b_init_salt_personal(&state,
                                                                  key.data(), // 密钥：MAC1_Key (32 字节)
                                                                  key.size(), // 密钥长度
                                                                  COOKIE_LEN, // 期望输出长度：16 字节
                                                                  nullptr, nullptr // salt 和 personal 使用默认值（空）
                    );
            if (ret != 0) {
                throw std::runtime_error("Failed to initialize BLAKE2s for MAC1");
            }

            // 更新哈希状态（添加消息内容）
            crypto_generichash_blake2b_update(&state,
                                              data, // 消息指针
                                              len // 输入长度（不包括 MAC2）
            );

            CookieData mac;
            // 完成计算，输出 MAC1
            crypto_generichash_blake2b_final(&state,
                                             mac.data(), // 输出缓冲区
                                             COOKIE_LEN // 输出长度：16 字节
            );
            return mac;
        }

        /**
         * ===== 解密 Cookie =====
         * 使用 XChaCha20Poly1305 解密
         * 密文：encrypted_cookie (32 字节 = 16 字节 Cookie + 16 字节认证标签)
         * 附加数据：last_sent_mac1 (16 字节)
         *
         * @param cookie
         */
        void decryptCookie(const CookieData mac1, const MessageCookie *msg, const SymmetricKey key) {
            CookieData decrypted_cookie;
            unsigned long long plaintext_len;
            int ret = crypto_aead_xchacha20poly1305_ietf_decrypt(decrypted_cookie.data(), &plaintext_len,
                                                                 nullptr, // 不返回额外认证信息
                                                                 msg->encryptedCookie, // 密文
                                                                 sizeof(msg->encryptedCookie), // 密文长度 = 32
                                                                 mac1.data(), COOKIE_LEN, // 附加数据（MAC1）
                                                                 msg->nonce, // 24 字节 nonce
                                                                 key.data() // Cookie 解密密钥
            );
            if (ret != 0) {
                // 解密失败（可能是伪造的 Cookie）
                throw WGException(
                    "解密失败（可能是伪造的 Cookie）Failed to decrypt cookie: authentication failed (ret=%d)", ret);
            }
        }

        SymmetricKey hmacBLAKE2s(const uint8_t *data, size_t dataLen, const SymmetricKey &key) {
            // HMAC-BLAKE2b 构造（RFC 2104）：H((K' ⊕ opad) || H((K' ⊕ ipad) || data))
            constexpr size_t BLOCK_SIZE = 64; // BLAKE2b 块大小为 64 字节
            uint8_t kPrime[BLOCK_SIZE] = {0};

            // 如果密钥长度超过块大小，先进行哈希压缩
            if (SYMMETRIC_KEY_LEN > BLOCK_SIZE) {
                auto hashed = blake2s(key.data(), SYMMETRIC_KEY_LEN);
                memcpy(kPrime, hashed.data(), HASH_LEN);
            } else {
                memcpy(kPrime, key.data(), SYMMETRIC_KEY_LEN);
            }

            // 生成内层密钥和外层密钥
            uint8_t iKey[BLOCK_SIZE], oKey[BLOCK_SIZE];
            for (int i = 0; i < BLOCK_SIZE; ++i) {
                iKey[i] = kPrime[i] ^ 0x36; // ipad (内填充)
                oKey[i] = kPrime[i] ^ 0x5c; // opad (外填充)
            }

            // 内层哈希：H((K' ⊕ ipad) || data)
            std::vector<uint8_t> innerData(BLOCK_SIZE + dataLen);
            memcpy(innerData.data(), iKey, BLOCK_SIZE);
            memcpy(innerData.data() + BLOCK_SIZE, data, dataLen);
            auto innerHash = blake2s(innerData);

            // 外层哈希：H((K' ⊕ opad) || innerHash)
            std::vector<uint8_t> outerData(BLOCK_SIZE + HASH_LEN);
            memcpy(outerData.data(), oKey, BLOCK_SIZE);
            memcpy(outerData.data() + BLOCK_SIZE, innerHash.data(), HASH_LEN);

            return blake2s(outerData);
        }

        /**
         * HKDF（HMAC-based Key Derivation Function）是一种标准化的密钥派生函数（KDF），由 IETF 在 RFC 5869
         * 中正式定义。它的核心目标是：从一个初始密钥材料（Input Key Material,
         * IKM）安全地派生出一个或多个密码学上强健的密钥，适用于加密、认证、完整性保护等多种用途。
         *
         * // kdf 函数会执行：\
         * // 1. first_dst = HMAC(secret, 0x01)  ← 更新后的 chaining_key
         * // 2. second_dst = HMAC(secret, first || 0x02)  ← 派生的临时密钥
         *
         * @param out1  更新后的 chaining_key
         * @param out2 派生的临时密钥
         * @param data
         * @param dataLen
         * @param chainKey
         */
        void kdf(SymmetricKey &out1, SymmetricKey &out2, const uint8_t *data, size_t dataLen,
                 const SymmetricKey &chainKey) {
            // HKDF 密钥派生（RFC 5869）

            // Extract 阶段：PRK = HMAC-Hash(chainKey, data)
            auto prk = hmacBLAKE2s(data, dataLen, chainKey);

            // Expand 阶段：扩展输出密钥材料
            // T(1) = HMAC(PRK, 0x01)
            uint8_t t1[HASH_LEN];
            memset(t1, 0, HASH_LEN);
            t1[HASH_LEN - 1] = 0x01;
            auto okm1 = hmacBLAKE2s(t1, HASH_LEN, prk);
            memcpy(out1.data(), okm1.data(), SYMMETRIC_KEY_LEN);

            // T(2) = HMAC(PRK, T(1) || 0x02)
            uint8_t t2[HASH_LEN * 2];
            memcpy(t2, okm1.data(), HASH_LEN);
            t2[HASH_LEN * 2 - 1] = 0x02;
            auto okm2 = hmacBLAKE2s(t2, HASH_LEN * 2, prk);
            memcpy(out2.data(), okm2.data(), SYMMETRIC_KEY_LEN);

            // 清除敏感数据（防止内存残留）
            sodium_memzero(prk.data(), prk.size());
            sodium_memzero(t1, sizeof(t1));
            sodium_memzero(t2, sizeof(t2));
        }

        void kdf3(SymmetricKey &out1, SymmetricKey &out2, SymmetricKey &out3, const uint8_t *data, size_t dataLen,
                  const SymmetricKey &chainKey) {
            // HKDF 密钥派生（RFC 5869）- 派生 3 个子密钥
            // Extract 阶段：PRK = HMAC-Hash(chainKey, data)
            auto prk = hmacBLAKE2s(data, dataLen, chainKey);

            // Expand 阶段：扩展输出 3 个密钥材料
            uint8_t t[HASH_LEN * 3];
            sodium_memzero(t, sizeof(t));

            // T(1) = HMAC(PRK, 0x01)
            t[HASH_LEN - 1] = 0x01;
            auto okm1 = hmacBLAKE2s(t, HASH_LEN, prk);
            memcpy(out1.data(), okm1.data(), SYMMETRIC_KEY_LEN);

            // T(2) = HMAC(PRK, T(1) || 0x02)
            memcpy(t, okm1.data(), HASH_LEN);
            t[HASH_LEN * 2 - 1] = 0x02;
            auto okm2 = hmacBLAKE2s(t, HASH_LEN * 2, prk);
            memcpy(out2.data(), okm2.data(), SYMMETRIC_KEY_LEN);

            // T(3) = HMAC(PRK, T(2) || 0x03)
            memcpy(t + HASH_LEN, okm2.data(), HASH_LEN);
            t[HASH_LEN * 3 - 1] = 0x03;
            auto okm3 = hmacBLAKE2s(t, HASH_LEN * 3, prk);
            memcpy(out3.data(), okm3.data(), SYMMETRIC_KEY_LEN);

            // 清除敏感数据（防止内存残留）
            sodium_memzero(t, sizeof(t));
            sodium_memzero(prk.data(), prk.size());
        }

        bool encrypt(std::vector<uint8_t> &ciphertext, const uint8_t *plaintext, const size_t plainLen,
                     const uint8_t *aad, const size_t aadLen, const Nonce nonce, const SymmetricKey &key) {
            // ChaCha20-Poly1305 AEAD 加密（RFC 8439）
            // 使用 libsodium 标准 API：crypto_aead_chacha20poly1305_ietf_encrypt
            ciphertext.resize(plainLen + AUTHTAG_LEN);

            unsigned long long actualLen;
            int ret = crypto_aead_chacha20poly1305_ietf_encrypt(ciphertext.data(), &actualLen, plaintext, plainLen, aad,
                                                                aadLen, nullptr, nonce.data(), key.data());

            return ret == 0 && actualLen == ciphertext.size();
        }

        bool encrypt(std::vector<uint8_t> &ciphertext, const uint8_t *plaintext, const size_t plainLen,
                     const uint8_t *aad, const size_t aadLen, const uint64_t nonce, const SymmetricKey &key) {
            Nonce n{};
            std::memcpy(n.data(), &nonce, sizeof(nonce));
            return encrypt(ciphertext, plaintext, plainLen, aad, aadLen, n, key);
        }


        bool decrypt(std::vector<uint8_t> &plaintext, const uint8_t *ciphertext, const size_t cipherLen,
                     const uint8_t *aad, const size_t aadLen, const Nonce nonce, const SymmetricKey &key) {
            // ChaCha20-Poly1305 AEAD 解密（RFC 8439）
            // 使用 libsodium 标准 API：crypto_aead_chacha20poly1305_ietf_decrypt
            if (cipherLen < AUTHTAG_LEN)
                return false;

            plaintext.resize(cipherLen - AUTHTAG_LEN);

            unsigned long long actualLen;
            int ret = crypto_aead_chacha20poly1305_ietf_decrypt(plaintext.data(), &actualLen, nullptr, ciphertext,
                                                                cipherLen, aad, aadLen, nonce.data(), key.data());

            return ret == 0 && actualLen == plaintext.size();
        }

        bool decrypt(std::vector<uint8_t> &plaintext, const uint8_t *ciphertext, const size_t cipherLen,
                     const uint8_t *aad, const size_t aadLen, const uint64_t nonce, const SymmetricKey &key) {
            Nonce n{};
            std::memcpy(n.data(), &nonce, sizeof(nonce));
            return decrypt(plaintext, ciphertext, cipherLen, aad, aadLen, n, key);
        }


        void randomBytes(void *buf, size_t len) {
            // 生成密码学安全的随机数
            // 使用 libsodium 标准 API：randombytes_buf
            // 该函数使用操作系统的熵源（/dev/urandom 或 CryptGenRandom）
            randombytes_buf(buf, len);
        }

        template<size_t N>
        void randomBytes(std::array<uint8_t, N> &arr) {
            // array 版本的重载
            randombytes_buf(arr.data(), N);
        }

        // 显式实例化常用类型
        template void randomBytes<32>(std::array<uint8_t, 32> & arr);

        template void randomBytes<12>(std::array<uint8_t, 12> & arr);

        template void randomBytes<16>(std::array<uint8_t, 16> & arr);

        template<typename T>
        void secureZero(T &data) {
            // 安全清除敏感数据
            // 使用 libsodium 标准 API：sodium_memzero
            // 该函数确保不会被编译器优化掉，真正清除内存中的敏感数据
            sodium_memzero(&data, sizeof(data));
        }

        template void secureZero<std::array<uint8_t, 12> >(std::array<uint8_t, 12> & arr);

        template void secureZero<std::array<uint8_t, 16> >(std::array<uint8_t, 16> & arr);

        template void secureZero<std::array<uint8_t, 32> >(std::array<uint8_t, 32> & arr);

        // 显式实例化常用类型
        //        template void secureZero<PrivateKey>(PrivateKey &);
        //        template void secureZero<SymmetricKey>(SymmetricKey &);
        //        template void secureZero<Hash>(Hash &);

        namespace Message {
            // 辅助方法：从 Hash 初始化链式密钥（不修改成员变量）
            void initializeChainingKeyFromHash(Hash &outChainKey) {
                outChainKey = Crypto::blake2s(reinterpret_cast<const uint8_t *>(NOISE_NAME), strlen(NOISE_NAME));
            }


            void mixHash(Hash &hash, const uint8_t *data, size_t len) {
                std::vector<uint8_t> input;
                input.reserve(HASH_LEN + len);
                input.insert(input.end(), hash.begin(), hash.end());
                input.insert(input.end(), data, data + len);
                hash = Crypto::blake2s(input);
            }

            void kdfSingle(SymmetricKey &chainKey, SymmetricKey &out, const uint8_t *data, size_t dataLen) {
                SymmetricKey unused;
                Crypto::kdf(out, unused, data, dataLen, chainKey); // 派生一个密钥，忽略第二个
            }

            void mixChainKey(SymmetricKey &chainKey, const uint8_t *data, size_t dataLen) {
                SymmetricKey unused;
                Crypto::kdf(chainKey, unused, data, dataLen, chainKey); // 派生一个密钥，忽略第二个
            }

            /**
             * 计算 私钥和公钥的 DH 并混淆到 chainKey中 然后通过混淆狗的 chainKey 派生 outKey
             * @param chainKey
             * @param outKey
             * @param priv
             * @param pub
             * @return
             */
            bool mixDH(SymmetricKey &chainKey, SymmetricKey &outKey, const PrivateKey &priv, const PublicKey &pub) {
                SymmetricKey dhResult;
                if (!Crypto::dh(dhResult, priv, pub)) {
                    return false; // DH 计算失败
                }
                kdfSingle(chainKey, outKey, dhResult.data(), PUBLIC_KEY_LEN); // 混合到链式密钥
                return true;
            }

            bool messageDecrypt(uint8_t *plaintext, const uint8_t *ciphertext, size_t cipherLen,
                                const SymmetricKey &key) {
                std::vector<uint8_t> result;
                if (!Crypto::decrypt(result, ciphertext, cipherLen, nullptr, 0, Nonce{0}, key)) {
                    return false; // 解密失败或认证失败
                }
                if (plaintext) {
                    memcpy(plaintext, result.data(), result.size());
                }
                return true;
            }

            bool messageDecrypt(uint8_t *plaintext, const uint8_t *ciphertext, size_t cipherLen,
                                const uint8_t *aad, size_t aadLen,
                                const SymmetricKey &key) {
                std::vector<uint8_t> result;
                if (!Crypto::decrypt(result, ciphertext, cipherLen, aad, aadLen, Nonce{0}, key)) {
                    return false; // 解密失败或认证失败
                }
                if (plaintext) {
                    memcpy(plaintext, result.data(), result.size());
                }
                return true;
            }

            PublicKey getPublicKey(const MessageInitiation &msg, const PrivateKey &local_private_key) {
                crypto::NOISEReceive receive{};
                receive.init(local_private_key);
                receive.decodeCheckHandshakeInitiation(msg);
                return receive.remote_public;
            }
        }; // namespace Message

        namespace Noise {
            void kdfDual(SymmetricKey &chainKey, SymmetricKey &out1, SymmetricKey &out2) {
                Crypto::kdf(out1, out2, nullptr, 0, chainKey);
            }
        }; // namespace Noise
    }; // namespace Crypto
}; // namespace WireGuard