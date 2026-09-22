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
#include <random>
#include <thread>
#include <unordered_map>

#include "cookie.h"
#include "version.h"
#include "tools/wg_stream_log.h"
#include "tools/socket/socket_tools.h"

namespace WireGuard {
    /**
     * 由于Wireguard的设计是端对端，所以无论是服务端还是客户端，都有发起握手的权力，
     * 那么，实际上，我需要处理两种情况，需要根据实际情况判断当前端是 发送端 还是 接收端
     */
    class Device final {
    public:
        /**
         * @param config 设备配置
         * @return
         */
        explicit Device(const DeviceRegisterConfig &config);

        ~Device();

    protected: // 确定参数
        const ContentKey content_key_;
        const DeviceConfig config;
        UDPSocket socket{DNS::IPV6};
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
        // 【异常边界架构】
        // 1. 顶层外部调用方法（initSocketStart/start/close/swapSocket/sendPacket等）：
        //    不在内部吞异常，向上抛出，由NAPI胶水层统一捕获转ArkTS走正常异常流程；
        // 2. 工作线程（无胶水边界，异常逃逸=std::terminate=进程崩溃）：
        //    - 迭代内可恢复异常：迭代级catch记日志继续运行，不算故障；
        //    - 线程致命退出（读线程自愈耗尽/未知异常等）：经reportSocketEvent上报
        //      SOCKET_ERROR回调通知宿主，随后由心跳线程守护(ensureSocketReadLoop)
        //      自动重新拉起，不算崩溃。
        std::thread _loopSocketHeartbeatTask{};
        Tools::PipeWait pipWaitForHeartbeatTask{}; // 轮询等待使用阻塞
        // ============ Socket 数据读写任务 ===============
        std::thread _loopSocketTask{};
        mutable std::atomic<bool> isSocketRunning{false}; // 用于判断和控制 socket 线程是否执行
        std::function<void(int &)> onSocketFDChange{}; // 当socket发生变化时调用
        mutable std::mutex _readLoopMutex{}; // 读线程重建/守护与 close 的互斥，避免 join 竞态
        /** 连续发送失败计数（达到阈值时经 streamLog 通道上报 SOCKET_ERROR 事件） */
        mutable std::atomic<int> _consecutiveSendFailures{0};
        /** 连续发送失败上报阈值 */
        static constexpr int SEND_FAILURE_REPORT_THRESHOLD = 3;
        /** 各Peer最后一次握手失联判死上报时间（仅心跳线程访问，无锁） */
        std::unordered_map<size_t, TimePoint> _staleReportTimes{};
        // =============== 虚拟VPN网卡读取 ===============
        mutable std::atomic<uint32_t> tunFd{0};
        std::thread _loopTunFdTask{};
        mutable std::atomic<bool> isLoopTunRunning{false}; // 用于判断和控制 tun 是否在读取中
        // =============== 本地代理Proxy（未开发） ===============

        // =============== Cookie 挑战配置 ===============
        bool enableCookie{false}; // 是否开启 cookie 挑战
        CookieChecker cookieChecker{content_key_};

        // =============== 日志打印 ===============
        StreamLog::StreamLogPrint streamLog{
            [](StreamLog::Message msg) {
                // const auto direction = msg.direction == WireGuard::StreamLog::RECEIVE ? "接收" : "发送";
                // LOG_INFO("Device in [streamLog]：peerIndex=%d, 方向=%s 数据量=%zu", static_cast<int>(msg.peerIndex),
                //          direction,
                //          msg.sc.length);
            }
        };

    public: // 对外操作方法
        /**
         * 创建Socket服务，并且绑定本地端口，返回socket套接字
         */
        uint32_t initSocketStart(const std::function<void(int &)> &onSocketFDChange);

        /**
         * 启动轮询任务，读写数据包
         *
         * @param tunFd 网卡套接字，用于读写本地虚拟VPN网卡数据
         */
        void start(const uint32_t &tunFd);

        /**
         * 设置流监听
         *
         * @param listener stream 流监听
         */
        void setStreamLog(const StreamLog::StreamLogPrint &listener);

        /**
         * 停止并清除资源，close 后需要重新初始化
         */
        void close();

        /**
         * 运行时重建底层UDP socket并经onSocketFDChange通知宿主重新protect
         *
         * 仅替换socket fd（保留epoll/唤醒管道/会话与Peer状态），宿主重新protect后
         * WireGuard可自动漫游到新网络源地址，无需整体重建VPN连接。
         * 供宿主在网络切换时调用；socket fd swap与读线程自愈共用重入保护。
         *
         * @return 新的socket fd
         * @throws WGException 重建失败
         */
        int swapSocket();

        /**
         * 发送数据包到所有已建立连接的Peer
         * @param data 数据指针
         * @param len 数据长度
         */
        void sendPacket(const uint8_t *data, size_t len) const;

    private: // 被动操作 初始化、轮询、监听等
        void initPeers(const std::vector<PeerConfig> &peer);

        /**
         * 心跳任务，用于维护udp链接
         */
        void loopSocketHeartbeatTask();

        /**
         * 守护 socket 读线程：发现读线程死亡（自愈耗尽/异常退出）时重新拉起
         * 由心跳线程每轮调用
         */
        void ensureSocketReadLoop();

        /**
         * 读循环故障恢复：有限次重建 socket fd 并通知宿主重新 protect
         *
         * @param retries 连续重试计数（调用方持有，读成功后归零）
         * @return true=重建成功，可继续读循环；false=重试耗尽（内部已上报链路死亡事件）
         */
        bool recoverSocketReadLoop(int &retries);

        /**
         * 向宿主上报 Socket 链路级事件（MessageType::SOCKET_ERROR，success=false）
         * 不依赖具体 Peer，用于读线程死亡、连续发送失败等链路故障
         */
        void reportSocketEvent(const std::string &message) const;

        /**
         * 记录一次发送失败：累计计数，达到阈值时上报 SOCKET_ERROR 事件并清零
         */
        void noteSendFailure(const std::exception &e) const;

        /**
         * 握手失联判死（握手维护统一到C层的最终裁决，替代宿主层握手超时检查）：
         * Peer 2分钟无任何入站（isActive()==false）且外发活跃（近期有握手/数据/心跳发出）
         * → 判定隧道失效，经 SOCKET_ERROR 事件上报宿主重建隧道。
         * 外发不活跃（keepalive=0的空闲隧道）不武装，避免误判。同一Peer上报节流120s。
         *
         * 由心跳线程每轮对每个Peer调用
         */
        void checkPeerStale(const std::shared_ptr<Peer> &peer);

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
         * 接收端 Cookie处理
         */
        void handleCookie(const char *data, size_t len, const Endpoint &endpoint);

        /**
         * 接收到加密的数据传输 这个无关发送端还是接收端
         */
        void handleData(const char *data, const size_t &len, const Endpoint &endpoint);

        /**
         * _receiverIndexPeers和_keypairIndexPeers清理
         * 在心跳轮询时调用，用于检查索引是否过期，防止内存溢出
         */
        void indexMapClear();

    private: // 协议相关主动操作
        void sendInitiation(const std::shared_ptr<Peer> &peer, const bool &force = false);

        /**
         * cookie挑战
         * - 判断是否需要发起cookie请求
         * - 如果本地cookie存在且有效，mac2也有值，则判断mac2是否合理
         *
         * cookie 只需要 握手消息和 mac2 参与即可
         *
         * 如果需要cookie挑战，那么需要遵循以下规则
         * > 验证mac1需要对端公钥
         * > 验证mac2只需要cookie即可
         * - 收到消息后，不解析publicKey，先验证cookie
         *  - 如果cookie为空、或者cookie失效，不验证mac2，直接cookie挑战。
         *  - 如果mac2为空或者无效，发送cookie挑战。
         *  - 如果mac2有值，则验证是否合格
         *      - 合格：true
         *      - 不合格：false
         *
         * @param endpoint
         * @param msg
         * @return 是否挑战成功！ 如果是true，表示验证成功，并且Cookie挑战成功
         *                      如果是false，表示可能cookie挑战失败或者cookie失效，才刚发出cookie
         */
        bool checkCookieForMac2(const Endpoint &endpoint, const MessageInitiation &msg);

        /**
         * 发送Cookie到客户端
         *
         * @param msg 发起放的索引
         * @param endpoint 发送的端点
         */
        void sendCookieReply(const MessageInitiation &msg, const Endpoint &endpoint);

        /**
         * 加密数据包后并发送到对应的Peer
         */
        void encryptPacketAndSendSocket(const std::shared_ptr<Peer> &peer, const uint8_t *data, size_t len) const;

    private: // 主动操作：发送数据包、发起握手等
        /**
         * 发送 peer 等待的数据包
         */
        void sendStagedPackets(const std::shared_ptr<Peer> &peer) const;

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

        void printStreamLog(const std::shared_ptr<Peer> &peer, MessageType type, StreamLog::StreamDirection direction,
                            size_t len) const;

        /**
         * 异常打印
         *
         * @param peer
         * @param type
         * @param direction
         * @param len
         * @param message
         */
        void printStreamLogThrow(const std::shared_ptr<Peer> &peer, MessageType type,
                                 StreamLog::StreamDirection direction, uint64_t len,
                                 const std::string &message = "") const;
    };
}; // namespace WireGuard
#endif // WIREGUARD_DEVICE_H
