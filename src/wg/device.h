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
// Created on 2026/3/29.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef WIREGUARD_DEVICE_H
#define WIREGUARD_DEVICE_H
#include "allowedips.h"
#include "entity.h"
#include "pipwait.h"
#include "udp_socket.h"
#include <cstdint>
#include <random>
#include <thread>
#include <unordered_map>

#include "version.h"

namespace WireGuard {
    /**
     * 由于Wireguard的设计是端对端，所以无论是服务端还是客户端，都有发起握手的权力，
     * 那么，实际上，我需要处理两种情况，需要根据实际情况判断当前端是 发送端 还是 接收端
     */
    class Device {
    public:
        /**
         * @param config 设备配置
         * @param iAmInitiator 判断是否为发起者
         * @return
         */
        Device(const DeviceRegisterConfig &config);

        virtual ~Device();

    protected: // 确定参数
        bool iAmInitiator{true}; // 是否为发起者。默认是，会率先主动发起握手

        const DeviceConfig &config{};
        UDPSocket socket{};
        AllowedIPs allowedIps{};

        // ============ Peer 管理 ===============
        mutable std::mutex _peerMutex{};
        std::unordered_map<PublicKey, std::shared_ptr<Peer>, Key32Hash> _peers{};

        // 会话索引
        mutable std::mutex _indexMutex{};
        std::mt19937_64 _rng{std::random_device{}()};

        std::unordered_map<uint32_t, std::shared_ptr<Peer> > _receiverIndexPeers{};
        std::unordered_map<uint32_t, std::weak_ptr<KeyPair> > _keypairIndexPeers{};

        // 用于判断当前设备是否运行，所有任务都要受到这个参数控制
        mutable std::atomic<bool> isRunning{false};
        // ============ Socket 心跳任务 ===============
        std::thread _loopSocketHeartbeatTask{};
        Tools::PipeWait pipWaitForHeartbeatTask{}; // 轮询等待使用阻塞
        // ============ Socket 数据读写任务 ===============
        std::thread _loopSocketTask{};
        mutable std::atomic<bool> isSocketRunning{false}; // 用于判断和控制 socket 线程是否执行
        std::function<void(int &)> onSocketFDChange{}; // 当socket发生变化时调用
        // =============== 虚拟VPN网卡读取 ===============
        mutable std::atomic<uint32_t> tunFd{0};
        std::thread _loopTunFdTask{};
        mutable std::atomic<bool> isLoopTunRunning{false}; // 用于判断和控制 tun 是否在读取中
        // =============== 本地代理Proxy（未开发） ===============


    public: // 对外操作方法
        /**
         * 创建Socket服务，并且绑定本地端口，返回socket套接字
         */
        uint32_t initSocket(const std::function<void(int &)> &onSocketFDChange);

        /**
         * 启动轮询任务，读写数据包
         *
         * @param tunFd 网卡套接字，用于读写本地虚拟VPN网卡数据
         */
        virtual void start(const uint32_t &tunFd);


        /**
         * 停止并清除资源，close 后需要重新初始化
         */
        void close();

    private: // 被动操作 初始化、轮询、监听等
        void initPeers(const std::vector<PeerConfig> &peer);

        /**
         * 心跳任务，用于维护udp链接
         */
        void loopSocketHeartbeatTask();

        /**
         * 循环接收数据
         *
         * 通过 errno 值判断链接情况
         * EAGAIN   //  表示没有数据，通道正常
         *
         * ECONNRESET   //  对端强制关闭了连接（如 RST 包）。
         * ETIMEDOUT // 连接超时（如长时间无 ACK 响应）。
         * ENOTCONN  // socket 未连接（可能已被意外关闭）。
         * EBADF     // 表示文件描述符无效（可能已被 close 或损坏）。
         * EPIPE、ECONNABORTED  // EPIPE 或 ECONNABORTED
         * 连接被中止或写入已关闭的管道。处理方式：连接失效，应关闭并视业务逻辑决定是否重建。
         */
        void loopReceiveForSocket();

        /**
         * 处理接收到的包
         *
         * @param data 接收到的数据
         * @param len 数据长度
         * @param endpoint 远端端口
         */
        void processSocketPacket(const char *data, size_t len, const Endpoint &endpoint);

        void socketNewFd(int _socketFd);

        /**
         * 循环接收VPN虚拟网卡数据 并且加密 发送到远端peer
         */
        void loopReceiveForTun();

        /**
         * 处理收到的网卡数据包
         */
        void consumeTunData(const uint8_t *data, const ssize_t &readLen);

        /**
         * 从本地读取数据
         * - tun 本地VPN虚拟网卡套接字
         * - proxy 本地代理（未开发）
         *
         * @param buf
         * @param len
         */
        ssize_t readFromLocal(uint8_t *buf, size_t len) const;

        /**
         * socket 监听到消息后处理
         *
         * 已经监听 throw 不会影响程序运行
         *
         * @param type 消息类型
         * @param data 消息
         * @param len  消息长度
         * @param endpoint socket 来源端点
         */
        void socketListenerMessage(const MessageType &type, const char *data, const size_t &len,
                                   const Endpoint &endpoint);

        /**
         * 接收端：接收到握手请求
         */
        void handleInitiation(const char *data, const size_t &len, const Endpoint &endpoint);

        /**
         * 发送端：收到握手响应
         */
        void handleResponse(const char *data, size_t len, const Endpoint &endpoint);

        /**
         * Cookie处理
         */
        void handleCookie(const char *data, size_t len, const Endpoint &endpoint);

        /**
         * 接收到加密的数据传输 这个无关发送端还是接收端
         */
        void handleData(const char *data, const size_t &len, const Endpoint &endpoint);

    private: // 协议相关主动操作
        void sendInitiation(const std::shared_ptr<Peer> &peer);

        /**
         * 发送Cookie 相应
         * @param peer
         */
        void sendCookieReply(std::shared_ptr<Peer> &peer);

        /**
         * 加密数据包后并发送到对应的Peer
         */
        void encryptPacketAndSendSocket(const std::shared_ptr<Peer> &peer, const uint8_t *data, size_t len);

    private: // 主动操作：发送数据包、发起握手等
        /**
         * 发送 peer 等待的数据包
         */
        void sendStagedPackets(const std::shared_ptr<Peer> &peer);

        /**
         * 缓存要发送的数据，并且让peer重新握手
         * 内部会对数据进行move操作，执行后，数据源不可再用
         */
        void cacheSendPacketAndPeerInit(const std::shared_ptr<Peer> &peer, const std::vector<uint8_t> &data);

        /**
         * 给Peer 创建新的索引并添加
         * @return 索引
         */
        uint32_t createNewIndex(std::shared_ptr<Peer> peer);

        /**
         * 移除索引
         */
        void removeIndex(uint32_t index);

        /**
         * 写数据到本地（网卡或者代理）
         */
        void sendToLocal(const uint8_t *data, size_t len) const;
    };
}; // namespace WireGuard
#endif // WIREGUARD_DEVICE_H