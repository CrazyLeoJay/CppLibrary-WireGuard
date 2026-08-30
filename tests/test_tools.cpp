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
 * Created by Leojay on 2026/4/4.
 *
 * @author leojay`fu
 * @email crazyleojay@163.com
 * @url https://github.com/CrazyLeoJay
 */


#include "crypto/crypto.h"
#include "crypto/nonce.h"
#include "gtest/gtest.h"
#include "tools/conf_file.h"

const WireGuard::PrivateKey client_private{
    WireGuard::crypto::base642Bin32Array("CKvZGm8S0HoQUwvUIsZ8wd39Bqt/5Z5vaJNuKX4LHGI=")
};
const WireGuard::PublicKey client_public{
    WireGuard::crypto::base642Bin32Array("gN9lnPxypH67F7KystwjDdpwNsT007AV8s/MOOc0QGM=")
};
const WireGuard::PrivateKey server_private{
    WireGuard::crypto::base642Bin32Array("6CPPJCvfaej0+lwY5amd5pKJ0WLT0JuSv0VyPnMimVE=")
};
const WireGuard::PublicKey server_public{
    WireGuard::crypto::base642Bin32Array("sMDHZrFHvyZKaYe1NYCy9+r2iR2DSQlcIFVFpeAh32A=")
};

namespace WireGuard {
    TEST(TOOLS, b64_2_hex) {
        std::string b64Str = "MDswPQmFaailKxTHciByyx5Sira4ryctoqjNrRKu828=";
        auto bin = crypto::base642Bin32Array(b64Str);
        auto hex = crypto::bin2Hex(bin.data(), bin.size());
        printf("%s", hex.c_str());
    }
}

std::string test_wg_conf = R"(
[Interface]
PrivateKey = CKvZGm8S0HoQUwvUIsZ8wd39Bqt/5Z5vaJNuKX4LHGI=
Address = 10.0.0.2/24
DNS = 8.8.8.8, 1.1.1.1
[Peer]
PublicKey = sMDHZrFHvyZKaYe1NYCy9+r2iR2DSQlcIFVFpeAh32A=
Endpoint = your.server.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
PreSharedKey = sMDHZrFHvyZKaYe1NYCy9+r2iR2DSQlcIFVFpeAh32A=
)";

TEST(tools_conf, readWireGuardConfFileToJson) {

    LOG_INFO("read file: \n%s" , test_wg_conf.c_str());

    const auto config = WireGuard::Tools::readConfFileToEntity(test_wg_conf);
    const auto str = WireGuard::Tools::wgConfToOfficialConfigStr(config);
    LOG_INFO("read file to Conf: \n%s" , str.c_str());


}

// ========== 应用过滤配置（ExcludedApplications / IncludedApplications）边界测试 ==========

// 基础配置模板（不含应用过滤），用于拼接测试
static const char* base_conf_prefix = R"(
[Interface]
PrivateKey = CKvZGm8S0HoQUwvUIsZ8wd39Bqt/5Z5vaJNuKX4LHGI=
Address = 10.0.0.2/24
DNS = 8.8.8.8
)";

static const char* base_conf_suffix = R"(
[Peer]
PublicKey = sMDHZrFHvyZKaYe1NYCy9+r2iR2DSQlcIFVFpeAh32A=
Endpoint = your.server.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
)";

// 测试1: ExcludedApplications 有多个包名
TEST(tools_conf, excludedApplications_multiple_values) {
    std::string conf = std::string(base_conf_prefix) +
        "ExcludedApplications = com.app1,com.app2,com.app3\n" +
        base_conf_suffix;

    const auto config = WireGuard::Tools::readConfFileToEntity(conf);
    ASSERT_EQ(config.inter.excludedApplications.size(), 3u);
    EXPECT_EQ(config.inter.excludedApplications[0], "com.app1");
    EXPECT_EQ(config.inter.excludedApplications[1], "com.app2");
    EXPECT_EQ(config.inter.excludedApplications[2], "com.app3");
    EXPECT_TRUE(config.inter.includedApplications.empty());
}

// 测试2: IncludedApplications 有多个包名
TEST(tools_conf, includedApplications_multiple_values) {
    std::string conf = std::string(base_conf_prefix) +
        "IncludedApplications = com.app4,com.app5\n" +
        base_conf_suffix;

    const auto config = WireGuard::Tools::readConfFileToEntity(conf);
    ASSERT_EQ(config.inter.includedApplications.size(), 2u);
    EXPECT_EQ(config.inter.includedApplications[0], "com.app4");
    EXPECT_EQ(config.inter.includedApplications[1], "com.app5");
    EXPECT_TRUE(config.inter.excludedApplications.empty());
}

// 测试3: 空值（ExcludedApplications = 后面无内容）
TEST(tools_conf, excludedApplications_empty_value) {
    std::string conf = std::string(base_conf_prefix) +
        "ExcludedApplications =\n" +
        base_conf_suffix;

    const auto config = WireGuard::Tools::readConfFileToEntity(conf);
    EXPECT_TRUE(config.inter.excludedApplications.empty());
    EXPECT_TRUE(config.inter.includedApplications.empty());
}

// 测试4: 空白字符串（ExcludedApplications = 后面只有空格）
TEST(tools_conf, excludedApplications_whitespace_only) {
    std::string conf = std::string(base_conf_prefix) +
        "ExcludedApplications =    \n" +
        base_conf_suffix;

    const auto config = WireGuard::Tools::readConfFileToEntity(conf);
    EXPECT_TRUE(config.inter.excludedApplications.empty());
}

// 测试5: 单个值（ExcludedApplications = com.leojay.app）
TEST(tools_conf, excludedApplications_single_value) {
    std::string conf = std::string(base_conf_prefix) +
        "ExcludedApplications = com.leojay.app\n" +
        base_conf_suffix;

    const auto config = WireGuard::Tools::readConfFileToEntity(conf);
    ASSERT_EQ(config.inter.excludedApplications.size(), 1u);
    EXPECT_EQ(config.inter.excludedApplications[0], "com.leojay.app");
}

// 测试6: IncludedApplications 单个值
TEST(tools_conf, includedApplications_single_value) {
    std::string conf = std::string(base_conf_prefix) +
        "IncludedApplications = com.leojay.app\n" +
        base_conf_suffix;

    const auto config = WireGuard::Tools::readConfFileToEntity(conf);
    ASSERT_EQ(config.inter.includedApplications.size(), 1u);
    EXPECT_EQ(config.inter.includedApplications[0], "com.leojay.app");
}

// 测试7: 包名前后有空格，应被 trim
TEST(tools_conf, applications_trim_spaces) {
    std::string conf = std::string(base_conf_prefix) +
        "ExcludedApplications =  com.app1 ,  com.app2  \n" +
        base_conf_suffix;

    const auto config = WireGuard::Tools::readConfFileToEntity(conf);
    ASSERT_EQ(config.inter.excludedApplications.size(), 2u);
    EXPECT_EQ(config.inter.excludedApplications[0], "com.app1");
    EXPECT_EQ(config.inter.excludedApplications[1], "com.app2");
}

// 测试8: 连续逗号（空项应被过滤）
TEST(tools_conf, applications_consecutive_commas) {
    std::string conf = std::string(base_conf_prefix) +
        "ExcludedApplications = com.app1,,com.app2\n" +
        base_conf_suffix;

    const auto config = WireGuard::Tools::readConfFileToEntity(conf);
    ASSERT_EQ(config.inter.excludedApplications.size(), 2u);
    EXPECT_EQ(config.inter.excludedApplications[0], "com.app1");
    EXPECT_EQ(config.inter.excludedApplications[1], "com.app2");
}

// 测试9: 两者同时存在（互斥但不校验，都应被解析）
TEST(tools_conf, both_excluded_and_included) {
    std::string conf = std::string(base_conf_prefix) +
        "ExcludedApplications = com.app1\n" +
        "IncludedApplications = com.app2\n" +
        base_conf_suffix;

    const auto config = WireGuard::Tools::readConfFileToEntity(conf);
    ASSERT_EQ(config.inter.excludedApplications.size(), 1u);
    EXPECT_EQ(config.inter.excludedApplications[0], "com.app1");
    ASSERT_EQ(config.inter.includedApplications.size(), 1u);
    EXPECT_EQ(config.inter.includedApplications[0], "com.app2");
}

// 测试10: 配置不包含应用过滤项时，字段应为空
TEST(tools_conf, no_applications_filter) {
    const auto config = WireGuard::Tools::readConfFileToEntity(test_wg_conf);
    EXPECT_TRUE(config.inter.excludedApplications.empty());
    EXPECT_TRUE(config.inter.includedApplications.empty());
}

// 测试11: 生成配置文本 - 空列表不输出
TEST(tools_conf, generate_empty_applications_omitted) {
    const auto config = WireGuard::Tools::readConfFileToEntity(test_wg_conf);
    const auto str = WireGuard::Tools::wgConfToOfficialConfigStr(config);
    EXPECT_EQ(str.find("ExcludedApplications"), std::string::npos);
    EXPECT_EQ(str.find("IncludedApplications"), std::string::npos);
}

// 测试12: 生成配置文本 - 非空列表正确输出
TEST(tools_conf, generate_applications_output) {
    std::string conf = std::string(base_conf_prefix) +
        "ExcludedApplications = com.app1,com.app2\n" +
        "IncludedApplications = com.app3\n" +
        base_conf_suffix;

    const auto config = WireGuard::Tools::readConfFileToEntity(conf);
    const auto str = WireGuard::Tools::wgConfToOfficialConfigStr(config);
    EXPECT_NE(str.find("ExcludedApplications=com.app1,com.app2"), std::string::npos);
    EXPECT_NE(str.find("IncludedApplications=com.app3"), std::string::npos);
}

// 测试13: 传递到 DeviceConfig（使用 IP 地址避免 DNS 解析失败）
TEST(tools_conf, transfer_to_device_config) {
    std::string conf = std::string(base_conf_prefix) +
        "ExcludedApplications = com.app1\n" +
        "IncludedApplications = com.app2\n"
        "[Peer]\n"
        "PublicKey = sMDHZrFHvyZKaYe1NYCy9+r2iR2DSQlcIFVFpeAh32A=\n"
        "Endpoint = 10.0.0.1:51820\n"
        "AllowedIPs = 0.0.0.0/0\n"
        "PersistentKeepalive = 25\n";

    const auto wgConf = WireGuard::Tools::readConfFileToEntity(conf);
    const auto drc = WireGuard::Tools::wgConfToDeviceRegisterConfig(wgConf);
    ASSERT_EQ(drc.client.excludedApplications.size(), 1u);
    EXPECT_EQ(drc.client.excludedApplications[0], "com.app1");
    ASSERT_EQ(drc.client.includedApplications.size(), 1u);
    EXPECT_EQ(drc.client.includedApplications[0], "com.app2");
}
