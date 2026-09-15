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
#include <arpa/inet.h>

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
        : content_key_(config.client.private_key), config(config.client) {
        initPeers(config.peers);
    }

    Device::~Device() {
        try {
            LOG_INFO("析构 Device 关闭");
            close();
        } catch (const std::exception &e) {
            LOG_ERROR("设备关闭Close方法异常：%{public}s", e.what());
        }
    }

    uint32_t Device::initSocketStart(const std::function<void(int &)> &onSocketFDChange) {
        LOG_INFO("初始化 socket");
        if (config.listener_port) {
            LOG_INFO("监听端口：%{public}d", *config.listener_port);
        }
        int fd = socket.initSocketStart(config.listener_port, config.bind_address);
        LOG_INFO("socket init config: %{public}d", fd);
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
        // 先置读线程运行标记，再创建线程：避免心跳线程的看门狗在线程尚未起步时误判"读线程已停"
        isSocketRunning.store(true, std::memory_order_release);
        _socketReadTaskExited.store(false, std::memory_order_release);
        // 启动心跳线程
        _loopSocketHeartbeatTask = std::thread(&Device::loopSocketHeartbeatTask, this);
        // 轮询读取远端 Socket 数据包
        _loopSocketTask = std::thread(&Device::loopReceiveForSocket, this);
        // 轮询读取本地 VPN 虚拟网卡数据包
        _loopTunFdTask = std::thread(&Device::loopReceiveForTun, this);
        LOG_INFO("device start end");
    }

    void Device::setStreamLog(const StreamLog::StreamLogPrint &listener) {
        if (!listener) {
            LOG_WARN("setStreamLog: listener 为空可调用对象，保持默认");
            return;
        }
        streamLog = listener;
    }

    void Device::close() {
        LOG_INFO("device close 通知停止所有任务");
        isRunning.store(false, std::memory_order_release);
        isSocketRunning.store(false, std::memory_order_release);
        pipWaitForHeartbeatTask.notify(); // 通知心跳任务停止阻塞
        socket.close(); // 关闭 socket

        // 等待网卡读取线程结束
        if (_loopTunFdTask.joinable()) {
            _loopTunFdTask.join();
        }
        LOG_INFO("Tun read task stoped");

        // 等待Socket读取线程结束
        {
            // 与看门狗重启读线程互斥，避免并发 join/赋值同一个 std::thread
            std::lock_guard<std::mutex> lockSocketTask(_socketTaskMutex);
            if (_loopSocketTask.joinable()) {
                _loopSocketTask.join();
            }
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
        _pendingInitiatorIndexes.clear();
        LOG_INFO("device 索引清除");
        // 清理所有 Peer
        std::lock_guard<std::mutex> guard(_peerMutex);
        _peers.clear();
        LOG_INFO("device 清除Peers");
        LOG_INFO("关闭设备通信并清除数据");
    }

    void Device::sendPacket(const uint8_t *data, const size_t len) const {
        std::lock_guard<std::mutex> lock(_peerMutex);
        for (const auto &pair: _peers) {
            auto peer = pair.second;
            if (peer->isCanSendData()) {
                encryptPacketAndSendSocket(peer, data, len);
            }
        }
    }

    void Device::initPeers(const std::vector<PeerConfig> &peers) {
        // 每次初始化先关闭清理资源
        //        close();
        std::lock_guard<std::mutex> lock(_peerMutex);
        this->_peers.clear();
        LOG_INFO("peers clear");
        // 添加新配置
        _peers.reserve(peers.size());
        size_t index = 0;
        for (const PeerConfig &pc: peers) {
            auto peer = std::make_shared<Peer>(index, content_key_, pc);
            peer->init();
            // 配置Ip树查询
            this->allowedIps.addPeer(peer);
            _peers[pc.public_key] = peer;
            ++index;
        }
        //        allowedIps.debugPrint();
        LOG_INFO("peers push finish : %{public}zu", peers.size());
    }

    void Device::loopSocketHeartbeatTask() {
        LOG_INFO("开启心跳+清理任务");
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

            // ===== 读线程看门狗 =====
            // 读线程一旦退出，历史实现没有任何机制恢复 → 隧道变成"只写不读"
            // （VPN 显示已连接、通知正常，但再也收不到数据）。
            // 这里发现"设备仍在运行但读线程已停"就（必要时重建 socket）重启读线程。
            if (isRunning.load(std::memory_order_acquire) && !isSocketRunning.load(std::memory_order_acquire) &&
                _socketReadTaskExited.load(std::memory_order_acquire)) {
                if (Clock::now() >= _socketTaskRestartNextAllowed) {
                    // 与 close() 互斥，避免并发 join/赋值同一个 std::thread
                    std::lock_guard<std::mutex> lockSocketTask(_socketTaskMutex);
                    // 持锁后二次确认，避免与 close() 竞争
                    if (isRunning.load(std::memory_order_acquire) &&
                        !isSocketRunning.load(std::memory_order_acquire) &&
                        _socketReadTaskExited.load(std::memory_order_acquire)) {
                        LOG_WARN("检测到Socket读取任务已停止，准备重启读取任务");
                        if (!socket.isRunning()) {
                            try {
                                const auto fd = socket.resetSocketFd();
                                LOG_WARN("看门狗重建Socket fd=%{public}d", fd);
                                socketNewFd(fd);
                            } catch (const std::exception &e) {
                                LOG_ERROR("看门狗重建Socket失败：%{public}s", e.what());
                            }
                        }
                        if (_loopSocketTask.joinable()) {
                            _loopSocketTask.join();
                        }
                        if (isRunning.load(std::memory_order_acquire) && socket.isRunning()) {
                            _socketReadTaskExited.store(false, std::memory_order_release);
                            isSocketRunning.store(true, std::memory_order_release);
                            _loopSocketTask = std::thread(&Device::loopReceiveForSocket, this);
                            const uint32_t restarts =
                                    _socketReadRestartCount.fetch_add(1, std::memory_order_acq_rel) + 1;
                            LOG_WARN("Socket读取任务已重启，累计=第%{public}d次", static_cast<int>(restarts));
                            // 连续多次重启说明故障未消除：拉长退避窗口，避免忙循环
                            const auto backoff = restarts >= 3
                                                     ? std::chrono::seconds(30)
                                                     : std::chrono::seconds(3);
                            _socketTaskRestartNextAllowed = Clock::now() + backoff;
                        } else {
                            _socketTaskRestartNextAllowed = Clock::now() + std::chrono::seconds(3);
                        }
                    }
                }
            } else if (isSocketRunning.load(std::memory_order_acquire)) {
                // 读线程存活：清零连续重启计数，恢复正常退避窗口
                _socketReadRestartCount.store(0, std::memory_order_release);
                _socketTaskRestartNextAllowed = Clock::now();
            }

            for (const auto &peer: peers) {
                if (!peer) {
                    continue;
                }

                if (!peer->isCanSendData()) {
                    // 如果还没准备好，但触发了心跳，那就发送握手，而不是心跳包
                    LOG_DEBUG(
                        "发现有Peer还未准备好，则发起握手 当前 iAmInitiator=%{public}s",
                        peer->getIAmInitiator() ? "发起者" : "接收者"
                    );
                    try {
                        sendInitiation(peer);
                        peer->updateHeartbeatPacketSendTime();
                    } catch (const std::exception &e) {
                        // 一般是创建的太频繁，这里等2秒再循环 或者直接调用握手
                        LOG_WARN(
                            "发送握手初始化失败 peerIndex=%{public}zu err=%{public}s，2秒后重试", peer->getIndex(),
                            e.what()
                        );
                    }
                    nextSleepDuration = std::chrono::seconds(2);
                    continue;
                }

                // 判断发送心跳包还需要等待的时间
                auto waitTime = peer->heartbeatPacketSendWaitTime();

                if (waitTime == std::chrono::milliseconds(0)) {
                    if (peer->canSendHeartbeatPacket()) {
                        // 发送心跳包需要判断段是否需要发送，如果间隔时间为0，则只需要判断握手即可
                        try {
                            // 心跳也必须先检查密钥是否可用/过期（与数据路径一致）：
                            // 否则息屏/doze 唤醒后仍会用过期密钥发心跳，服务器静默丢弃，
                            // 隧道进入"一直发但收不到"的僵尸状态，只能等真实数据包才触发重握手
                            // （用户表现为"回到前台要等一会儿才好"）。
                            peer->needsReKey();
                            encryptPacketAndSendSocket(peer, nullptr, 0); // 发送心跳包
                            peer->updateHeartbeatPacketSendTime();
                            // 成功后计算下一次时间
                            const auto keep = std::chrono::seconds(peer->getKeepaliveInterval());
                            const auto keep_ms = std::chrono::duration_cast<std::chrono::milliseconds>(keep);
                            nextSleepDuration = std::min(nextSleepDuration, keep_ms);
                        } catch (const WGException &e) {
                            // 密钥过期/失效：立即重新握手，而不是继续用过期密钥发心跳
                            LOG_WARN(
                                "心跳前检查需重新握手：%{public}s，peerIndex=%{public}zu 发起握手", e.what(),
                                peer->getIndex()
                            );
                            try {
                                sendInitiation(peer);
                                peer->updateHeartbeatPacketSendTime();
                                nextSleepDuration = std::chrono::seconds(1);
                            } catch (const std::exception &e2) {
                                LOG_WARN(
                                    "心跳触发握手失败 peerIndex=%{public}zu err=%{public}s，2秒后重试",
                                    peer->getIndex(), e2.what()
                                );
                                nextSleepDuration = std::chrono::seconds(2);
                            }
                        } catch (const std::exception &e) {
                            // 如果发送发生异常，就设置一个小的等待时间，再次尝试
                            LOG_WARN(
                                "心跳发送数据包失败 peerIndex=%{public}zu err=%{public}s，1秒后重试", peer->getIndex(),
                                e.what()
                            );
                            nextSleepDuration = std::chrono::seconds(1);
                        }
                    }
                } else {
                    nextSleepDuration = std::min(nextSleepDuration, waitTime);
                }
            }

            // 执行清理任务
            indexMapClear();

            // 根据最短时间设置睡眠时间，否则就睡默认值s数
            // 即使在退出心跳任务时，这个任务不需要等待结束，在后台默默退出即可
            pipWaitForHeartbeatTask.wait(nextSleepDuration);
            LOG_DEBUG("pip wait callback");
        }
        LOG_INFO("心跳任务结束");
    }

    void Device::loopReceiveForSocket() {
        LOG_INFO("开始Socket读取任务");

        std::vector<char> buffer(65536);
        Endpoint endpoint;
        isSocketRunning = true;
        int i = 0;
        // 连续错误计数：用于异常路径退避，避免异常反复触发时忙循环
        int consecutiveErrors = 0;
        while (isRunning.load(std::memory_order_acquire) && isSocketRunning.load(std::memory_order_acquire) &&
               socket.isRunning()) {
            try {
                LOG_INFO("socket read for count=%{public}d begin", ++i);
                const ssize_t received = socket.read(buffer.data(), buffer.size(), endpoint);
                LOG_INFO("socket read for count=%{public}d red end, received=%{public}zd", i, received);
                if (received < 0) {
                    if (!isRunning.load(std::memory_order_acquire) ||
                        !isSocketRunning.load(std::memory_order_acquire) ||
                        !socket.isRunning()) {
                        break;
                    }
                    if (received == UDPSocket::READ_STOP) {
                        // 只有主动 close()（唤醒管道）才走这里
                        LOG_INFO("socket 读取收到停止信号，读取任务退出");
                        break;
                    }
                    if (received == UDPSocket::READ_RETRY || errno == EAGAIN || errno == EWOULDBLOCK ||
                        errno == EINTR) {
                        // 可重试：被信号打断(EINTR)/暂无数据/未知就绪事件。
                        // 历史实现在这里直接 break 退出读线程，导致隧道变成"只写不读"
                        // （VPN 显示已连接、通知正常，但再也收不到任何数据），必须继续重读。
                        consecutiveErrors++;
                        std::this_thread::sleep_for(std::chrono::milliseconds(1));
                        continue;
                    }
                    // 其它错误：重建 socket 后继续；重建失败也不退出读线程
                    try {
                        auto fd = socket.resetSocketFd();
                        LOG_SOCKET("更换Socket fd=%{public}d", fd);
                        socketNewFd(fd);
                        consecutiveErrors = 0;
                    } catch (const std::exception &e) {
                        LOG_ERROR("重建Socket失败，1秒后重试：%{public}s", e.what());
                        std::this_thread::sleep_for(std::chrono::seconds(1));
                    }
                    continue;
                }
                consecutiveErrors = 0;
                Logs::print_space([&]() {
                    LOG_SOCKET(
                        "数据流:Socket接收目标 %{public}s len: %{public}zd", endpoint.address.toIpStr().c_str(),
                        received
                    );
                });
                // 将读取的数据写出
                processSocketPacket(buffer.data(), static_cast<size_t>(received), endpoint);
                LOG_INFO("socket read for count=%{public}d finish", i);
            } catch (const WGException &e) {
                if (e.type == WGErrType::SOCKET_CLOSE_SING) {
                    // 正常断开，无需打印日志
                    break;
                }
                LOG_ERROR("socket 异常中断： %{public}s", e.what());
                // 单个异常不应终止读线程（否则隧道只写不读）：退避后继续
                consecutiveErrors++;
                std::this_thread::sleep_for(
                    consecutiveErrors > 5 ? std::chrono::seconds(5) : std::chrono::milliseconds(500)
                );
            } catch (const std::exception &e) {
                LOG_ERROR("socket 异常中断： %{public}s", e.what());
                consecutiveErrors++;
                std::this_thread::sleep_for(
                    consecutiveErrors > 5 ? std::chrono::seconds(5) : std::chrono::milliseconds(500)
                );
            }
        }
        isSocketRunning = false;
        _socketReadTaskExited.store(true, std::memory_order_release);
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
            LOG_WARN(
                "socket 接收消息异常(%{public}u target:%{public}s)：%{public}s", static_cast<uint32_t>(type),
                endpoint.toIpStr().c_str(), e.what()
            );
        }
    }

    void WireGuard::Device::socketNewFd(int _socketFd) {
        if (onSocketFDChange) {
            this->onSocketFDChange(_socketFd);
        }
        // 通知去握手
    }

    void Device::loopReceiveForTun() {
        LOG_INFO("开始VPN Tun读取任务");
        std::vector<uint8_t> buffer(TUN_READ_BUFFER_SIZE);
        while (isRunning.load(std::memory_order_acquire) && isLoopTunRunning.load(std::memory_order_acquire) &&
               tunFd.load(std::memory_order_acquire) > 0) {
            try {
                // 读取网卡数据
                ssize_t readLen = readFromLocal(buffer.data(), TUN_READ_BUFFER_SIZE);
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
                LOG_SOCKET("读取异常：%{public}s", e.what());
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
            const auto ph = Tools::readPacketEndpoint(data, readLen);
            endpoint = ph.dst; // 设置目标
            Logs::print_space([&]() {
                LOG_SOCKET("Tun接收 : %{public}s len: %{public}zd", ph.toIpLog().c_str(), readLen);
            });
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
                    "Tun读取：ip:(%{public}s/%{public}s) 没有匹配到Peer", endpoint.address.toIpStr().c_str(),
                    endpoint.address.toIpHex().c_str()
                );
                return;
            }
        } catch (const std::exception &e) {
            LOG_WARN("获取 peer 异常：%{public}s", e.what());
            return;
        }

        if (!peer->isCanSendData()) {
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
        currentPeer->addRxBytes(len);
        currentPeer->setIAmInitiator(false);
        currentPeer->updateEndpoint(endpoint);
        printStreamLog(currentPeer, MessageType::HANDSHAKE_INITIATION, StreamLog::RECEIVE, len);

        try {
            currentPeer->handleHandshakeInitiation(*msg);
        } catch (const std::exception &e) {
            Logs::print_space([&]() {
                LOG_WARN(
                    "地址（%{public}s）握手失败: %{public}s", WireGuard::Tools::printStr(endpoint.address).c_str(),
                    e.what()
                );
            });
            return;
        }

        // 记录客户端索引（需要转换为本地字节序）
        _receiverIndexPeers[ntohl(msg->senderIndex)] = currentPeer;
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
                printStreamLogThrow(currentPeer, MessageType::HANDSHAKE_RESPONSE, StreamLog::SEND, sizeof(response));
                throw WGException("发送失败");
            }
            // 发送数据流日志
            printStreamLog(currentPeer, MessageType::HANDSHAKE_RESPONSE, StreamLog::SEND, sizeof(response));
            // 发送等待的数据包
            // 服务端在被攻击或者解密失败时，会等待客户端重新握手，或者cookie访问后，继续服务，所以也是有积压的数据的。
            sendStagedPackets(currentPeer);
            Logs::print_space([&]() { LOG_SOCKET("发送握手响应返回发起端，并释放缓存数据包"); });
        } else {
            Logs::print_space([&]() {
                LOG_WARN(
                    "握手响应失败：服务（%{public}s）：KeyPair 生成异常", Tools::printStr(endpoint.address).c_str()
                );
            });
        }
    }

    void Device::handleResponse(const char *data, size_t len, const Endpoint &endpoint) {
        if (len < sizeof(MessageResponse)) {
            return;
        }

        LOG_INFO("握手响应");
        auto *msg = reinterpret_cast<const MessageResponse *>(data);
        // 需要判断是否需要cookie验证

        std::lock_guard<std::mutex> guard(_indexMutex);

        // 根据 receiver_index 查找发起方 Peer（需要转换为本地字节序）
        const uint32_t receiverIndex = ntohl(msg->receiverIndex);
        if (_receiverIndexPeers.find(receiverIndex) == _receiverIndexPeers.end()) {
            throw WGException("未找到远端Peer");
        }
        // 获取到当前 peer
        const auto currentPeer = _receiverIndexPeers[receiverIndex];
        currentPeer->addRxBytes(len);
        // 发送数据流日志
        printStreamLog(currentPeer, MessageType::HANDSHAKE_RESPONSE, StreamLog::RECEIVE, len);
        // 更新端点 (PS:其实我觉得没啥更新必要，按道理，返回的ip地址和端口，应该和请求的一致)
        currentPeer->updateEndpoint(endpoint);

        try {
            CookieChecker::verifyMac1(*msg, content_key_.local_public_key);
        } catch (const std::exception &e) {
            LOG_WARN("MAC1 验证失败： %{public}s", e.what());
            return;
        }

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
            _keypairIndexPeers[ntohl(msg->receiverIndex)] = keypair;
            // 握手已完成：解除"待响应"保护（此后该索引由"存活密钥对"保护）
            _pendingInitiatorIndexes.erase(ntohl(msg->receiverIndex));
            // 发送等待的数据包
            sendStagedPackets(currentPeer);
            LOG_INFO("握手成功 并存储密钥 remoteIndex=%{public}s", crypto::bin2Hex(msg->senderIndex).c_str());
            // // 发送心跳包
            // encryptPacketAndSendSocket(currentPeer, nullptr, 0);
            // LOG_INFO("握手成功 发送心跳包");
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

        std::lock_guard<std::mutex> guard(_indexMutex);

        // 根据 receiver_index 查找发起方 Peer（需要转换为本地字节序）
        const uint32_t receiverIndex = ntohl(msg->receiverIndex);
        if (_receiverIndexPeers.find(receiverIndex) == _receiverIndexPeers.end()) {
            throw WGException("未找到远端Peer");
        }
        // 获取到当前 peer
        const std::shared_ptr<Peer> currentPeer = _receiverIndexPeers[receiverIndex];
        currentPeer->addRxBytes(len);
        // 发送数据流日志
        printStreamLog(currentPeer, MessageType::HANDSHAKE_COOKIE, StreamLog::RECEIVE, len);
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
        LOG_SOCKET("接收到数据");
        const size_t cipherLen = len - sizeof(MessageData);
        //        if (cipherLen < 16 || cipherLen % 16 != 0) {
        //            throw WGException("接收到的加密消息长度不是16倍数len=%d", cipherLen);
        //        }
        auto *msg = reinterpret_cast<const MessageData *>(data);
        std::lock_guard<std::mutex> guard(_indexMutex);
        // 简化处理：遍历所有 Peer
        const uint32_t keyIndex = ntohl(msg->keyIndex);
        if (_receiverIndexPeers.find(keyIndex) == _receiverIndexPeers.end()) {
            throw WGException("未找到远端Peer");
        }
        if (_keypairIndexPeers.find(keyIndex) == _keypairIndexPeers.end()) {
            throw WGException("未找到远端KeyPair index=0x%s", crypto::bin2Hex(msg->keyIndex).c_str());
        }
        //        // 获取到当前 peer
        const auto currentPeer = _receiverIndexPeers[keyIndex];
        // 记录接收的数据
        currentPeer->addRxBytes(cipherLen);
        // 发送数据流日志
        printStreamLog(currentPeer, MessageType::DATA, StreamLog::RECEIVE, len);
        //        // 解密数据流
        //        auto result = currentPeer->decryptPacket(msg, len);
        //        // 获取密钥对
        const auto kp = _keypairIndexPeers[keyIndex];
        if (kp.expired()) {
            sendInitiation(currentPeer); // 如果当前是接收端，这里便会转变角色变成发送端
            throw WGException("keyPair 不存在，需要重新握手");
        }
        // 解密数据
        const std::vector<uint8_t> result = kp.lock()->decrypt(msg, len);
        if (result.empty()) {
            LOG_SOCKET("接收到心跳包");
            return;
        }

        // 根据IP头部提取真实数据长度（去掉加密时添加的零填充）
        size_t actualLen = result.size();
        if (result.size() >= 4) {
            if ((result[0] >> 4) == 4) {
                // IPv4: 总长度在第2-3字节（big-endian）
                actualLen = (static_cast<size_t>(result[2]) << 8) | result[3];
            } else if ((result[0] >> 4) == 6) {
                // IPv6: 有效载荷长度在第4-5字节（big-endian），不包含40字节头部
                size_t payloadLen = (static_cast<size_t>(result[4]) << 8) | result[5];
                actualLen = 40 + payloadLen;
            }
        }

        // 将解密的数据写入网卡进行返回
        sendToLocal(result.data(), actualLen);
    }

    void Device::indexMapClear() {
        std::lock_guard<std::mutex> guard(_indexMutex);

        // 1) 过期未收到响应的"本地发起索引"记录：正常往返只有几十毫秒，30 秒足够宽松
        const auto now = Clock::now();
        const auto pendingTtl = std::chrono::seconds(30);
        for (auto it = _pendingInitiatorIndexes.begin(); it != _pendingInitiatorIndexes.end();) {
            if (now - it->second > pendingTtl) {
                it = _pendingInitiatorIndexes.erase(it);
            } else {
                ++it;
            }
        }

        for (auto it = _receiverIndexPeers.begin(); it != _receiverIndexPeers.end();) {
            const auto index = it->first;
            // 2) 正在等待对端握手响应的本地索引：绝不能清理。
            //    历史实现在这里只看 isActive()（对端 2 分钟内是否有收包），而密钥过期阈值同样是 120 秒：
            //    轮换密钥的那一刻"对端已 2 分钟没发包"几乎必然同时成立，于是刚 createNewIndex 出来的索引
            //    会在同一次心跳循环的清理里被立刻删掉，对端的握手响应全部以"未找到远端Peer"被丢弃，
            //    客户端只能以 REKEY_TIMEOUT 的节奏反复重发握手（实测每 6 秒一次、持续 1 分多钟），
            //    直到对端主动发包刷新活跃状态才恢复 —— 用户表现为"VPN 连着但一段时间没反应"。
            if (_pendingInitiatorIndexes.find(index) != _pendingInitiatorIndexes.end()) {
                ++it;
                continue;
            }
            // 3) 仍绑定着存活会话密钥的索引：接收数据包要靠它反查 Peer，同样必须保留
            const auto kpIt = _keypairIndexPeers.find(index);
            if (kpIt != _keypairIndexPeers.end() && !kpIt->second.expired()) {
                ++it;
                continue;
            }
            // 4) 对端近期有收包 → 保留（原有语义）
            if (it->second->isActive()) {
                ++it;
                continue;
            }
            it = _receiverIndexPeers.erase(it);
        }

        for (auto it = _keypairIndexPeers.begin(); it != _keypairIndexPeers.end();) {
            if (auto k = it->second.lock()) {
                if (!it->second.expired()) {
                    // 如果没有过期，就继续轮询
                    ++it;
                    continue;
                }
            }
            // 如果过期了，并且不不存在值引用了，就直接返回。
            it = _keypairIndexPeers.erase(it);
        }
    }

    void Device::sendInitiation(const std::shared_ptr<Peer> &peer, const bool &force) {
        // 先设置当前设备为发起端
        // 如果发送握手协议，则需要设置为true
        peer->setIAmInitiator(true);

        // 配置 peer 索引
        const auto index = createNewIndex(peer);
        // 登记为"本地发起、等待响应"的索引：心跳循环里的清理任务不能在同一次循环中把它删掉
        markPendingInitiatorIndex(index);
        const auto msg = peer->createHandshakeInitiation(index, force);
        const auto endpoint = peer->getEndpoint();

        LOG_INFO(
            "发送握手请求到：%{public}s:%{public}d  %{public}s, msg_size=%{public}zu",
            endpoint.address.toIpStr().c_str(), endpoint.port, endpoint.address.toIpHex().c_str(), sizeof(msg)
        );

        if (endpoint.port == 0) {
            std::string str = "Peer(index=" + std::to_string(peer->getIndex()) + ") ";
            str +=
                    "端点为空（" + endpoint.address.toIpStr() + ":" + std::to_string(endpoint.port) + "），跳过握手发送。";
            str += "请确认是否已收到对端握手包或是否配置了 Endpoint";
            printStreamLogThrow(peer, MessageType::HANDSHAKE_INITIATION, StreamLog::SEND, sizeof(msg), str);
            LOG_WARN("%{public}s", str.c_str());
            return;
        }

        LOG_INFO(
            "握手消息内容 - header.type=%hhu, senderIndex=%u, msg_size=%zu", msg.header.type, ntohl(msg.senderIndex),
            sizeof(msg)
        );
        const auto result = socket.write(&msg, sizeof(msg), endpoint);
        if (result < 0) {
            std::string error;
            error +=
                    "握手信息发送失败！目标=" + endpoint.address.toIpStr() + ":" + std::to_string(endpoint.port) + ", ";
            error.append("errno=%d, err=%s", errno, *strerror(errno));
            printStreamLogThrow(peer, MessageType::HANDSHAKE_INITIATION, StreamLog::SEND, sizeof(msg), error);
            throw WGException(error);
        }
        peer->addTxBytes(sizeof(msg));
        LOG_INFO("握手请求发送成功，result=%{public}zd", result);
        LOG_INFO(
            "socket fd=%{public}d, isRunning=%{public}s, isSocketRunning=%{public}s", socket.fd(),
            socket.isRunning() ? "true" : "false", isSocketRunning.load() ? "true" : "false"
        );
        // 发送数据流日志
        printStreamLog(peer, MessageType::HANDSHAKE_INITIATION, StreamLog::SEND, sizeof(msg));
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
        // 发送数据流日志
        auto it = _receiverIndexPeers.find(ntohl(msg.senderIndex));
        const std::shared_ptr<Peer> peer = (it != _receiverIndexPeers.end()) ? it->second : nullptr;
        printStreamLog(peer, MessageType::HANDSHAKE_COOKIE, StreamLog::SEND, sizeof(cookieMsg));
    }

    void
    Device::encryptPacketAndSendSocket(const std::shared_ptr<Peer> &peer, const uint8_t *data, const size_t len) const {
        std::lock_guard<std::mutex> lock(_indexMutex);
        // 发送消息到 Peer 使用Peer的ip和端口，接收端会解密包，然后按照实际请求发出
        const Endpoint &endpoint = peer->getEndpoint();
        // 发送数据包到peer
        std::vector<uint8_t> message = peer->encryptPacketToMessageData(data, len);
        try {
            Logs::print_space([&]() {
                LOG_SOCKET(
                    "数据流:写出到Socket(address:%{public}s:%{public}d) size=%{public}zu",
                    endpoint.address.toIpStr().c_str(), endpoint.port, message.size()
                );
            });
            // 加密数据，并且通过 socket 发送
            socket.write(message.data(), message.size(), endpoint);
            peer->addTxBytes(message.size());
            // 发送数据流日志
            printStreamLog(peer, MessageType::DATA, StreamLog::SEND, message.size());
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
                // 发送数据流日志
                printStreamLog(peer, MessageType::DATA, StreamLog::SEND, msg.size());
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
        // if (peer->getIAmInitiator()) {
        sendInitiation(peer);
        // }
    }

    void Device::markPendingInitiatorIndex(const uint32_t index) {
        std::lock_guard<std::mutex> guard(_indexMutex);
        _pendingInitiatorIndexes[index] = Clock::now();
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
        Logs::print_space([&]() { LOG_SOCKET("写入网卡数据 len=%{public}zu", len); });
        write(tunFd, data, len);
    }

    void Device::printStreamLog(
        const std::shared_ptr<Peer> &peer, const MessageType type, const StreamLog::StreamDirection direction,
        const size_t len
    ) const {
        if (!peer) {
            LOG_WARN("printStreamLog: peer 为空，跳过日志");
            return;
        }
        if (!streamLog) {
            return;
        }
        const auto rx = peer->getRxBytes(); // 接收总量
        const auto tx = peer->getTxBytes(); // 发送总量
        const auto now = std::chrono::system_clock::now();
        try {
            streamLog({
                now, peer->getPublicKey(), peer->getIndex(), type, direction, {len, rx, tx},
                true, "成功发送"
            });
        } catch (const std::exception &e) {
            LOG_WARN("[%s] 日志输出异常： %s", LOG_TAG, e.what());
        }
    }

    void Device::printStreamLogThrow(
        const std::shared_ptr<Peer> &peer, const MessageType type, const StreamLog::StreamDirection direction,
        const uint64_t len, const std::string &message
    ) const {
        if (!peer) {
            LOG_WARN("printStreamLogThrow: peer 为空，跳过日志");
            return;
        }
        const auto rx = peer->getRxBytes(); // 接收总量
        const auto tx = peer->getTxBytes(); // 发送总量
        const auto now = std::chrono::system_clock::now();
        try {
            streamLog({
                now, peer->getPublicKey(), peer->getIndex(), type, direction, {len, rx, tx},
                false, message
            });
        } catch (const std::exception &e) {
            LOG_WARN("[%s] 日志输出异常： %s", LOG_TAG, e.what());
        }
    }
}; // namespace WireGuard
