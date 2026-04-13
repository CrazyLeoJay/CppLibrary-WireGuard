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

#include "udp_socket.h"
#include "WGException.h"
#include <arpa/inet.h>
#include <complex>
#include <cstdint>
#include <cstring>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <memory>
#include <unistd.h>

#include "sys/epoll.h"

namespace WireGuard {
    WireGuard::UDPSocket::UDPSocket() = default;

    WireGuard::UDPSocket::~UDPSocket() { close(); };

    int WireGuard::UDPSocket::initSocket(
        const std::shared_ptr<uint32_t> &port, const std::shared_ptr<IPAddress> &bindAddress
    ) {
        _port = port;
        _bindAddress = bindAddress;
        _fd = createSocket();
        return _fd;
    }

    int WireGuard::UDPSocket::createSocket() {
        // 由于存在socket 被迫终端重新创建的情况，这里要先close 关闭一下之前开启的fd
        close();
        // int socket(int domain, int type, int protocol);
        //  domain：地址族（Address Family）
        //  AF_INET：IPv4
        //  AF_INET6：IPv6
        //  AF_UNIX：本地通信（Unix Domain Socket）
        //  type：套接字类型
        //  SOCK_STREAM：面向连接（TCP）
        //  SOCK_DGRAM：无连接（UDP）
        //  SOCK_RAW：原始套接字
        //  protocol：协议（通常设为 0，由系统根据 type 自动选择）
        //  如 IPPROTO_TCP、IPPROTO_UDP
        _fd = socket(AF_INET, SOCK_DGRAM, 0);
        // 设置 套接字 可以被重用
        int enable = 1;
        if (setsockopt(_fd, SOL_SOCKET, SO_REUSEADDR, &enable, sizeof(enable)) < 0) {
            close();
            throw WGException("设置 socket fd 重用异常");
        }

        if (!_port) {
            _port = std::make_shared<uint32_t>();
        }
        if (_port) {
            struct sockaddr_in addr{};
            addr.sin_family = AF_INET;
            addr.sin_port = htons(*_port);
            if (_bindAddress && _bindAddress->family == IPAddress::IPv4) {
                addr.sin_addr.s_addr = _bindAddress->ip.ipv4;
            } else {
                addr.sin_addr.s_addr = htonl(INADDR_ANY);
            }
            if (::bind(_fd, (struct sockaddr *) &addr, sizeof(addr)) < 0) {
                close();
                throw WGException("绑定到端口异常: %d", *_port);
            }
        }

        // 通过 pipe(int fd[2]) 创建一个单向通信通道：
        // fd[0]：读端
        // fd[1]：写端
        if (pipe(wakeup_pipe_) != 0) {
            close();
            throw WGException("创建唤醒管道异常");
        }

        // 增加 epoll 多路复用方式获取数据
        epoll_fd_ = epoll_create1(EPOLL_CLOEXEC);
        if (epoll_fd_ == -1) {
            // 如果 epoll_fd 创建失败，使用 select 方式多路复用
            return false;
        }

        struct epoll_event ev;
        ev.events = EPOLLIN;
        ev.data.fd = _fd.load();
        if (epoll_ctl(epoll_fd_, EPOLL_CTL_ADD, _fd.load(), &ev) == -1) {
            close();
            throw WGException("将 socketFd 添加入 epoll 失败");
        }

        // 将唤醒管道添加入 epoll
        ev.data.fd = wakeup_pipe_[0];
        if (epoll_ctl(epoll_fd_, EPOLL_CTL_ADD, wakeup_pipe_[0], &ev) == -1) {
            close();
            throw WGException("将 wakeup_pip 添加入 epoll 失败");
        }
        _initialized = true;
        return _fd;
    }

    ssize_t WireGuard::UDPSocket::read(char *buf, size_t len, Endpoint &endpoint) {
        if (!_initialized) {
            LOG_WARN("socket 未初始化");
            throw WGException(WGErrType::SOCKET_CLOSE_SING);
        }
        if (!isRunning()) {
            throw WGException(WGErrType::SOCKET_CLOSE_SING);
        }
        if (epoll_fd_ != -1) {
            return read_epoll(buf, len, endpoint);
        } else {
            return read_select(buf, len, endpoint);
        }
    }

    ssize_t WireGuard::UDPSocket::read_select(char *buf, size_t len, Endpoint &endpoint) {
        // 使用 IO 多路复用，防止
        fd_set read_fds;
        // 清空 fd_set 集合（必须初始化）
        FD_ZERO(&read_fds);

        // 获取最大的fd
        int max_fd = _fd.load();
        // 将 UDP socket 文件描述符加入监听集合
        FD_SET(_fd.load(), &read_fds);
        if (max_fd < wakeup_pipe_[0]) {
            max_fd = wakeup_pipe_[0];
        }
        // 将自管道的读端（wakeup_pipe_[0]）也加入监听集合，
        // 这样当有停止信号写入管道时，select 会立即返回
        FD_SET(wakeup_pipe_[0], &read_fds);

        // 调用 select 阻塞等待，直到以下任一情况发生：
        //   - UDP socket 有数据可读
        //   - 自管道有数据可读（即收到停止信号）
        //   - 发生错误
        // 第四个参数 timeout 为 nullptr，表示无限期阻塞
        int activeFd = ::select(max_fd + 1, &read_fds, nullptr, nullptr, nullptr);
        // 如果 select 返回负值，说明发生错误（如被信号中断等）
        if (activeFd < 0) {
            return -2;
        }

        // 检查是否是自管道可读（即收到了停止信号）
        if (FD_ISSET(wakeup_pipe_[0], &read_fds)) {
            pip_read_wake();
            return -2;
        }

        // 如果不是停止信号，那么应该是 socket 数据
        if (_fd.load() != -1 && FD_ISSET(_fd.load(), &read_fds)) {
            return pip_read_socket(buf, len, endpoint);
        }
        return -1;
    }

    ssize_t WireGuard::UDPSocket::read_epoll(char *buf, size_t len, Endpoint &endpoint) {
        // 阻塞等待事件，-1 表示无限期等待
        int nfds = epoll_wait(epoll_fd_, events, MAX_EVENTS, -1);
        if (nfds == -1) {
            return -1;
        }
        // 遍历所有就绪的事件
        for (int i = 0; i < nfds; ++i) {
            int fd = events[i].data.fd;
            // 检查是否是 UDP socket 事件
            if (fd == _fd.load()) {
                return pip_read_socket(buf, len, endpoint);
            } else if (fd == wakeup_pipe_[0]) {
                // 检查是否是自管道事件（停止信号）
                // 这里会抛出异常
                pip_read_wake();
            }
        }
        // 如果都没有就默认返回-1
        return -1;
    }

    void WireGuard::UDPSocket::pip_read_wake() {
        // 从管道读取一个字节（必须读走，否则下次 select 仍会触发）
        // 这里只读一个字节，因为我们只写了一个字节作为信号
        char dummy;
        ssize_t n = ::read(wakeup_pipe_[0], &dummy, 1);
        // 抛出异常，表示管道正常关闭
        throw WGException(WGErrType::SOCKET_CLOSE_SING);
    }

    ssize_t WireGuard::UDPSocket::pip_read_socket(char *buf, size_t len, Endpoint &endpoint) {
        struct sockaddr_in addr{};
        socklen_t addrLen = sizeof(addr);
        auto ret = recvfrom(_fd.load(), buf, len, 0, (struct sockaddr *) &addr, &addrLen);
        if (ret < 0) {
            //            if (errno == EAGAIN || errno == EWOULDBLOCK) {
            //                return -1; // 没有数据（或暂时无法写入）或标记为“可稍后重试”
            //            }
            // 未读取到
            return -1;
        }
        endpoint.port = ntohs(addr.sin_port);
        if (addr.sin_family == AF_INET6) {
            endpoint.address.family = IPAddress::IPv6;
        } else {
            endpoint.address.family = IPAddress::IPv4;
        }
        endpoint.address.ip.ipv4 = addr.sin_addr.s_addr;
        return ret;
    }

    /**
     * 端口需要小端序
     * ip地址需要大端序
     *
     * @param buf
     * @param len
     * @param endpoint
     * @return
     */
    ssize_t WireGuard::UDPSocket::write(const void *buf, const size_t len, const Endpoint &endpoint) {
        if (!_initialized) {
            throw WGException("还未初始化");
        }
        if (_fd < 0) {
            throw WGException("套接字还未创建");
        }
        if (!buf) {
            throw WGException("数据不存在");
        }
        // 0 端口保留，不能用于通信（sendto 使用端口 0 通常会报 EINVAL）
        if (endpoint.port <= 0 || endpoint.port > 65535) {
            throw WGException("端口号不合法：port=%d", endpoint.port);
        }
        ssize_t ret;
        if (endpoint.address.family == IPAddress::IPv4) {
            struct sockaddr_in addr{};
            memset(&addr, 0, sizeof(addr)); // 清零
            addr.sin_family = AF_INET;
            addr.sin_port = htons(endpoint.port);
            addr.sin_addr.s_addr = endpoint.address.ip.ipv4;
            ret = sendto(_fd.load(), buf, len, 0, (struct sockaddr *) &addr, sizeof(struct sockaddr_in));
        } else if (endpoint.address.family == IPAddress::IPv6) {
            // IPv6 支持
            struct sockaddr_in6 addr{};
            memset(&addr, 0, sizeof(addr)); // 清零
            addr.sin6_family = AF_INET6;
            addr.sin6_port = htons(endpoint.port);
            std::memcpy(&addr.sin6_addr, endpoint.address.ip.ipv6, 16);
            ret = sendto(_fd.load(), buf, len, 0, (struct sockaddr *) &addr, sizeof(struct sockaddr_in6));
        } else {
            throw WGException("特殊数据类型，ipv?");
        }
        if (ret != len) {
            std::string error;
            error += std::to_string(errno);
            throw WGException(
                "Socket发送异常：ret=%d len=%d sendto failed: %s(%s)", ret, len, strerror(errno), error.c_str()
            );
        }
        return ret;
    }

    bool WireGuard::UDPSocket::isRunning() { return _initialized && _fd.load() != -1; }

    void WireGuard::UDPSocket::close() {
        if (wakeup_pipe_[1] != -1) {
            // 管道写入唤醒包
            char wake = 1;
            ::write(wakeup_pipe_[1], &wake, 1);
        }

        if (_fd != -1) {
            ::close(_fd);
            _fd = -1;
        }

        if (epoll_fd_ != -1) {
            ::close(epoll_fd_);
            epoll_fd_ = -1;
        }
        // 关闭唤醒通道
        for (auto i = 0; i < MAX_WAKEUP_PIP_COUNT; ++i) {
            auto wp_fd = wakeup_pipe_[i];
            if (wp_fd != -1) {
                ::close(wp_fd);
                wakeup_pipe_[i] = -1;
            }
        }
        _initialized = false;
    }
}; // namespace WireGuard
