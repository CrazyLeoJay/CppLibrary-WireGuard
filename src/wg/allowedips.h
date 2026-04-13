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
// Created on 2026/3/18.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef WIREGUARD_ALLOWEDIPS_H
#define WIREGUARD_ALLOWEDIPS_H


#include "peer.h"
#include "entity.h"
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <memory>

namespace WireGuard {
    class AllowedIPs {
    public:
        explicit AllowedIPs();

        ~AllowedIPs();

        void addPeer(const std::shared_ptr<Peer> &peer);

        std::shared_ptr<Peer> findPeer(const IPAddress &address);

        std::shared_ptr<Peer> findPeer(const IPAddress::Family &family, const uint8_t *ip, const size_t &ipLen);

        /**
         * 清空所有索引
         */
        void clear();

        void debugPrint();

    private:
        std::unique_ptr<TrieNode> ipv4Root{}; ///< IPv4 虚拟根节点（cidr=255）
        std::unique_ptr<TrieNode> ipv6Root{}; ///< IPv6 虚拟根节点（cidr=255）
        mutable std::mutex mutex; ///< 读写锁（保护 Trie 树）


        /**
         * 给 根索引添加 节点
         *
         * @param root  要操作的索引
         * @param ip    插入的ip
         * @param ipLen ip 长度
         * @param cidr  掩码
         * @param peer  记录的Peer
         */
        void insertTrieNode(std::unique_ptr<TrieNode> &root, const uint8_t *ip, const size_t ipLen, const uint32_t cidr,
                            const std::shared_ptr<Peer> &peer);

        /**
         * 通过ip查找树获取 Peer 指针
         *
         * @param index 索引类
         * @param ip 查询的ip
         * @return Peer
         */
        std::shared_ptr<Peer> findPeerForNodeTree(const std::unique_ptr<TrieNode> &index, const uint8_t *ip,
                                                  const size_t len) const;


        std::string printNode(const TrieNode *node, const std::string prefix = "");
    };
} // namespace WireGuard

#endif // WIREGUARD_ALLOWEDIPS_H