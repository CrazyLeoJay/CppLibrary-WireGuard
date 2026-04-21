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
/**
 * Created by Leojay on 2026/4/4.
 *
 * @author leojay`fu
 * @email crazyleojay@163.com
 * @url https://github.com/CrazyLeoJay
 */

#ifndef WG_MAIN_NONCE2_H
#define WG_MAIN_NONCE2_H
#include <cstring>
#include <string>

#include "version.h"
#include "crypto.h"
#include "entity.h"
#include "messages.h"
#include "keypair.h"

namespace WireGuard {
    namespace crypto {
        /**
         * 握手阶段
         */
        enum NOISEState :uint8_t {
            none, // 初始状态，还未初始化
            init, // 初始化后
            /*
            发送端
            */
            send_created_handshake_initiation_msg, // 发起方成功创建握手消息后
            send_consume_handshake_response_msg, // 接收到握手消息 消费后（可以传输数据）
            /*
            接收端
            */
            receive_checked_handshake_initiation_msg, // 接收端接收到握手消息后并处理
            receive_created_handshake_response_msg, // 接收端 创建握手响应后 （放可以传输数据）
        };

        class NOISE {
        public:
            virtual ~NOISE() = default;

            mutable PrivateKey local_private{}; // 本地私钥
            mutable PrivateKey local_public{}; // 本地私钥
            mutable PublicKey remote_public{}; // 对端公钥  发送端需要初始化，接收端需要解析后写入
            mutable PrivateKey ephemeral_private_key{}; // 握手时临时密钥
            mutable PublicKey ephemeral_public_key{}; // 握手时临时密钥
            mutable PublicKey remote_ephemeral_public_key{}; // 握手对端的临时公钥

            SymmetricKey pre_shared_key{}; // 预共享密钥

        protected:
            mutable NOISEState state{none};
            mutable std::mutex _noiseMutex{};
            mutable Hash init_hash{};
            mutable ChainKey init_chain_key{};

            mutable Hash hash{};
            mutable ChainKey chain_key{};
            mutable SymmetricKey dh{};

            mutable uint32_t remote_index{0}; // 对端传递的索引

            mutable std::shared_ptr<CookieData> last_received_cookie{}; // 上一次记录的Cookie


        public:
            std::shared_ptr<KeyPair> makeKeyPair(const bool &iAmInitiator) const;

            /**
             * @return 是否可以发送数据
             */
            virtual bool canSendData() = 0;
        };

        /**
         * 接收端
         */
        class NOISEReceive : public NOISE {
        public:
            void init(const PrivateKey &local_private);

            void decodeCheckHandshakeInitiation(const MessageInitiation &msg);

            MessageResponse createHandshakeResponse(const uint32_t &senderIndex);

            bool canSendData() override { return state == receive_created_handshake_response_msg; }
        };

        /**
         * 发送端
         */
        class NOISESend : public NOISE {
        public:
            void init(const PrivateKey &local_private, const PublicKey &remote_public);

            MessageInitiation encodeHandshakeInitiation(uint32_t senderIndex);

            void verifyHandshakeInitiationResponse(const MessageResponse &msg);

            bool canSendData() override { return state == send_consume_handshake_response_msg; }
        };
    } // namespace crypto2

    namespace crypto_static {
        const std::string CONSTRUCTION = "Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s";
        const std::string IDENTIFIER = "WireGuard v1 zx2c4 Jason@zx2c4.com";
        const std::string LABEL_MAC1 = "mac1----";
        const std::string LABEL_COOKIE = "cookie--";

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
            return crypto_static::mixHash(hash.data(), HASH_LEN, data, len);
        }

        inline Hash mixHash(const WGKey &hash, const WGKey &key) {
            return crypto_static::mixHash(hash, key.data(), SYMMETRIC_KEY_LEN);
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
    } // namespace crypto_static
} // namespace WireGuard

#endif // WG_MAIN_NONCE2_H
