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
 *
 * @author leojay`fu
 * @email crazyleojay@163.com
 * @url https://github.com/CrazyLeoJay
 */

// #define SHOW_DEBUG_LOGS true //Debug日志打印开关

#include "nonce.h"
#include <cassert>
#include <netinet/in.h>
#include <random>
#include <sys/stat.h>
#include "WGException.h"
#include "crypto.h"
#include "sodium.h"
#include "blake2s/blake2.h"
#include "tools/tools.h"


namespace WireGuard {
    std::shared_ptr<KeyPair> crypto::NOISE::makeKeyPair(const bool &iAmInitiator) const {
        // 必须在响应之后，或者是发出响应后才能调用创建
        if (iAmInitiator && state != NOISEState::send_consume_handshake_response_msg) {
            throw WGException("发起者：必须在处理握手响应Response之后才能创建密钥 当前：state=%d", state);
        } else if (!iAmInitiator && state != NOISEState::receive_created_handshake_response_msg) {
            throw WGException("响应者：必须在发出握手响应Response之后才能创建密钥 当前：state=%d", state);
        }

        auto keypair = std::make_shared<KeyPair>();
        keypair->iAmTheInitiator = iAmInitiator;
        keypair->remoteIndex = remote_index;

        SymmetricKey send_key, recv_key;

        if (iAmInitiator) {
            // 客户端 第一个是 发送密钥 第二个是接收密钥
            crypto_static::kdf2(send_key, recv_key, chain_key, nullptr, 0);
        } else {
            // 服务端 第一个是 接收密钥 第二个是发送密钥
            crypto_static::kdf2(recv_key, send_key, chain_key, nullptr, 0);
        }

        auto time = std::chrono::steady_clock::now().time_since_epoch();
        uint64_t now = std::chrono::duration_cast<std::chrono::nanoseconds>(time).count();

        memcpy(keypair->sending.key.data(), send_key.data(), SYMMETRIC_KEY_LEN);
        keypair->sending.birthdate = now;
        keypair->sending.isValid = true;

        memcpy(keypair->receiving.key.data(), recv_key.data(), SYMMETRIC_KEY_LEN);
        keypair->receiving.birthdate = now;
        keypair->receiving.isValid = true;

        // clear();

        return keypair;
    }

    void crypto::NOISEReceive::init(const PrivateKey &local_private) {
        state = NOISEState::none;
        this->local_private = local_private;
        Crypto::generatePublicKey(local_public, local_private);
        init_chain_key = crypto_static::hash(crypto_static::CONSTRUCTION);
        // 接收端主要是用于解析，这里使用 本地公钥初始化
        auto init_init_hash = crypto_static::mixHash(init_chain_key, crypto_static::IDENTIFIER);
        Logs::print_space([&]() {
            crypto_static::printHashChainKey(init_init_hash, init_chain_key, "init", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });

        init_hash = crypto_static::mixHash(init_init_hash, local_public);
        crypto_static::printHashChainKey(init_hash, init_chain_key, "add (接收端公钥)", [](const std::string &log) {
            LOG_DEBUG("%{public}s", log.c_str());
        });
        state = NOISEState::init;
    }

    void crypto::NOISEReceive::decodeCheckHandshakeInitiation(const MessageInitiation &msg) {
        std::lock_guard<std::mutex> lock(_noiseMutex);
        // 初始化参数
        // initHashAndChainKey();

        remote_index = msg.senderIndex;

        // 获取对端的临时公钥
        // PublicKey remote_ephemeral_public_key{};
        std::memcpy(remote_ephemeral_public_key.data(), msg.ephemeral, PUBLIC_KEY_LEN);
        //  hash 和 chain_key混淆 临时公钥
        hash = crypto_static::mixHash(init_hash, remote_ephemeral_public_key);
        crypto_static::kdf(chain_key, init_chain_key, remote_ephemeral_public_key.data(), PUBLIC_KEY_LEN);
        Logs::print_space([&]() {
            crypto_static::printHashChainKey(hash, chain_key, "add 临时公钥", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });

        // chain_key  混入 本地私钥和临时公钥的DH
        SymmetricKey eDh;
        try {
            eDh = crypto_static::dh(local_private, remote_ephemeral_public_key);
            LOG_DEBUG("共享密钥（DH）：%{public}s\n", Crypto::bin2B64(eDh.data(), HASH_LEN).c_str());
        } catch (const std::exception &e) {
            throw WGException("DH（本地私钥，临时公钥） 计算异常: %{public}s", e.what());
        }

        // 派生临时密钥
        SymmetricKey temp_key{};
        crypto_static::kdf2(chain_key, temp_key, chain_key, eDh.data(), PUBLIC_KEY_LEN);
        LOG_DEBUG("派生临时密钥（tempKey）：%{public}s\n", Crypto::bin2B64(temp_key.data(), SYMMETRIC_KEY_LEN).c_str());
        Logs::print_space([&]() {
            crypto_static::printHashChainKey(hash, chain_key, "ck add temp_key", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // 解密 对方公钥
        try {
            auto plan_text =
                    crypto_static::decodeAEAD(temp_key, 0, msg.encryptedStatic, sizeof(msg.encryptedStatic), &hash);
            std::memcpy(remote_public.data(), plan_text.data(), PUBLIC_KEY_LEN);
            LOG_DEBUG(
                "解密静态公钥（peerPublicKey）：%{public}s\n",
                Crypto::bin2B64(remote_public.data(), PUBLIC_KEY_LEN).c_str()
            );
        } catch (const WGException &e) {
            throw WGException("解析对方公钥异常：%{public}s", e.what());
        }

        // hash 混入对方公钥的加密字段
        hash = crypto_static::mixHash(hash, msg.encryptedStatic, sizeof(msg.encryptedStatic));
        Logs::print_space([&]() {
            crypto_static::printHashChainKey(hash, chain_key, "hash add 加密公钥", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // chain_key 根据对方 公钥和自己的私钥计算 DH 更新临时加解密公钥
        try {
            crypto_static::dh(dh, local_private, remote_public);
        } catch (const std::exception &e) {
            throw WGException("DH(本地私钥，对端公钥) 计算失败：%{public}s", e.what());
        }

        // 派生临时密钥 temp_key
        crypto_static::kdf2(chain_key, temp_key, chain_key, dh.data(), PUBLIC_KEY_LEN);

        Logs::print_space([&]() {
            crypto_static::printHashChainKey(hash, chain_key, "add DH ", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        try {
            // 解密时间戳 并且将时间戳加入 hash
            Timestamp timestamp{};
            auto etLen = sizeof(msg.encryptedTimestamp);
            auto time = crypto_static::decodeAEAD(temp_key, 0, msg.encryptedTimestamp, etLen, &hash);
            std::memcpy(timestamp.data(), time.data(), TIMESTAMP_LEN);
            hash = crypto_static::mixHash(hash, msg.encryptedTimestamp, etLen);
        } catch (const WGException &e) {
            throw WGException("解析时间戳异常：%{public}s", e.what());
        }
        Logs::print_space([&]() {
            crypto_static::printHashChainKey(hash, chain_key, "add 加密后时间戳 ", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // mac 验证和hash
        // 初始化 cookie hash 验证
        auto cookieInitHash = crypto_static::mixHash(crypto_static::LABEL_MAC1, local_public);

        // 转为 const uint8_t*（只读）
        const auto *bytes = reinterpret_cast<const uint8_t *>(&msg);
        size_t mac1_input_length = sizeof(MessageInitiation) - COOKIE_LEN * 2;
        auto mac1 = crypto_static::MAC(cookieInitHash, bytes, mac1_input_length);
        if (std::memcmp(mac1.data(), msg.mac1, COOKIE_LEN) != 0) {
            throw WGException("MAC1 验证失败！");
        }

        if (last_received_cookie) {
            size_t mac2_input_length = sizeof(MessageInitiation) - COOKIE_LEN;
            auto mac2 = crypto_static::MAC(last_received_cookie->data(), COOKIE_LEN, bytes, mac2_input_length);
            if (std::memcmp(mac2.data(), msg.mac2, COOKIE_LEN) != 0) {
                throw WGException("MAC2 验证失败！");
            }
        }

        state = NOISEState::receive_checked_handshake_initiation_msg;
    }

    MessageResponse crypto::NOISEReceive::createHandshakeResponse(const uint32_t &senderIndex) {
        std::lock_guard<std::mutex> lock(_noiseMutex);
        if (state != NOISEState::receive_checked_handshake_initiation_msg) {
            throw WGException("必须是处理完成握手之后才能创建响应");
        }
        Logs::print_space([&]() {
            crypto_static::printHashChainKey(hash, chain_key, "创建握手响应", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });

        // 创建随机公钥私钥
        Crypto::generatePrivateKey(ephemeral_private_key);
        Crypto::generatePublicKey(ephemeral_public_key, ephemeral_private_key);

        MessageResponse msg{};
        // 转为网络字节序
        msg.receiverIndex = remote_index;
        msg.senderIndex = senderIndex;

        // 写入公钥 并且混合 hash 和 chain_key
        std::memcpy(msg.ephemeral, ephemeral_public_key.data(), PUBLIC_KEY_LEN);
        hash = crypto_static::mixHash(hash, msg.ephemeral, PUBLIC_KEY_LEN);
        crypto_static::kdf(chain_key, chain_key, msg.ephemeral, PUBLIC_KEY_LEN);
        Logs::print_space([&]() {
            crypto_static::printHashChainKey(
                hash, chain_key,
                "混合临公钥 :" + Crypto::bin2B64(ephemeral_public_key.data(), ephemeral_public_key.size()),
                [](const std::string &log) { LOG_DEBUG("%{public}s", log.c_str()); }
            );
        });

        // 计算 临时DH(本地临时私钥，对端临时公钥) 并混入chain_key
        const auto e_dh = crypto_static::dh(ephemeral_private_key, remote_ephemeral_public_key);
        crypto_static::kdf(chain_key, chain_key, e_dh.data(), PUBLIC_KEY_LEN);
        Logs::print_space([&]() {
            auto logStr = std::string("混合本地临私钥 和 对方临时公钥") +
                          "\nlocal ephemeral private key: " + Crypto::bin32Array2Base64(ephemeral_private_key) +
                          "\nremote ephemeral public key: " + Crypto::bin32Array2Base64(remote_ephemeral_public_key);
            crypto_static::printHashChainKey(hash, chain_key, logStr, [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // 计算 临时DH(本地临时私钥，对端公钥) 并混入chain_key
        const auto e_dh2 = crypto_static::dh(ephemeral_private_key, remote_public);
        crypto_static::kdf(chain_key, chain_key, e_dh2.data(), PUBLIC_KEY_LEN);
        Logs::print_space([&]() {
            auto logStr = std::string("混合本地临私钥 和 对方公钥") +
                          "\nlocal ephemeral private key: " + Crypto::bin32Array2Base64(ephemeral_private_key) +
                          "\nremote           public key: " + Crypto::bin32Array2Base64(remote_public);
            crypto_static::printHashChainKey(hash, chain_key, logStr, [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // 计算 预共享密钥 并混入chain_key
        SymmetricKey temp2;
        SymmetricKey key;
        crypto_static::kdf3(chain_key, temp2, key, chain_key, pre_shared_key.data(), SYMMETRIC_KEY_LEN);
        hash = crypto_static::mixHash(hash, temp2.data(), temp2.size());
        Logs::print_space([&]() {
            crypto_static::printHashChainKey(
                hash, chain_key,
                "派生公钥，并加入预共享密钥 " + Crypto::bin2B64(pre_shared_key.data(), SYMMETRIC_KEY_LEN),
                [](const std::string &log) { LOG_DEBUG("%{public}s", log.c_str()); }

            );
            LOG_DEBUG("加密密钥：%s", Crypto::bin2B64(key.data(), SYMMETRIC_KEY_LEN).c_str());
        });
        // 加密空数据
        auto encodeStr = crypto_static::encodeAEAD(key, 0, nullptr, 0, &hash);
        std::memcpy(msg.encryptedNothing, encodeStr.data(), encodeStr.size());
        Logs::print_space([&]() { LOG_DEBUG("加密证完成"); });

        // mac 填充
        auto cookieInitHash = crypto_static::mixHash(crypto_static::LABEL_MAC1, remote_public);
        // 处理mac1
        // 转为 const uint8_t*（只读）
        const auto *bytes = reinterpret_cast<const uint8_t *>(&msg);
        size_t mac1_input_length = sizeof(MessageResponse) - COOKIE_LEN * 2;
        auto mac1 = crypto_static::MAC(cookieInitHash, bytes, mac1_input_length);
        std::memcpy(msg.mac1, mac1.data(), COOKIE_LEN);

        // 处理mac2
        if (last_received_cookie) {
            size_t mac2_input_length = sizeof(MessageResponse) - COOKIE_LEN;
            auto mac2 = crypto_static::MAC(last_received_cookie->data(), COOKIE_LEN, bytes, mac2_input_length);
            std::memcpy(msg.mac2, mac2.data(), COOKIE_LEN);
        } else {
            std::memset(msg.mac2, 0, COOKIE_LEN);
        }
        state = NOISEState::receive_created_handshake_response_msg;
        Logs::print_space([&]() { LOG_DEBUG("InitiationResponse 构建完成"); });
        return msg;
    }

    void crypto::NOISESend::init(const PrivateKey &local_private, const PublicKey &remote_public) {
        state = NOISEState::none;
        this->local_private = local_private;
        this->remote_public = remote_public;
        Crypto::generatePublicKey(local_public, local_private);
        // 预先计算 DH
        dh = crypto_static::dh(local_private, remote_public);
        init_chain_key = crypto_static::hash(crypto_static::CONSTRUCTION);
        auto hashBefore = crypto_static::mixHash(init_chain_key, crypto_static::IDENTIFIER);
        crypto_static::printHashChainKey(hashBefore, init_chain_key, "init", [](const std::string &log) {
            LOG_DEBUG("%{public}s", log.c_str());
        });

        // 接收端主要是用于解析，这里使用 本地公钥初始化
        init_hash = crypto_static::mixHash(hashBefore, remote_public);
        LOG_DEBUG("add remote_public: %{public}s\n", Crypto::bin32Array2Base64(remote_public).c_str());
        crypto_static::printHashChainKey(init_hash, init_chain_key, "init(add 远端Public)", [](const std::string &log) {
            LOG_DEBUG("%{public}s", log.c_str());
        });
        state = NOISEState::init;
    }

    MessageInitiation crypto::NOISESend::encodeHandshakeInitiation(uint32_t senderIndex) {
        std::lock_guard<std::mutex> lock(_noiseMutex);

        Crypto::generatePrivateKey(ephemeral_private_key);
        // 计算 临时 私钥 公钥对
        Crypto::generatePublicKey(ephemeral_public_key, ephemeral_private_key);
        MessageInitiation msg;
        msg.senderIndex = senderIndex;
        // 写入临时公钥
        std::memcpy(msg.ephemeral, ephemeral_public_key.data(), PUBLIC_KEY_LEN);

        // hash 混淆 临时公钥
        hash = crypto_static::mixHash(init_hash, ephemeral_public_key);
        crypto_static::kdf(chain_key, init_chain_key, ephemeral_public_key.data(), PUBLIC_KEY_LEN);
        LOG_DEBUG("临时公钥：%{public}s\n", Crypto::bin32Array2Base64(ephemeral_public_key).c_str());
        Logs::print_space([&]() {
            crypto_static::printHashChainKey(hash, chain_key, "add 临时公钥", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        //
        SymmetricKey tempKey;
        crypto_static::kdf2(
            chain_key, tempKey, chain_key,
            crypto_static::dh(ephemeral_private_key, remote_public).data(), // 临时密钥和远端公钥
            PUBLIC_KEY_LEN
        );
        Logs::print_space([&]() {
            LOG_DEBUG(
                "临时DH：%{public}s\n",
                Crypto::bin32Array2Base64(crypto_static::dh(ephemeral_private_key, remote_public)).c_str()
            );
            LOG_DEBUG("派生TempKey：%{public}s\n", Crypto::bin32Array2Base64(tempKey).c_str());
            crypto_static::printHashChainKey(hash, chain_key, "add 临时DH", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // AEAD
        auto encode = crypto_static::encodeAEAD(tempKey, 0, local_public.data(), PUBLIC_KEY_LEN, &hash);
        std::memcpy(msg.encryptedStatic, encode.data(), encode.size()); // 将本地公钥进行加密写入
        // 混入hash
        hash = crypto_static::mixHash(hash, encode.data(), encode.size());
        //
        // 混合服务端私钥和对端公钥的 DH
        crypto_static::kdf2(chain_key, tempKey, chain_key, dh.data(), PUBLIC_KEY_LEN);

        Logs::print_space([&]() {
            LOG_DEBUG("加密的公钥：%{public}s\n", Crypto::bin32Array2Base64(local_public).c_str());
            LOG_DEBUG("加密后的公钥值：%{public}s\n", Crypto::bin2B64(encode.data(), encode.size()).c_str());
            LOG_DEBUG("派生TempKey：%{public}s\n", Crypto::bin32Array2Base64(tempKey).c_str());
            crypto_static::printHashChainKey(
                hash, chain_key, "add hash加密后密钥 chain_key 混淆 DH",
                [](const std::string &log) { LOG_DEBUG("%{public}s", log.c_str()); }
            );
        });
        // 加密时间
        Timestamp timestamp;
        crypto_static::tai64n_now(timestamp);
        const auto time = crypto_static::encodeAEAD(tempKey, 0, timestamp.data(), TIMESTAMP_LEN, &hash);
        std::memcpy(msg.encryptedTimestamp, time.data(), time.size());
        hash = crypto_static::mixHash(hash, msg.encryptedTimestamp, sizeof(msg.encryptedTimestamp));
        Logs::print_space([&]() {
            crypto_static::printHashChainKey(hash, chain_key, "add 加密后时间戳", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // mac 填充
        auto cookieInitHash = crypto_static::mixHash(crypto_static::LABEL_MAC1, remote_public);

        // 处理mac1
        // 转为 const uint8_t*（只读）
        const auto *bytes = reinterpret_cast<const uint8_t *>(&msg);
        size_t mac1_input_length = sizeof(MessageInitiation) - COOKIE_LEN * 2;
        auto mac1 = crypto_static::MAC(cookieInitHash, bytes, mac1_input_length);
        std::memcpy(msg.mac1, mac1.data(), COOKIE_LEN);

        // 处理mac2
        if (last_received_cookie) {
            size_t mac2_input_length = sizeof(MessageInitiation) - COOKIE_LEN;
            auto mac2 = crypto_static::MAC(last_received_cookie->data(), COOKIE_LEN, bytes, mac2_input_length);
            std::memcpy(msg.mac2, mac2.data(), COOKIE_LEN);
        } else {
            std::memset(msg.mac2, 0, COOKIE_LEN);
        }

        state = NOISEState::send_created_handshake_initiation_msg;
        return msg;
    }

    void crypto::NOISESend::verifyHandshakeInitiationResponse(const MessageResponse &msg) {
        std::lock_guard<std::mutex> lock(_noiseMutex);
        // 需要判断当前状态，是否为刚握手完成，否则应该抛出异常重新握手
        if (state != NOISEState::send_created_handshake_initiation_msg) {
            throw WGException("必须在发送握手请求后才能处理响应，应该重新握手");
        }
        Logs::print_space([&]() {
            crypto_static::printHashChainKey(hash, chain_key, "开始验证握手响应", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // 记录当前索引
        remote_index = msg.senderIndex;

        // e: 读取临时公钥（服务端的临时公钥）
        PublicKey e;
        memcpy(e.data(), msg.ephemeral, PUBLIC_KEY_LEN);
        hash = crypto_static::mixHash(hash, msg.ephemeral, PUBLIC_KEY_LEN);
        crypto_static::kdf(chain_key, chain_key, msg.ephemeral, PUBLIC_KEY_LEN);
        Logs::print_space([&]() {
            crypto_static::printHashChainKey(
                hash, chain_key, "混合临公钥 :" + Crypto::bin2B64(e.data(), e.size()),
                [](const std::string &log) { LOG_DEBUG("%{public}s", log.c_str()); }
            );
        });
        // ee: DH(e_local, e_remote)
        //  使用本地的 临时私钥（握手时生成） 和 对方的临时公钥
        const SymmetricKey e_dh1 = crypto_static::dh(ephemeral_private_key, e);
        crypto_static::kdf(chain_key, chain_key, e_dh1.data(), PUBLIC_KEY_LEN);
        Logs::print_space([&]() {
            auto logStr = std::string("混合本地临私钥 和 对方临时公钥") +
                          "\nlocal ephemeral private key: " + Crypto::bin32Array2Base64(ephemeral_private_key) +
                          "\nremote ephemeral public key: " + Crypto::bin32Array2Base64(e);
            crypto_static::printHashChainKey(hash, chain_key, logStr, [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // se: DH(s_local, e_remote)
        //  使用本地的 本地私钥 和 对方的临时公钥
        const auto e_dh2 = crypto_static::dh(local_private, e);
        crypto_static::kdf(chain_key, chain_key, e_dh2.data(), PUBLIC_KEY_LEN);
        Logs::print_space([&]() {
            auto logStr = std::string("混合本地私钥 和 对方临时公钥") +
                          "\nlocal           private key: " + Crypto::bin32Array2Base64(local_private) +
                          "\nremote ephemeral public key: " + Crypto::bin32Array2Base64(e);
            crypto_static::printHashChainKey(hash, chain_key, logStr, [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // 计算 预共享密钥 并混入chain_key
        SymmetricKey temp2; // 用于更新哈希
        SymmetricKey key; // 用于解密
        crypto_static::kdf3(chain_key, temp2, key, chain_key, pre_shared_key.data(), SYMMETRIC_KEY_LEN);
        hash = crypto_static::mixHash(hash, temp2.data(), temp2.size());
        Logs::print_space([&]() {
            crypto_static::printHashChainKey(
                hash, chain_key,
                "派生公钥，并加入预共享密钥 " + Crypto::bin2B64(pre_shared_key.data(), SYMMETRIC_KEY_LEN),
                [](const std::string &log) { LOG_DEBUG("%{public}s", log.c_str()); }
            );
            LOG_DEBUG("解密密钥：%{public}s", Crypto::bin2B64(key.data(), SYMMETRIC_KEY_LEN).c_str());
        });

        // 解密空数据
        crypto_static::decodeAEAD(key, 0, msg.encryptedNothing, sizeof(msg.encryptedNothing), &hash);
        Logs::print_space([&]() { LOG_DEBUG("解密成功："); });
        // mac 填充
        auto cookieInitHash = crypto_static::mixHash(crypto_static::LABEL_MAC1, local_public);
        // 处理mac1
        // 转为 const uint8_t*（只读）
        const auto *bytes = reinterpret_cast<const uint8_t *>(&msg);
        size_t mac1_input_length = sizeof(msg) - COOKIE_LEN * 2;
        auto mac1 = crypto_static::MAC(cookieInitHash, bytes, mac1_input_length);
        if (std::memcmp(msg.mac1, mac1.data(), COOKIE_LEN) != 0) {
            // std::memcpy(msg.mac1, mac1.data(), COOKIE_LEN);
            throw WGException(
                "mac1 验证失败 msg.mac1=%s c_mac1=%s", Crypto::bin2B64(msg.mac1, COOKIE_LEN).c_str(),
                Crypto::bin2B64(mac1.data(), COOKIE_LEN).c_str()
            );
        }

        // 处理mac2
        if (last_received_cookie) {
            size_t mac2_input_length = sizeof(msg) - COOKIE_LEN;
            auto mac2 = crypto_static::MAC(last_received_cookie->data(), COOKIE_LEN, bytes, mac2_input_length);
            if (std::memcmp(msg.mac2, mac2.data(), COOKIE_LEN) != 0) {
                // std::memcpy(msg.mac2, mac2.data(), COOKIE_LEN);
                throw WGException(
                    "mac2 验证失败msg.mac2=%s c_mac2=%s", Crypto::bin2B64(msg.mac2, COOKIE_LEN).c_str(),
                    Crypto::bin2B64(mac2.data(), COOKIE_LEN).c_str()
                );
            }
        }

        state = send_consume_handshake_response_msg;
        Logs::print_space([&]() { LOG_DEBUG("InitiationResponse 验证完成"); });
    }

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

    namespace crypto_static {
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
                Crypto::bin2Hex(ciphertext, ciphertext_len).c_str()
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
            auto hashStr = Crypto::bin2B64(hash.data(), hash.size());
            auto ckStr = Crypto::bin2B64(ck.data(), ck.size());
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

        const uint64_t get_current_time_ns() {
            auto now = std::chrono::steady_clock::now();
            return std::chrono::duration_cast<std::chrono::nanoseconds>(now.time_since_epoch()).count();
        }
    } // namespace crypto_static
} // namespace WireGuard