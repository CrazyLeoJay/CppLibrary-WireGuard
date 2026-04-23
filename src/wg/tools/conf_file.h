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

#ifndef WG_MAIN_CONFFILE_H
#define WG_MAIN_CONFFILE_H
#include <array>
#include <memory>
#include <string>
#include <vector>

#include "entity.h"

namespace WireGuard {
    namespace Tools {
        constexpr size_t WG_KEY_LEN = 32;
        using WGKey = std::array<uint8_t, WG_KEY_LEN>;

        /**
         * 网络站点地址，需要ip或者域名和端口
         * 主要表达可以访问的地址
         * 需要注意可以是 域名
         */
        struct WebSitePoint {
            std::string ipStrOrDomain; // ip地址或者域名
            uint32_t port; // 远程端口，没有默认80
        };

        struct WGConfInterface {
            WGKey privateKey;
            IpAddressArea ipArea;
            std::vector<IPAddress> dns;
        };

        struct WGConfPeer {
            WGKey publicKey;
            WebSitePoint endpoint; // 要建立链接的站点地址
            std::vector<IpAddressArea> allowedIPs; // 需要路由的ip地址域
            uint32_t persistentKeepalive; // 保活时间
        };

        /**
         * WireGuard 配置实体
         * demo：
         * [Interface]
         * PrivateKey = <你的客户端私钥>
         * Address = 10.0.0.2/24
         * DNS = 8.8.8.8, 1.1.1.1
         *
         * [Peer]
         * PublicKey = <服务器公钥>
         * Endpoint = your.server.com:51820
         * AllowedIPs = 0.0.0.0/0
         * PersistentKeepalive = 25
         *
         */
        struct WGConf {
            WGConfInterface inter;
            std::vector<WGConfPeer> peers;
        };


        /**
         * 解析WireGuard 的 conf 文件内容，解析成实实体
         *
         * @param content conf WireGuard配置文件内容
         * @return 转化为数据实体
         */
        WGConf readConfFileToEntity(const std::string &content);


        /**
         * 将配置文件解析成json
         * 由于字段比较多，为了减少跨语言之间的配置读写，使用json序列化
         *
         * @param content 配置文件内容
         * @return 解析的json
         */
        std::string readConfFileToJson(const std::string &content);

        std::string wgConfToJson(const WGConf &config);
    }
} // WireGuardTools

#endif //WG_MAIN_CONFFILE_H
