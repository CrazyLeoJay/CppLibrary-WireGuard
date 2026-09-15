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
 * Created by Leojay on 2026/7/5.
 *
 * @author leojay`fu
 * @email crazyleojay@163.com
 * @url https://github.com/CrazyLeoJay
 */

#ifndef WG_MAIN_SOCKET_TOOLS_H
#define WG_MAIN_SOCKET_TOOLS_H
#define MAX_WAKEUP_PIP_COUNT 2
#define MAX_EVENTS           2
// 读等待的有限超时（毫秒）。close() 关闭 epoll fd 不会唤醒正阻塞在该 epoll 上的
// epoll_wait（Linux 行为），只靠唤醒管道存在交错竞态；超时用于周期性自检退出。
#define EPOLL_WAIT_TIMEOUT_MS 500

#include <atomic>
#include <mutex>
#include <sys/socket.h>
#include <sys/epoll.h>

#include "tools/wg_dns.h"

namespace WireGuard {
    class UDPSocket {
    public:
        explicit UDPSocket(const DNS::IPType &type);

        ~UDPSocket();

    private:
        const DNS::IPType type;
        std::shared_ptr<uint32_t> _port{nullptr};
        std::shared_ptr<IPAddress> _bind_address{nullptr};
        mutable std::atomic<int> _fd{-1};
        mutable std::atomic<bool> _initialized{false};
        mutable std::atomic<bool> _isFinish{false};

        // 唤醒管道：pipe() 需要传入 int[2]，无法改成原子类型，
        // 与读线程（read_epoll/read_select）存在跨线程并发读写，统一由 _wakeupMutex 保护
        int wakeup_pipe_[MAX_WAKEUP_PIP_COUNT]{-1, -1};
        // 保护 wakeup_pipe_ 的并发读写（wakeUpReader 写、close 重置、读线程取快照）
        mutable std::mutex _wakeupMutex{};
        // epoll 文件描述符：close()/initEpollFd() 写、读线程 read_epoll() 读，故用原子
        mutable std::atomic<int> epoll_fd_{-1};

        // epoll 事件数组，这里只监听两个 fd，所以大小为 2 足够
        // 实际应用中可根据需要调整
        epoll_event events[MAX_EVENTS]{};

    public:
        /**
         * 初始化  UDPSocket 参数和状态，并且创建一个socket
         * 使用参数创建一个 socket
         *
         * @param port 指定端口
         * @param bindAddress 指定绑定的地址
         * @return
         */
        int initSocketStart(const std::shared_ptr<uint32_t> &port = nullptr,
                       const std::shared_ptr<IPAddress> &bindAddress = nullptr);

        /**
         * @return 重置Socket的套接字
         */
        int resetSocketFd();

        int fd() const { return _fd.load(); }

        /**
         * 从套接字中读取数据
         *
         * @param buf 缓存区
         * @param len 缓冲区大小
         * @param endpoint 从socket 读取时，记录对端 ip 端口 等信息
         * @return
         */
        ssize_t read(char *buf, size_t len, Endpoint &endpoint);

        /**
         * 通过socket 写入
         *
         * @param buf 写入数据的缓存区
         * @param len 缓冲区长度
         * @param endpoint 写入的节点
         */
        ssize_t write(const void *buf, size_t len, const Endpoint &endpoint) const;

        /**
         * @return socket 是否在运行
         */
        bool isRunning() const;

        void close();

        /**
         * 唤醒阻塞在读等待（epoll/select）中的读取线程。
         * 用于看门狗请求重建 Socket：读取线程被唤醒后自行完成重建，
         * 不会关闭 Socket，也不会终止读取循环。
         */
        void wakeUpReader() const;

    private:
        void bindPortForIpv4(uint32_t port, const std::shared_ptr<IPAddress> &bindHost);

        void bindPortForIpv6(uint32_t port, const std::shared_ptr<IPAddress> &bindHost);

        /**
         * 初始化 epoll 多路复用
         * - 创建 wakeup_pipe_ 通道
         * - 创建 epoll_fd 套接字
         * - 配置通道
         *
         * 主要用于结束阻塞，防止socket read时一直等待。
         */
        void initEpollFd();

        /**
        * select 多路复用方式
        * @param buf
        * @param len
        * @param endpoint
        * @return
        */
        ssize_t read_select(char *buf, size_t len, Endpoint &endpoint) const;

        /**
         * epoll多路复用方式(Linux 支持，更加高效！)
         *
         * @param buf
         * @param len
         * @param endpoint
         * @return
         */
        ssize_t read_epoll(char *buf, size_t len, Endpoint &endpoint);

        /**
         * 唤醒操作退出操作
         */
        void pip_read_wake() const;

        /**
         * 从管道里读取数据
         * @param buf
         * @param len
         * @param endpoint
         * @return
         */
        ssize_t pip_read_socket(char *buf, size_t len, Endpoint &endpoint) const;
    };
} // WireGuard

#endif //WG_MAIN_SOCKET_TOOLS_H
