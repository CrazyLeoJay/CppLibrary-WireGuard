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

#ifndef WG_MAIN_WG_DNS_H
#define WG_MAIN_WG_DNS_H
#include "conf_file.h"
#include "entity.h"

namespace WireGuard {
    namespace DNS {
        enum IPType {
            IPV4 = 4,
            IPV6 = 6,
        };

        /**
         * @return 将域名解析成ip地址，优先解析IPv4，如果IPv4解析失败则尝试IPv6
         */
        IPAddress readDomainToIp(const std::string &domain, const IPType &type = IPV4);

        /**
         * @return 将域名解析成所有可用的ip地址（包括IPv4和IPv6）
         */
        std::vector<IPAddress> readDomainToIpAll(const std::string &domain);

        /**
         * @return 将域名优先解析为IPv4，如果失败则解析为IPv6
         */
        IPAddress readDomainToIpPreferIpv4(const std::string &domain);

        /**
         * 构建标准UDP DNS查询报文（RFC1035）
         *
         * @param queryId 事务ID
         * @param domain 待解析域名
         * @param qtype 查询类型：1=A(IPv4) 28=AAAA(IPv6)
         */
        std::vector<uint8_t> buildDnsQuery(uint16_t queryId, const std::string &domain, uint16_t qtype);

        /**
         * 解析DNS响应报文，提取第一条匹配qtype的A/AAAA记录
         *
         * @param response 响应报文
         * @param queryId 期望的事务ID（不匹配返回false）
         * @param qtype 期望的记录类型
         * @param out 解析出的地址（网络字节序）
         * @return true=解析成功
         */
        bool parseDnsResponse(const std::vector<uint8_t> &response, uint16_t queryId, uint16_t qtype, IPAddress &out);

        /**
         * 直接向指定DNS服务器发起查询（不经过系统解析器）
         *
         * 场景：部分路由器DNS会对自家DDNS域名返回NAT硬回流的内网IP，
         * 系统解析器随之拿到内网地址。此函数直接向公网DNS查询A/AAAA记录获取公网解析结果。
         *
         * @param domain 待解析域名
         * @param type IPV4/IPV6
         * @param dnsServer DNS服务器IPv4地址（如 223.5.5.5）
         * @throws 解析失败或网络超时抛出异常
         */
        IPAddress readDomainToIpFromDnsServer(const std::string &domain, const IPType &type,
                                              const std::string &dnsServer);
    }
} // WireGuardTools

#endif //WG_MAIN_WG_DNS_H
