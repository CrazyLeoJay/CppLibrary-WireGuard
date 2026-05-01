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

#include "device.h"

#include <algorithm>

#include "WGException.h"
#include "pipwait.h"
#include "tools.h"
#include <cerrno>
#include <cstddef>
#include <utility>
#include <unistd.h>
#include <sys/socket.h>

#include "cookie.h"

namespace WireGuard {
    ContentKey::ContentKey(const PrivateKey &private_key) {
        local_private_key = private_key;
        crypto::generatePublicKey(local_public_key, private_key);
    }

    Device::Device(const DeviceRegisterConfig &config)
        : content_key_(config.client.private_key),
          config(config.client) {
        initPeers(config.peers);
    }

    Device::~Device() {
        try {
            close();
        } catch (const std::exception &e) {
            LOG_ERROR("设备关闭Close方法异常：%{public}s", e.what());
        }
    }

    uint32_t Device::initSocket(const std::function<void(int &)> &onSocketFDChange) {
        LOG_INFO("初始化 socket");
        if (config.listener_port) {
            LOG_INFO("监听端口：%{public}d", *config.listener_port);
        }
        int fd = socket.initSocket(config.listener_port, config.bind_address);
        LOG_INFO("socket init");
        onSocketFDChange(fd);
        this->onSocketFDChange = onSocketFDChange;
        LOG_INFO("初始化 socket 完成");
        return fd;
    }

    void Device::start(const uint32_t &tunFd) {
        LOG_INFO("device start");
        this->tunFd = tunFd;
        isRunning.store(true, std::memory_order_release);
        isLoopTunRunning.store(true, std::memory_order_release);
        // 启动心跳线程
        _loopSocketHeartbeatTask = std::thread(&Device::loopSocketHeartbeatTask, this);
        // 轮询读取远端 Socket 数据包
        _loopSocketTask = std::thread(&Device::loopReceiveForSocket, this);
        // 轮询读取本地 VPN 虚拟网卡数据包
        _loopTunFdTask = std::thread(&Device::loopReceiveForTun, this);
        LOG_INFO("device start end");
    }

    void Device::close() {
        LOG_INFO("device close 通知停止所有任务");
        isRunning.store(false, std::memory_order_release);
        pipWaitForHeartbeatTask.notify(); // 通知心跳任务停止阻塞
        socket.close(); // 关闭 socket

        // 等待网卡读取线程结束
        if (_loopTunFdTask.joinable()) {
            _loopTunFdTask.join();
        }
        LOG_INFO("Tun read task stoped");

        // 等待Socket读取线程结束
        if (_loopSocketTask.joinable()) {
            _loopSocketTask.join();
        }
        LOG_INFO("socket read task stoped");

        // 等待轮询任务结束
        if (_loopSocketHeartbeatTask.joinable()) {
            _loopSocketHeartbeatTask.join();
        }
        LOG_INFO("hearthbeat read task stoped");
        // 清理网卡配置
        this->tunFd.store(0, std::memory_order_release);
        LOG_INFO("配置和运行标记清除");
        std::lock_guard<std::mutex> lockIndex(_indexMutex);
        _keypairIndexPeers.clear();
        _receiverIndexPeers.clear();
        LOG_INFO("device 索引清除");
        // 清理所有 Peer
        std::lock_guard<std::mutex> guard(_peerMutex);
        _peers.clear();
        LOG_INFO("device 清除Peers");
        LOG_INFO("关闭设备通信并清除数据");
    }

    void Device::initPeers(const std::vector<PeerConfig> &peers) {
        // 每次初始化先关闭清理资源
        //        close();
        std::lock_guard<std::mutex> lock(_peerMutex);
        this->_peers.clear();
        LOG_INFO("peers clear");
        // 添加新配置
        _peers.reserve(peers.size());
        for (const PeerConfig &pc: peers) {
            auto peer = std::make_shared<Peer>(content_key_, pc);
            peer->init();
            // 配置Ip树查询
            this->allowedIps.addPeer(peer);
            _peers[pc.public_key] = peer;
        }
        //        allowedIps.debugPrint();
        LOG_INFO("peers push finish : %{public}zu", peers.size());
    }

    void Device::loopSocketHeartbeatTask() {
        LOG_INFO("开启心跳任务");
        std::vector<std::shared_ptr<Peer> > peers{};
        while (isRunning.load(std::memory_order_acquire)) {
            // 睡眠等待任务由 Tools::PipeWait 实现，
            // 当需要结束时，会由通道唤醒，所以这里正常25s睡眠即可
            std::chrono::milliseconds nextSleepDuration = std::chrono::seconds(25);
            {
                std::lock_guard<std::mutex> lock(_peerMutex);
                peers.clear();
                if (_peers.size() > peers.capacity()) {
                    peers.reserve(_peers.size());
                }
                for (const auto &it: _peers) {
                    if (it.second) {
                        peers.push_back(it.second);
                    }
                }
            }

            for (const auto &peer: peers) {
                if (!peer) {
                    continue;
                }

                // 判断发送心跳包还需要等待的时间
                auto waitTime = peer->heartbeatPacketSendWaitTime();
                if (waitTime == std::chrono::milliseconds(0)) {
                    if (!peer->isCanSendData(iAmInitiator)) {
                        // 如果还没准备好，但触发了心跳，那就发送握手，而不是心跳包
                        LOG_DEBUG(
                            "发现有Peer还未准备好，则发起握手 当前 iAmInitiator=%{public}s",
                            iAmInitiator ? "发起者" : "接收者"
                        );
                        try {
                            sendInitiation(peer);
                            peer->updateHeartbeatPacketSendTime();
                        } catch (const std::exception &e) {
                            // 一般是创建的太频繁，这里等2秒再循环 或者直接调用握手
                            nextSleepDuration = std::chrono::seconds(2);
                        }
                    } else {
                        try {
                            encryptPacketAndSendSocket(peer, nullptr, 0);
                            peer->updateHeartbeatPacketSendTime();
                        } catch (const std::exception &e) {
                            // 如果发送发生异常，就设置一个小的等待时间，再次尝试
                            nextSleepDuration = std::chrono::seconds(1);
                        }
                    }
                } else {
                    nextSleepDuration = std::min(nextSleepDuration, waitTime);
                }
            }
            // 根据最短时间设置睡眠时间，否则就睡默认值s数
            // 即使在退出心跳任务时，这个任务不需要等待结束，在后台默默退出即可
            pipWaitForHeartbeatTask.wait(nextSleepDuration);
            LOG_DEBUG("pip wait callback");
        }
        LOG_INFO("心跳任务结束");
    }

    void Device::loopReceiveForSocket() {
        LOG_INFO("开始Socket读取任务");

        std::vector<char> buffer(3000); // 一般udp的包也就 1450 左右
        Endpoint endpoint;
        isSocketRunning = true;
        while (isRunning.load(std::memory_order_acquire) && isSocketRunning.load(std::memory_order_acquire) &&
               socket.fd() != -1) {
            try {
                const ssize_t received = socket.read(buffer.data(), buffer.size(), endpoint);
                if (received < 0) {
                    if (!isRunning.load(std::memory_order_acquire) ||
                        !isSocketRunning.load(std::memory_order_acquire)) {
                        break;
                    }
                    if (errno == EAGAIN || errno == EWOULDBLOCK) {
                        // 没有数据，休眠后继续循环
                        // 表示当前没有数据可读（通常发生在非阻塞 socket 上）。
                        std::this_thread::sleep_for(std::chrono::milliseconds(1));
                        continue;
                    }
                    // 关闭屏幕时，也会停止，应该要重新链接
                    // 异常，直接跳出
                    //                    LOG_WARN("socket 读取异常，跳出。");
                    // 需要重新建立socket
                    // 由于socket创建fd后需要系统标记保护，需要外部触发。或者创建回调
                    //                    break; // 套接字错误
                    auto fd = socket.createSocket(); // 重新创建套接字然后去通信，需要重新握手 并且需要通知客户端
                    LOG_DEBUG("更换Socket fd=%{public}d", fd);
                    socketNewFd(fd); // 通知fd更换
                    continue;
                }
                LOG_DEBUG(
                    "数据流:Socket接收目标 %{public}s len: %{public}zd", endpoint.address.toIpStr().c_str(), received
                );
                // 将读取的数据写出
                processSocketPacket(buffer.data(), static_cast<size_t>(received), endpoint);
            } catch (const WGException &e) {
                if (e.type == WGErrType::SOCKET_CLOSE_SING) {
                    // 正常断开，无需打印日志
                    break;
                }
                LOG_ERROR("socket 异常中断： %{public}s", e.what());
                break;
            } catch (const std::exception &e) {
                LOG_ERROR("socket 异常中断： %{public}s", e.what());
                break;
            }
        }
        isSocketRunning = false;
        LOG_INFO("Socket读取任务(%{public}d) 读取停止", socket.fd());
    }

    void Device::processSocketPacket(const char *data, size_t len, const Endpoint &endpoint) {
        if (len < sizeof(MessageHeader)) {
            return;
        }
        auto *header = reinterpret_cast<const MessageHeader *>(data);
        auto type = static_cast<MessageType>(header->type);
        try {
            socketListenerMessage(type, data, len, endpoint);
        } catch (const std::exception &e) {
            LOG_WARN("socket 消息异常(%{public}u)：%{public}s", static_cast<uint32_t>(type), e.what());
        }
    }

    void WireGuard::Device::socketNewFd(int _socketFd) {
        this->onSocketFDChange(_socketFd);
        // 通知去握手
    }

    void Device::loopReceiveForTun() {
        LOG_INFO("开始VPN Tun读取任务");
        std::vector<uint8_t> buffer(TUN_READ_BUFFER_SIZE);
        ssize_t readLen;
        while (isRunning.load(std::memory_order_acquire) && isLoopTunRunning.load(std::memory_order_acquire) &&
               tunFd.load(std::memory_order_acquire) > 0) {
            try {
                // 读取网卡数据
                readLen = readFromLocal(buffer.data(), TUN_READ_BUFFER_SIZE);
                if (readLen <= 0) {
                    if (errno != EAGAIN) {
                        if (tunFd < 0 || !isLoopTunRunning.load(std::memory_order_acquire)) {
                            break;
                        }
                    }
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    continue;
                }
                //                LOG_WARN("读取到数据：%{public}zd", readLen);
                consumeTunData(buffer.data(), readLen);
            } catch (const std::exception &e) {
                LOG_WARN("读取异常：%{public}s", e.what());
                continue;
            }
        }
        LOG_INFO("Tun任务(%{public}d) 读取停止", tunFd.load());
        isLoopTunRunning = false;
    }

    void Device::consumeTunData(const uint8_t *data, const ssize_t &readLen) {
        // 解析读取的数据头
        Endpoint endpoint;
        try {
            auto ph = Tools::readPacketEndpoint(data, readLen);
            endpoint = ph.dst; // 设置目标
            LOG_DEBUG("Tun接收 : %{public}s len: %{public}zd", ph.toIpLog().c_str(), readLen);
        } catch (const std::exception &e) {
            LOG_WARN("获取包目标地址失败 %{public}s", e.what());
            return;
        }
        // 判断请求的端点是否存在，
        // 如果存在就获取相应的 peer
        std::shared_ptr<Peer> peer;
        try {
            peer = allowedIps.findPeer(endpoint.address);
            if (!peer) {
                LOG_WARN(
                    "ip:(%{public}s/%{public}s) 没有匹配到合适的Peer", endpoint.address.toIpStr().c_str(),
                    endpoint.address.toIpHex().c_str()
                );
                return;
            }
        } catch (const std::exception &e) {
            LOG_WARN("获取 peer 异常：%{public}s", e.what());
            return;
        }

        if (!peer->isCanSendData(iAmInitiator)) {
            // 当前不可发送，则表示握手还未成功，加入消息队列 并去请求握手
            try {
                LOG_WARN("peer还未准备好，保存请求，并触发握手协议");
                cacheSendPacketAndPeerInit(peer, std::vector<uint8_t>(*data, readLen));
            } catch (const std::exception &e2) {
                //                LOG_ERROR("发起握手失败 msg: %{public}s", e2.what());
            }
            return;
        }

        try {
            // 这里会去检查是否有密钥，并且判断密钥是否可用
            peer->needsReKey();
        } catch (const std::exception &e) {
            LOG_WARN("加密前异常: %{public}s", e.what());
            try {
                LOG_WARN("发起握手");
                cacheSendPacketAndPeerInit(peer, std::vector<uint8_t>(*data, readLen));
            } catch (const std::exception &e2) {
                LOG_ERROR("发起握手失败 msg: %{public}s", e2.what());
            }
            return;
        }

        try {
            // 发送数据包到peer
            // 加密数据，并且通过 socket 发送
            encryptPacketAndSendSocket(peer, data, readLen);
        } catch (const std::exception &e) {
            LOG_WARN("加密数据包异常，msg：%{public}s", e.what());
            try {
                LOG_WARN("重新握手！");
                cacheSendPacketAndPeerInit(peer, std::vector<uint8_t>(*data, readLen));
            } catch (const std::exception &e) {
                LOG_WARN("发起握手失败 e=%{public}s", e.what());
            }
            return;
        }
    }

    ssize_t Device::readFromLocal(uint8_t *buf, size_t len) const { return read(tunFd, buf, len); }

    void Device::socketListenerMessage(
        const MessageType &type, const char *data, const size_t &len, const Endpoint &endpoint
    ) {
        switch (type) {
            case MessageType::HANDSHAKE_INITIATION:
                handleInitiation(data, len, endpoint);
                break;
            case MessageType::HANDSHAKE_RESPONSE:
                handleResponse(data, len, endpoint);
                break;
            case MessageType::HANDSHAKE_COOKIE:
                handleCookie(data, len, endpoint);
                break;
            case MessageType::DATA:
                handleData(data, len, endpoint);
                break;
            case MessageType::INVALID:
            default:
                LOG_WARN("接收到异常数据包类型：type=%{public}hhu", static_cast<uint8_t>(type));
                break;
        }
    }

    void Device::handleInitiation(const char *data, const size_t &len, const Endpoint &endpoint) {
        if (len < sizeof(MessageInitiation)) {
            return;
        }
        std::lock_guard<std::mutex> guard(_peerMutex);
        // 如果接收到握手请求，则表示当前设备为接收端
        // 如果发送握手协议，则需要设置为true
        iAmInitiator = false;
        auto *msg = reinterpret_cast<const MessageInitiation *>(data);

        // 特殊情况，当CPU使用率比较高时，接收端可以选择开启cookie挑战
        // 比如：疑似Dos攻击，需要强制执行判断
        if (enableCookie) {
            // 检查是否发起cookie或者检查mac2是否合规
            if (!checkCookieForMac2(endpoint, *msg)) {
                // 如果挑战失败，或者需要发起挑战，直接返回，不做任何处理
                return;
            }
        }

        // 查找对应的 Peer（需要解密静态公钥）
        const PublicKey pk = crypto::getPublicKey(*msg, config.private_key);
        if (_peers.find(pk) == _peers.end()) {
            Logs::print_space([&]() {
                LOG_WARN("地址（%{public}s）未找到注册设备", WireGuard::Tools::printStr(endpoint.address).c_str());
            });
            return;
        }
        const auto currentPeer = _peers[pk];
        try {
            currentPeer->handleHandshakeInitiation(*msg);
        } catch (const std::exception &e) {
            Logs::print_space([&]() {
                LOG_WARN(
                    "地址（%{public}s）握手失败: %{public}s",
                    WireGuard::Tools::printStr(endpoint.address).c_str(),
                    e.what()
                );
            });
            return;
        }

        // 记录客户端索引
        _receiverIndexPeers[msg->senderIndex] = currentPeer;
        // 创建新索引
        const auto newIndex = createNewIndex(currentPeer);

        // 创建 Response
        MessageResponse response = currentPeer->createHandshakeResponse(newIndex);
        if (enableCookie) {
            cookieChecker.messageAddMac2(endpoint, response);
        }
        // 开始会话
        const auto keypair = currentPeer->beginSession(false);
        if (keypair) {
            _keypairIndexPeers[newIndex] = keypair;
            currentPeer->setCurrentKeypair(keypair);
            // 发送 Response
            const auto wl = socket.write(&response, sizeof(response), endpoint);
            if (wl < 0) {
                throw WGException("发送失败");
            }
            // 发送等待的数据包
            // 服务端在被攻击或者解密失败时，会等待客户端重新握手，或者cookie访问后，继续服务，所以也是有积压的数据的。
            sendStagedPackets(currentPeer);
            Logs::print_space([&]() {
                LOG_INFO("发送握手响应返回发起端，并释放缓存数据包");
            });
        } else {
            Logs::print_space([&]() {
                LOG_WARN("握手响应失败：服务（%{public}s）：KeyPair 生成异常", Tools::printStr(endpoint.address).c_str());
            });
        }
    }

    void Device::handleResponse(const char *data, size_t len, const Endpoint &endpoint) {
        if (len < sizeof(MessageResponse)) {
            return;
        }

        LOG_INFO("握手响应");
        auto *msg = reinterpret_cast<const MessageResponse *>(data);
        // todo 需要判断是否需要cookie验证

        // 根据 receiver_index 查找发起方 Peer
        if (_receiverIndexPeers.find(msg->receiverIndex) == _receiverIndexPeers.end()) {
            throw WGException("未找到远端Peer");
        }
        // 获取到当前 peer
        const auto currentPeer = _receiverIndexPeers[msg->receiverIndex];

        // 更新端点 (PS:其实我觉得没啥更新必要，按道理，返回的ip地址和端口，应该和请求的一致)
        currentPeer->updateEndpoint(endpoint);

        try {
            currentPeer->verifyHandshakeInitiationResponse(*msg);
            LOG_INFO("握手验证： 验证通过 下一步，创建密钥");
        } catch (const std::exception &e) {
            LOG_WARN("握手异常： %{public}s", e.what());
            return;
        }

        // 开始会话
        const auto keypair = currentPeer->beginSession(true);
        if (keypair) {
            // keypair 建立索引
            _keypairIndexPeers[msg->receiverIndex] = keypair;
            // 发送等待的数据包
            sendStagedPackets(currentPeer);
            LOG_INFO("握手成功 并存储密钥 remoteIndex=%{public}s", crypto::bin2Hex(msg->senderIndex).c_str());
            // 发送心跳包
            encryptPacketAndSendSocket(currentPeer, nullptr, 0);
        } else {
            LOG_WARN("握手异常：keypair 生成失败");
        }
    }

    void Device::handleCookie(const char *data, const size_t len, const Endpoint &endpoint) {
        // 发起端，接收cookie消息，解析cookie
        if (len < sizeof(MessageCookie)) {
            return;
        }
        auto *msg = reinterpret_cast<const MessageCookie *>(data);

        // 根据 receiver_index 查找发起方 Peer
        if (_receiverIndexPeers.find(msg->receiverIndex) == _receiverIndexPeers.end()) {
            throw WGException("未找到远端Peer");
        }
        // 获取到当前 peer
        const std::shared_ptr<Peer> currentPeer = _receiverIndexPeers[msg->receiverIndex];

        // 处理cookie消息，并且保存cookie到peer中，再次发送握手时，会携带cookie加密后的mac2
        // 由于解密时用到了握手时的mac1，所以只有发送了握手消息才能获取到正确cookie
        currentPeer->handleCookie(*msg);

        // 然后重新发送握手请求
        // 不需要检查间隔，直接再次握手
        sendInitiation(currentPeer, true);
    }

    void Device::handleData(const char *data, const size_t &len, const Endpoint &endpoint) {
        if (len < sizeof(MessageData)) {
            return;
        }
        LOG_DEBUG("接收到数据");
        const size_t cipherLen = len - sizeof(MessageData);
        //        if (cipherLen < 16 || cipherLen % 16 != 0) {
        //            throw WGException("接收到的加密消息长度不是16倍数len=%d", cipherLen);
        //        }
        auto *msg = reinterpret_cast<const MessageData *>(data);
        // 简化处理：遍历所有 Peer
        if (_receiverIndexPeers.find(msg->keyIndex) == _receiverIndexPeers.end()) {
            throw WGException("未找到远端Peer");
        }
        if (_keypairIndexPeers.find(msg->keyIndex) == _keypairIndexPeers.end()) {
            throw WGException("未找到远端KeyPair index=0x%s", crypto::bin2Hex(msg->keyIndex).c_str());
        }
        //        // 获取到当前 peer
        const auto currentPeer = _receiverIndexPeers[msg->keyIndex];
        //        // 解密数据流
        //        auto result = currentPeer->decryptPacket(msg, len);
        //        // 获取密钥对
        const auto kp = _keypairIndexPeers[msg->keyIndex];
        if (kp.expired()) {
            sendInitiation(currentPeer); // 如果当前是接收端，这里便会转变角色变成发送端
            throw WGException("keyPair 不存在，需要重新握手");
        }
        // 解密数据
        const std::vector<uint8_t> result = kp.lock()->decrypt(msg, len);
        if (result.empty()) {
            LOG_DEBUG("接收到心跳包");
            return;
        }
        // 记录接收的数据
        currentPeer->addRxBytes(cipherLen);
        // 将解密的数据写入网卡进行返回
        sendToLocal(result.data(), result.size());
    }

    void Device::sendInitiation(const std::shared_ptr<Peer> &peer, const bool &force) {
        // 先设置当前设备为发起端
        // 如果发送握手协议，则需要设置为true
        iAmInitiator = true;

        // 配置 peer 索引
        const auto index = createNewIndex(peer);
        const auto msg = peer->createHandshakeInitiation(index, force);
        const auto endpoint = peer->getEndpoint();

        LOG_INFO(
            "发送握手请求到：%{public}s:%{public}d  %{public}s", endpoint.address.toIpStr().c_str(), endpoint.port,
            endpoint.address.toIpHex().c_str()
        );
        const auto result = socket.write(&msg, sizeof(msg), endpoint);
        if (result < 0) {
            throw WGException("握手信息，发送失败！");
        }
    }

    bool Device::checkCookieForMac2(const Endpoint &endpoint, const MessageInitiation &msg) {
        // 处理 cookie 挑战
        // 判断 该站点的cookie是否生成过
        const auto cookie = cookieChecker.getCookieNoMake(endpoint);
        if (!cookie) {
            // 如果cookie还未生成，就发送cookie到端
            sendCookieReply(msg, endpoint);
            return false;
        }
        // 如果cookie为空、或者cookie失效，不验证mac2，直接cookie挑战。
        if (!cookieChecker.verifySecretValid()) {
            sendCookieReply(msg, endpoint);
            return false;
        }
        // 验证mac2
        if (cookie::isEmpty(msg.mac2)) {
            // mac2 没有，需要发送到客户端需要 cookie 挑战
            sendCookieReply(msg, endpoint);
            return false;
        }

        // 如果mac2 不为空，则验证mac2是否正确，抛出异常则直接返回false表示不合格
        try {
            CookieChecker::verifyMac2(msg, *cookie);
        } catch (const std::exception &e) {
            return false;
        }
        return true;
    }

    void Device::sendCookieReply(const MessageInitiation &msg, const Endpoint &endpoint) {
        // 接收端行为，使用本地公钥
        const auto cookieMsg = cookieChecker.createCookieReply(msg, endpoint, content_key_.local_public_key);
        const auto let = socket.write(&cookieMsg, sizeof(cookieMsg), endpoint);
        if (let < 0) {
            throw WGException("发送cookie挑战失败");
        }
    }

    void Device::encryptPacketAndSendSocket(const std::shared_ptr<Peer> &peer, const uint8_t *data,
                                            const size_t len) const {
        std::lock_guard<std::mutex> lock(_indexMutex);
        // 发送消息到 Peer 使用Peer的ip和端口，接收端会解密包，然后按照实际请求发出
        const Endpoint &endpoint = peer->getEndpoint();
        LOG_DEBUG(
            "send to socket 发送 : %{public}s:%{public}d len: %{public}zd", endpoint.address.toIpStr().c_str(),
            endpoint.port, len
        );
        // 发送数据包到peer
        std::vector<uint8_t> message = peer->encryptPacketToMessageData(data, len);

        try {
            LOG_DEBUG(
                "数据流:写出到Socket(ip:%{public}s) size=%{public}zu", endpoint.address.toIpStr().c_str(),
                message.size()
            );
            // 加密数据，并且通过 socket 发送
            socket.write(message.data(), message.size(), endpoint);
        } catch (const std::exception &e) {
            // 由于发送失败是服务自己原因，这里不去触发重新握手
            LOG_WARN("socket 发送失败：%{public}s", e.what());
        }
    }


    void Device::sendStagedPackets(const std::shared_ptr<Peer> &peer) const {
        try {
            // 消费所有 待发送的数据包
            auto packets = peer->consumeStagedPackets();
            while (!packets.empty()) {
                auto &packet = packets.front();
                // 将数据加密并生成 MessageData
                auto msg = peer->encryptPacketToMessageData(packet.data(), packet.size());
                // 写到远端
                socket.write(msg.data(), msg.size(), peer->getEndpoint());

                packets.pop();
            }
        } catch (const std::exception &e) {
            // 这里就不重复握手了，如果异常表示之前握手逻辑还是有问题
            LOG_ERROR("发送缓存数据异常，msg：%{public}s", e.what());
        }
    }


    void Device::cacheSendPacketAndPeerInit(const std::shared_ptr<Peer> &peer, const std::vector<uint8_t> &data) {
        // 保存数据到队列
        peer->queuePacket(data);
        // 子端其他处理
        if (iAmInitiator) {
            sendInitiation(peer);
        }
    }

    uint32_t Device::createNewIndex(std::shared_ptr<Peer> peer) {
        std::lock_guard<std::mutex> guard(_indexMutex);
        // 随机数分布（均匀的 32 位整数）
        std::uniform_int_distribution<uint32_t> dist;

        uint32_t index;
        int attempts = 0;
        constexpr int MAX_ATTEMPTS = 100;
        // 尝试找到一个未使用的索引
        do {
            index = dist(_rng);
            // 确保索引不为 0（保留值）
            if (index == 0)
                continue;
            // 检查是否已存在
            if (_receiverIndexPeers.find(index) == _receiverIndexPeers.end()) {
                break;
            }
            attempts++;
        } while (attempts < MAX_ATTEMPTS);

        if (attempts >= MAX_ATTEMPTS) {
            // 理论上几乎不可能发生（2^32 的空间）
            throw std::runtime_error("Failed to generate unique index");
        }
        _receiverIndexPeers[index] = std::move(peer);
        return index;
    }

    void Device::removeIndex(const uint32_t index) {
        std::lock_guard<std::mutex> guard(_indexMutex);
        _receiverIndexPeers.erase(index);
        _keypairIndexPeers.erase(index);
    }


    void Device::sendToLocal(const uint8_t *data, const size_t len) const {
        Logs::print_space([&]() { LOG_DEBUG("写入网卡数据 len=%{public}zu", len); });
        write(tunFd, data, len);
    }
}; // namespace WireGuard
