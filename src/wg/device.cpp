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
#include <cstring>
#include <utility>
#include <unistd.h>
#include <sys/socket.h>

#include "cookie.h"

namespace {
    // 当前 steady 时钟毫秒时间戳，用于看门狗计时（不受系统时间跳变影响）
    int64_t steadyNowMs() {
        return std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
    }
}

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
        // 初始化看门狗计时基准，给首次握手留出宽限时间（支持 close 后重新 start 的复用场景）
        const auto nowMs = steadyNowMs();
        lastRecvTimeMs_.store(nowMs, std::memory_order_release);
        lastSendTimeMs_.store(nowMs, std::memory_order_release);
        consecutiveSendFailures_.store(0, std::memory_order_release);
        watchdogAnchorMs_.store(0, std::memory_order_release);
        watchdogStage_.store(0, std::memory_order_release);
        lastTunRestartRequestMs_.store(0, std::memory_order_release);
        tunRestartFailCount_.store(0, std::memory_order_release);
        // 复位"承载切换快速通道"相关状态：close 后重新 start 是复用同一 Device 对象的，
        // 若不复位，上一生命周期残留的静默标记会吞掉新生命周期的首次故障哨兵，
        // 加速超时也会带着旧值进入新会话。
        rebindQuiet_.store(false, std::memory_order_release);
        lastCarrierRebindMs_.store(0, std::memory_order_release);
        lastQuietRebuildMs_.store(0, std::memory_order_release);
        watchdogRecvTimeoutMs_.store(WATCHDOG_RECV_TIMEOUT_MS, std::memory_order_release);
        // 复位"未准备好"节流锚点：新生命周期首次遇到未准备好时必须立即尝试握手并打日志
        lastTunNotReadyAtMs_.store(0, std::memory_order_release);
        // 复位失效上报限频：新连接生命周期里 tun fd 再次失效应立即上报，不必等旧窗口
        lastTunDeadNotifyMs_.store(0, std::memory_order_release);
        // 先启动读取线程（心跳线程首轮即会执行看门狗检查，须保证读取线程状态已就绪）
        {
            std::lock_guard<std::mutex> lock(_socketTaskMutex);
            isSocketRunning.store(true, std::memory_order_release);
            _loopSocketTask = std::thread(&Device::loopReceiveForSocket, this);
        }
        // 启动心跳线程
        _loopSocketHeartbeatTask = std::thread(&Device::loopSocketHeartbeatTask, this);
        // 轮询读取本地 VPN 虚拟网卡数据包
        // 持锁：与心跳线程 restartTunThread() 中的 join/赋值互斥——对同一个 std::thread 对象
        // 并发执行 join 与 move-assign 属于数据竞争（UB），socket 侧已用 _socketTaskMutex 保护
        {
            std::lock_guard<std::mutex> lock(_tunTaskMutex);
            _loopTunFdTask = std::thread(&Device::loopReceiveForTun, this);
        }
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

        // 等待网卡读取线程结束（持锁与心跳线程的 restartTunThread 互斥，避免并发 join）
        {
            std::lock_guard<std::mutex> lock(_tunTaskMutex);
            if (_loopTunFdTask.joinable()) {
                _loopTunFdTask.join();
            }
        }
        LOG_INFO("Tun read task stoped");

        // 等待Socket读取线程结束
        {
            std::lock_guard<std::mutex> lock(_socketTaskMutex);
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
                        // 主动rekey：needsReKey原先只在TUN流量路径（readFromLocal）检查，
                        // 纯keepalive场景（如夜间锁屏无流量）密钥超过REJECT_AFTER_TIME后服务器拒收、
                        // 看门狗90s后才被动重建——形成周期性断流且握手时间长期不刷新。
                        // 心跳周期主动轮换密钥后，KeyPairs三槽机制平滑切换，握手表项每~2分钟正常更新。
                        try {
                            peer->needsReKey();
                        } catch (const std::exception &) {
                            try {
                                sendInitiation(peer); // 主动rekey（内部限频REKEY_TIMEOUT 5s防风暴）
                            } catch (const std::exception &e) {
                                LOG_WARN("心跳周期主动rekey失败 peerIndex=%{public}zu err=%{public}s",
                                    peer->getIndex(), e.what());
                            }
                            // 本轮心跳仍用旧密钥发送（REJECT_AFTER_TIME前仍有效），新会话在后台完成切换
                        }
                        try {
                            encryptPacketAndSendSocket(peer, nullptr, 0); // 发送心跳包
                            peer->updateHeartbeatPacketSendTime();
                            // 成功后计算下一次时间
                            const auto keep = std::chrono::seconds(peer->getKeepaliveInterval());
                            const auto keep_ms = std::chrono::duration_cast<std::chrono::milliseconds>(keep);
                            nextSleepDuration = std::min(nextSleepDuration, keep_ms);
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

            // 看门狗检查：通路自愈（锁屏/网络切换后 Socket 失效、读取线程意外退出等场景）
            watchdogCheck();

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
        while (isRunning.load(std::memory_order_acquire) && isSocketRunning.load(std::memory_order_acquire) &&
               socket.isRunning()) {
            try {
                // 计数自增必须提到宏外：LOG_SOCKET 在 release(SHOW_DEBUG_LOGS 未定义)下是空宏，
                // 宏参数不会被求值——若把 ++i 留在参数中，计数将永远不前进，
                // 且日后若有人复用 i 做逻辑判断会引入隐蔽 bug。
                ++i;
                LOG_SOCKET("socket read for count=%{public}d begin", i);
                const ssize_t received = socket.read(buffer.data(), buffer.size(), endpoint);
                LOG_SOCKET("socket read for count=%{public}d red end, received=%{public}zd", i, received);
                if (received < 0) {
                    // 关闭流程中：直接退出，不做任何恢复
                    if (!isRunning.load(std::memory_order_acquire) || !socket.isRunning()) {
                        LOG_INFO("关闭流程中，Socket读取任务退出");
                        break;
                    }
                    if (received == -2) {
                        // -2 仅由唤醒信号引发；非关闭流程收到，视为看门狗重建请求
                        LOG_WARN("Socket读取收到唤醒信号(-2)，非关闭流程，尝试重建Socket恢复");
                        if (tryRebuildSocketAndRehandshake()) {
                            continue;
                        }
                        std::this_thread::sleep_for(std::chrono::seconds(2));
                        continue;
                    }
                    if (errno == EAGAIN || errno == EWOULDBLOCK) {
                        std::this_thread::sleep_for(std::chrono::milliseconds(1));
                        continue;
                    }
                    // 读错误（如底层网络变化导致的 ENETDOWN/ECONNRESET 等）：重建 Socket 恢复
                    LOG_SOCKET("Socket读错误 errno=%{public}d (%{public}s)，重建Socket", errno, strerror(errno));
                    if (tryRebuildSocketAndRehandshake()) {
                        continue;
                    }
                    std::this_thread::sleep_for(std::chrono::seconds(2));
                    continue;
                }
                Logs::print_space([&]() {
                    LOG_SOCKET(
                        "数据流:Socket接收目标 %{public}s len: %{public}zd", endpoint.address.toIpStr().c_str(),
                        received
                    );
                });
                // 将读取的数据写出
                processSocketPacket(buffer.data(), static_cast<size_t>(received), endpoint);
                LOG_SOCKET("socket read for count=%{public}d finish", i);
            } catch (const WGException &e) {
                if (e.type == WGErrType::SOCKET_CLOSE_SING) {
                    // 唤醒信号：区分正常关闭与看门狗重建请求
                    if (isRunning.load(std::memory_order_acquire) && isSocketRunning.load(std::memory_order_acquire)
                        && socket.isRunning()) {
                        LOG_WARN("收到唤醒信号（非关闭流程），重建Socket并强制重新握手");
                        if (tryRebuildSocketAndRehandshake()) {
                            continue;
                        }
                        std::this_thread::sleep_for(std::chrono::seconds(2));
                        continue;
                    }
                    // 正常断开，无需打印日志
                    break;
                }
                LOG_ERROR("socket 异常中断： %{public}s", e.what());
                if (isRunning.load(std::memory_order_acquire) && socket.isRunning()) {
                    if (tryRebuildSocketAndRehandshake()) {
                        continue;
                    }
                    std::this_thread::sleep_for(std::chrono::seconds(2));
                    continue;
                }
                break;
            } catch (const std::exception &e) {
                LOG_ERROR("socket 异常中断： %{public}s", e.what());
                if (isRunning.load(std::memory_order_acquire) && socket.isRunning()) {
                    if (tryRebuildSocketAndRehandshake()) {
                        continue;
                    }
                    std::this_thread::sleep_for(std::chrono::seconds(2));
                    continue;
                }
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
        // 收到合法类型的 WireGuard 消息才视为通路存活信号（过滤扫描等随机杂散UDP包）
        auto *header = reinterpret_cast<const MessageHeader *>(data);
        auto type = static_cast<MessageType>(header->type);
        if (type == MessageType::HANDSHAKE_INITIATION || type == MessageType::HANDSHAKE_RESPONSE ||
            type == MessageType::HANDSHAKE_COOKIE || type == MessageType::DATA) {
            lastRecvTimeMs_.store(steadyNowMs(), std::memory_order_release);
            watchdogAnchorMs_.store(0, std::memory_order_release);
            watchdogStage_.store(0, std::memory_order_release);
            // 通路已确认存活：结束"承载切换加速窗口"，恢复默认接收超时。
            // 仅在值不同时才写，避免每个数据包都做一次原子写。
            if (watchdogRecvTimeoutMs_.load(std::memory_order_acquire) != WATCHDOG_RECV_TIMEOUT_MS) {
                watchdogRecvTimeoutMs_.store(WATCHDOG_RECV_TIMEOUT_MS, std::memory_order_release);
            }
        }
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
        // 连续硬错误计数：tun fd 失效（EBADF等）时 read 会立即持续失败，
        // 计数达阈值判定 fd 失效，置 isLoopTunRunning=false 退出线程，
        // 交由心跳线程看门狗重启（避免原实现陷入1ms间隔忙循环空转：
        // 原退出条件 tunFd < 0 对无符号 atomic<uint32_t> 恒为 false，是死代码）
        int32_t consecutiveReadErrors = 0;
        int64_t firstErrMs = 0;
        while (isRunning.load(std::memory_order_acquire) && isLoopTunRunning.load(std::memory_order_acquire) &&
               tunFd.load(std::memory_order_acquire) > 0) {
            try {
                // 读取网卡数据
                ssize_t readLen = readFromLocal(buffer.data(), TUN_READ_BUFFER_SIZE);
                if (readLen <= 0) {
                    if (errno != EAGAIN && errno != EINTR) {
                        // 错误窗口：只有窗口内连续达到阈值才判定fd失效。
                        // 低频偶发硬错误（网络切换的EIO/ENETDOWN等）会跨窗口重置，不会误杀读取线程
                        const int64_t errNowMs = steadyNowMs();
                        if (consecutiveReadErrors == 0 || errNowMs - firstErrMs > TUN_READ_ERROR_WINDOW_MS) {
                            firstErrMs = errNowMs;
                            consecutiveReadErrors = 0;
                        }
                        consecutiveReadErrors++;
                        // 日志降频：fd失效时read立即返回，1ms间隔会在几十毫秒内刷满50条ERROR。
                        // 注意本行是"降频采样"（每10次打一条），并非判定阈值——真实阈值见常量，
                        // 文案中显式标出，避免把"连续10次"误读成"阈值为10"。
                        if (consecutiveReadErrors % 10 == 0) {
                            LOG_ERROR(
                                "Tun读取硬错误 errno=%{public}d 已连续%{public}d次（降频采样，判定阈值%{public}d）",
                                errno, consecutiveReadErrors, TUN_READ_ERROR_EXIT_THRESHOLD
                            );
                        }
                        if (consecutiveReadErrors >= TUN_READ_ERROR_EXIT_THRESHOLD) {
                            LOG_ERROR(
                                "Tun读取窗口%{public}lld ms内连续硬错误达阈值，判定tun fd失效，退出读取线程等待看门狗重启",
                                static_cast<long long>(errNowMs - firstErrMs)
                            );
                            isLoopTunRunning.store(false, std::memory_order_release);
                            // 计入重启失败：本次退出是"重启后仍未撑住"的证据，
                            // 供 restartTunThread 判断是否已达上限（fd真失效时不再空转）
                            tunRestartFailCount_.fetch_add(1, std::memory_order_acq_rel);
                            break;
                        }
                    } else {
                        consecutiveReadErrors = 0; // EAGAIN无数据/EINTR中断为正常瞬时状态
                    }
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    continue;
                }
                consecutiveReadErrors = 0;
                // 成功读到数据说明 fd 是好的：复位重启失败计数，
                // 避免此前的异常被累计到"fd永久失效"判定上（仅在计数非0时才写，减少原子写开销）
                if (tunRestartFailCount_.load(std::memory_order_relaxed) > 0) {
                    tunRestartFailCount_.store(0, std::memory_order_release);
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
            // 当前不可发送，则表示握手还未成功，加入消息队列 并去请求握手。
            // 节流（见 PEER_NOT_READY_THROTTLE_MS）：未准备好期间逐包发握手是无效动作——
            // REKEY_TIMEOUT(5s) 内的请求必被速率限制拒绝，真机实测 8 秒刷 320 条日志且
            // 抛异常被静默吞掉。这里把"握手尝试 + 日志"节流到 1 秒一次；
            // 数据包本身仍然全部入队（不丢包，握手成功后由 sendStagedPackets 一次性发出）。
            const int64_t notReadyNowMs = steadyNowMs();
            const int64_t lastNotReadyMs = lastTunNotReadyAtMs_.load(std::memory_order_acquire);
            const bool shouldRetryHandshake =
                    lastNotReadyMs <= 0 || notReadyNowMs - lastNotReadyMs >= PEER_NOT_READY_THROTTLE_MS;
            // 先入队：无论后续握手成功与否都不能丢包（对齐原 cacheSendPacketAndPeerInit 的顺序，
            // 且避免"握手抛异常把入队一起跳过"）
            peer->queuePacket(std::vector<uint8_t>(data, data + static_cast<size_t>(readLen)));
            if (shouldRetryHandshake) {
                lastTunNotReadyAtMs_.store(notReadyNowMs, std::memory_order_release);
                LOG_WARN(
                    "peer还未准备好，保存请求，并触发握手协议（节流：%{public}lld ms 内仅尝试一次）",
                    static_cast<long long>(PEER_NOT_READY_THROTTLE_MS)
                );
                try {
                    sendInitiation(peer);
                } catch (const std::exception &e2) {
                    // 通常是"创建太频繁"（速率限制）：属预期，等待心跳任务或下一轮节流窗口重试
                    LOG_DEBUG("未准备好期间发起握手失败（可忽略，等待重试）：%{public}s", e2.what());
                }
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
                cacheSendPacketAndPeerInit(peer, std::vector<uint8_t>(data, data + static_cast<size_t>(readLen)));
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
                cacheSendPacketAndPeerInit(peer, std::vector<uint8_t>(data, data + static_cast<size_t>(readLen)));
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
        // 修复：索引 map 在其它所有路径（handleResponse/handleData/createNewIndex/
        // indexMapClear/removeIndex/encryptPacketAndSendSocket）均由 _indexMutex 保护，
        // 此处原先只在 _peerMutex 下写入，会与心跳线程的 indexMapClear（持 _indexMutex）
        // 并发读写同一个 unordered_map，构成数据竞争(UB)。故统一到 _indexMutex。
        // 注意：createNewIndex 内部会再次获取 _indexMutex，故本块须先出作用域再调用它。
        {
            std::lock_guard<std::mutex> indexGuard(_indexMutex);
            _receiverIndexPeers[ntohl(msg->senderIndex)] = currentPeer;
        }
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
            // 修复：与 _receiverIndexPeers 同理，keypair 索引 map 统一由 _indexMutex 保护
            {
                std::lock_guard<std::mutex> indexGuard(_indexMutex);
                _keypairIndexPeers[newIndex] = keypair;
            }
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

        std::shared_ptr<Peer> currentPeer;
        {
            std::lock_guard<std::mutex> guard(_indexMutex);
            // 根据 receiver_index 查找发起方 Peer（需要转换为本地字节序）
            const uint32_t receiverIndex = ntohl(msg->receiverIndex);
            if (_receiverIndexPeers.find(receiverIndex) == _receiverIndexPeers.end()) {
                throw WGException("未找到远端Peer");
            }
            // 获取到当前 peer
            currentPeer = _receiverIndexPeers[receiverIndex];
            currentPeer->addRxBytes(len);
            // 发送数据流日志
            printStreamLog(currentPeer, MessageType::HANDSHAKE_COOKIE, StreamLog::RECEIVE, len);
            // 处理cookie消息，并且保存cookie到peer中，再次发送握手时，会携带cookie加密后的mac2
            // 由于解密时用到了握手时的mac1，所以只有发送了握手消息才能获取到正确cookie
            currentPeer->handleCookie(*msg);
        }
        // 锁外重新发送握手请求：sendInitiation 内部会再次获取 _indexMutex，锁内调用会同线程重入死锁
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
        // 锁内只做查找与记录；重握手与解密在锁外执行
        // （sendInitiation 内部会再次获取 _indexMutex，锁内调用会同线程重入死锁）
        std::shared_ptr<Peer> currentPeer;
        std::shared_ptr<KeyPair> kp;
        bool needRehandshake = false;
        {
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
            currentPeer = _receiverIndexPeers[keyIndex];
            // 记录接收的数据
            currentPeer->addRxBytes(cipherLen);
            // 发送数据流日志
            printStreamLog(currentPeer, MessageType::DATA, StreamLog::RECEIVE, len);
            //        // 解密数据流
            //        auto result = currentPeer->decryptPacket(msg, len);
            //        // 获取密钥对
            const auto kpWeak = _keypairIndexPeers[keyIndex];
            if (kpWeak.expired()) {
                needRehandshake = true; // 如果当前是接收端，这里便会转变角色变成发送端
            } else {
                kp = kpWeak.lock();
            }
        }
        if (needRehandshake || !kp) {
            sendInitiation(currentPeer);
            throw WGException("keyPair 不存在，需要重新握手");
        }
        // 解密数据
        const std::vector<uint8_t> result = kp->decrypt(msg, len);
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
        // 修复：actualLen 取自对端 IP 头部声明的长度，可能大于实际解密长度
        // （持有合法密钥的对端只要发送"头长撒谎"的包即可构造，IPv6 的
        // payloadLen 上限 65535 更是远超一般报文）。不设上限会让 sendToLocal
        // 从 result 缓冲区之后越界读并写入 tun 网卡。此处按缓冲区实际大小收敛。
        if (actualLen > result.size()) {
            actualLen = result.size();
        }

        // 将解密的数据写入网卡进行返回
        sendToLocal(result.data(), actualLen);
    }

    void Device::indexMapClear() {
        std::lock_guard<std::mutex> guard(_indexMutex);

        for (auto it = _receiverIndexPeers.begin(); it != _receiverIndexPeers.end();) {
            if (!it->second->isActive()) {
                it = _receiverIndexPeers.erase(it);
            } else {
                ++it;
            }
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

    void Device::watchdogCheck() {
        if (!isRunning.load(std::memory_order_acquire)) {
            return;
        }

        // 情况一：Socket 读取线程意外退出（如重建失败后退出），恢复重建并重启读取线程
        if (!isSocketRunning.load(std::memory_order_acquire)) {
            LOG_WARN("看门狗：Socket读取线程未在运行，尝试恢复");
            // 这是故障兜底路径，必须发布 SOCKET_REBUILT 哨兵；清掉可能残留的
            // "承载切换静默"标记（其唤醒无人接收时会留下未消费的标记）
            rebindQuiet_.store(false, std::memory_order_release);
            tryRebuildSocketAndRehandshake();
            restartReaderThread();
            return;
        }

        // 情况一点五：tun 读取线程已退出（fd失效判定退出/意外退出）但设备仍在运行——重启恢复。
        // tun线程死亡=应用层流量黑洞（用户可见"图标在但连不通"），而UDP层keepalive/握手
        // 正常收发，Socket看门狗（情况二）与主进程心跳判据均不触发，必须在此兑底重启。
        if (isRunning.load(std::memory_order_acquire) && tunFd.load(std::memory_order_acquire) > 0 &&
            !isLoopTunRunning.load(std::memory_order_acquire)) {
            LOG_WARN("看门狗：tun读取线程已退出但设备运行中，尝试重启");
            if (restartTunThread()) {
                return; // 确实拉起了新线程：本轮给它时间重建，不再叠加通路判定
            }
            // 重启未生效（防抖中/线程创建失败/连续失败达上限）——不能在此早退：
            // 一旦 return，下面情况二的通路探测与Socket重建判据会被永久饿死，
            // tun线程死亡期间看门狗将只剩"重启"这一个动作，UDP通路故障无人处理
        }

        // 情况二：通路疑似失效 —— 最后一次接收之后持续成功发送，但超过阈值仍无任何接收。
        // 典型场景：锁屏期间网络切换/NAT映射失效，sendto 依然成功但回包永远收不到。
        // 采用两阶段探测：先发强制握手作为通路探针（避免健康但空闲的隧道被误重建），仍无接收才重建。
        const int64_t nowMs = steadyNowMs();
        const int64_t anchor = watchdogAnchorMs_.load(std::memory_order_acquire);
        // 承载切换会话内使用较短的接收超时（P1 兜底加速），首个有效接收后自动恢复默认值
        const int64_t recvTimeoutMs = watchdogRecvTimeoutMs_.load(std::memory_order_acquire);
        if (anchor <= 0 || nowMs - anchor < recvTimeoutMs) {
            return;
        }
        if (watchdogStage_.load(std::memory_order_acquire) == 0) {
            LOG_WARN(
                "看门狗：%{public}lld ms 未收到远端数据（距上次接收 %{public}lld ms），发送强制握手探测通路",
                nowMs - anchor, nowMs - lastRecvTimeMs_.load(std::memory_order_acquire)
            );
            // 进入探测阶段并重新计时；握手响应到达后锚点会被清零，健康隧道不会再触发
            watchdogStage_.store(1, std::memory_order_release);
            watchdogAnchorMs_.store(nowMs, std::memory_order_release);
            forceRehandshakeAll();
            // G1：上报"通路探测已开始"，上层据此重新解析域名端点（DDNS 漂移自愈）。
            // 不持任何锁；回调经 tsfn 异步下发，不阻塞心跳线程。
            notifyPathProbeStarted();
            return;
        }
        LOG_WARN("看门狗：握手探测后仍 %{public}lld ms 无接收，判定通路故障，请求重建Socket恢复", nowMs - anchor);
        // 重新计时并复位探测阶段，避免下一次检查立即重复触发（重建请求本身有防抖）
        watchdogStage_.store(0, std::memory_order_release);
        watchdogAnchorMs_.store(nowMs, std::memory_order_release);
        requestSocketRebuild();
    }

    void Device::requestSocketRebuild() const {
        const int64_t nowMs = steadyNowMs();
        const int64_t last = lastRebuildRequestMs_.load(std::memory_order_acquire);
        if (last > 0 && nowMs - last < WATCHDOG_REBUILD_MIN_INTERVAL_MS) {
            LOG_DEBUG("重建Socket请求被防抖忽略");
            return;
        }
        lastRebuildRequestMs_.store(nowMs, std::memory_order_release);
        // 本路径是"故障兜底重建"，语义上必须发布 SOCKET_REBUILT 哨兵；
        // 清掉可能残留的"承载切换静默"标记，避免吞掉本次故障上报。
        rebindQuiet_.store(false, std::memory_order_release);
        // 唤醒读取线程，由读取线程执行重建（避免跨线程并发重建）
        socket.wakeUpReader();
    }

    void Device::requestSocketRebuildQuiet() const {
        const int64_t nowMs = steadyNowMs();
        const int64_t last = lastQuietRebuildMs_.load(std::memory_order_acquire);
        if (last > 0 && nowMs - last < QUIET_REBUILD_MIN_INTERVAL_MS) {
            LOG_DEBUG("静默重建Socket请求被防抖忽略");
            return;
        }
        lastQuietRebuildMs_.store(nowMs, std::memory_order_release);
        // 静默重建：不发布 SOCKET_REBUILT 哨兵，只重建本地 fd + 强制重握手。
        // 刻意不占用 lastRebuildRequestMs_（那是"故障上报"的 15 秒防抖），
        // 否则持续失败时的升级上报会被自己的静默重建挡住。
        rebindQuiet_.store(true, std::memory_order_release);
        // 唤醒读取线程，由读取线程执行重建（避免跨线程并发重建）
        socket.wakeUpReader();
    }

    bool Device::forceRebindSocket() {
        if (!isRunning.load(std::memory_order_acquire)) {
            LOG_WARN("承载切换重建Socket被忽略：设备未运行");
            return false;
        }
        const int64_t nowMs = steadyNowMs();
        const int64_t last = lastCarrierRebindMs_.load(std::memory_order_acquire);
        if (last > 0 && nowMs - last < CARRIER_REBIND_MIN_INTERVAL_MS) {
            LOG_DEBUG("承载切换重建Socket被防抖忽略（距上次 %{public}lld ms）", nowMs - last);
            return false;
        }
        lastCarrierRebindMs_.store(nowMs, std::memory_order_release);

        // 读取线程若已退出，唤醒将无人接收，先拉起（复用看门狗情况一的恢复姿势）
        if (!isSocketRunning.load(std::memory_order_acquire)) {
            LOG_WARN("承载切换重建Socket：读取线程未在运行，先尝试重启");
            restartReaderThread();
        }
        if (!isSocketRunning.load(std::memory_order_acquire)) {
            LOG_ERROR("承载切换重建Socket失败：读取线程不可用");
            return false;
        }

        // 标记为"承载切换快速通道"：重建完成后不发布 SOCKET_REBUILT 哨兵。
        // 由 tryRebuildSocketAndRehandshake() 以 exchange 消费，用后即清。
        rebindQuiet_.store(true, std::memory_order_release);

        // 同步看门狗重建请求防抖：刚重建过，短时间内不再接受看门狗 stage2 的重复重建
        lastRebuildRequestMs_.store(nowMs, std::memory_order_release);

        // P1 兜底加速：切换会话内把接收超时降为 15s；若锚点已武装则重置为当前时刻，
        // 使短阈值从现在开始重新计时（否则可能沿用切换前的旧锚点立刻触发）。
        // 首个有效接收到达后由 processSocketPacket 恢复默认 90s。
        watchdogRecvTimeoutMs_.store(WATCHDOG_SWITCH_RECV_TIMEOUT_MS, std::memory_order_release);
        if (watchdogAnchorMs_.load(std::memory_order_acquire) > 0) {
            watchdogAnchorMs_.store(nowMs, std::memory_order_release);
            watchdogStage_.store(0, std::memory_order_release);
        }

        LOG_WARN("承载切换：请求重建Socket（不重启隧道、不发布故障哨兵）");
        socket.wakeUpReader();
        return true;
    }

    void Device::restartReaderThread() {
        std::lock_guard<std::mutex> lock(_socketTaskMutex);
        if (!isRunning.load(std::memory_order_acquire)) {
            return;
        }
        if (isSocketRunning.load(std::memory_order_acquire)) {
            return; // 已有读取线程在运行
        }
        if (_loopSocketTask.joinable()) {
            _loopSocketTask.join(); // 线程已退出，join 立即返回
        }
        isSocketRunning.store(true, std::memory_order_release);
        try {
            _loopSocketTask = std::thread(&Device::loopReceiveForSocket, this);
            LOG_INFO("Socket读取线程已重启");
        } catch (const std::exception &e) {
            isSocketRunning.store(false, std::memory_order_release);
            LOG_ERROR("Socket读取线程重启失败：%{public}s", e.what());
        }
    }

    bool Device::restartTunThread() {
        // 【放弃态前置判定：不持锁、不刷 ERROR】
        // fd真失效时重启的是同一个坏fd，连续 TUN_RESTART_MAX_FAILS 次后重启已无意义。
        // 放弃态是单调的（仅 start() 复位），无需持锁读取；把上报放在锁外，
        // 避免持有 _tunTaskMutex 时回调上层（notifyTunFdDead -> streamLog -> ArkTS）。
        // 上报本身按 TUN_DEAD_NOTIFY_INTERVAL_MS 限频，因此这里可以每轮都调用。
        if (tunRestartFailCount_.load(std::memory_order_acquire) >= TUN_RESTART_MAX_FAILS) {
            notifyTunFdDead(); // 内部按 TUN_DEAD_NOTIFY_INTERVAL_MS 限频（含日志）
            return false;
        }
        std::lock_guard<std::mutex> lock(_tunTaskMutex);
        if (!isRunning.load(std::memory_order_acquire)) {
            return false;
        }
        if (isLoopTunRunning.load(std::memory_order_acquire)) {
            return false; // 已有读取线程在运行
        }
        // 防抖：限制重启间隔，避免fd失效时高频重启空转
        const int64_t nowMs = steadyNowMs();
        const int64_t last = lastTunRestartRequestMs_.load(std::memory_order_acquire);
        if (last > 0 && nowMs - last < WATCHDOG_REBUILD_MIN_INTERVAL_MS) {
            LOG_WARN("tun读取线程重启请求被防抖忽略（距上次 %{public}lld ms）", nowMs - last);
            return false;
        }
        lastTunRestartRequestMs_.store(nowMs, std::memory_order_release);
        if (_loopTunFdTask.joinable()) {
            _loopTunFdTask.join(); // 线程已退出，join 立即返回
        }
        isLoopTunRunning.store(true, std::memory_order_release);
        try {
            _loopTunFdTask = std::thread(&Device::loopReceiveForTun, this);
            LOG_INFO(
                "Tun读取线程已重启（此前连续失败 %{public}d 次）",
                tunRestartFailCount_.load(std::memory_order_relaxed)
            );
            return true;
        } catch (const std::exception &e) {
            isLoopTunRunning.store(false, std::memory_order_release);
            tunRestartFailCount_.fetch_add(1, std::memory_order_acq_rel);
            LOG_ERROR("Tun读取线程重启失败：%{public}s", e.what());
            return false;
        }
    }

    std::shared_ptr<Peer> Device::anyPeerForReport() const {
        std::shared_ptr<Peer> anyPeer{};
        std::lock_guard<std::mutex> lock(_peerMutex);
        if (!_peers.empty()) {
            anyPeer = _peers.begin()->second;
        }
        return anyPeer;
    }

    void Device::notifyPathProbeStarted() const {
        // 看门狗 stage1 每 180s 周期至多触发一次，本身已限频，无需再叠加防抖
        const auto anyPeer = anyPeerForReport();
        if (!anyPeer) {
            LOG_WARN("通路探测上报跳过：当前无可用 peer");
            return;
        }
        LOG_WARN("上报上层：通路探测已开始（90s 无接收），请求重新解析域名端点");
        printStreamLogThrow(anyPeer, MessageType::INVALID, StreamLog::RECEIVE, 0, "PATH_PROBE_START");
    }

    void Device::notifySocketRebuilt() const {
        const auto anyPeer = anyPeerForReport();
        if (!anyPeer) {
            LOG_WARN("Socket重建上报跳过：当前无可用 peer");
            return;
        }
        LOG_WARN("上报上层：Socket 已重建，请求重新解析域名端点（未变化则整隧道重启兜底）");
        printStreamLogThrow(anyPeer, MessageType::INVALID, StreamLog::RECEIVE, 0, "SOCKET_REBUILT");
    }

    void Device::notifyTunFdDead() {
        // 限频：看门狗每轮（约25s）都会走到这里，避免日志刷屏与对上层恢复流程的重复冲击
        const int64_t nowMs = steadyNowMs();
        const int64_t last = lastTunDeadNotifyMs_.load(std::memory_order_acquire);
        if (last > 0 && nowMs - last < TUN_DEAD_NOTIFY_INTERVAL_MS) {
            return;
        }
        lastTunDeadNotifyMs_.store(nowMs, std::memory_order_release);
        // 取任意一个 Peer 作为上报载体：这是 Device 级故障，peer 只是流日志结构的必需字段。
        // 不持 _tunTaskMutex（见 restartTunThread 注释）。
        const auto anyPeer = anyPeerForReport();
        if (!anyPeer) {
            LOG_WARN("tun fd 失效上报跳过：当前无可用 peer");
            return;
        }
        LOG_ERROR(
            "tun fd 已失效（连续重启失败%{public}d次），上报上层触发整体重连（间隔%{public}lld ms）",
            tunRestartFailCount_.load(std::memory_order_acquire),
            static_cast<long long>(TUN_DEAD_NOTIFY_INTERVAL_MS)
        );
        // 复用既有异常流日志通道：success=false + INVALID + 固定标识串。
        // ArkTS 侧按 (messageType==INVALID && success==false) 识别，语义由 msg 区分
        printStreamLogThrow(anyPeer, MessageType::INVALID, StreamLog::RECEIVE, 0, "TUN_FD_DEAD");
    }

    bool Device::updatePeerEndpoint(const size_t index, const std::string &ipStr, const uint16_t port) {
        if (!isRunning.load(std::memory_order_acquire)) {
            LOG_WARN("更新端点跳过：设备未运行");
            return false;
        }
        if (ipStr.empty() || port == 0) {
            LOG_WARN("更新端点失败：参数非法 ip=%{public}s port=%{public}d", ipStr.c_str(), port);
            return false;
        }

        // 解析 IP：与 conf_file/wg_dns 同款 inet_pton，网络字节序存储（socket.write 直接取用）
        IPAddress addr{};
        if (inet_pton(AF_INET, ipStr.c_str(), &addr.ip.ipv4) == 1) {
            addr.family = IPAddress::IPv4;
        } else if (inet_pton(AF_INET6, ipStr.c_str(), addr.ip.ipv6) == 1) {
            addr.family = IPAddress::IPv6;
        } else {
            LOG_WARN("更新端点失败：非法 IP 地址 %{public}s", ipStr.c_str());
            return false;
        }

        std::shared_ptr<Peer> target{};
        {
            std::lock_guard<std::mutex> lock(_peerMutex);
            for (const auto &it: _peers) {
                if (it.second && it.second->getIndex() == index) {
                    target = it.second;
                    break;
                }
            }
        }
        if (!target) {
            LOG_WARN("更新端点失败：未找到 index=%{public}zu 的 Peer", index);
            return false;
        }

        Endpoint ep{};
        ep.address = addr;
        ep.port = port;
        const Endpoint old = target->getEndpoint();
        if (old == ep) {
            LOG_INFO("更新端点：目标未变化（%{public}s），跳过重握手", ep.toIpStr().c_str());
            // 地址确实没变（DNS 仍是旧值）：不算"已修复"，调用方据此走 α 兜底
            return false;
        }

        target->updateEndpoint(ep);
        LOG_WARN(
            "端点已更新 peerIndex=%{public}zu：%{public}s -> %{public}s，立即强制重握手",
            index, old.toIpStr().c_str(), ep.toIpStr().c_str()
        );
        try {
            // force=true 绕过 REKEY_TIMEOUT 限频：本次是故障恢复，必须立刻发包到新地址
            sendInitiation(target, true);
        } catch (const std::exception &e) {
            LOG_ERROR(
                "端点更新后重握手失败 peerIndex=%{public}zu err=%{public}s，交由上层兜底", index, e.what()
            );
            return false;
        }
        return true;
    }

    bool Device::tryRebuildSocketAndRehandshake() {
        if (!isRunning.load(std::memory_order_acquire)) {
            return false;
        }
        bool expected = false;
        if (!rebuilding_.compare_exchange_strong(expected, true)) {
            LOG_INFO("Socket重建已在进行中，跳过本次请求");
            return false;
        }
        // 消费"承载切换快速通道"标记：true 表示本次重建由网络承载切换触发，
        // 重建成功后不发布 SOCKET_REBUILT 哨兵（不惊动上层、不升级 α）。
        const bool quietRebind = rebindQuiet_.exchange(false, std::memory_order_acq_rel);
        bool ok = false;
        try {
            LOG_WARN("开始重建Socket（原fd=%{public}d）", socket.fd());
            const int newFd = socket.resetSocketFd();
            LOG_WARN("Socket重建完成，新fd=%{public}d，通知上层重新protect并强制重新握手", newFd);
            // 通知上层（ArkTS）对新 fd 执行 protect
            socketNewFd(newFd);
            // 重置看门狗计时（接收锚点/探测阶段/连续失败计数），给重新握手留出宽限。
            // 注意：此处刻意不重置 lastSendTimeMs_——它代表“最后一次真实成功发送”，
            // 是 encryptPacketAndSendSocket 中 persistent 升级判据（距上次成功发送≥10s）的
            // 唯一依据。若在此把它刷成 now，会无限期掩盖“发送持续失败”的真相，
            // 导致永不升级到 SOCKET_REBUILT（参见 9/12 事故：native 静默重建空转 ~20 分钟）。
            const auto nowMs = steadyNowMs();
            lastRecvTimeMs_.store(nowMs, std::memory_order_release);
            watchdogAnchorMs_.store(0, std::memory_order_release);
            watchdogStage_.store(0, std::memory_order_release);
            consecutiveSendFailures_.store(0, std::memory_order_release);
            // 强制所有 Peer 立即重新握手（绕过限速）
            forceRehandshakeAll();
            ok = true;
        } catch (const std::exception &e) {
            LOG_ERROR("Socket重建失败：%{public}s", e.what());
        }
        rebuilding_.store(false, std::memory_order_release);
        if (ok) {
            if (quietRebind) {
                // 承载切换快速通道：只重建本地 fd + 重握手，隧道/长时任务/通知均未动，
                // 不发布故障哨兵，避免上层重新解析域名甚至升级整隧道重启。
                LOG_INFO("承载切换快速通道：Socket已重建并强制重握手（不发布故障哨兵）");
            } else {
                // G2：上报"Socket 已重建"，上层据此重新解析域名端点；
                // 解析结果未变化则由上层退化为整隧道重启（α 兜底）。
                // 此处已释放 rebuilding_，且不持任何 Device 锁。
                notifySocketRebuilt();
            }
        }
        return ok;
    }

    void Device::forceRehandshakeAll() {
        LOG_INFO("强制所有Peer重新握手");
        std::vector<std::shared_ptr<Peer> > peers{};
        {
            std::lock_guard<std::mutex> lock(_peerMutex);
            peers.reserve(_peers.size());
            for (const auto &it: _peers) {
                if (it.second) {
                    peers.push_back(it.second);
                }
            }
        }
        for (const auto &peer: peers) {
            try {
                // force=true 绕过握手频率限制
                sendInitiation(peer, true);
            } catch (const std::exception &e) {
                LOG_WARN(
                    "强制握手失败 peerIndex=%{public}zu err=%{public}s，等待心跳任务重试", peer->getIndex(), e.what()
                );
            }
        }
    }

    void Device::sendInitiation(const std::shared_ptr<Peer> &peer, const bool &force) {
        // 先设置当前设备为发起端
        // 如果发送握手协议，则需要设置为true
        peer->setIAmInitiator(true);

        // 配置 peer 索引
        const auto index = createNewIndex(peer);
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
            // 修复：std::string::append 没有 printf 变参重载。原写法
            // append("...%d...", errno, *strerror(errno)) 会命中
            // append(const basic_string&, size_type pos, size_type n) 重载，
            // 把 errno 当作 pos 对格式串做切片（错误消息乱码），且 errno>=格式串长度
            // （17）时直接抛 std::out_of_range，覆盖掉本应抛出的握手失败异常。
            const char *errStr = strerror(errno);
            error += "errno=" + std::to_string(errno) + ", err=" + (errStr ? errStr : "unknown");
            printStreamLogThrow(peer, MessageType::HANDSHAKE_INITIATION, StreamLog::SEND, sizeof(msg), error);
            throw WGException(error);
        }
        peer->addTxBytes(sizeof(msg));
        // 记录发送活跃时间，并标记“无接收周期”的开始锚点（仅首个成功发送时设置）
        const auto sendNowMs = steadyNowMs();
        lastSendTimeMs_.store(sendNowMs, std::memory_order_release);
        int64_t anchorExpected = 0;
        watchdogAnchorMs_.compare_exchange_strong(anchorExpected, sendNowMs);
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
            const auto sendNowMs = steadyNowMs();
            lastSendTimeMs_.store(sendNowMs, std::memory_order_release);
            consecutiveSendFailures_.store(0, std::memory_order_release);
            int64_t anchorExpected = 0;
            watchdogAnchorMs_.compare_exchange_strong(anchorExpected, sendNowMs);
            // 发送数据流日志
            printStreamLog(peer, MessageType::DATA, StreamLog::SEND, message.size());
        } catch (const std::exception &e) {
            // 由于发送失败是服务自己原因，这里不去触发重新握手
            LOG_WARN("socket 发送失败：%{public}s", e.what());
            // 连续发送失败达到阈值：大概率底层网络已变化，分级处置——
            // （1）先静默重建：只重建本地 fd + 强制重握手，不发布 SOCKET_REBUILT 哨兵。
            //     承载切换场景上层已有 P0-b 快速通道，若此处抢先上报，上层会白做一次
            //     域名重解析/自愈流程（真机实测 native 早于承载检测 4 秒发哨兵）。
            // （2）只有"距上次成功发送"已超过 SEND_FAIL_ESCALATE_MS 仍持续失败，才判定
            //     为非承载切换的真故障，升级为故障上报（发布哨兵，让上层重解析/兜底）。
            const int32_t fails = consecutiveSendFailures_.fetch_add(1, std::memory_order_acq_rel) + 1;
            if (fails >= SEND_FAIL_REBUILD_THRESHOLD) {
                consecutiveSendFailures_.store(0, std::memory_order_release);
                const int64_t nowMs = steadyNowMs();
                const int64_t lastOkSendMs = lastSendTimeMs_.load(std::memory_order_acquire);
                const bool persistent = lastOkSendMs > 0 && nowMs - lastOkSendMs >= SEND_FAIL_ESCALATE_MS;
                if (persistent) {
                    LOG_WARN(
                        "发送失败持续 %{public}lld ms（自上次成功发送）未恢复，请求重建Socket并上报故障",
                        static_cast<long long>(nowMs - lastOkSendMs)
                    );
                    requestSocketRebuild();
                } else {
                    LOG_WARN(
                        "连续发送失败达 %{public}d 次，静默重建Socket（暂不上报，持续 %{public}lld ms 未恢复才升级）",
                        SEND_FAIL_REBUILD_THRESHOLD, static_cast<long long>(SEND_FAIL_ESCALATE_MS)
                    );
                    requestSocketRebuildQuiet();
                }
            }
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
