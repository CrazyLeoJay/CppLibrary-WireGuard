#include <gtest/gtest.h>
#include <arpa/inet.h>
#include <cstdio>

namespace WireGuard {
namespace Test {

TEST(ByteOrderTest, htons_ntohs_roundtrip) {
    uint16_t host_port = 51820;
    uint16_t network_port = htons(host_port);
    uint16_t converted_back = ntohs(network_port);
    
    printf("htons/ntohs 测试:\n");
    printf("  主机字节序端口: %u (0x%04X)\n", host_port, host_port);
    printf("  网络字节序端口: %u (0x%04X)\n", network_port, network_port);
    printf("  转换回主机: %u (0x%04X)\n", converted_back, converted_back);
    
    ASSERT_EQ(host_port, converted_back) << "htons/ntohs 往返转换失败";
}

TEST(ByteOrderTest, htonl_ntohl_roundtrip) {
    uint32_t host_ip = 0x0A00000A; // 10.0.0.10
    uint32_t network_ip = htonl(host_ip);
    uint32_t converted_back = ntohl(network_ip);
    
    printf("\nhtonl/ntohl 测试:\n");
    printf("  主机字节序IP(10.0.0.10): 0x%08X\n", host_ip);
    printf("  网络字节序IP: 0x%08X\n", network_ip);
    printf("  转换回主机: 0x%08X\n", converted_back);
    
    ASSERT_EQ(host_ip, converted_back) << "htonl/ntohl 往返转换失败";
}

TEST(ByteOrderTest, inet_ntop_requires_network_order) {
    uint32_t host_ip = 0x0A00000A; // 10.0.0.10 (对称，巧合)
    uint32_t host_ip_asym = 0xC0A80101; // 192.168.1.1 (非对称)
    
    uint32_t network_ip = htonl(host_ip);
    uint32_t network_ip_asym = htonl(host_ip_asym);
    
    char buf1[INET_ADDRSTRLEN];
    char buf2[INET_ADDRSTRLEN];
    char buf3[INET_ADDRSTRLEN];
    char buf4[INET_ADDRSTRLEN];
    
    inet_ntop(AF_INET, &host_ip, buf1, INET_ADDRSTRLEN);
    inet_ntop(AF_INET, &network_ip, buf2, INET_ADDRSTRLEN);
    inet_ntop(AF_INET, &host_ip_asym, buf3, INET_ADDRSTRLEN);
    inet_ntop(AF_INET, &network_ip_asym, buf4, INET_ADDRSTRLEN);
    
    printf("\ninet_ntop 测试:\n");
    printf("  对称IP 10.0.0.10:\n");
    printf("    输入主机字节序(0x%08X): %s\n", host_ip, buf1);
    printf("    输入网络字节序(0x%08X): %s\n", network_ip, buf2);
    printf("  非对称IP 192.168.1.1:\n");
    printf("    输入主机字节序(0x%08X): %s\n", host_ip_asym, buf3);
    printf("    输入网络字节序(0x%08X): %s\n", network_ip_asym, buf4);
    
    ASSERT_STREQ("192.168.1.1", buf4) << "inet_ntop 需要网络字节序输入";
}

TEST(ByteOrderTest, ipv4_address_layout) {
    uint32_t ip = 0x0A00000A; // 10.0.0.10
    uint8_t* bytes = reinterpret_cast<uint8_t*>(&ip);
    
    printf("\n小端序内存布局(IP 10.0.0.10 = 0x0A00000A):\n");
    printf("  地址[0]: 0x%02X (%d)\n", bytes[0], bytes[0]);
    printf("  地址[1]: 0x%02X (%d)\n", bytes[1], bytes[1]);
    printf("  地址[2]: 0x%02X (%d)\n", bytes[2], bytes[2]);
    printf("  地址[3]: 0x%02X (%d)\n", bytes[3], bytes[3]);
    printf("  网络字节序(大端)应该是: 0x0A 0x00 0x00 0x0A\n");
    
    ASSERT_EQ(bytes[0], 0x0A) << "小端序: 低字节在低地址";
    ASSERT_EQ(bytes[3], 0x0A) << "小端序: 高字节在高地址";
}

TEST(ByteOrderTest, sockaddr_in_layout) {
    uint32_t ip_host = 0x0A00000A; // 10.0.0.10
    uint32_t ip_network = htonl(ip_host);
    
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(51820);
    addr.sin_addr.s_addr = ip_host; // 错误：直接用主机字节序
    
    char buf[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &addr.sin_addr.s_addr, buf, INET_ADDRSTRLEN);
    
    printf("\nsockaddr_in 测试:\n");
    printf("  sin_addr.s_addr (主机字节序): 0x%08X\n", addr.sin_addr.s_addr);
    printf("  inet_ntop 解析结果: %s\n", buf);
    printf("  期望结果: 10.0.0.10\n");
}

TEST(ByteOrderTest, ipv4_mapped_address) {
    uint32_t ip_host = 0x0A00000A; // 10.0.0.10
    uint32_t ip_network = htonl(ip_host);
    
    in6_addr v4mapped{};
    memset(&v4mapped, 0, sizeof(v4mapped));
    v4mapped.s6_addr[10] = 0xFF;
    v4mapped.s6_addr[11] = 0xFF;
    memcpy(v4mapped.s6_addr + 12, &ip_network, 4); // 注意：复制网络字节序
    
    uint32_t read_back = *reinterpret_cast<uint32_t*>(v4mapped.s6_addr + 12);
    uint32_t read_back_converted = ntohl(read_back);
    
    printf("\nIPv4-mapped IPv6 测试:\n");
    printf("  s6_addr[12-15]: 0x%08X (网络字节序)\n", read_back);
    printf("  ntohl 转换后: 0x%08X\n", read_back_converted);
    printf("  原始主机字节序: 0x%08X\n", ip_host);
    
    ASSERT_EQ(read_back_converted, ip_host) << "IPv4-mapped地址需要ntohl转换";
}

} // namespace Test
} // namespace WireGuard
