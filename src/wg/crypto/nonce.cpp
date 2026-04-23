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
#include "blake2.h"
#include "../tools.h"


namespace WireGuard {
    std::shared_ptr<KeyPair> Noise::NOISE::makeKeyPair(const bool &iAmInitiator) const {
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
            crypto::kdf2(send_key, recv_key, chain_key, nullptr, 0);
        } else {
            // 服务端 第一个是 接收密钥 第二个是发送密钥
            crypto::kdf2(recv_key, send_key, chain_key, nullptr, 0);
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

    void Noise::NOISEReceive::init(const PrivateKey &local_private) {
        state = NOISEState::none;
        this->local_private = local_private;
        crypto::generatePublicKey(local_public, local_private);
        init_chain_key = crypto::hash(crypto::CONSTRUCTION);
        // 接收端主要是用于解析，这里使用 本地公钥初始化
        auto init_init_hash = crypto::mixHash(init_chain_key, crypto::IDENTIFIER);
        Logs::print_space([&]() {
            crypto::printHashChainKey(init_init_hash, init_chain_key, "init", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });

        init_hash = crypto::mixHash(init_init_hash, local_public);
        crypto::printHashChainKey(init_hash, init_chain_key, "add (接收端公钥)", [](const std::string &log) {
            LOG_DEBUG("%{public}s", log.c_str());
        });
        state = NOISEState::init;
    }

    void Noise::NOISEReceive::decodeCheckHandshakeInitiation(const MessageInitiation &msg) {
        std::lock_guard<std::mutex> lock(_noiseMutex);
        // 初始化参数
        // initHashAndChainKey();

        remote_index = msg.senderIndex;

        // 获取对端的临时公钥
        // PublicKey remote_ephemeral_public_key{};
        std::memcpy(remote_ephemeral_public_key.data(), msg.ephemeral, PUBLIC_KEY_LEN);
        //  hash 和 chain_key混淆 临时公钥
        hash = crypto::mixHash(init_hash, remote_ephemeral_public_key);
        crypto::kdf(chain_key, init_chain_key, remote_ephemeral_public_key.data(), PUBLIC_KEY_LEN);
        Logs::print_space([&]() {
            crypto::printHashChainKey(hash, chain_key, "add 临时公钥", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });

        // chain_key  混入 本地私钥和临时公钥的DH
        SymmetricKey eDh;
        try {
            eDh = crypto::dh(local_private, remote_ephemeral_public_key);
            LOG_DEBUG("共享密钥（DH）：%{public}s\n", crypto::bin2B64(eDh.data(), HASH_LEN).c_str());
        } catch (const std::exception &e) {
            throw WGException("DH（本地私钥，临时公钥） 计算异常: %{public}s", e.what());
        }

        // 派生临时密钥
        SymmetricKey temp_key{};
        crypto::kdf2(chain_key, temp_key, chain_key, eDh.data(), PUBLIC_KEY_LEN);
        LOG_DEBUG("派生临时密钥（tempKey）：%{public}s\n", crypto::bin2B64(temp_key.data(), SYMMETRIC_KEY_LEN).c_str());
        Logs::print_space([&]() {
            crypto::printHashChainKey(hash, chain_key, "ck add temp_key", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // 解密 对方公钥
        try {
            auto plan_text =
                    crypto::decodeAEAD(temp_key, 0, msg.encryptedStatic, sizeof(msg.encryptedStatic), &hash);
            std::memcpy(remote_public.data(), plan_text.data(), PUBLIC_KEY_LEN);
            LOG_DEBUG(
                "解密静态公钥（peerPublicKey）：%{public}s\n",
                crypto::bin2B64(remote_public.data(), PUBLIC_KEY_LEN).c_str()
            );
        } catch (const WGException &e) {
            throw WGException("解析对方公钥异常：%{public}s", e.what());
        }

        // hash 混入对方公钥的加密字段
        hash = crypto::mixHash(hash, msg.encryptedStatic, sizeof(msg.encryptedStatic));
        Logs::print_space([&]() {
            crypto::printHashChainKey(hash, chain_key, "hash add 加密公钥", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // chain_key 根据对方 公钥和自己的私钥计算 DH 更新临时加解密公钥
        try {
            crypto::dh(dh, local_private, remote_public);
        } catch (const std::exception &e) {
            throw WGException("DH(本地私钥，对端公钥) 计算失败：%{public}s", e.what());
        }

        // 派生临时密钥 temp_key
        crypto::kdf2(chain_key, temp_key, chain_key, dh.data(), PUBLIC_KEY_LEN);

        Logs::print_space([&]() {
            crypto::printHashChainKey(hash, chain_key, "add DH ", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        try {
            // 解密时间戳 并且将时间戳加入 hash
            Timestamp timestamp{};
            auto etLen = sizeof(msg.encryptedTimestamp);
            auto time = crypto::decodeAEAD(temp_key, 0, msg.encryptedTimestamp, etLen, &hash);
            std::memcpy(timestamp.data(), time.data(), TIMESTAMP_LEN);
            hash = crypto::mixHash(hash, msg.encryptedTimestamp, etLen);
        } catch (const WGException &e) {
            throw WGException("解析时间戳异常：%{public}s", e.what());
        }
        Logs::print_space([&]() {
            crypto::printHashChainKey(hash, chain_key, "add 加密后时间戳 ", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // mac 验证和hash
        // 初始化 cookie hash 验证
        auto cookieInitHash = crypto::mixHash(crypto::LABEL_MAC1, local_public);

        // 转为 const uint8_t*（只读）
        const auto *bytes = reinterpret_cast<const uint8_t *>(&msg);
        size_t mac1_input_length = sizeof(MessageInitiation) - COOKIE_LEN * 2;
        auto mac1 = crypto::MAC(cookieInitHash, bytes, mac1_input_length);
        if (std::memcmp(mac1.data(), msg.mac1, COOKIE_LEN) != 0) {
            throw WGException("MAC1 验证失败！");
        }

        if (last_received_cookie) {
            size_t mac2_input_length = sizeof(MessageInitiation) - COOKIE_LEN;
            auto mac2 = crypto::MAC(last_received_cookie->data(), COOKIE_LEN, bytes, mac2_input_length);
            if (std::memcmp(mac2.data(), msg.mac2, COOKIE_LEN) != 0) {
                throw WGException("MAC2 验证失败！");
            }
        }

        state = NOISEState::receive_checked_handshake_initiation_msg;
    }

    MessageResponse Noise::NOISEReceive::createHandshakeResponse(const uint32_t &senderIndex) {
        std::lock_guard<std::mutex> lock(_noiseMutex);
        if (state != NOISEState::receive_checked_handshake_initiation_msg) {
            throw WGException("必须是处理完成握手之后才能创建响应");
        }
        Logs::print_space([&]() {
            crypto::printHashChainKey(hash, chain_key, "创建握手响应", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });

        // 创建随机公钥私钥
        crypto::generatePrivateKey(ephemeral_private_key);
        crypto::generatePublicKey(ephemeral_public_key, ephemeral_private_key);

        MessageResponse msg{};
        // 转为网络字节序
        msg.receiverIndex = remote_index;
        msg.senderIndex = senderIndex;

        // 写入公钥 并且混合 hash 和 chain_key
        std::memcpy(msg.ephemeral, ephemeral_public_key.data(), PUBLIC_KEY_LEN);
        hash = crypto::mixHash(hash, msg.ephemeral, PUBLIC_KEY_LEN);
        crypto::kdf(chain_key, chain_key, msg.ephemeral, PUBLIC_KEY_LEN);
        Logs::print_space([&]() {
            crypto::printHashChainKey(
                hash, chain_key,
                "混合临公钥 :" + crypto::bin2B64(ephemeral_public_key.data(), ephemeral_public_key.size()),
                [](const std::string &log) { LOG_DEBUG("%{public}s", log.c_str()); }
            );
        });

        // 计算 临时DH(本地临时私钥，对端临时公钥) 并混入chain_key
        const auto e_dh = crypto::dh(ephemeral_private_key, remote_ephemeral_public_key);
        crypto::kdf(chain_key, chain_key, e_dh.data(), PUBLIC_KEY_LEN);
        Logs::print_space([&]() {
            auto logStr = std::string("混合本地临私钥 和 对方临时公钥") +
                          "\nlocal ephemeral private key: " + crypto::bin32Array2Base64(ephemeral_private_key) +
                          "\nremote ephemeral public key: " + crypto::bin32Array2Base64(remote_ephemeral_public_key);
            crypto::printHashChainKey(hash, chain_key, logStr, [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // 计算 临时DH(本地临时私钥，对端公钥) 并混入chain_key
        const auto e_dh2 = crypto::dh(ephemeral_private_key, remote_public);
        crypto::kdf(chain_key, chain_key, e_dh2.data(), PUBLIC_KEY_LEN);
        Logs::print_space([&]() {
            auto logStr = std::string("混合本地临私钥 和 对方公钥") +
                          "\nlocal ephemeral private key: " + crypto::bin32Array2Base64(ephemeral_private_key) +
                          "\nremote           public key: " + crypto::bin32Array2Base64(remote_public);
            crypto::printHashChainKey(hash, chain_key, logStr, [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // 计算 预共享密钥 并混入chain_key
        SymmetricKey temp2;
        SymmetricKey key;
        crypto::kdf3(chain_key, temp2, key, chain_key, pre_shared_key.data(), SYMMETRIC_KEY_LEN);
        hash = crypto::mixHash(hash, temp2.data(), temp2.size());
        Logs::print_space([&]() {
            crypto::printHashChainKey(
                hash, chain_key,
                "派生公钥，并加入预共享密钥 " + crypto::bin2B64(pre_shared_key.data(), SYMMETRIC_KEY_LEN),
                [](const std::string &log) { LOG_DEBUG("%{public}s", log.c_str()); }

            );
            LOG_DEBUG("加密密钥：%s", crypto::bin2B64(key.data(), SYMMETRIC_KEY_LEN).c_str());
        });
        // 加密空数据
        auto encodeStr = crypto::encodeAEAD(key, 0, nullptr, 0, &hash);
        std::memcpy(msg.encryptedNothing, encodeStr.data(), encodeStr.size());
        Logs::print_space([&]() { LOG_DEBUG("加密证完成"); });

        // mac 填充
        auto cookieInitHash = crypto::mixHash(crypto::LABEL_MAC1, remote_public);
        // 处理mac1
        // 转为 const uint8_t*（只读）
        const auto *bytes = reinterpret_cast<const uint8_t *>(&msg);
        size_t mac1_input_length = sizeof(MessageResponse) - COOKIE_LEN * 2;
        auto mac1 = crypto::MAC(cookieInitHash, bytes, mac1_input_length);
        std::memcpy(msg.mac1, mac1.data(), COOKIE_LEN);

        // 处理mac2
        if (last_received_cookie) {
            size_t mac2_input_length = sizeof(MessageResponse) - COOKIE_LEN;
            auto mac2 = crypto::MAC(last_received_cookie->data(), COOKIE_LEN, bytes, mac2_input_length);
            std::memcpy(msg.mac2, mac2.data(), COOKIE_LEN);
        } else {
            std::memset(msg.mac2, 0, COOKIE_LEN);
        }
        state = NOISEState::receive_created_handshake_response_msg;
        Logs::print_space([&]() { LOG_DEBUG("InitiationResponse 构建完成"); });
        return msg;
    }

    void Noise::NOISESend::init(const PrivateKey &local_private, const PublicKey &remote_public) {
        state = NOISEState::none;
        this->local_private = local_private;
        this->remote_public = remote_public;
        crypto::generatePublicKey(local_public, local_private);
        // 预先计算 DH
        dh = crypto::dh(local_private, remote_public);
        init_chain_key = crypto::hash(crypto::CONSTRUCTION);
        auto hashBefore = crypto::mixHash(init_chain_key, crypto::IDENTIFIER);
        crypto::printHashChainKey(hashBefore, init_chain_key, "init", [](const std::string &log) {
            LOG_DEBUG("%{public}s", log.c_str());
        });

        // 接收端主要是用于解析，这里使用 本地公钥初始化
        init_hash = crypto::mixHash(hashBefore, remote_public);
        LOG_DEBUG("add remote_public: %{public}s\n", crypto::bin32Array2Base64(remote_public).c_str());
        crypto::printHashChainKey(init_hash, init_chain_key, "init(add 远端Public)", [](const std::string &log) {
            LOG_DEBUG("%{public}s", log.c_str());
        });
        state = NOISEState::init;
    }

    MessageInitiation Noise::NOISESend::encodeHandshakeInitiation(uint32_t senderIndex) {
        std::lock_guard<std::mutex> lock(_noiseMutex);

        crypto::generatePrivateKey(ephemeral_private_key);
        // 计算 临时 私钥 公钥对
        crypto::generatePublicKey(ephemeral_public_key, ephemeral_private_key);
        MessageInitiation msg;
        msg.senderIndex = senderIndex;
        // 写入临时公钥
        std::memcpy(msg.ephemeral, ephemeral_public_key.data(), PUBLIC_KEY_LEN);

        // hash 混淆 临时公钥
        hash = crypto::mixHash(init_hash, ephemeral_public_key);
        crypto::kdf(chain_key, init_chain_key, ephemeral_public_key.data(), PUBLIC_KEY_LEN);
        LOG_DEBUG("临时公钥：%{public}s\n", crypto::bin32Array2Base64(ephemeral_public_key).c_str());
        Logs::print_space([&]() {
            crypto::printHashChainKey(hash, chain_key, "add 临时公钥", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        //
        SymmetricKey tempKey;
        crypto::kdf2(
            chain_key, tempKey, chain_key,
            crypto::dh(ephemeral_private_key, remote_public).data(), // 临时密钥和远端公钥
            PUBLIC_KEY_LEN
        );
        Logs::print_space([&]() {
            LOG_DEBUG(
                "临时DH：%{public}s\n",
                crypto::bin32Array2Base64(crypto::dh(ephemeral_private_key, remote_public)).c_str()
            );
            LOG_DEBUG("派生TempKey：%{public}s\n", crypto::bin32Array2Base64(tempKey).c_str());
            crypto::printHashChainKey(hash, chain_key, "add 临时DH", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // AEAD
        auto encode = crypto::encodeAEAD(tempKey, 0, local_public.data(), PUBLIC_KEY_LEN, &hash);
        std::memcpy(msg.encryptedStatic, encode.data(), encode.size()); // 将本地公钥进行加密写入
        // 混入hash
        hash = crypto::mixHash(hash, encode.data(), encode.size());
        //
        // 混合服务端私钥和对端公钥的 DH
        crypto::kdf2(chain_key, tempKey, chain_key, dh.data(), PUBLIC_KEY_LEN);

        Logs::print_space([&]() {
            LOG_DEBUG("加密的公钥：%{public}s\n", crypto::bin32Array2Base64(local_public).c_str());
            LOG_DEBUG("加密后的公钥值：%{public}s\n", crypto::bin2B64(encode.data(), encode.size()).c_str());
            LOG_DEBUG("派生TempKey：%{public}s\n", crypto::bin32Array2Base64(tempKey).c_str());
            crypto::printHashChainKey(
                hash, chain_key, "add hash加密后密钥 chain_key 混淆 DH",
                [](const std::string &log) { LOG_DEBUG("%{public}s", log.c_str()); }
            );
        });
        // 加密时间
        Timestamp timestamp;
        crypto::tai64n_now(timestamp);
        const auto time = crypto::encodeAEAD(tempKey, 0, timestamp.data(), TIMESTAMP_LEN, &hash);
        std::memcpy(msg.encryptedTimestamp, time.data(), time.size());
        hash = crypto::mixHash(hash, msg.encryptedTimestamp, sizeof(msg.encryptedTimestamp));
        Logs::print_space([&]() {
            crypto::printHashChainKey(hash, chain_key, "add 加密后时间戳", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // mac 填充
        auto cookieInitHash = crypto::mixHash(crypto::LABEL_MAC1, remote_public);

        // 处理mac1
        // 转为 const uint8_t*（只读）
        const auto *bytes = reinterpret_cast<const uint8_t *>(&msg);
        size_t mac1_input_length = sizeof(MessageInitiation) - COOKIE_LEN * 2;
        auto mac1 = crypto::MAC(cookieInitHash, bytes, mac1_input_length);
        std::memcpy(msg.mac1, mac1.data(), COOKIE_LEN);

        // 处理mac2
        if (last_received_cookie) {
            size_t mac2_input_length = sizeof(MessageInitiation) - COOKIE_LEN;
            auto mac2 = crypto::MAC(last_received_cookie->data(), COOKIE_LEN, bytes, mac2_input_length);
            std::memcpy(msg.mac2, mac2.data(), COOKIE_LEN);
        } else {
            std::memset(msg.mac2, 0, COOKIE_LEN);
        }

        state = NOISEState::send_created_handshake_initiation_msg;
        return msg;
    }

    void Noise::NOISESend::verifyHandshakeInitiationResponse(const MessageResponse &msg) const {
        std::lock_guard<std::mutex> lock(_noiseMutex);
        // 需要判断当前状态，是否为刚握手完成，否则应该抛出异常重新握手
        if (state != NOISEState::send_created_handshake_initiation_msg) {
            throw WGException("必须在发送握手请求后才能处理响应，应该重新握手");
        }
        Logs::print_space([&]() {
            crypto::printHashChainKey(hash, chain_key, "开始验证握手响应", [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // 记录当前索引
        remote_index = msg.senderIndex;

        // e: 读取临时公钥（服务端的临时公钥）
        PublicKey e;
        memcpy(e.data(), msg.ephemeral, PUBLIC_KEY_LEN);
        hash = crypto::mixHash(hash, msg.ephemeral, PUBLIC_KEY_LEN);
        crypto::kdf(chain_key, chain_key, msg.ephemeral, PUBLIC_KEY_LEN);
        Logs::print_space([&]() {
            crypto::printHashChainKey(
                hash, chain_key, "混合临公钥 :" + crypto::bin2B64(e.data(), e.size()),
                [](const std::string &log) { LOG_DEBUG("%{public}s", log.c_str()); }
            );
        });
        // ee: DH(e_local, e_remote)
        //  使用本地的 临时私钥（握手时生成） 和 对方的临时公钥
        const SymmetricKey e_dh1 = crypto::dh(ephemeral_private_key, e);
        crypto::kdf(chain_key, chain_key, e_dh1.data(), PUBLIC_KEY_LEN);
        Logs::print_space([&]() {
            auto logStr = std::string("混合本地临私钥 和 对方临时公钥") +
                          "\nlocal ephemeral private key: " + crypto::bin32Array2Base64(ephemeral_private_key) +
                          "\nremote ephemeral public key: " + crypto::bin32Array2Base64(e);
            crypto::printHashChainKey(hash, chain_key, logStr, [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // se: DH(s_local, e_remote)
        //  使用本地的 本地私钥 和 对方的临时公钥
        const auto e_dh2 = crypto::dh(local_private, e);
        crypto::kdf(chain_key, chain_key, e_dh2.data(), PUBLIC_KEY_LEN);
        Logs::print_space([&]() {
            auto logStr = std::string("混合本地私钥 和 对方临时公钥") +
                          "\nlocal           private key: " + crypto::bin32Array2Base64(local_private) +
                          "\nremote ephemeral public key: " + crypto::bin32Array2Base64(e);
            crypto::printHashChainKey(hash, chain_key, logStr, [](const std::string &log) {
                LOG_DEBUG("%{public}s", log.c_str());
            });
        });
        // 计算 预共享密钥 并混入chain_key
        SymmetricKey temp2; // 用于更新哈希
        SymmetricKey key; // 用于解密
        crypto::kdf3(chain_key, temp2, key, chain_key, pre_shared_key.data(), SYMMETRIC_KEY_LEN);
        hash = crypto::mixHash(hash, temp2.data(), temp2.size());
        Logs::print_space([&]() {
            crypto::printHashChainKey(
                hash, chain_key,
                "派生公钥，并加入预共享密钥 " + crypto::bin2B64(pre_shared_key.data(), SYMMETRIC_KEY_LEN),
                [](const std::string &log) { LOG_DEBUG("%{public}s", log.c_str()); }
            );
            LOG_DEBUG("解密密钥：%{public}s", crypto::bin2B64(key.data(), SYMMETRIC_KEY_LEN).c_str());
        });

        // 解密空数据
        crypto::decodeAEAD(key, 0, msg.encryptedNothing, sizeof(msg.encryptedNothing), &hash);
        Logs::print_space([&]() { LOG_DEBUG("解密成功："); });
        // mac 填充
        auto cookieInitHash = crypto::mixHash(crypto::LABEL_MAC1, local_public);
        // 处理mac1
        // 转为 const uint8_t*（只读）
        const auto *bytes = reinterpret_cast<const uint8_t *>(&msg);
        size_t mac1_input_length = sizeof(msg) - COOKIE_LEN * 2;
        auto mac1 = crypto::MAC(cookieInitHash, bytes, mac1_input_length);
        if (std::memcmp(msg.mac1, mac1.data(), COOKIE_LEN) != 0) {
            // std::memcpy(msg.mac1, mac1.data(), COOKIE_LEN);
            throw WGException(
                "mac1 验证失败 msg.mac1=%s c_mac1=%s", crypto::bin2B64(msg.mac1, COOKIE_LEN).c_str(),
                crypto::bin2B64(mac1.data(), COOKIE_LEN).c_str()
            );
        }

        // 处理mac2
        if (last_received_cookie) {
            size_t mac2_input_length = sizeof(msg) - COOKIE_LEN;
            auto mac2 = crypto::MAC(last_received_cookie->data(), COOKIE_LEN, bytes, mac2_input_length);
            if (std::memcmp(msg.mac2, mac2.data(), COOKIE_LEN) != 0) {
                // std::memcpy(msg.mac2, mac2.data(), COOKIE_LEN);
                throw WGException(
                    "mac2 验证失败msg.mac2=%s c_mac2=%s", crypto::bin2B64(msg.mac2, COOKIE_LEN).c_str(),
                    crypto::bin2B64(mac2.data(), COOKIE_LEN).c_str()
                );
            }
        }

        state = send_consume_handshake_response_msg;
        Logs::print_space([&]() { LOG_DEBUG("InitiationResponse 验证完成"); });
    }

} // namespace WireGuard
