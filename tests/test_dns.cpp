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
