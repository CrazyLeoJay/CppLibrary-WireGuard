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
 * Created by Leojay on 2026/4/22.
 *
 * @author leojay`fu
 * @email crazyleojay@163.com
 * @url https://github.com/CrazyLeoJay
 */

#include "wg_dns.h"
#include <stdexcept>
#include <cstring>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "entity.h"

#ifdef _WIN32
#include <ws2tcpip.h>
#else
#include <sys/socket.h>
#include <netdb.h>
#include <arpa/inet.h>
#endif

namespace WireGuard {
    namespace DNS {
        namespace {
            /**
             * getaddrinfo 限时执行状态。
             *
             * 为什么要把解析放到独立线程：getaddrinfo 没有超时参数，域名服务器不可达/丢包时
             * 会阻塞很久（历史实测 5 分 8 秒）。而该调用经由同步 NAPI 位于 VEA 主线程，
             * 一旦卡住会把整个串行重连链（opChain）与网络切换重连一起饿死，
             * 表现为"切网后要等很久才恢复"。
             */
            struct ResolveState {
                std::mutex mutex{};
                std::condition_variable cv{};
                bool done{false};
                int errCode{0}; // 0=成功；否则为 getaddrinfo 错误码或超时哨兵
                std::vector<IPAddress> addresses{};
            };

            // 超时哨兵：EAI_* 均为非负小整数，取负值以区分"超时"与"解析失败"
            constexpr int RESOLVE_TIMEOUT_CODE = -1000;

            void resolveWorker(
                const std::shared_ptr<ResolveState> &state, const std::string &domain, int family, int sockType,
                int protocol
            ) {
                addrinfo hints{};
                hints.ai_family = family;
                hints.ai_socktype = sockType;
                hints.ai_protocol = protocol;

                addrinfo *result = nullptr;
                const int rc = getaddrinfo(domain.c_str(), nullptr, &hints, &result);

                std::vector<IPAddress> addresses{};
                if (rc == 0 && result != nullptr) {
                    for (auto ptr = result; ptr != nullptr; ptr = ptr->ai_next) {
                        if (ptr->ai_family == AF_INET) {
                            IPAddress ipAddress{};
                            const auto ipv4 = reinterpret_cast<struct sockaddr_in *>(ptr->ai_addr);
                            ipAddress.family = IPAddress::IPv4;
                            ipAddress.ip.ipv4 = ipv4->sin_addr.s_addr;
                            addresses.push_back(ipAddress);
                        } else if (ptr->ai_family == AF_INET6) {
                            IPAddress ipAddress{};
                            const auto ipv6 = reinterpret_cast<struct sockaddr_in6 *>(ptr->ai_addr);
                            ipAddress.family = IPAddress::IPv6;
                            memcpy(ipAddress.ip.ipv6, ipv6->sin6_addr.s6_addr, sizeof(ipAddress.ip.ipv6));
                            addresses.push_back(ipAddress);
                        }
                    }
                }
                if (result != nullptr) {
                    freeaddrinfo(result);
                }

                {
                    std::lock_guard<std::mutex> lock(state->mutex);
                    state->errCode = rc;
                    state->addresses = std::move(addresses);
                    state->done = true;
                }
                // 通知放在锁外：等待方醒来后自行取结果
                state->cv.notify_all();
            }

            /**
             * 限时域名解析。
             *
             * @return 0=成功（out 已填充）；RESOLVE_TIMEOUT_CODE=超时；
             *         其他=getaddrinfo 的错误码（可用 gai_strerror 转文本）
             *
             * 超时后工作线程被 detach：getaddrinfo 无法取消，但该线程只持有自己的
             * 状态对象（shared_ptr 生命周期由线程自身维持），不触碰 Device/socket 等
             * 共享资源，因此超时返回后主流程可以安全继续，不会出现悬垂引用。
             * 真正的成本只是"极端网络下可能短暂多一个后台线程"，远优于阻塞主线程数分钟。
             */
            int resolveWithTimeout(
                const std::string &domain, int family, int sockType, int protocol, std::vector<IPAddress> &out
            ) {
                auto state = std::make_shared<ResolveState>();
                std::thread worker(resolveWorker, state, domain, family, sockType, protocol);

                int code = 0;
                {
                    std::unique_lock<std::mutex> lock(state->mutex);
                    const bool finished = state->cv.wait_for(
                        lock, std::chrono::milliseconds(DNS_RESOLVE_TIMEOUT_MS), [&state] { return state->done; }
                    );
                    if (!finished) {
                        // 超时：放弃等待，工作线程 detach 后自行收尾
                        LOG_ERROR("域名解析超时（%{public}d ms）：%{public}s",
                                  static_cast<int>(DNS_RESOLVE_TIMEOUT_MS), domain.c_str());
                        worker.detach();
                        return RESOLVE_TIMEOUT_CODE;
                    }
                    code = state->errCode;
                    out = state->addresses;
                }
                worker.join();
                return code;
            }

            /** 解析失败时抛出统一的异常（含超时与 getaddrinfo 错误码两种情形） */
            [[noreturn]] void throwResolveError(const std::string &domain, int code) {
                if (code == RESOLVE_TIMEOUT_CODE) {
                    throw std::runtime_error("域名解析超时: " + domain);
                }
                throw std::runtime_error("域名解析失败: " + std::string(gai_strerror(code)));
            }
        } // namespace

        IPAddress readDomainToIp(const std::string &domain, const IPType &type) {
            const int family = (type == IPV4) ? AF_INET : AF_INET6;
            std::vector<IPAddress> addresses{};
            const int code = resolveWithTimeout(domain, family, SOCK_STREAM, IPPROTO_TCP, addresses);
            if (code != 0) {
                throwResolveError(domain, code);
            }
            if (addresses.empty()) {
                throw std::runtime_error("域名解析失败: 未找到可用的IP地址");
            }
            return addresses.front();
        }

        IPAddress readDomainToIpPreferIpv4(const std::string &domain) {
            std::vector<IPAddress> addresses{};
            const int code = resolveWithTimeout(domain, AF_UNSPEC, SOCK_STREAM, IPPROTO_TCP, addresses);
            if (code != 0) {
                throwResolveError(domain, code);
            }
            // 优先返回 IPv4，其次 IPv6（保持与原实现相同的偏好语义）
            for (const auto &address: addresses) {
                if (address.family == IPAddress::IPv4) {
                    return address;
                }
            }
            for (const auto &address: addresses) {
                if (address.family == IPAddress::IPv6) {
                    return address;
                }
            }
            throw std::runtime_error("域名解析失败: 未找到可用的IP地址");
        }

        std::vector<IPAddress> readDomainToIpAll(const std::string &domain) {
            std::vector<IPAddress> addresses{};
            const int code = resolveWithTimeout(domain, AF_UNSPEC, SOCK_STREAM, IPPROTO_TCP, addresses);
            if (code != 0) {
                throwResolveError(domain, code);
            }
            return addresses;
        }
    }
} // WireGuardTools
