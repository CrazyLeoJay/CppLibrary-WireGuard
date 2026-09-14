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
#include "gtest/gtest.h"
#include "tools/wg_dns.h"


void printIps(const std::string &domain) {
    const std::vector<WireGuard::IPAddress> allResult = WireGuard::DNS::readDomainToIpAll(domain);
    LOG_INFO("%s : ", domain.c_str());
    for (auto ip_address: allResult) {
        LOG_INFO("\t\tIP：%s", ip_address.toIpStr().c_str());
    }
}

TEST(DNS, testDomainToIp) {
    printIps("www.baidu.com");
    printIps("www.google.com");
    printIps("leojay.synology.me");
}

// ===== 原始DNS查询报文构建与解析（公网DNS直查，绕过路由器NAT硬回流） =====

TEST(DNS, buildDnsQueryStructure) {
    const auto q = WireGuard::DNS::buildDnsQuery(0x1234, "leojay.synology.me", 1);
    // 12字节Header + QNAME(1+6 + 1+8 + 1+2 + 1结束符=20) + QTYPE(2) + QCLASS(2) = 36
    ASSERT_EQ(q.size(), static_cast<size_t>(36));
    EXPECT_EQ(q[0], 0x12); // 事务ID
    EXPECT_EQ(q[1], 0x34);
    EXPECT_EQ(q[2], 0x01); // FLAGS: RD=1
    EXPECT_EQ(q[3], 0x00);
    EXPECT_EQ(q[4], 0x00); // QDCOUNT=1
    EXPECT_EQ(q[5], 0x01);
    // QNAME首标签：len=6, "leojay"
    EXPECT_EQ(q[12], 6);
    EXPECT_EQ(q[13], 'l');
    // QNAME结束符
    EXPECT_EQ(q[q.size() - 5], 0x00);
    // QTYPE=1(A)
    EXPECT_EQ(q[q.size() - 4], 0x00);
    EXPECT_EQ(q[q.size() - 3], 0x01);
    // QCLASS=1(IN)
    EXPECT_EQ(q[q.size() - 2], 0x00);
    EXPECT_EQ(q[q.size() - 1], 0x01);
}

TEST(DNS, parseDnsResponseARecord) {
    // 用查询报文拼出响应：Header+Question一致，改FLAGS为响应，追加一条A记录（带压缩指针）
    const auto query = WireGuard::DNS::buildDnsQuery(0xABCD, "leojay.synology.me", 1);
    std::vector<uint8_t> resp(query.begin(), query.end());
    resp[2] = 0x81; // QR=1, RD=1
    resp[3] = 0x80; // RA=1
    resp[6] = 0x00; // ANCOUNT=1
    resp[7] = 0x01;
    // Answer: Name=压缩指针指向偏移12, TYPE=A, CLASS=IN, TTL=60, RDLENGTH=4, RDATA=125.121.122.213
    resp.push_back(0xC0);
    resp.push_back(0x0C);
    resp.push_back(0x00);
    resp.push_back(0x01);
    resp.push_back(0x00);
    resp.push_back(0x01);
    resp.push_back(0x00);
    resp.push_back(0x00);
    resp.push_back(0x00);
    resp.push_back(60);
    resp.push_back(0x00);
    resp.push_back(0x04);
    resp.push_back(125);
    resp.push_back(121);
    resp.push_back(122);
    resp.push_back(213);

    WireGuard::IPAddress out{};
    ASSERT_TRUE(WireGuard::DNS::parseDnsResponse(resp, 0xABCD, 1, out));
    EXPECT_EQ(out.family, WireGuard::IPAddress::IPv4);
    // 网络字节序逐字节比对
    const auto *bytes = reinterpret_cast<const uint8_t *>(&out.ip.ipv4);
    EXPECT_EQ(bytes[0], 125);
    EXPECT_EQ(bytes[1], 121);
    EXPECT_EQ(bytes[2], 122);
    EXPECT_EQ(bytes[3], 213);
}

TEST(DNS, parseDnsResponseRejectsWrongId) {
    const auto query = WireGuard::DNS::buildDnsQuery(0xABCD, "a.b", 1);
    std::vector<uint8_t> resp(query.begin(), query.end());
    resp[2] = 0x81;
    resp[3] = 0x80;
    WireGuard::IPAddress out{};
    EXPECT_FALSE(WireGuard::DNS::parseDnsResponse(resp, 0x1111, 1, out));
}

TEST(DNS, parseDnsResponseSkipsCname) {
    // Answer第一条是CNAME，第二条才是A：应跳过CNAME取到A记录
    const auto query = WireGuard::DNS::buildDnsQuery(0xBEEF, "leojay.synology.me", 1);
    std::vector<uint8_t> resp(query.begin(), query.end());
    resp[2] = 0x81;
    resp[3] = 0x80;
    resp[6] = 0x00;
    resp[7] = 0x02; // ANCOUNT=2
    // Answer1: Name=指针, TYPE=5(CNAME), CLASS=IN, TTL=60, RDLENGTH=15, RDATA=指针(指向QNAME内第二个标签后)
    resp.push_back(0xC0);
    resp.push_back(0x0C);
    resp.push_back(0x00);
    resp.push_back(0x05);
    resp.push_back(0x00);
    resp.push_back(0x01);
    resp.push_back(0x00);
    resp.push_back(0x00);
    resp.push_back(0x00);
    resp.push_back(60);
    resp.push_back(0x00);
    resp.push_back(0x02);
    resp.push_back(0xC0);
    resp.push_back(0x0F); // 随意的压缩指针占位
    // Answer2: Name=指针, TYPE=A, ...
    resp.push_back(0xC0);
    resp.push_back(0x0C);
    resp.push_back(0x00);
    resp.push_back(0x01);
    resp.push_back(0x00);
    resp.push_back(0x01);
    resp.push_back(0x00);
    resp.push_back(0x00);
    resp.push_back(0x00);
    resp.push_back(30);
    resp.push_back(0x00);
    resp.push_back(0x04);
    resp.push_back(1);
    resp.push_back(2);
    resp.push_back(3);
    resp.push_back(4);

    WireGuard::IPAddress out{};
    ASSERT_TRUE(WireGuard::DNS::parseDnsResponse(resp, 0xBEEF, 1, out));
    const auto *bytes = reinterpret_cast<const uint8_t *>(&out.ip.ipv4);
    EXPECT_EQ(bytes[0], 1);
    EXPECT_EQ(bytes[3], 4);
}
