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
 *  并发访问安全：使用互斥锁保护 trie 树的读写操作
 *  该模块使用 trie 树（前缀树）数据结构来存储 IP 前缀，支持高效的插入、删除和查找操作。
 *  最长前缀匹配算法：当多个前缀匹配时，返回掩码最长的匹配结果。
 * Created on 2026/3/18.
 * @author leojay`fu
 */

#include "allowedips.h"
#include "WGException.h"
#include "tools.h"
#include <cstdint>
#include <cstring>
#include <memory>
#include <netinet/in.h>

namespace WireGuard {
    AllowedIPs::AllowedIPs() { clear(); };

    AllowedIPs::~AllowedIPs() { clear(); }

    /**
     * @brief 将 IP 地址按 CIDR 掩码进行处理，只保留网络位
     *
     * 例如：10.0.0.1/24 → 10.0.0.0（后8位清零）
     *
     * @param ip 输入的 IP 地址字节数组（网络字节序）
     * @param ipLen IP 地址长度（IPv4=4, IPv6=16）
     * @param cidr 前缀长度
     * @param result 输出的掩码后的 IP 地址（长度必须 >= ipLen）
     */
    void WireGuard::AllowedIPs::applyMask(const uint8_t *ip, size_t ipLen, uint32_t cidr, uint8_t *result) {
        std::memcpy(result, ip, ipLen);

        size_t fullBytes = cidr / 8;
        size_t remainingBits = cidr % 8;

        if (fullBytes < ipLen) {
            if (remainingBits > 0) {
                result[fullBytes] &= (0xFF << (8 - remainingBits));
                fullBytes++;
            }
            for (size_t i = fullBytes; i < ipLen; ++i) {
                result[i] = 0;
            }
        }
    }

    /**
     * @brief 将 Peer 的所有允许 IP 地址前缀添加到路由表中
     *
     * 遍历 Peer 的 allowedIps 列表，将每个 IP 地址前缀插入到对应的 trie 树中：
     * - IPv4 地址插入到 ipv4Root 树
     * - IPv6 地址插入到 ipv6Root 树
     *
     * 如果 CIDR 未指定（<= 0），使用默认值：
     * - IPv4 默认 /32（单个主机）
     * - IPv6 默认 /128（单个主机）
     *
     * 重要：插入前会对 IP 地址进行掩码处理，只保留网络位。
     * 例如：10.0.0.1/24 会被转换为 10.0.0.0/24 存储。
     *
     * @param peer 待添加的 Peer 指针
     */
    void WireGuard::AllowedIPs::addPeer(const std::shared_ptr<Peer> &peer) {
        std::lock_guard<std::mutex> lock(mutex);
        std::vector<IpAddressArea> allowedIps = peer->getAllowedIps();
        for (IpAddressArea item: allowedIps) {
            if (item.address.family == IPAddress::IPv4) {
                LOG_INFO("ip bin: %{public}s", item.address.toIpHex().c_str());
                // CIDR=255（uint8_t -1）表示未设置掩码，使用默认值 /32
                const uint32_t cidr = item.cidr != 255 ? item.cidr : (4 * 8);
                uint8_t maskedIp[4];
                applyMask(reinterpret_cast<const uint8_t *>(&item.address.ip.ipv4), 4, cidr, maskedIp);
                LOG_INFO("ip bin ipBytes: %{public}s", crypto::bin2Hex(maskedIp, 4).c_str());
                insertTrieNode(ipv4Root, maskedIp, sizeof(uint32_t), cidr, peer);
            } else {
                // CIDR=255（uint8_t -1）表示未设置掩码，使用默认值 /128
                const uint32_t cidr = item.cidr != 255 ? item.cidr : (16 * 8);
                uint8_t maskedIp[16];
                applyMask(item.address.ip.ipv6, 16, cidr, maskedIp);
                insertTrieNode(ipv6Root, maskedIp, 16, cidr, peer);
            }
        }
    }

    /**
     * @brief 根据 IPAddress 对象查找匹配的 Peer（最长前缀匹配）
     *
     * 根据 IP 地址类型选择对应的 trie 树进行查找：
     * - IPv4 地址在 ipv4Root 树中查找
     * - IPv6 地址在 ipv6Root 树中查找
     *
     * @param address 待查找的 IPAddress 对象
     * @return 匹配到的 Peer 指针，如果没有匹配返回 nullptr
     */
    std::shared_ptr<Peer> WireGuard::AllowedIPs::findPeer(const IPAddress &address) {
        if (address.family == IPAddress::IPv4) {
            auto ip = reinterpret_cast<const uint8_t *>(&address.ip.ipv4);
            return findPeer(address.family, ip, sizeof(address.ip.ipv4));
        } else {
            return findPeer(address.family, address.ip.ipv6, sizeof(address.ip.ipv6));
        }
    }

    /**
     * @brief 根据 IP 地址原始字节查找匹配的 Peer（最长前缀匹配）
     *
     * 线程安全版本，内部使用互斥锁保护 trie 树的读操作。
     * 根据 IP 地址类型选择对应的 trie 树进行查找。
     *
     * @param family IP 地址类型（IPv4 或 IPv6）
     * @param ip 待查找的 IP 地址字节数组（网络字节序）
     * @param ipLen IP 地址长度（IPv4=4, IPv6=16）
     * @return 匹配到的 Peer 指针，如果没有匹配返回 nullptr
     */
    std::shared_ptr<Peer> WireGuard::AllowedIPs::findPeer(const IPAddress::Family &family, const uint8_t *ip,
                                                          const size_t &ipLen) {
        std::lock_guard<std::mutex> lock(mutex);
        if (family == IPAddress::IPv4) {
            return findPeerForNodeTree(ipv4Root, ip, ipLen);
        } else {
            return findPeerForNodeTree(ipv6Root, ip, ipLen);
        }
    }

    /**
     * @brief 向 trie 树中插入 IP 前缀节点
     *
     * 插入逻辑说明：
     * 1. 如果当前节点与待插入 IP 完全匹配（相同 IP 和 CIDR），更新 peer 引用
     * 2. 如果子节点存在且是待插入 IP 的父节点（子节点 CIDR 更小且前缀匹配），递归插入到子节点
     * 3. 如果子节点不存在，直接创建新节点作为子节点
     * 4. 如果子节点存在但不是父节点，计算两者的公共前缀：
     *    - 公共前缀小于两者的 CIDR：创建中间节点，将两者作为其子节点
     *    - 新节点是子节点的父节点：将子节点挂到新节点下
     *    - 否则：递归插入到子节点
     *
     * @param index 当前遍历到的 trie 节点
     * @param ip 待插入的 IP 地址（网络字节序）
     * @param ipLen IP 地址长度（IPv4=4, IPv6=16）
     * @param cidr 前缀长度（如 24 表示 /24）
     * @param peer 关联的 Peer 指针
     */
    void WireGuard::AllowedIPs::insertTrieNode(std::unique_ptr<TrieNode> &index, const uint8_t *ip, const size_t ipLen,
                                               const uint32_t cidr, const std::shared_ptr<Peer> &peer) {
        if (!index) {
            return;
        }

        if (!peer) {
            throw WGException("index or peer is null");
            return;
        }

        // 默认路由（CIDR=0）匹配所有 IP，直接设置在根节点上
        if (cidr == 0) {
            index->peer = peer;
            index->cidr = 0;
            index->bits.assign(ip, ip + ipLen);
            return;
        }

        // 如果当前节点不是根节点，检查是否与待插入 IP 完全匹配
        if (!index->isRoot()) {
            if (index->cidr == cidr && index->bits.size() == ipLen) {
                if (std::memcmp(index->bits.data(), ip, ipLen) == 0) {
                    // IP 和 CIDR 完全一致，更新 peer 引用
                    index->peer = peer;
                    return;
                }
            }
        }

        // 计算下一个子节点的索引
        auto nextNodeIndex = index->isRoot() ? (ip[0] >> 7) & 1 : index->chooseBit(ip, ipLen);
        std::unique_ptr<TrieNode> &next = index->child[nextNodeIndex];

        // 如果子节点存在，先检查是否完全匹配（相同 IP 和 CIDR）
        if (next) {
            // 检查子节点是否与待插入 IP 完全匹配（相同 IP 和 CIDR）
            if (next->cidr == cidr && next->bits.size() == ipLen) {
                if (std::memcmp(next->bits.data(), ip, ipLen) == 0) {
                    // IP 和 CIDR 完全一致，更新 peer 引用
                    next->peer = peer;
                    return;
                }
            }

            // 判断下一个索引是否为当前索引的父节点
            bool isParent = next->cidr < cidr && Tools::IP::prefixMatches(next.get(), ip);
            if (isParent) {
                // 如果是，则自回调
                insertTrieNode(next, ip, ipLen, cidr, peer);
                return;
            }
        }

        // 创建新节点
        auto newNode = std::make_unique<TrieNode>();
        newNode->peer = peer;
        newNode->cidr = cidr;
        newNode->bits.assign(ip, ip + ipLen);

        // 子节点不存在，直接挂载
        if (!next) {
            index->child[nextNodeIndex] = std::move(newNode);
            return;
        }

        // 计算新节点与现有子节点的公共前缀位数
        uint8_t common = Tools::IP::commonBits(newNode->bits.data(), next->bits.data(), ipLen);

        if (common < newNode->cidr && common < next->cidr) {
            // 情况1：公共前缀小于两者的 CIDR，需要创建中间节点
            auto intermediate = std::make_unique<TrieNode>();
            intermediate->cidr = common;
            intermediate->bits.assign(ipLen, 0);
            // 按公共前缀位数进行掩码处理，只保留前 common 位
            applyMask(ip, ipLen, common, intermediate->bits.data());

            // 根据公共前缀后的位值，将两个节点挂到中间节点的不同子节点
            uint8_t nextBit = intermediate->chooseBit(next->bits.data(), next->bits.size());
            intermediate->child[nextBit] = std::move(next);

            uint8_t newBit = intermediate->chooseBit(newNode->bits.data(), newNode->bits.size());
            intermediate->child[newBit] = std::move(newNode);

            // 将中间节点挂载到当前节点
            index->child[nextNodeIndex] = std::move(intermediate);
        } else if (common >= newNode->cidr && Tools::IP::prefixMatches(next.get(), ip)) {
            // 情况2：新节点是现有子节点的父节点，将子节点挂到新节点下
            newNode->child[newNode->chooseBit(next->bits.data(), next->bits.size())] = std::move(next);
            index->child[nextNodeIndex] = std::move(newNode);
        } else {
            // 情况3：新节点应该插入到现有子节点的子树中，递归处理
            insertTrieNode(next, ip, ipLen, cidr, peer);
        }
    }

    /**
     * @brief 在 trie 树中查找匹配指定 IP 地址的 Peer（最长前缀匹配）
     *
     * 查找逻辑说明：
     * 1. 如果当前节点为空，返回 nullptr
     * 2. 根据 IP 地址的当前位选择子节点
     * 3. 优先递归查找子节点（深度优先），如果找到匹配则直接返回（保证最长前缀匹配）
     * 4. 如果子节点没有匹配，检查当前节点是否匹配：
     *    - 根节点直接跳过
     *    - 非根节点检查 IP 是否匹配当前节点的前缀
     *    - 如果匹配且有 peer 引用，返回 peer
     *    - 否则返回 nullptr
     *
     * 该算法保证返回最长前缀匹配的结果，因为深度优先搜索会优先返回更深层的匹配。
     *
     * @param index 当前遍历到的 trie 节点
     * @param ip 待查找的 IP 地址（网络字节序）
     * @param len IP 地址长度（IPv4=4, IPv6=16）
     * @return 匹配到的 Peer 指针，如果没有匹配返回 nullptr
     */
    std::shared_ptr<Peer> WireGuard::AllowedIPs::findPeerForNodeTree(const std::unique_ptr<TrieNode> &index,
                                                                     const uint8_t *ip, const size_t len) const {
        if (!index) {
            return nullptr;
        }

        // 根据 IP 地址的当前位选择子节点
        auto bit = index->isRoot() ? (ip[0] >> 7) & 1 : index->chooseBit(ip, len);
        const std::unique_ptr<TrieNode> &next = index->child[bit];

        // 深度优先搜索：优先查找子节点，保证最长前缀匹配
        if (next) {
            auto matchPeer = findPeerForNodeTree(next, ip, len);
            if (matchPeer) {
                return matchPeer;
            }
        }

        // 子节点没有匹配，检查当前节点
        // 根节点如果设置了 peer（默认路由 CIDR=0），则作为最后兜底返回
        if (index->isRoot()) {
            if (index->peer.lock()) {
                return index->peer.lock();
            }
            return nullptr;
        }

        // 判断 IP 是否匹配当前节点的前缀
        bool isMatch = Tools::IP::prefixMatches(index.get(), ip);
        if (isMatch && index->peer.lock()) {
            return index->peer.lock();
        } else {
            return nullptr;
        }
    }

    /**
     * @brief 清空路由表中的所有节点
     *
     * 创建新的根节点，将 IPv4 和 IPv6 的 trie 树全部重置为空。
     * 线程安全，内部使用互斥锁保护。
     */
    void AllowedIPs::clear() {
        std::lock_guard<std::mutex> lock(mutex);
        ipv4Root = std::make_unique<TrieNode>();
        ipv4Root->setRoot(IPAddress::IPv4);
        ipv6Root = std::make_unique<TrieNode>();
        ipv6Root->setRoot(IPAddress::IPv6);
    }

    /**
     * @brief 递归打印 trie 树节点（用于调试）
     *
     * 以缩进格式打印节点信息，包括：
     * - IP 地址（点分十进制或冒号分隔格式）
     * - 二进制表示（十六进制）
     * - CIDR 前缀长度
     * - 子节点信息（递归打印）
     *
     * @param node 当前节点指针
     * @param prefix 缩进前缀（用于格式化输出）
     * @return 格式化后的节点信息字符串
     */
    std::string WireGuard::AllowedIPs::printNode(const TrieNode *node, const std::string prefix) {
        if (!node) {
            return "null def";
        }
        std::string msg{};
        msg += prefix;
        auto ip = node->bits.size() <= 4
                      ? Tools::ipv4_to_string(node->bits.data())
                      : Tools::ipv6_to_string(node->bits.data());
        msg = "node: (" + ip + "/" + crypto::bin2Hex(node->bits.data(), node->bits.size()) + ")";

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

    /**
     * @brief 打印整个路由表结构（用于调试）
     *
     * 分别打印 IPv4 和 IPv6 的 trie 树结构，便于调试和验证路由表状态。
     */
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
