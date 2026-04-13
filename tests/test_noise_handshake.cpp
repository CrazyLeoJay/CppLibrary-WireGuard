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
// 握手测试
//
// Created by Leojay on 2026/4/4.
//

#include "cookie.h"
#include "crypto/nonce2.h"
#include "test_params.h"
#include "tools/tools.h"
#include "udp_socket.h"
#include "crypto/nonce2.h"
#include "gtest/gtest.h"
/*
 * 记录测试
 * 客户端keypair
 * private: CKvZGm8S0HoQUwvUIsZ8wd39Bqt/5Z5vaJNuKX4LHGI=
 * public : gN9lnPxypH67F7KystwjDdpwNsT007AV8s/MOOc0QGM=
 *
 * 服务端
 * Private : 6CPPJCvfaej0+lwY5amd5pKJ0WLT0JuSv0VyPnMimVE=
 * Public  : sMDHZrFHvyZKaYe1NYCy9+r2iR2DSQlcIFVFpeAh32A=
 *
 *
 * 临时：
 * private : CKvZGm8S0HoQUwvUIsZ8wd39Bqt/5Z5vaJNuKX4LHGI=
 * public  : gN9lnPxypH67F7KystwjDdpwNsT007AV8s/MOOc0QGM=
 */

namespace WireGuard {
    /**
     * 创建握手
     */
    TEST(Noise_Handshake, clientCreateInitiationMessage) {
        WireGuard::crypto2::NOISESend noise{};
        // noise.init(client_private, server_public);
        // WireGuard::CookieManager cm{};
        // auto msg = noise.createInitiation(client_public, server_public, &cm);
        // printf("echo: "
        //        "TYPE: %u"
        //        "Sender: %s", msg.header.type, msg.);
    }

    /**
    *
    *
    */
    TEST(Noise_Handshake, serverDecodeInitiationMessage) {
        const std::string hex =
                "010000003a3e1613a8d7f898fc0d3bd961bea695a24bd7909061cd3e1d0de0a4daa8b804b620292dbf889016d704caca8b942469583851cba029c94fbcd74c1f9387262b40761a13cb652aad37a8449a8ef2fd5c62e5c040d6e4be3a8bf6200f16e319eaa2df23f8c504ba35e77b722eca1c15cdb646320a1779aa09b68af64df06daa3a00000000000000000000000000000000";
        auto bytes = hexStringToArray(hex);
        // MessageInitiation msg{};
        // std::memcpy(&msg, bytes.data(), bytes.size());
        auto msg = *reinterpret_cast<const MessageInitiation *>(bytes.data());
        printf("sender:%s\nephemeral:%s\nencrypted:%s\nTimestamp:%s\nmac1:%s\n",
               Crypto::bin2Hex(msg.senderIndex).c_str(),
               Crypto::bin32Array2Base64(reinterpret_cast<const std::array<uint8_t, 32> &>(msg.ephemeral)).c_str(),
               Crypto::bin2Hex(msg.encryptedStatic, 48).c_str(),
               Crypto::bin2Hex(msg.encryptedTimestamp, 12 + 16).c_str(),
               Crypto::bin2Hex(msg.mac1, 16).c_str()
        );

        crypto2::NOISEReceive noise;
        noise.init(server_private);
        noise.decodeCheckHandshakeInitiation(msg);

        auto pub = noise.remote_public;
        auto str = Crypto::bin32Array2Base64(pub);
        printf("remote public_key :%s", str.c_str());
        EXPECT_EQ(pub, client_public);
    }

    /**
     * 检测客户端生成和服务端解析
     */
    TEST(Noise_Handshake, clientAndServerInitiationMessageCheck) {
        LOG_DEBUG("=============== 发送端：加密！ =================\n");
        MessageInitiation msg;
        crypto2::NOISESend send{};
        send.init(client_private, server_public);
        send.ephemeral_private_key = ephemeral_private;
        try {
            // auto index = crypto_static::createIndex();
            auto index = 0;
            msg = send.encodeHandshakeInitiation(index);
        } catch (const std::exception &e) {
            printf("exception client 加密失败: %s\n", e.what());
            throw e;
        }

        LOG_DEBUG("=============== 接收端：解密！ =================\n");
        crypto2::NOISEReceive receive;
        receive.init(server_private);
        try {
            receive.decodeCheckHandshakeInitiation(msg);
        } catch (const std::exception &e) {
            printf("exception server 解密失败: %s\n", e.what());
            throw e;
        }
        auto pub = receive.remote_public;
        auto str = Crypto::bin32Array2Base64(pub);
        printf("client public_key :%s\n", str.c_str());
        EXPECT_EQ(pub, client_public);


        LOG_DEBUG("=============== 接收端：响应结果 =================\n");
        auto receiveIndex = crypto_static::createIndex();
        MessageResponse respMsg;
        try {
            respMsg = receive.createHandshakeResponse(receiveIndex);
        } catch (const std::exception &e) {
            printf("exception server 创建握手响应: %s\n", e.what());
            throw e;
        }

        LOG_DEBUG("=============== 发送端：验证响应 =================\n");
        // 解析握手响应
        try {
            send.verifyHandshakeInitiationResponse(respMsg);
        } catch (const std::exception &e) {
            printf("exception client 解密握手响应异常 : %s\n", e.what());
            throw e;
        }

        auto sendKp = send.makeKeyPair(true);
        auto receiveKp = receive.makeKeyPair(false);
        auto nonce = sendKp->allocateNonce();
        LOG_DEBUG("=============== 发送端：发送 NULL 消息验证 =================\n");
        auto nullSendStr = sendKp->encrypt(nullptr, 0, *nonce);
        LOG_DEBUG("加密数据(len:%d): %s", nullSendStr.size(),
                  Crypto::bin2B64(nullSendStr.data(), nullSendStr.size()).c_str());
        auto nullDecryptMsg = receiveKp->decrypt(nullSendStr.data(), nullSendStr.size(), *nonce);
        LOG_DEBUG("解密数据(len:%d): %s", nullDecryptMsg.size(),
                  Crypto::bin2B64(nullDecryptMsg.data(), nullDecryptMsg.size()).c_str());
        EXPECT_EQ(nullDecryptMsg.size(), 0);

        LOG_DEBUG("=============== 发送端：发送消息验证 =================\n");
        nonce = sendKp->allocateNonce();
        auto sendMessage = "test debug message sssssss";
        LOG_DEBUG("sendMessage(len:%d) hex: %s", std::strlen(sendMessage),
                  Crypto::bin2B64(reinterpret_cast<const uint8_t *>(sendMessage), std::strlen(sendMessage)).c_str());

        LOG_DEBUG("加密");
        auto encryptMsg = sendKp->encrypt(reinterpret_cast<const uint8_t *>(sendMessage), std::strlen(sendMessage),
                                          *nonce);
        LOG_DEBUG("加密数据(len:%d): %s", encryptMsg.size(), Crypto::bin2B64(encryptMsg.data(), encryptMsg.size()).c_str());

        LOG_DEBUG("解密");
        auto decryptMsg = receiveKp->decrypt(encryptMsg.data(), encryptMsg.size(), *nonce);
        LOG_DEBUG("解密数据(len:%d): %s", decryptMsg.size(), Crypto::bin2B64(decryptMsg.data(), decryptMsg.size()).c_str());
        LOG_DEBUG("对比");
        auto decryptMessage = std::string(reinterpret_cast<const char *>(decryptMsg.data()), decryptMsg.size());
        EXPECT_EQ(sendMessage, decryptMessage);
    }

    /**
     * 发送一个握手给服务端看看效果
     */
    TEST(Noise_Handshake, clientSendInitiationMessage) {
        MessageInitiation msg;
        try {
            crypto2::NOISESend send{};
            send.init(client_private, server_public);
            send.ephemeral_private_key = ephemeral_private;
            // auto index = crypto_static::createIndex();
            auto index = 0;
            msg = send.encodeHandshakeInitiation(index);
        } catch (const std::exception &e) {
            printf("exception client 加密失败: %s\n", e.what());
            throw e;
        }

        UDPSocket sock;
        // sock.bind(61113);
        sock.initSocket(std::make_shared<uint32_t>(61113), nullptr);
        Endpoint ep = Tools::IP::makeEndpointIpv4("10.3.3.2", 62222);
        sock.write(&msg, sizeof(msg), ep);
        sock.close();
    }
}
