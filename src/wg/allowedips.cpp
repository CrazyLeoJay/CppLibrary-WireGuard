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
 *
 * allowedips 是 WireGuard 的核心组件之一，用于实现 IP 地址前缀路由表。它的主要作用是：
 *  维护允许的 IP 地址范围：存储每个 peer（对端）允许通信的 IP 地址前缀（CIDR 格式）
 *  快速查找路由：根据数据包的目标 IP 或源 IP 快速找到对应的 peer
 *  支持 IPv4 和 IPv6：分别维护两个独立的 trie 树（前缀树）
 *  高效内存管理：使用 slab 分配器优化内存分配，支持 RCU（Read-Copy-Update）并发访问
 *  该模块使用 trie 树（前缀树） 数据结构来存储 IP 前缀，支持高效的插入、删除和查找操作。
 * Created on 2026/3/18.
 * @author leojay`fu
 * Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
 * please include "napi/native_api.h".
 */

#include "allowedips.h"
#include "WGException.h"
#include "tools/tools.h"
#include <cstdint>
#include <cstring>
#include <memory>
#include <netinet/in.h>

namespace WireGuard {
    AllowedIPs::AllowedIPs() { clear(); };

    AllowedIPs::~AllowedIPs() { clear(); }

    void WireGuard::AllowedIPs::addPeer(const std::shared_ptr<Peer> &peer) {
        std::lock_guard<std::mutex> lock(mutex);
        std::vector<IPAddress> allowedIps = peer->getAllowedIps();
        for (IPAddress item: allowedIps) {
            if (item.family == IPAddress::IPv4) {
                //                uint8_t ipBytes[4];
                LOG_INFO("ip bin: %{public}s", item.toIpHex().c_str());
                const uint8_t *ipBytes = reinterpret_cast<const uint8_t *>(&item.ip.ipv4);
                LOG_INFO("ip bin ipBytes: %{public}s", Crypto::bin2Hex(ipBytes, 4).c_str());
                uint32_t cidr = item.cidr > 0 ? item.cidr : (4 * 8); // 32
                insertTrieNode(ipv4Root, ipBytes, sizeof(uint32_t), cidr, peer);
            } else {
                uint32_t cidr = item.cidr > 0 ? item.cidr : (16 * 8); // 128
                insertTrieNode(ipv6Root, item.ip.ipv6, 16, cidr, peer);
            }
        }
    }

    std::shared_ptr<Peer> WireGuard::AllowedIPs::findPeer(const IPAddress &address) {
        if (address.family == IPAddress::IPv4) {
            //            std::vector<uint8_t> data(4);
            //            auto ip = ntohl(address.ip.ipv4);
            //            std::memcpy(data.data(), &ip, 4);
            auto ip = reinterpret_cast<const uint8_t *>(&address.ip.ipv4);
            return findPeer(address.family, ip, sizeof(address.ip.ipv4));
        } else {
            return findPeer(address.family, address.ip.ipv6, sizeof(address.ip.ipv6));
        }
    }

    std::shared_ptr<Peer> WireGuard::AllowedIPs::findPeer(const IPAddress::Family &family, const uint8_t *ip,
                                                          const size_t &ipLen) {
        std::lock_guard<std::mutex> lock(mutex);
        if (family == IPAddress::IPv4) {
            return findPeerForNodeTree(ipv4Root, ip, ipLen);
        } else {
            return findPeerForNodeTree(ipv6Root, ip, ipLen);
        }
    }

    void WireGuard::AllowedIPs::insertTrieNode(std::unique_ptr<TrieNode> &index, const uint8_t *ip, const size_t ipLen,
                                               const uint32_t cidr, const std::shared_ptr<Peer> &peer) {
        if (!index) {
            return;
        }
        // 会自我调用，不可加锁
        if (!peer) {
            // 不会为null都是判断非空后才传入
            throw WGException("index or peer is null");
            return;
        }

        // 先判断是是否一致
        // 根节点不参与判断
        if (!index->isRoot()) {
            // 如果不是root，就判断是否一致
            // 判断 索引index 是否匹配
            // 如果完全匹配，则表示更新 peer 或者表示peer冲突抛出异常
            if (index->cidr == cidr && index->bits.size() == ipLen) {
                if (std::memcmp(index->bits.data(), ip, ipLen) == 0) {
                    // ip 和 掩码完全一致
                    //                    if (index->peer.expired()) {
                    //                        // peer 早已存在 判断是否需要抛出异常有重复
                    //                    }
                    // 设置peer
                    index->peer = peer;
                    return;
                }
            }
        }

        // 判断子节点
        auto nextNodeIndex = index->isRoot() ? (ip[0] >> 7) & 1 : index->chooseBit(ip, ipLen);
        std::unique_ptr<TrieNode> &next = index->child[nextNodeIndex];
        if (next) {
            // 判断下一个索引是否为当前索引的父节点
            bool isParent = next->cidr < cidr && Tools::IP::prefixMatches(next.get(), ip);
            if (isParent) {
                // 如果是，则自回调
                insertTrieNode(next, ip, ipLen, cidr, peer);
                return;
            }
        }

        // 否则。则表示当前ip是下一个节点的父节点，需要插入到index 和 next 之间
        // 空子节点，直接创建
        auto newNode = std::make_unique<TrieNode>();
        newNode->peer = peer;
        newNode->cidr = cidr;
        newNode->bits.assign(ip, ip + ipLen);
        //        newNode->bits.reserve(ipLen);
        //        std::memcpy(newNode->bits.data(), ip, ipLen);
        if (next) {
            // 如果next存在，且代码走到这儿，则表示 next 是 newNode的子叶
            // 将next移动过来
            newNode->child[newNode->chooseBit(next->bits.data(), next->bits.size())] = std::move(next);
        }
        // 将newNode 添加入 当前索引
        index->child[index->chooseBit(ip, ipLen)] = std::move(newNode);
    }

    std::shared_ptr<Peer> WireGuard::AllowedIPs::findPeerForNodeTree(const std::unique_ptr<TrieNode> &index,
                                                                     const uint8_t *ip, const size_t len) const {
        if (!index) {
            return nullptr;
        }
        // 会自我调用，不可加锁
        auto bit = index->isRoot() ? (ip[0] >> 7) & 1 : index->chooseBit(ip, len);
        // 判断子节点
        const std::unique_ptr<TrieNode> &next = index->child[bit];
        if (next) {
            // 优先返回最深的索引
            // 会一直匹配到ip位的值不一样为止，可以保证获取的索引一定是掩码最大的情况
            // 会一直递归到叶子节点或空节点，然后从底向上返回第一个匹配的 peer，保证返回最长前缀匹配的结果。
            auto matchIndex = findPeerForNodeTree(next, ip, len);
            // 如果最深的索引有匹配到结果，就直接返回
            if (matchIndex) {
                return matchIndex;
            }
            // 如果不匹配，会一层一层向上依次匹配索引
        }
        // 如果没有子索引，就开始判断是否符合
        // root 直接跳过
        if (index->isRoot()) {
            return nullptr;
        }
        // 判断ip是否匹配索引
        bool isMatch = Tools::IP::prefixMatches(index.get(), ip);
        if (isMatch && index->peer.lock()) {
            return index->peer.lock();
        } else {
            return nullptr;
        }
    }

    void AllowedIPs::clear() {
        std::lock_guard<std::mutex> lock(mutex);
        // 初始化 root 节点 全部清空
        ipv4Root = std::make_unique<TrieNode>();
        ipv4Root->setRoot(IPAddress::IPv4);
        ipv6Root = std::make_unique<TrieNode>();
        ipv6Root->setRoot(IPAddress::IPv6);
    }

    std::string WireGuard::AllowedIPs::printNode(const TrieNode *node, const std::string prefix) {
        if (!node) {
            return "null def";
        }
        std::string msg{};
        msg += prefix;
        auto ip = node->bits.size() <= 4
                      ? Tools::ipv4_to_string(node->bits.data())
                      : Tools::ipv6_to_string(node->bits.data());
        msg = "node: (" + ip + "/" + Crypto::bin2Hex(node->bits.data(), node->bits.size()) + ")";

        msg += "/掩码=";
        msg += std::to_string(node->cidr);
        msg += ("\n");

        msg += prefix;
        msg += ("\tchild=0\n");

        msg += prefix + "\t\t";
        msg += (printNode(node->child[0].get(), prefix + "\t")).append("\n");

        msg += prefix;
        msg += ("\tchild=1\n");

        msg += prefix + "\t\t";
        msg += (printNode(node->child[1].get(), prefix + "\t")).append("\n");
        return msg;
    }

    void WireGuard::AllowedIPs::debugPrint() {
        if (ipv4Root) {
            auto msg = printNode(ipv4Root.get());
            LOG_INFO("ipv4Node %{public}s", msg.c_str());
        }

        if (ipv6Root) {
            auto msg = printNode(ipv6Root.get());
            LOG_INFO("ipv6Node %{public}s", msg.c_str());
        }
    }
}
