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
/**
 * Created by Leojay on 2026/7/16.
 *
 * AllowedIPs 单元测试
 * 测试 IPv4 和 IPv6 地址通过 AllowedIPs 路由表时的正确识别
 *
 * 使用数据驱动测试，可以通过修改 testData 中的配置动态添加/删除测试用例。
 */

#include <gtest/gtest.h>
#include <arpa/inet.h>
#include <sodium.h>
#include <string>
#include <vector>

#include "allowedips.h"
#include "entity.h"
#include "peer.h"
#include "tools/conf_file.h"
#include "test_params.h"

using namespace WireGuard;

// ========== 测试辅助函数 ==========

/**
 * 从 IPv4 字符串创建 IPAddress
 */
static IPAddress makeIpv4(const std::string &ipStr) {
    return Tools::ipAddressForIpv4(ipStr);
}

/**
 * 从 IPv6 字符串创建 IPAddress
 */
static IPAddress makeIpv6(const std::string &ipStr) {
    return Tools::ipAddressForIpv6(ipStr);
}

/**
 * 创建一个 PeerConfig，包含指定的 allowedIPs
 * @param name Peer 名称标识（用于日志区分）
 * @param allowedIps 允许的 IP 地址区域列表
 */
static PeerConfig makePeerConfig(const std::string &name,
                                 const std::vector<std::pair<std::string, uint8_t> > &allowedIps) {
    PeerConfig config{};
    config.public_key = client_public;
    config.keepaliveInterval = 25;
    for (const auto &item: allowedIps) {
        IpAddressArea area{};
        if (item.first.find(':') != std::string::npos) {
            area.address = makeIpv6(item.first);
        } else {
            area.address = makeIpv4(item.first);
        }
        area.cidr = item.second;
        config.allowedIps.push_back(area);
    }
    return config;
}

/**
 * 创建一个 Peer 对象
 * @param index Peer 索引
 * @param name Peer 名称标识
 * @param allowedIps 允许的 IP 地址区域列表（IP字符串, CIDR）
 */
static std::shared_ptr<Peer> makePeer(size_t index, const std::string &name,
                                      const std::vector<std::pair<std::string, uint8_t> > &allowedIps) {
    ContentKey contentKey(client_private);
    PeerConfig config = makePeerConfig(name, allowedIps);
    return std::make_shared<Peer>(index, contentKey, config);
}

// ========== 数据驱动测试框架 ==========

/**
 * 测试用例数据结构
 */
struct RouteTestCase {
    std::string testName; // 测试名称
    std::string peerName; // Peer 名称
    std::vector<std::pair<std::string, uint8_t> > allowedIps; // Peer 的 allowedIPs
};

/**
 * 查找测试用例数据结构
 */
struct LookupTestCase {
    std::string testName; // 测试名称
    std::string lookupIp; // 要查找的 IP
    int expectPeerIndex; // 期望的 Peer 索引（-1 表示期望 nullptr）
};

/**
 * 测试夹具：管理多个 Peer 和 AllowedIPs 实例
 * 注意：Peer 类内部以 const 引用存储 ContentKey 和 PeerConfig，
 * 因此这两个对象必须比 Peer 活得更久，这里用 vector 持有它们。
 */
class AllowedIPsTest : public ::testing::Test {
protected:
    AllowedIPs allowedIps;
    std::vector<std::shared_ptr<Peer> > peers;
    // 保持 ContentKey 和 PeerConfig 的生命周期，防止 Peer 悬空引用
    std::vector<std::shared_ptr<ContentKey> > contentKeys;
    std::vector<std::shared_ptr<PeerConfig> > peerConfigs;

    void SetUp() override {
        // 初始化 libsodium（ContentKey 构造时需要）
        if (sodium_init() < 0) {
            FAIL() << "sodium_init() failed";
        }
        allowedIps.clear();
        peers.clear();
        contentKeys.clear();
        peerConfigs.clear();
    }

    void TearDown() override {
    }

    /**
     * 创建一个 Peer 对象，并保持 ContentKey 和 PeerConfig 的生命周期
     * @param index Peer 索引
     * @param name Peer 名称标识
     * @param allowedIps 允许的 IP 地址区域列表（IP字符串, CIDR）
     */
    std::shared_ptr<Peer> createPeer(size_t index, const std::string &name,
                                     const std::vector<std::pair<std::string, uint8_t> > &allowedIpList) {
        auto contentKey = std::make_shared<ContentKey>(client_private);
        auto config = std::make_shared<PeerConfig>(makePeerConfig(name, allowedIpList));
        contentKeys.push_back(contentKey);
        peerConfigs.push_back(config);
        return std::make_shared<Peer>(index, *contentKey, *config);
    }

    /**
     * 根据测试用例列表批量添加 Peer
     * @param testCases Peer 路由配置列表
     */
    void setupPeers(const std::vector<RouteTestCase> &testCases) {
        for (size_t i = 0; i < testCases.size(); i++) {
            auto peer = createPeer(i, testCases[i].peerName, testCases[i].allowedIps);
            peers.push_back(peer);
            allowedIps.addPeer(peer);
        }
    }

    /**
     * 执行查找并验证结果
     * @param lookupIp 要查找的 IP 字符串
     * @param expectPeerIndex 期望匹配的 Peer 索引（-1 表示期望 nullptr）
     */
    void verifyLookup(const std::string &lookupIp, int expectPeerIndex) {
        IPAddress addr;
        if (lookupIp.find(':') != std::string::npos) {
            addr = makeIpv6(lookupIp);
        } else {
            addr = makeIpv4(lookupIp);
        }

        auto result = allowedIps.findPeer(addr);

        if (expectPeerIndex < 0) {
            EXPECT_EQ(result, nullptr) << "查找 IP " << lookupIp << " 期望返回 nullptr，但返回了非空 Peer";
        } else {
            ASSERT_NE(result, nullptr) << "查找 IP " << lookupIp << " 期望返回 Peer[" << expectPeerIndex
                    << "]，但返回了 nullptr";
            EXPECT_EQ(result->getIndex(), static_cast<size_t>(expectPeerIndex))
                    << "查找 IP " << lookupIp << " 期望返回 Peer[" << expectPeerIndex << "]，但返回了 Peer["
                    << result->getIndex() << "]";
        }
    }

    /**
     * 批量执行查找测试
     * @param lookupCases 查找测试用例列表
     */
    void runLookups(const std::vector<LookupTestCase> &lookupCases) {
        for (const auto &tc: lookupCases) {
            verifyLookup(tc.lookupIp, tc.expectPeerIndex);
        }
    }
};

// ========== IPv4 基础路由测试 ==========

/**
 * 在此处添加或删除 IPv4 测试用例
 * 格式：{ "测试名称", "Peer名称", { {"IP/CIDR", 掩码}, ... } }
 */
const std::vector<RouteTestCase> ipv4RouteCases = {
    {"PeerA_10.0.0.0_24", "PeerA", {{"10.0.0.0", 24}}},
    {"PeerB_10.1.0.0_24", "PeerB", {{"10.1.0.0", 24}}},
    {"PeerC_192.168.1.0_24", "PeerC", {{"192.168.1.0", 24}}},
    {"PeerD_10.0.0.0_8", "PeerD", {{"10.0.0.0", 8}}},
};

/**
 * 在此处添加或删除 IPv4 查找测试用例
 * 格式：{ "测试名称", "查找IP", 期望Peer索引(-1=nullptr) }
 */
const std::vector<LookupTestCase> ipv4LookupCases = {
    {"match_PeerA_exact", "10.0.0.1", 0},
    {"match_PeerA_range", "10.0.0.200", 0},
    {"match_PeerB_exact", "10.1.0.1", 1},
    {"match_PeerB_range", "10.1.0.254", 1},
    {"match_PeerC_exact", "192.168.1.1", 2},
    {"match_PeerC_range", "192.168.1.100", 2},
    {"match_longest_prefix", "10.0.0.50", 0},
    {"match_PeerD_10.2.3.4", "10.2.3.4", 3},
    {"match_PeerD_10.255.255.255", "10.255.255.255", 3},
    {"no_match_172.16.0.1", "172.16.0.1", -1},
    {"no_match_8.8.8.8", "8.8.8.8", -1},
};

TEST_F(AllowedIPsTest, IPv4_BasicRouting) {
    setupPeers(ipv4RouteCases);
    runLookups(ipv4LookupCases);
}

// ========== IPv6 基础路由测试 ==========

/**
 * 在此处添加或删除 IPv6 测试用例
 */
const std::vector<RouteTestCase> ipv6RouteCases = {
    {"PeerA_fd00_1__64", "PeerA", {{"fd00::1", 64}}},
    {"PeerB_fd00_2__64", "PeerB", {{"fd00:2::1", 64}}},
    {"PeerC_2001_db8_1__48", "PeerC", {{"2001:db8:1::", 48}}},
    {"PeerD_fd00__8", "PeerD", {{"fd00::", 8}}},
};

/**
 * 在此处添加或删除 IPv6 查找测试用例
 */
const std::vector<LookupTestCase> ipv6LookupCases = {
    {"match_PeerA_exact", "fd00::1", 0},
    {"match_PeerA_range", "fd00::ffff", 0},
    {"match_PeerA_large", "fd00:0:0:0:0:0:0:1234", 0},
    {"match_PeerB_exact", "fd00:2::1", 1},
    {"match_PeerB_range", "fd00:2::abcd", 1},
    {"match_PeerC_exact", "2001:db8:1::1", 2},
    {"match_PeerC_range", "2001:db8:1:2:3:4:5:6", 2},
    {"match_PeerD_other", "fd00:abcd::1", 3},
    {"match_PeerD_large", "fd00:ffff:ffff:ffff:ffff:ffff:ffff:ffff", 3},
    {"no_match_fe80", "fe80::1", -1},
    {"no_match_2001_db8_2", "2001:db8:2::1", -1},
};

TEST_F(AllowedIPsTest, IPv6_BasicRouting) {
    setupPeers(ipv6RouteCases);
    runLookups(ipv6LookupCases);
}

// ========== 最长前缀匹配测试 ==========

/**
 * 测试当多个前缀匹配时，返回掩码最长的匹配结果
 */
TEST_F(AllowedIPsTest, LongestPrefixMatch_IPv4) {
    // Peer0: 10.0.0.0/8
    // Peer1: 10.0.0.0/24
    // Peer2: 10.0.0.1/32
    setupPeers({
        {"Peer0_10.0.0.0_8", "Peer0", {{"10.0.0.0", 8}}},
        {"Peer1_10.0.0.0_24", "Peer1", {{"10.0.0.0", 24}}},
        {"Peer2_10.0.0.1_32", "Peer2", {{"10.0.0.1", 32}}},
    });

    // 10.0.0.1 应该匹配 /32（Peer2，最长前缀）
    verifyLookup("10.0.0.1", 2);

    // 10.0.0.2 应该匹配 /24（Peer1）
    verifyLookup("10.0.0.2", 1);

    // 10.0.1.1 应该匹配 /8（Peer0）
    verifyLookup("10.0.1.1", 0);

    // 10.255.255.255 应该匹配 /8（Peer0）
    verifyLookup("10.255.255.255", 0);
}

TEST_F(AllowedIPsTest, LongestPrefixMatch_IPv6) {
    // Peer0: fd00::/8
    // Peer1: fd00::/64
    // Peer2: fd00::1/128
    setupPeers({
        {"Peer0_fd00__8", "Peer0", {{"fd00::", 8}}},
        {"Peer1_fd00__64", "Peer1", {{"fd00::", 64}}},
        {"Peer2_fd00__1_128", "Peer2", {{"fd00::1", 128}}},
    });

    // fd00::1 应该匹配 /128（Peer2）
    verifyLookup("fd00::1", 2);

    // fd00::2 应该匹配 /64（Peer1）
    verifyLookup("fd00::2", 1);

    // fd00:1:: 应该匹配 /8（Peer0）
    verifyLookup("fd00:1::", 0);

    // fd00:ffff:ffff:ffff:ffff:ffff:ffff:ffff 应该匹配 /8（Peer0）
    verifyLookup("fd00:ffff:ffff:ffff:ffff:ffff:ffff:ffff", 0);
}

// ========== 相同前缀覆盖测试 ==========

/**
 * 测试相同网络前缀的路由规则，后添加的会覆盖先添加的
 */
TEST_F(AllowedIPsTest, PeerOverride_SameNetwork_IPv4) {
    // 10.0.0.1/24 和 10.0.0.2/24 掩码后都是 10.0.0.0/24
    setupPeers({
        {"PeerA_10.0.0.1_24", "PeerA", {{"10.0.0.1", 24}}},
        {"PeerB_10.0.0.2_24", "PeerB", {{"10.0.0.2", 24}}},
    });

    // 10.0.0.100 应该返回 PeerB（后添加的覆盖了 PeerA）
    verifyLookup("10.0.0.100", 1);

    // 10.0.0.0 也应该返回 PeerB
    verifyLookup("10.0.0.0", 1);
}

TEST_F(AllowedIPsTest, PeerOverride_SameNetwork_IPv6) {
    // fd00::1/64 和 fd00::2/64 掩码后都是 fd00::/64
    setupPeers({
        {"PeerA_fd00__1_64", "PeerA", {{"fd00::1", 64}}},
        {"PeerB_fd00__2_64", "PeerB", {{"fd00::2", 64}}},
    });

    // fd00::abcd 应该返回 PeerB（后添加的覆盖了 PeerA）
    verifyLookup("fd00::abcd", 1);

    // fd00:: 也应该返回 PeerB
    verifyLookup("fd00::", 1);
}

// ========== 完全相同路由覆盖测试 ==========

/**
 * 测试完全相同的 IP 和 CIDR，后添加的 Peer 覆盖
 */
TEST_F(AllowedIPsTest, PeerOverride_ExactSame_IPv4) {
    setupPeers({
        {"PeerA", "PeerA", {{"10.0.0.0", 24}}},
        {"PeerB", "PeerB", {{"10.0.0.0", 24}}},
    });

    // 查找 10.0.0.x 应该返回 PeerB
    verifyLookup("10.0.0.50", 1);
}

TEST_F(AllowedIPsTest, PeerOverride_ExactSame_IPv6) {
    setupPeers({
        {"PeerA", "PeerA", {{"fd00::", 64}}},
        {"PeerB", "PeerB", {{"fd00::", 64}}},
    });

    // 查找 fd00::abcd 应该返回 PeerB
    verifyLookup("fd00::abcd", 1);
}

// ========== 混合 IPv4/IPv6 测试 ==========

/**
 * 测试同时存在 IPv4 和 IPv6 路由时，不会互相干扰
 */
TEST_F(AllowedIPsTest, MixedIPv4IPv6_NoInterference) {
    setupPeers({
        {"PeerA_ipv4", "PeerA", {{"10.0.0.0", 24}}},
        {"PeerB_ipv6", "PeerB", {{"fd00::", 64}}},
    });

    // IPv4 查找不应返回 IPv6 的 Peer
    verifyLookup("10.0.0.1", 0);

    // IPv6 查找不应返回 IPv4 的 Peer
    verifyLookup("fd00::1", 1);

    // IPv4 地址不应匹配 IPv6 路由
    verifyLookup("172.16.0.1", -1);

    // IPv6 地址不应匹配 IPv4 路由
    verifyLookup("fe80::1", -1);
}

// ========== 多 Peer 多路由测试 ==========

/**
 * 测试一个 Peer 拥有多个 allowedIPs
 */
TEST_F(AllowedIPsTest, SinglePeerMultipleAllowedIPs) {
    auto peer = createPeer(0, "MultiPeer", {
        {"10.0.0.0", 24},
        {"192.168.1.0", 24},
        {"fd00::", 64},
        {"2001:db8::", 32},
    });
    allowedIps.addPeer(peer);

    // 所有配置的 IP 都应该返回 Peer0
    verifyLookup("10.0.0.1", 0);
    verifyLookup("10.0.0.254", 0);
    verifyLookup("192.168.1.1", 0);
    verifyLookup("192.168.1.254", 0);
    verifyLookup("fd00::1", 0);
    verifyLookup("fd00:0:0:0:0:0:0:ffff", 0);
    verifyLookup("2001:db8::1", 0);
    verifyLookup("2001:db8:ffff::", 0);

    // 未配置的 IP 应返回 nullptr
    verifyLookup("10.1.0.1", -1);
    verifyLookup("172.16.0.1", -1);
    verifyLookup("fd01::1", -1);
    verifyLookup("fe80::1", -1);
}

// ========== 默认路由测试 ==========

/**
 * 测试 0.0.0.0/0 和 ::/0 默认路由
 */
TEST_F(AllowedIPsTest, DefaultRoute) {
    setupPeers({
        {"PeerA_default_v4", "PeerA", {{"0.0.0.0", 0}}},
        {"PeerB_default_v6", "PeerB", {{"::", 0}}},
    });

    // IPv4 任何地址都应匹配 PeerA
    verifyLookup("8.8.8.8", 0);
    verifyLookup("192.168.1.1", 0);
    verifyLookup("10.0.0.1", 0);

    // IPv6 任何地址都应匹配 PeerB
    verifyLookup("2001:db8::1", 1);
    verifyLookup("fe80::1", 1);
    verifyLookup("fd00::1", 1);
}

// ========== 单主机路由测试 ==========

/**
 * 测试 /32 (IPv4) 和 /128 (IPv6) 单主机路由
 */
TEST_F(AllowedIPsTest, SingleHostRoute) {
    setupPeers({
        {"PeerA_10.0.0.1_32", "PeerA", {{"10.0.0.1", 32}}},
        {"PeerB_fd00__1_128", "PeerB", {{"fd00::1", 128}}},
    });

    // 精确匹配
    verifyLookup("10.0.0.1", 0);
    verifyLookup("fd00::1", 1);

    // 相邻地址不应匹配
    verifyLookup("10.0.0.2", -1);
    verifyLookup("fd00::2", -1);
    verifyLookup("10.0.0.0", -1);
    verifyLookup("fd00::0", -1);
}

// ========== 查找原始字节接口测试 ==========

/**
 * 测试通过原始字节接口查找
 */
TEST_F(AllowedIPsTest, FindByRawBytes_IPv4) {
    setupPeers({
        {"PeerA", "PeerA", {{"10.0.0.0", 24}}},
    });

    // 构造 IPv4 原始字节（网络字节序）
    uint32_t ipRaw = htonl(0x0A000064); // 10.0.0.100
    auto result = allowedIps.findPeer(IPAddress::IPv4, reinterpret_cast<const uint8_t *>(&ipRaw), 4);
    ASSERT_NE(result, nullptr);
    EXPECT_EQ(result->getIndex(), 0u);
}

TEST_F(AllowedIPsTest, FindByRawBytes_IPv6) {
    setupPeers({
        {"PeerA", "PeerA", {{"fd00::", 64}}},
    });

    // 构造 IPv6 原始字节
    uint8_t ipRaw[16] = {0xfd, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x64}; // fd00::100
    auto result = allowedIps.findPeer(IPAddress::IPv6, ipRaw, 16);
    ASSERT_NE(result, nullptr);
    EXPECT_EQ(result->getIndex(), 0u);
}

// ========== 空表查找测试 ==========

/**
 * 测试空路由表的查找
 */
TEST_F(AllowedIPsTest, EmptyTable) {
    // 不添加任何 Peer，直接查找
    verifyLookup("10.0.0.1", -1);
    verifyLookup("fd00::1", -1);
    verifyLookup("0.0.0.0", -1);
    verifyLookup("::", -1);
}
