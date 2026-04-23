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

#include "../entity.h"
#include "../messages.h"
#include <array>
#include <cstdint>
#include <string>
#include <cstring>
#include <vector>
#include "../version.h"

namespace WireGuard {
    namespace crypto {
        const std::string CONSTRUCTION = "Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s";
        const std::string IDENTIFIER = "WireGuard v1 zx2c4 Jason@zx2c4.com";
        const std::string LABEL_MAC1 = "mac1----";
        const std::string LABEL_COOKIE = "cookie--";


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
        void generatePrivateKey(WireGuard::PrivateKey &key);

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
         * 对私钥和公钥进行Curve25519曲线上的点乘运算，返回32字节的输出。
         *
         * @param private_key
         * @param public_key
         * @return
         */
        SymmetricKey dh(const PrivateKey &private_key, const PublicKey &public_key);

        void dh(SymmetricKey &dhKey, const PrivateKey &private_key, const PublicKey &public_key);

        /**
         * AEAD(密钥, 计数器, 明文, 认证文本)：
         * 按照RFC 7539规定的ChaCha20-Poly1305 AEAD密码套件，其nonce由32位全零后接计数器的64位小端序值组成。
         */
        void encodeAEAD(std::vector<uint8_t> &outPlan, const SymmetricKey &key, uint64_t counter,
                        const unsigned char *plain_text, const size_t &plain_text_len, const Hash *auth);

        std::vector<uint8_t> encodeAEAD(const SymmetricKey &key, uint64_t counter, const unsigned char *plain_text,
                                        const size_t &plain_text_len, const Hash *auth);

        void decodeAEAD(std::vector<uint8_t> &outPlan, const SymmetricKey &key, uint64_t counter,
                        const uint8_t *ciphertext, size_t ciphertext_len, const Hash *auth);

        std::vector<uint8_t> decodeAEAD(const SymmetricKey &key, uint64_t counter, const uint8_t *ciphertext,
                                        size_t ciphertext_len, const Hash *auth);


        Hash hash(const uint8_t *data, size_t len);

        Hash hash(const std::vector<uint8_t> &data);

        Hash hash(const std::array<uint8_t, 32> &data);

        Hash hash(const std::string &data);

        Hash mixHash(const uint8_t *befData, size_t befLen, const uint8_t *data, size_t len);

        void mixHash(Hash &outHash, const uint8_t *befData, size_t befLen, const uint8_t *data, size_t len);

        inline Hash mixHash(const WGKey &hash, const uint8_t *data, size_t len) {
            return crypto::mixHash(hash.data(), HASH_LEN, data, len);
        }

        inline Hash mixHash(const WGKey &hash, const WGKey &key) {
            return crypto::mixHash(hash, key.data(), SYMMETRIC_KEY_LEN);
        }

        inline Hash mixHash(const WGKey &hash, const std::string &value) {
            return mixHash(hash, reinterpret_cast<const uint8_t *>(value.c_str()), strlen(value.c_str()));
        }

        inline Hash mixHash(const std::string &tag, const WGKey &key) {
            return mixHash(reinterpret_cast<const uint8_t *>(tag.data()), tag.size(), key.data(), key.size());
        }

        /**
         *  Keyed-BLAKE2s(key, input, outlen=16)
         *
         * @param key
         * @param keylen
         * @param input
         * @param inputlen
         * @param out
         * @param outlen 不超过 32
         * @return
         */
        int keyed_blake2s(unsigned char *out, size_t outlen, const unsigned char *input, size_t inputlen,
                          const unsigned char *key, size_t keylen);

        // /**
        //  * 对缓冲区进行异或操作
        //  */
        // static void xor_buffer(uint8_t *buffer, uint8_t value, size_t len) {
        //     for (size_t i = 0; i < len; ++i) {
        //         buffer[i] ^= value;
        //     }
        // }

        void hmac_blake2s(uint8_t *out, const uint8_t *message, size_t message_len, const uint8_t *key, size_t key_len);

        /**
         * 如果不提供 key：它就是一个快速、安全的密码学哈希函数（类似 SHA-256，但更快）。
         *  如果提供 key：它就变成一个 消息认证码（MAC），可用于验证数据完整性和真实性（类似 HMAC，但更高效）。
         * MAC(key, input): Keyed-Blake2s(key, input, 16), returning 16 bytes of output
         *
         * @param data
         * @param data_len
         * @return
         */
        MacData MAC(const uint8_t *keyData, const size_t &keyLen, const uint8_t *data, const size_t &data_len);

        inline MacData MAC(const WGKey &key, const uint8_t *data, const size_t data_len) {
            return MAC(key.data(), WG_KEY_LEN, data, data_len);
        }

        /**
         * HMAC 哈希计算
         *
         * @param key
         * @param data
         * @param data_len
         * @return
         */
        inline WGKey HMAC(const WGKey &key, const uint8_t *data, const size_t data_len) {
            WGKey output;
            hmac_blake2s(output.data(), data, data_len, key.data(), WG_KEY_LEN);
            return output;
        }

        inline void HMAC(WGKey &output, const WGKey &key, const uint8_t *data, const size_t data_len) {
            hmac_blake2s(output.data(), data, data_len, key.data(), WG_KEY_LEN);
        }

        void kdf(WGKey &output1, const WGKey &chaining_key, const uint8_t *data, const size_t &data_len);

        void kdf2(WGKey &output1, WGKey &output2, const WGKey &chaining_key, const uint8_t *data,
                  const size_t &data_len);

        void kdf3(WGKey &output1, WGKey &output2, WGKey &output3, const WGKey &chaining_key, const uint8_t *data,
                  const size_t &data_len);


        /**
         * Cookie回复包 用到
         * XAEAD(密钥, 随机数, 明文, 认证文本):
         * XChaCha20Poly1305密文封装算法，使用随机的24字节随机数
         * XAEAD: 使用 XChaCha20-Poly1305 加密
         */
        std::vector<uint8_t> encodeXAEAD(const uint8_t *key, // 32 字节密钥
                                         const uint8_t *nonce, // 24 字节随机 nonce
                                         const uint8_t *plaintext, size_t plaintext_len, const uint8_t *ad,
                                         size_t ad_len // 认证附加数据 (AAD)
        );

        std::vector<uint8_t> decodeXAEAD(const uint8_t *key, const uint8_t *nonce, const uint8_t *ciphertext,
                                         size_t ciphertext_len, const uint8_t *ad, size_t ad_len);

        /**
         * @return 创建索引
         */
        uint32_t createIndex();

        /**
         * 打印日志
         */
        void printHashChainKey(const Hash &hash, const ChainKey &ck, const std::string &tag,
                               std::function<void(const std::string &)> func
        );

        void tai64n_now(Timestamp &timestamp);

        /**
         * 从握手消息中获取 PublicKey
         * @param msg
         * @param local_private_key
         * @return
         */
        PublicKey getPublicKey(const MessageInitiation &msg, const PrivateKey &local_private_key);


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
    } // namespace Crypto
} // namespace WireGuard

#endif // WIREGUARD_CRYPTO_H
