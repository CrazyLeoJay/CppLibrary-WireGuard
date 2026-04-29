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
#include "crypto.h"
#include "entity.h"
#include "messages.h"
#include "keypair.h"

#include "version.h"

namespace WireGuard {
    namespace Noise {
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
            mutable PrivateKey local_public{}; // 本地公钥
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
        class NOISEReceive final : public NOISE {
        public:
            void init(const PrivateKey &local_private) const;
            /**
             * 仅获取协议中的 publicKey
             * @param msg 信息
             */
            PublicKey onlyDecodeHandshakePublicKey(const MessageInitiation &msg) const;

            /**
             * 从头计算握手协议，并且解析验证
             *
             * @param msg
             */
            void decodeCheckHandshakeInitiation(const MessageInitiation &msg) const;


            /**
             * 创建握手响应
             * 握手响应在收到消息时已经验证，这里无需二次验证
             *
             * @param senderIndex 服务解析索引
             * @return 响应信息
             */
            MessageResponse createHandshakeResponse(const uint32_t &senderIndex) const;

            bool canSendData() override { return state == receive_created_handshake_response_msg; }
        };

        /**
         * 发送端
         */
        class NOISESend final : public NOISE {
        private:
            CookieData initHandshakeMac1 = {};
            mutable std::shared_ptr<CookieData> last_received_cookie{}; // 上一次记录的Cookie decryptCookie时会记录

        public:
            void init(const PrivateKey &local_private, const PublicKey &remote_public) const;

            MessageInitiation encodeHandshakeInitiation(uint32_t senderIndex);

            void verifyHandshakeInitiationResponse(const MessageResponse &msg) const;

            bool canSendData() override { return state == send_consume_handshake_response_msg; }

            /**
             * 解密cookie消息到本地
             *
             * @param msg cookie消息
             * @return cookie
             */
            void decryptCookie(const MessageCookie &msg) const;
        };
    } // namespace crypto2
} // namespace WireGuard

#endif // WG_MAIN_NONCE2_H
