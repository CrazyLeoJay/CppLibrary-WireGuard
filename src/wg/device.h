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
        std::thread _loopSocketHeartbeatTask{};
        Tools::PipeWait pipWaitForHeartbeatTask{}; // 轮询等待使用阻塞
        // ============ Socket 数据读写任务 ===============
        std::thread _loopSocketTask{};
        mutable std::atomic<bool> isSocketRunning{false}; // 用于判断和控制 socket 线程是否执行
        std::function<void(int &)> onSocketFDChange{}; // 当socket发生变化时调用
        // =============== 看门狗（锁屏/网络切换后通路自愈） ===============
        // 最后一次收到远端数据的时间（steady 毫秒时间戳），0 表示未初始化
        mutable std::atomic<int64_t> lastRecvTimeMs_{0};
        // 最后一次成功发送数据的时间（steady 毫秒时间戳），0 表示未初始化
        mutable std::atomic<int64_t> lastSendTimeMs_{0};
        // 连续发送失败次数，达到阈值触发 Socket 重建
        mutable std::atomic<int32_t> consecutiveSendFailures_{0};
        // 看门狗锚点：最后一次接收之后首次成功发送的时间（steady 毫秒），0 表示不处于“发送中无接收”状态
        mutable std::atomic<int64_t> watchdogAnchorMs_{0};
        // 看门狗阶段：0=监测中，1=握手探针已发送（避免健康空闲隧道被误重建）
        mutable std::atomic<int32_t> watchdogStage_{0};
        // 上次请求重建 Socket 的时间（steady 毫秒），用于防抖
        mutable std::atomic<int64_t> lastRebuildRequestMs_{0};
        // 上次"承载切换快速重建"的时间（steady 毫秒），用于独立防抖
        // （见 CARRIER_REBIND_MIN_INTERVAL_MS）
        mutable std::atomic<int64_t> lastCarrierRebindMs_{0};
        // 上次"发送失败静默重建"的时间（steady 毫秒），用于独立防抖
        // （见 QUIET_REBUILD_MIN_INTERVAL_MS）。刻意与 lastRebuildRequestMs_ 分开，
        // 使"静默重建（快）"与"故障上报重建（慢防抖）"互不干扰。
        mutable std::atomic<int64_t> lastQuietRebuildMs_{0};
        // 本次 Socket 重建是否为"承载切换快速通道"（一次性标记）：
        // true 时重建完成后不发布 SOCKET_REBUILT 哨兵——该哨兵语义是"通路故障兜底"，
        // 会让上层重新解析域名、解析结果未变化时进一步升级为整隧道重启（α），
        // 而承载切换只是本地 fd 失效，重建即好，不应触发上层故障流程。
        // 由 tryRebuildSocketAndRehandshake() 以 exchange 方式消费（用后即清）。
        mutable std::atomic<bool> rebindQuiet_{false};
        // 上次由 TUN 数据路径在"peer 未准备好"时尝试握手/打印日志的时刻（steady 毫秒），
        // 用于节流（见 PEER_NOT_READY_THROTTLE_MS）。该窗口内的握手请求必被速率限制拒绝，
        // 逐包重试只会刷屏并空转；数据包仍全部入队，不丢包。
        mutable std::atomic<int64_t> lastTunNotReadyAtMs_{0};
        // 看门狗当前使用的接收超时（steady 毫秒语义的时长值）。
        // 默认 WATCHDOG_RECV_TIMEOUT_MS；承载切换后临时降为
        // WATCHDOG_SWITCH_RECV_TIMEOUT_MS，首个有效接收到达即恢复默认。
        mutable std::atomic<int64_t> watchdogRecvTimeoutMs_{WATCHDOG_RECV_TIMEOUT_MS};
        // Socket 重建互斥标记，防止多线程并发重建
        mutable std::atomic<bool> rebuilding_{false};
        // Socket 读取线程对象的操作锁（启动/重启/关闭 join 互斥）
        mutable std::mutex _socketTaskMutex{};
        // =============== 虚拟VPN网卡读取 ===============
        mutable std::atomic<uint32_t> tunFd{0};
        std::thread _loopTunFdTask{};
        mutable std::atomic<bool> isLoopTunRunning{false}; // 用于判断和控制 tun 是否在读取中
        // tun 读取线程对象的操作锁（启动/重启/关闭 join 互斥，对齐 _socketTaskMutex 模式）
        mutable std::mutex _tunTaskMutex{};
        // 上次重启 tun 读取线程的时间（steady 毫秒），用于防抖：fd真失效时重启线程无法恢复，
        // 循环重启只会空转烧CPU，限制间隔；连续重启失败达阈值后转交 Socket 重建路径兜底
        mutable std::atomic<int64_t> lastTunRestartRequestMs_{0};
        // tun 读取线程连续重启失败次数：fd真失效时重启无意义，达阈值后不再空转，
        // 由看门狗改走 Socket 重建/强制握手路径，并向上层暴露持续失败
        mutable std::atomic<int32_t> tunRestartFailCount_{0};
        // 上次向上层上报"tun fd 失效"的时间（steady 毫秒），限频避免恢复信号刷屏；
        // start() 复位，使新一次连接生命周期能立即上报
        mutable std::atomic<int64_t> lastTunDeadNotifyMs_{0};
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
         * 发送数据包到所有已建立连接的Peer
         * @param data 数据指针
         * @param len 数据长度
         */
        void sendPacket(const uint8_t *data, size_t len) const;

        /**
         * 更新 Peer 的网络端点（DDNS 变更后由上层重解析结果下发，不重建隧道）。
         *
         * 场景：对端域名的公网地址变化（DDNS 更新）后，本端仍向旧地址发握手，
         * 表现为"图标在但网不通"。上层（ArkTS）重新解析域名后经此接口下发新地址，
         * 本方法更新 Peer 的 Endpoint 并立即强制重握手一次，
         * 使恢复在毫秒级完成（对比重建 Socket 的秒级 / 重启隧道的秒级~分钟级）。
         *
         * 线程约束：可在任意线程调用（内部仅取 _peerMutex 与 Peer 自身锁），
         * 但不得在持有 _peerMutex / _indexMutex 的临界区内调用（sendInitiation 会再次取锁）。
         *
         * @param index  Peer 的顺序索引（与配置 peers 数组下标、流日志 peerIndex 一致）
         * @param ipStr  新的 IP 地址字符串（IPv4 或 IPv6）
         * @param port   新的端口（1~65535）
         * @return true = 已找到 Peer、端点确实发生变化、已更新且重握手已发出；
         *         false = 更新未生效（设备未运行 / 参数非法 / 未找到 Peer /
         *                 与当前端点相同 / 重握手发送失败）——调用方应退化到 α 整隧道重启
         */
        bool updatePeerEndpoint(size_t index, const std::string &ipStr, uint16_t port);

        /**
         * 网络承载切换（WiFi↔蜂窝）时的快速通道：立即重建本地 Socket 并强制重新握手。
         *
         * 与看门狗"故障兜底重建"的区别（这是本方法存在的全部理由）：
         * 1. **不发布 SOCKET_REBUILT 哨兵** —— 该哨兵是"通路故障"语义，会驱动上层
         *    重新解析域名、必要时升级为整隧道重启（α，销毁 VEA 进程）。而承载切换
         *    只是本地 fd 绑定的网络被移除，重建 fd 即可恢复，不应惊动上层。
         * 2. **不重启隧道** —— 不销毁 VEA、不重建长时任务、不动通知栏，
         *    因此恢复耗时在毫秒~秒级，而非 α 的秒级 + 主进程 60s 轮询发现。
         * 3. **顺带加速看门狗** —— 把该会话的接收超时降为
         *    WATCHDOG_SWITCH_RECV_TIMEOUT_MS，万一重建未奏效，兜底路径也从
         *    90s+90s 收敛到 15s+15s（首个有效接收后自动恢复默认值）。
         *
         * 由 ArkTS 在检测到 netCapabilitiesChange 的承载类型发生变化时调用。
         * 内部有 3 秒防抖（CARRIER_REBIND_MIN_INTERVAL_MS），可安全重复调用。
         *
         * 线程约束：可在任意线程调用（内部只做原子读写 + 唤醒读取线程），
         * 不得在持有 _socketTaskMutex 的临界区内调用（restartReaderThread 会再次取锁）。
         *
         * @return true=已受理并请求重建；false=设备未运行 / 读取线程不可用 / 防抖期内被忽略
         */
        bool forceRebindSocket();

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

        /**
         * 看门狗检查：持续发送中但长时间无任何接收时，请求重建 Socket。
         * 在心跳轮询中调用。
         */
        void watchdogCheck();

        /**
         * 请求重建 Socket（非阻塞）。
         * 通过唤醒读取线程执行重建，避免跨线程并发重建。
         * 重建完成后读取线程会自动重新握手，并通知上层重新 protect 新 fd。
         */
        void requestSocketRebuild() const;

        /**
         * 请求"静默"重建 Socket（非阻塞，不发布 SOCKET_REBUILT 哨兵）。
         * 用于发送失败路径的首轮自愈：只重建本地 fd + 强制重握手，不惊动上层
         * （承载切换由上层 P0-b 快速通道负责）；持续失败超窗口才升级为故障上报
         * （见 SEND_FAIL_ESCALATE_MS）。独立防抖见 QUIET_REBUILD_MIN_INTERVAL_MS。
         */
        void requestSocketRebuildQuiet() const;

        /**
         * 重启 Socket 读取线程（仅在线程已退出时生效）。
         * 在心跳线程的看门狗中调用，用于恢复意外退出的读取线程。
         */
        void restartReaderThread();

        /**
         * 重启 tun 读取线程（仅在线程已退出时生效）。
         * 在心跳线程的看门狗中调用：tun线程死亡=应用层流量黑洞（图标在但连不通），
         * 而UDP层keepalive/握手正常收发，Socket看门狗与主进程 heartbeat 判据均不触发，
         * 必须由心跳线程兑底重启。
         *
         * @return true=本次确实拉起了新线程；false=未重启（已有线程/未运行/防抖/创建失败/失败次数超限）。
         *         调用方据此决定是否继续看门狗的后续判据，避免早退把其他自愈路径饿死。
         */
        bool restartTunThread();

        /**
         * 向上层上报"tun fd 已失效"。
         *
         * tun fd 真失效（连续 TUN_RESTART_MAX_FAILS 次重启无效）后，UDP 通路仍
         * 正常收发、流日志心跳持续刷新，上层的进程级/心跳级自愈判据全部失明，
         * 应用会进入"图标在、通知在，但应用层全黑洞"的静默故障。
         *
         * 复用既有 streamLog 异常通道（success=false）上报，不新增 NAPI 接口：
         * 载荷为 (MessageType::INVALID, StreamLog::RECEIVE, success=false, "TUN_FD_DEAD")，
         * ArkTS 侧识别该组合后销毁 VEA 壳并重拉，由系统重建 tun 句柄。
         *
         * 限频 TUN_DEAD_NOTIFY_INTERVAL_MS 重发。调用方不得持有 _tunTaskMutex
         * （本方法会回调上层 ArkTS）。
         */
        void notifyTunFdDead();

        /**
         * 取任意一个 Peer 作为 Device 级故障上报的载体（无 Peer 时返回空指针）。
         *
         * 这些故障是 Device 级而非 Peer 级的，peer 只是流日志结构的必需字段，
         * 因此取第一个即可。调用方不得持有 _peerMutex（本方法内部会获取）。
         */
        std::shared_ptr<Peer> anyPeerForReport() const;

        /**
         * 上报"通路探测已开始"（G1 触点）。
         *
         * 触发点：看门狗 stage1 —— 最后一次接收之后持续成功发送，但 90s 内无任何接收，
         * 已发出一次强制握手作为通路探针。此时最可能的两种原因是"换网后 NAT 映射失效"
         * 或"对端域名公网地址已变（DDNS）"，两种都能靠"重新解析域名"改善。
         *
         * 复用既有 streamLog 异常通道（success=false + INVALID + 固定标识串）上报，
         * 不改动 native 任何行为：载荷为 "PATH_PROBE_START"。
         * ArkTS 侧识别后重新解析域名并把新端点推回（β 自愈）。
         *
         * 调用方不得持有 _peerMutex / _tunTaskMutex（本方法会回调上层 ArkTS）。
         */
        void notifyPathProbeStarted() const;

        /**
         * 上报"Socket 已重建"（G2 触点）。
         *
         * 触发点：看门狗 stage2 —— 握手探针发出后再 90s 仍无接收，判定通路故障并
         * 已重建 Socket + 重新 protect + 强制重握手。若故障根因是对端地址失效，
         * "重建 Socket"是无效动作（fd 重建了，目标地址还是旧的）。
         *
         * 复用既有 streamLog 异常通道上报，载荷为 "SOCKET_REBUILT"。
         * ArkTS 侧识别后重新解析域名：结果有变化则推新端点（β）；
         * 结果未变化则退化为整隧道重启（α 兜底，带指数退避）。
         *
         * 仅在上报时无任何 Device 锁（本方法会回调上层 ArkTS）。
         */
        void notifySocketRebuilt() const;

        /**
         * 重建 Socket 并强制所有 Peer 重新握手。
         * 仅在读取线程内，或读取线程已退出的前提下调用（由 rebuilding_ 保证互斥）。
         * @return 重建是否成功
         */
        bool tryRebuildSocketAndRehandshake();

        /**
         * 强制所有 Peer 立即重新握手（绕过握手频率限制）。
         * 在 Socket 重建后调用，用于快速恢复会话。
         */
        void forceRehandshakeAll();

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
