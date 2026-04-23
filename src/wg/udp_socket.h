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
// Created on 2026/3/24.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef WIREGUARD_UDP_SOCKET_H
#define WIREGUARD_UDP_SOCKET_H

#include <atomic>

#include "entity.h"
#include <cstddef>
#include <cstdint>
#include <sys/epoll.h>
#include "version.h"

#define MAX_WAKEUP_PIP_COUNT 2
#define MAX_EVENTS           2

namespace WireGuard {
    /**
     * UDP 通信
     * 不需要监听或者是连接操作
     * 服务端和客户端都是直接轮询  recvfrom 读取数据即可。。
     * todo 2026年4月9日 计划：需改实现方式，多路复用需要另外实现，
     * socket的fd可能被系统释放，所以我需要有一个重启机制。直接 socket 添加入多路复用，然后继续 read
     */
    class UDPSocket {
    private:
        std::shared_ptr<uint32_t> _port{0};
        std::shared_ptr<IPAddress> _bindAddress{0};


        mutable std::atomic<int> _fd{-1};
        mutable std::atomic<bool> _initialized{false};

        int wakeup_pipe_[MAX_WAKEUP_PIP_COUNT]{-1, -1};
        int epoll_fd_ = -1; // epoll 文件描述符

        // epoll 事件数组，这里只监听两个 fd，所以大小为 2 足够
        // 实际应用中可根据需要调整
        epoll_event events[MAX_EVENTS]{};

    public:
        UDPSocket();

        ~UDPSocket();

        /**
         * 初始化  UDPSocket 参数和状态，并且创建一个socket
         *
         *
         * @param port
         * @param bindAddress
         * @return
         */
        int initSocket(const std::shared_ptr<uint32_t> &port, const std::shared_ptr<IPAddress> &bindAddress);

        /**
         * 使用参数创建一个 socket
         * 如果有地址或者端口绑定，必须在 initSocket 之后，
         *
         * @return
         */
        int createSocket();

        int fd() { return _fd.load(); }

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
        ssize_t write(const void *buf, const size_t len, const Endpoint &endpoint) const;

        /**
         * @return socket 是否在运行
         */
        bool isRunning() const;

        void close();

    private:
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
}; // namespace WireGuard

#endif // WIREGUARD_UDP_SOCKET_H
