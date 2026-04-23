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
        /**
         * @return 将域名解析成ip地址
         */
        WireGuard::IPAddress readDomainToIp(const std::string &domain);
    }
} // WireGuardTools

#endif //WG_MAIN_WG_DNS_H
