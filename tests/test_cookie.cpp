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
 */

/**
 * Created by Leojay on 2026/4/30.
 *
 * @author leojay`fu
 * @email crazyleojay@163.com
 * @url https://github.com/CrazyLeoJay
 */

#include <arpa/inet.h>

#include "device.h"
#include "messages.h"
#include "test_params.h"
#include "crypto/nonce.h"
#include "gtest/gtest.h"

namespace WireGuard {
    namespace {
        DeviceRegisterConfig make(PrivateKey private_key, PublicKey peer_public_key) {
            DeviceRegisterConfig config;
            config.client.device_name = "test";
            config.client.private_key = private_key;
            config.client.listener_port = std::make_shared<uint32_t>(2000);

            PeerConfig peer{};
            peer.public_key = peer_public_key;
            config.peers.push_back(peer);
            return config;
        }
    }

    TEST(COOKIE, test_cookie) {
        CookieChecker
                receiveCookieChecker{ContentKey{server_private}},
                sendCookieChecker{ContentKey{client_private}};

        Endpoint sendEndpoint{};
        sendEndpoint.address.family = IPAddress::IPv4;
        sendEndpoint.address.ip.ipv4 = 10000;
        sendEndpoint.port = 5000;

        const auto index = 0;

        // 发送端
        Noise::NOISESend send{};
        send.init(client_private, server_public);
        send.ephemeral_private_key = ephemeral_private;

        // 接收端
        Noise::NOISEReceive receive;
        receive.init(server_private);


        LOG_DEBUG("%s： %d","数值测试", 12);
        LOG_DEBUG("=============== 发送端：第一次握手！ =================\n");
        MessageInitiation msg;
        try {
            msg = send.encodeHandshakeInitiation(index);
            LOG_DEBUG("第一次握手:\nmac1:%s\nmac2:%s",
                      crypto::bin2B64(msg.mac1, COOKIE_LEN).c_str(),
                      crypto::bin2B64(msg.mac2, COOKIE_LEN).c_str()
            );
        } catch (const std::exception &e) {
            printf("exception client 加密失败: %s\n", e.what());
            throw e;
        }

        LOG_DEBUG("=============== 接收端：计算Cookie 消息 =================\n");
        MessageCookie cookieReply;
        CookieData cookie;
        try {
            // 接收端：生成cookie挑戰參數
            cookieReply = receiveCookieChecker.createCookieReply(msg, sendEndpoint, server_public);
            cookie = receiveCookieChecker.getCookie(sendEndpoint);
            LOG_DEBUG("生成Cookie：%s", crypto::bin2B64(cookie.data(), cookie.size()).c_str());
        } catch (const std::exception &e) {
            LOG_DEBUG("生成cookie异常：%s", e.what());
            throw e;
        }

        LOG_DEBUG("=============== 发送端：获取Cookie并且再次发送握手 =================\n");
        // 发送端：解析cookie
        send.decryptCookie(cookieReply);
        // 发送端：再次发送握手协议
        LOG_DEBUG("=============== 发送端：第二次握手协议 =================\n");
        try {
            msg = send.encodeHandshakeInitiation(index);
            LOG_DEBUG("第二次握手:\nmac1:%s\nmac2:%s",
                      crypto::bin2B64(msg.mac1, COOKIE_LEN).c_str(),
                      crypto::bin2B64(msg.mac2, COOKIE_LEN).c_str()
            );
        } catch (const std::exception &e) {
            printf("exception client 加密失败: %s\n", e.what());
            throw e;
        }

        // 接收端：解析握手协议
        LOG_DEBUG("=============== 接收端：验证mac2 =================\n");
        CookieChecker::verifyMac2(msg, cookie);
        LOG_DEBUG("=============== 接收端：解析握手协议 =================\n");

        try {
            receive.decodeCheckHandshakeInitiation(msg);
        } catch (const std::exception &e) {
            printf("exception server 解密失败: %s\n", e.what());
            throw e;
        }
        auto pub = receive.remote_public;
        auto str = crypto::bin32Array2Base64(pub);
        printf("client public_key :%s\n", str.c_str());
        EXPECT_EQ(pub, client_public);

        LOG_DEBUG("=============== 接收端：生成响应参数 =================\n");
        const auto receiveIndex = crypto::createIndex();
        MessageResponse respMsg;
        try {
            respMsg = receive.createHandshakeResponse(receiveIndex);
            receiveCookieChecker.messageAddMac2(sendEndpoint, respMsg);

            LOG_DEBUG("握手Response:\nmac1:%s\nmac2:%s",
                  crypto::bin2B64(respMsg.mac1, COOKIE_LEN).c_str(),
                  crypto::bin2B64(respMsg.mac2, COOKIE_LEN).c_str()
        );
        } catch (const std::exception &e) {
            printf("exception server 创建握手响应: %s\n", e.what());
            throw e;
        }
        LOG_DEBUG("resp msg mac2: %s", crypto::bin2B64(respMsg.mac2, COOKIE_LEN).c_str());

        LOG_DEBUG("=============== 发送端：解析响应 =================\n");
        // 解析握手响应
        try {
            send.verifyHandshakeInitiationResponse(respMsg);
        } catch (const std::exception &e) {
            printf("exception client 解密握手响应异常 : %s\n", e.what());
            throw e;
        }

        LOG_DEBUG("=============== 构建密钥 =================\n");
        auto sendKp = send.makeKeyPair(true);
        auto receiveKp = receive.makeKeyPair(false);
        auto nonce = sendKp->allocateNonce();

        LOG_DEBUG("=============== 发送端：发送 NULL 消息验证 =================\n");
        auto nullSendStr = sendKp->encrypt(nullptr, 0, *nonce);
        LOG_DEBUG("加密数据(len:%d): %s", nullSendStr.size(),
                  crypto::bin2B64(nullSendStr.data(), nullSendStr.size()).c_str());
        auto nullDecryptMsg = receiveKp->decrypt(nullSendStr.data(), nullSendStr.size(), *nonce);
        LOG_DEBUG("解密数据(len:%d): %s", nullDecryptMsg.size(),
                  crypto::bin2B64(nullDecryptMsg.data(), nullDecryptMsg.size()).c_str());
        EXPECT_EQ(nullDecryptMsg.size(), 0);

        LOG_DEBUG("=============== 发送端：发送消息验证 =================\n");
        nonce = sendKp->allocateNonce();
        auto sendMessage = "test debug message sssssss";
        LOG_DEBUG("sendMessage(len:%d) hex: %s", std::strlen(sendMessage),
                  crypto::bin2B64(reinterpret_cast<const uint8_t *>(sendMessage), std::strlen(sendMessage)).c_str());

        LOG_DEBUG("加密");
        auto encryptMsg = sendKp->encrypt(reinterpret_cast<const uint8_t *>(sendMessage), std::strlen(sendMessage),
                                          *nonce);
        LOG_DEBUG("加密数据(len:%d): %s", encryptMsg.size(), crypto::bin2B64(encryptMsg.data(), encryptMsg.size()).c_str());

        LOG_DEBUG("解密");
        auto decryptMsg = receiveKp->decrypt(encryptMsg.data(), encryptMsg.size(), *nonce);
        LOG_DEBUG("解密数据(len:%d): %s", decryptMsg.size(), crypto::bin2B64(decryptMsg.data(), decryptMsg.size()).c_str());
        LOG_DEBUG("对比");
        auto decryptMessage = std::string(reinterpret_cast<const char *>(decryptMsg.data()), decryptMsg.size());
        EXPECT_EQ(sendMessage, decryptMessage);
    }
}
