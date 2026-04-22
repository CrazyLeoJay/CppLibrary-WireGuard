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
// Created on 2026/4/7.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef WIREGUARD_PIPWAIT_H
#define WIREGUARD_PIPWAIT_H

#include <chrono>

#include "WGException.h"
#include <cstdint>
#include <fcntl.h>
#include <poll.h>
#include <sys/epoll.h>
#include <unistd.h>

namespace WireGuard {
    namespace Tools {
        /**
         * 使用通道做轮询阻塞机制，可以快速退出
         */
        class PipeWait {
        public:
            PipeWait() {
                if (::pipe(wake_up_pip) != 0) {
                    close();
                    throw WGException("pipe通道创建失败");
                }
                // 在构造函数 pipe 创建后添加：
                // 将写入端设置为非阻塞 避免写入时阻塞
                int flags = fcntl(wake_up_pip[1], F_GETFL, 0);
                if (flags == -1 || fcntl(wake_up_pip[1], F_SETFL, flags | O_NONBLOCK) == -1) {
                    close();
                    throw WGException("设置 pipe 写端为非阻塞失败");
                }
                // 增加 epoll 多路复用方式获取数据
                epoll_fd_ = epoll_create1(EPOLL_CLOEXEC);
                if (epoll_fd_ == -1) {
                    // 如果 epoll_fd 创建失败
                    throw WGException("epoll_fd 创建失败");
                }

                // 将唤醒管道添加入 epoll
                struct epoll_event ev;
                ev.events = EPOLLIN;
                ev.data.fd = wake_up_pip[0];
                if (epoll_ctl(epoll_fd_, EPOLL_CTL_ADD, wake_up_pip[0], &ev) == -1) {
                    close();
                    throw WGException("将 wakeup_pip 添加入 epoll 失败");
                }
                LOG_DEBUG("PipeWait create ");
            }

            ~PipeWait() { close(); }

        private:
            int wake_up_pip[2]{-1, -1};
            int epoll_fd_ = -1;

            void close() {
                notify();
                if (wake_up_pip[0] != -1) {
                    ::close(wake_up_pip[0]);
                }
                if (wake_up_pip[1] != -1) {
                    ::close(wake_up_pip[1]);
                }
                if (epoll_fd_ != -1) {
                    ::close(epoll_fd_);
                }
            }

        public:
            /**
             * 等待
             * @param waitTime 等待时间
             */
            void wait(const std::chrono::milliseconds &waitTime) {
                // epoll 事件数组，这里只用到了一个通道
                // 实际应用中可根据需要调整
                constexpr int count = 1;
                epoll_event events[count]{};
                int nfds = ::epoll_wait(epoll_fd_, events, count, waitTime.count());
                if (nfds == 0) {
                    return;
                } else if (nfds < 0) {
                    LOG_WARN("pip wait epoll_wait failed : errno=%{public}d", nfds);
                    return;
                }
                // 遍历所有就绪的事件
                for (int i = 0; i < nfds; ++i) {
                    int fd = events[i].data.fd;
                    // 检查是否是 UDP socket 事件
                    if (fd == wake_up_pip[0]) {
                        pip_read_wake();
                        return;
                    }
                }
            }

            /**
             * 通知通道，停止等待，返回阻塞内容
             * 非线程安全，每个线程单独维护
             */
            void notify() {
                LOG_DEBUG("notify wake up return");
                char dummy = 1;
                ::write(wake_up_pip[1], &dummy, 1);
            }

        private:
            void pip_read_wake() {
                // 从管道读取一个字节（必须读走，否则下次 select 仍会触发）
                // 这里只读一个字节，因为我们只写了一个字节作为信号
                //                char dummy;
                //                ssize_t n = ::read(wake_up_pip[0], &dummy, 1);
                char dummy[64]; // 一次多读，减少系统调用
                // 读取一次，因为多路复用只保证读取一次的数据存在，如果没读取完成会再次调用多路复用
                // 循环读取会造成死锁
                ::read(wake_up_pip[0], dummy, sizeof(dummy));
                // 这里不做处理，消耗了即可，线程不再阻塞
            }
        };
    } // namespace Tools
}; // namespace WireGuard

#endif // WIREGUARD_PIPWAIT_H