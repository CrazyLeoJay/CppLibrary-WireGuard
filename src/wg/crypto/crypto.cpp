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
#include "encoding.hpp"
#include "nonce.h"
#include <sodium.h>
#include <stdexcept>
#include <cassert>
#include <netinet/in.h>
#include <random>
#include <sys/stat.h>
#include "WGException.h"
#include "blake2.h"
#include "../tools.h"

namespace WireGuard {
    namespace crypto {
        std::string bin2Hex(const uint8_t *data, const size_t &len) {
            std::vector<char> hex_out(len * 2 + 1); // +1 for null terminator
            sodium_bin2hex(hex_out.data(), hex_out.size(), data, len);
            return std::string{hex_out.data(), len * 2};
        }

        std::string bin2Hex(const uint32_t &data) {
            return bin2Hex(reinterpret_cast<const uint8_t *>(&data), sizeof(data));
        }

        std::string bin2B64(const uint8_t *data, const size_t &len) {
            const auto resultLen = sodium_base64_ENCODED_LEN(len, sodium_base64_VARIANT_ORIGINAL);
            std::vector<char> hex_out(resultLen); // +1 for null terminator
            sodium_bin2base64(hex_out.data(), resultLen, data, len, sodium_base64_VARIANT_ORIGINAL);
            return std::string{hex_out.data(), resultLen};
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

        std::vector<uint8_t> hex2Bin(const std::string &hexStr) {
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

        std::array<uint8_t, 32> base642Bin32Array(const std::string &b64) { return Base64::key_from_base64(b64); }

        std::string bin32Array2Base64(const std::array<uint8_t, 32> &bytes) {
            // sodium_bin2base64 的输出缓冲区
            char b64[sodium_base64_ENCODED_LEN(32, sodium_base64_VARIANT_ORIGINAL)];

            // 直接转换二进制到 Base64
            sodium_bin2base64(b64, sizeof(b64), bytes.data(), 32, sodium_base64_VARIANT_ORIGINAL);
            return std::string{b64};
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

        SymmetricKey dh(const PrivateKey &private_key, const PublicKey &public_key) {
            SymmetricKey shared;
            if (crypto_scalarmult_curve25519(shared.data(), private_key.data(), public_key.data()) != 0) {
                throw WGException("dh  failed");
            }
            return shared;
        }

        void dh(SymmetricKey &dhKey, const PrivateKey &private_key, const PublicKey &public_key) {
            if (crypto_scalarmult_curve25519(dhKey.data(), private_key.data(), public_key.data()) != 0) {
                throw WGException("dh  failed");
            }
        }


        void encodeAEAD(
            std::vector<uint8_t> &outPlan, const SymmetricKey &key, uint64_t counter, const unsigned char *plain_text,
            const size_t &plain_text_len, const Hash *auth
        ) {
            if (sodium_init() < 0)
                throw std::runtime_error("sodium_init failed");

            Nonce nonce = Tools::makeNonce(counter);

            //            std::vector<uint8_t> plain;
            // ChaCha20-Poly1305 AEAD 加密（RFC 8439）
            // 使用 libsodium 标准 API：crypto_aead_chacha20poly1305_ietf_encrypt
            // plain.resize(plain_text_len + AUTHTAG_LEN);
            outPlan.resize(plain_text_len + crypto_aead_chacha20poly1305_IETF_ABYTES);

            unsigned long long actualLen;

            int ret;
            if (auth) {
                ret = crypto_aead_chacha20poly1305_ietf_encrypt(
                    outPlan.data(), &actualLen, plain_text, plain_text_len, auth->data(), HASH_LEN, nullptr,
                    nonce.data(), key.data()
                );
            } else {
                ret = crypto_aead_chacha20poly1305_ietf_encrypt(
                    outPlan.data(), &actualLen, plain_text, plain_text_len, nullptr, 0, nullptr, nonce.data(),
                    key.data()
                );
            }
            if (ret == 0 && actualLen == outPlan.size()) {
                outPlan.resize(actualLen); // 应为 plaintext_len + 16
                return;
            }
            throw WGException("AEAD encrypt failed");
        }

        std::vector<uint8_t> encodeAEAD(
            const SymmetricKey &key, uint64_t counter, const unsigned char *plain_text, const size_t &plain_text_len,
            const Hash *auth
        ) {
            std::vector<uint8_t> outPlan;
            encodeAEAD(outPlan, key, counter, plain_text, plain_text_len, auth);
            return outPlan;
        }

        void decodeAEAD(
            std::vector<uint8_t> &plaintext, const SymmetricKey &key, uint64_t counter, const uint8_t *ciphertext,
            size_t ciphertext_len, const Hash *auth
        ) {
            if (sodium_init() < 0)
                throw std::runtime_error("sodium_init failed");
            if (ciphertext_len < crypto_aead_chacha20poly1305_IETF_ABYTES)
                throw std::runtime_error("Ciphertext too short");

            Nonce nonce = Tools::makeNonce(counter);

            // ChaCha20-Poly1305 AEAD 加密（RFC 8439）e
            // 使用 libsodium 标准 API：crypto_aead_chacha20poly1305_ietf_encrypt
            // plain.resize(ciphertext_len + AUTHTAG_LEN);
            plaintext.resize(ciphertext_len - crypto_aead_chacha20poly1305_IETF_ABYTES);
            unsigned long long decrypted_len = 0;
            // crypto_aead_chacha20poly1305_ietf_decrypt
            int ret;
            if (auth) {
                ret = crypto_aead_chacha20poly1305_ietf_decrypt(
                    plaintext.data(), &decrypted_len, nullptr, ciphertext, ciphertext_len, auth->data(), HASH_LEN,
                    nonce.data(), key.data()
                );
            } else {
                ret = crypto_aead_chacha20poly1305_ietf_decrypt(
                    plaintext.data(), &decrypted_len, nullptr, ciphertext, ciphertext_len, nullptr, 0, nonce.data(),
                    key.data()
                );
            }
            if (ret == 0) {
                plaintext.resize(decrypted_len);
                return;
            }
            throw WGException(
                "AEAD decrypt failed ret=%d counter=%d msg=%s", ret, counter,
                crypto::bin2Hex(ciphertext, ciphertext_len).c_str()
            );
        }

        std::vector<uint8_t> decodeAEAD(
            const SymmetricKey &key, uint64_t counter, const uint8_t *ciphertext, size_t ciphertext_len,
            const Hash *auth
        ) {
            std::vector<uint8_t> outPlan;
            decodeAEAD(outPlan, key, counter, ciphertext, ciphertext_len, auth);
            return outPlan;
        }

        Hash hash(const uint8_t *data, size_t len) {
            Hash hash;
            size_t outLen = HASH_LEN;
            blake2s(hash.data(), outLen, data, len, nullptr, 0);
            return hash;
        }

        namespace {
            class HashBuilder {
            private:
                blake2s_state state{};
                size_t outlen{32};

            public:
                HashBuilder() { blake2s_init(&state, outlen); }

                HashBuilder *add(const uint8_t *data, size_t len) {
                    blake2s_update(&state, data, len);
                    return this;
                }

                HashBuilder *add(const std::string &str) {
                    blake2s_update(&state, str.c_str(), str.size());
                    return this;
                }

                Hash build() {
                    Hash hash{};
                    blake2s_final(&state, hash.data(), outlen);
                    return hash;
                }

                void build(Hash &hash) { blake2s_final(&state, hash.data(), outlen); }
            };
        }

        Hash hash(const std::vector<uint8_t> &data) { return hash(data.data(), data.size()); }

        Hash hash(const std::array<uint8_t, 32> &data) { return hash(data.data(), 32); }

        Hash hash(const std::string &data) { return HashBuilder().add(data)->build(); }

        Hash mixHash(const uint8_t *befData, size_t befLen, const uint8_t *data, size_t len) {
            return HashBuilder().add(befData, befLen)->add(data, len)->build();
        }

        void mixHash(Hash &outHash, const uint8_t *befData, size_t befLen, const uint8_t *data, size_t len) {
            HashBuilder().add(befData, befLen)->add(data, len)->build(outHash);
        }

        int keyed_blake2s(
            unsigned char *out, size_t outlen, const unsigned char *input, size_t inputlen, const unsigned char *key,
            size_t keylen
        ) {
            if (outlen > BLAKE2S_OUTBYTES || keylen > BLAKE2S_KEYBYTES)
                return -1; // 参数超限

            blake2s_state state;
            if (blake2s_init_key(&state, outlen, key, keylen) != 0)
                return -1;
            blake2s_update(&state, input, inputlen);
            blake2s_final(&state, out, outlen);
            return 0;
        }

        void
        hmac_blake2s(uint8_t *out, const uint8_t *message, size_t message_len, const uint8_t *key, size_t key_len) {
            assert(out != nullptr);
            assert(message != nullptr || message_len == 0);
            assert(key != nullptr);

            std::vector<uint8_t> x_key(BLAKE2S_BLOCK_SIZE);
            std::vector<uint8_t> i_hash(BLAKE2S_HASH_SIZE);

            // 步骤1: 处理密钥 - 如果过长则哈希压缩
            if (key_len > BLAKE2S_BLOCK_SIZE) {
                blake2s_state state;
                blake2s_init(&state, BLAKE2S_HASH_SIZE);
                blake2s_update(&state, key, key_len);
                blake2s_final(&state, x_key.data(), BLAKE2S_BLOCK_SIZE);
            } else {
                std::memcpy(x_key.data(), key, key_len);
            }

            // 步骤2: 内层哈希 - K ⊕ ipad
            // xor_buffer(x_key.data(), 0x36, BLAKE2S_BLOCK_SIZE);
            for (size_t i = 0; i < BLAKE2S_BLOCK_SIZE; ++i) {
                x_key[i] ^= 0x36;
            }

            blake2s_state state;
            blake2s_init(&state, BLAKE2S_HASH_SIZE);
            blake2s_update(&state, x_key.data(), BLAKE2S_BLOCK_SIZE);
            blake2s_update(&state, message, message_len);
            blake2s_final(&state, i_hash.data(), BLAKE2S_HASH_SIZE);

            // 步骤3: 外层哈希 - K ⊕ opad
            // 0x5c ^ 0x36 撤销之前的0x36异或，再应用0x5c
            // xor_buffer(x_key.data(), 0x5c ^ 0x36, BLAKE2S_BLOCK_SIZE);
            for (size_t i = 0; i < BLAKE2S_BLOCK_SIZE; ++i) {
                x_key[i] ^= 0x5c ^ 0x36;
            }

            blake2s_init(&state, BLAKE2S_HASH_SIZE);
            blake2s_update(&state, x_key.data(), BLAKE2S_BLOCK_SIZE);
            blake2s_update(&state, i_hash.data(), BLAKE2S_HASH_SIZE);
            blake2s_final(&state, i_hash.data(), BLAKE2S_HASH_SIZE);

            // 步骤4: 输出结果
            std::memcpy(out, i_hash.data(), BLAKE2S_HASH_SIZE);
            std::memset(x_key.data(), 0, BLAKE2S_BLOCK_SIZE);
            std::memset(i_hash.data(), 0, BLAKE2S_HASH_SIZE);
        }

        MacData MAC(const uint8_t *keyData, const size_t &keyLen, const uint8_t *data, const size_t &data_len) {
            MacData output;
            keyed_blake2s(output.data(), COOKIE_LEN, data, data_len, keyData, keyLen);
            return output;
        }

        void kdf(WGKey &output1, const WGKey &chaining_key, const uint8_t *data, const size_t &data_len) {
            auto secret = HMAC(chaining_key, data, data_len);
            // 长度 32+1的output
            uint8_t value = 0x01;
            HMAC(output1, secret, &value, 1);

            // 清理敏感数据
            sodium_memzero(secret.data(), WG_KEY_LEN);
        }

        void
        kdf2(WGKey &output1, WGKey &output2, const WGKey &chaining_key, const uint8_t *data, const size_t &data_len) {
            auto secret = HMAC(chaining_key, data, data_len);
            // 长度 32+1的output
            std::array<uint8_t, BLAKE2S_HASH_SIZE + 1> output{};
            uint8_t value = 0x01;
            HMAC(output1, secret, &value, 1);

            std::memcpy(output.data(), output1.data(), BLAKE2S_HASH_SIZE);
            output[BLAKE2S_HASH_SIZE] = 0x02;
            HMAC(output2, secret, output.data(), BLAKE2S_HASH_SIZE + 1);

            // 清理敏感数据
            sodium_memzero(secret.data(), WG_KEY_LEN);
        }

        void kdf3(
            WGKey &output1, WGKey &output2, WGKey &output3, const WGKey &chaining_key, const uint8_t *data,
            const size_t &data_len
        ) {
            auto secret = HMAC(chaining_key, data, data_len);
            // 长度 32+1的output
            std::array<uint8_t, BLAKE2S_HASH_SIZE + 1> output{};
            uint8_t value = 0x01;
            HMAC(output1, secret, &value, 1);

            std::memcpy(output.data(), output1.data(), BLAKE2S_HASH_SIZE);
            output[BLAKE2S_HASH_SIZE] = 0x02;
            HMAC(output2, secret, output.data(), BLAKE2S_HASH_SIZE + 1);

            std::memcpy(output.data(), output2.data(), BLAKE2S_HASH_SIZE);
            output[BLAKE2S_HASH_SIZE] = 0x03;
            HMAC(output3, secret, output.data(), BLAKE2S_HASH_SIZE + 1);

            // 清理敏感数据
            sodium_memzero(secret.data(), WG_KEY_LEN);
        }

        std::vector<uint8_t> encodeXAEAD(
            const uint8_t *key, const uint8_t *nonce, const uint8_t *plaintext, size_t plaintext_len, const uint8_t *ad,
            size_t ad_len
        ) {
            if (sodium_init() < 0) {
                throw std::runtime_error("sodium_init() failed");
            }
            // 输出缓冲区 = 密文 + 16字节认证标签
            std::vector<uint8_t> ciphertext(plaintext_len + crypto_aead_xchacha20poly1305_IETF_ABYTES);

            unsigned long long ciphertext_len;

            int ret = crypto_aead_xchacha20poly1305_ietf_encrypt(
                ciphertext.data(), &ciphertext_len, plaintext, plaintext_len, ad, ad_len, // AAD（可为 nullptr）
                nullptr, // nsec（必须为 nullptr）
                nonce, key
            );

            if (ret != 0) {
                throw std::runtime_error("Encryption failed");
            }

            // 调整 vector 大小（实际应等于 plaintext_len + 16）
            ciphertext.resize(ciphertext_len);
            return ciphertext; // 包含密文 + 16-byte tag
        }

        std::vector<uint8_t> decodeXAEAD(
            const uint8_t *key, const uint8_t *nonce, const uint8_t *ciphertext, size_t ciphertext_len,
            const uint8_t *ad, size_t ad_len
        ) {
            if (sodium_init() < 0) {
                throw std::runtime_error("sodium_init() failed");
            }
            if (ciphertext_len < crypto_aead_xchacha20poly1305_IETF_ABYTES)
                throw std::runtime_error("Ciphertext too short");

            size_t plaintext_len = ciphertext_len - crypto_aead_xchacha20poly1305_IETF_ABYTES;
            std::vector<uint8_t> plaintext(plaintext_len);

            unsigned long long decrypted_len;
            int ret = crypto_aead_xchacha20poly1305_ietf_decrypt(
                plaintext.data(), &decrypted_len,
                nullptr, // nsec
                ciphertext, ciphertext_len, ad, ad_len, nonce, key
            );

            if (ret != 0)
                throw std::runtime_error("Decryption failed or tag mismatch");
            plaintext.resize(decrypted_len);
            return plaintext;
        }

        uint32_t createIndex() {
            // 随机数分布（均匀的 32 位整数）
            std::uniform_int_distribution<uint32_t> dist;
            std::mt19937_64 rng_{};
            // 尝试找到一个未使用的索引
            return dist(rng_);
        }

        void printHashChainKey(
            const Hash &hash, const ChainKey &ck, const std::string &tag, std::function<void(const std::string &)> func
        ) {
            const auto hashStr = crypto::bin2B64(hash.data(), hash.size());
            const auto ckStr = crypto::bin2B64(ck.data(), ck.size());
            func("current value :" + tag);
            func("hash = " + hashStr);
            func("ck = " + ckStr);
        }

        void tai64n_now(Timestamp &timestamp) {
            auto now = std::chrono::system_clock::now();
            auto epoch = now.time_since_epoch();
            auto seconds = std::chrono::duration_cast<std::chrono::seconds>(epoch).count();
            auto nanos = std::chrono::duration_cast<std::chrono::nanoseconds>(epoch).count() % 1000000000;

            uint64_t tai_seconds = static_cast<uint64_t>(seconds) + 10ULL + 37ULL;

            for (int i = 7; i >= 0; --i) {
                timestamp[i] = tai_seconds & 0xFF;
                tai_seconds >>= 8;
            }
            for (int i = 3; i >= 0; --i) {
                timestamp[8 + i] = (nanos >> ((3 - i) * 8)) & 0xFF;
            }
        }

        PublicKey getPublicKey(const MessageInitiation &msg, const PrivateKey &local_private_key) {
            Noise::NOISEReceive receive{};
            receive.init(local_private_key);
            receive.decodeCheckHandshakeInitiation(msg);
            return receive.remote_public;
        }


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

        const uint64_t get_current_time_ns() {
            auto now = std::chrono::steady_clock::now();
            return std::chrono::duration_cast<std::chrono::nanoseconds>(now.time_since_epoch()).count();
        }
    } // namespace crypto_static
}; // namespace WireGuard
