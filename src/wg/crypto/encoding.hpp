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
#ifndef ENCODING_HPP
#define ENCODING_HPP

#include <array>
#include <cstdint>
#include <string>
#include "linux/wireguard.h"
#include "../version.h"

namespace WireGuard {
    namespace Base64 {
        // 编译时常量
        constexpr std::size_t WG_KEY_LEN_BASE64 = (((WG_KEY_LEN) + 2) / 3) * 4 + 1;
        constexpr std::size_t WG_KEY_LEN_HEX = (WG_KEY_LEN) * 2 + 1;

        /**
         * @brief 将密钥转换为 base64 编码
         * @param key 输入密钥 (32 字节)
         * @return base64 编码字符串
         */
        std::string key_to_base64(const std::array<uint8_t, WG_KEY_LEN> &key);

        /**
         * @brief 从 base64 编码解码密钥
         * @param base64 base64 编码字符串
         * @return 解码后的密钥，如果失败则返回空数组
         */
        std::array<uint8_t, WG_KEY_LEN> key_from_base64(std::string base64);

        /**
         * @brief 将密钥转换为十六进制字符串
         * @param key 输入密钥 (32 字节)
         * @return 十六进制编码字符串
         */
        std::string key_to_hex(const std::array<uint8_t, WG_KEY_LEN> &key);

        /**
         * @brief 从十六进制字符串解码密钥
         * @param hex 十六进制编码字符串
         * @return 解码后的密钥，如果失败则返回空数组
         */
        std::array<uint8_t, WG_KEY_LEN> key_from_hex(std::string hex);

        /**
         * @brief 检查密钥是否全为零
         * @param key 输入密钥 (32 字节)
         * @return 如果全为零返回 true，否则返回 false
         */
        bool key_is_zero(const std::array<uint8_t, WG_KEY_LEN> &key);
    }; // namespace Base64
} // namespace WireGuard

#endif // ENCODING_HPP