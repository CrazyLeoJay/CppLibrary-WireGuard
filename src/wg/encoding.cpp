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
#include "encoding.hpp"
#include <array>
#include <string>
#include <cstring>
#include <stdexcept>

namespace WireGuard {
    namespace Base64 {
        // Base64 编码表（常量表达式）
        std::array<char, 64> make_base64_table() {
            std::array < char, 64 > table{};
            for (std::size_t i = 0; i < 26; ++i) {
                table[i] = 'A' + static_cast<char>(i);
                table[i + 26] = 'a' + static_cast<char>(i);
                table[i + 52] = '0' + static_cast<char>(i);
            }
            table[62] = '+';
            table[63] = '/';
            return table;
        }

        static const auto BASE64_TABLE = make_base64_table();

        /**
         * @brief 常量时间 base64 编码（3 字节 -> 4 字符）
         */
        void encode_base64(std::array<char, 4> &dest, const std::array<uint8_t, 3> &src) {
            const std::array<uint8_t, 4> input = {
                static_cast<uint8_t>((src[0] >> 2) & 63), static_cast<uint8_t>(((src[0] << 4) | (src[1] >> 4)) & 63),
                static_cast<uint8_t>(((src[1] << 2) | (src[2] >> 6)) & 63), static_cast<uint8_t>(src[2] & 63)
            };

            for (unsigned int i = 0; i < 4; ++i) {
                dest[i] = BASE64_TABLE[input[i]];
            }
        }

        /**
         * @brief 常量时间 base64 解码（4 字符 -> 3 字节）
         * @return 解码后的值，如果包含无效字符则最高位为 1
         */
        int decode_base64(const std::array<char, 4> &src) {
            int val = 0;

            for (unsigned int i = 0; i < 4; ++i) {
                int c = static_cast<unsigned char>(src[i]);
                int val_char = -1 + ((((('A' - 1) - c) & (c - ('Z' + 1))) >> 8) & (c - 64)) +
                               ((((('a' - 1) - c) & (c - ('z' + 1))) >> 8) & (c - 70)) +
                               ((((('0' - 1) - c) & (c - ('9' + 1))) >> 8) & (c + 5)) +
                               ((((('+' - 1) - c) & (c - ('+' + 1))) >> 8) & 63) +
                               ((((('/' - 1) - c) & (c - ('/' + 1))) >> 8) & 64);

                val |= val_char << (18 - 6 * i);
            }
            return val;
        }

        std::string key_to_base64(const std::array<uint8_t, WG_KEY_LEN> &key) {
            static thread_local std::string result;
            result.clear();
            result.reserve(WG_KEY_LEN_BASE64 - 1);

            std::size_t i = 0;
            for (i = 0; i < WG_KEY_LEN / 3; ++i) {
                std::array < char, 4 > encoded;
                encode_base64(encoded, {key[i * 3 + 0], key[i * 3 + 1], key[i * 3 + 2]});
                result.append(encoded.begin(), encoded.end());
            }

            // 处理剩余的字节（填充）
            std::array < char, 4 > encoded;
            encode_base64(encoded, {key[i * 3 + 0], key[i * 3 + 1], 0});
            result.push_back(encoded[0]);
            result.push_back(encoded[1]);
            result.push_back(encoded[2]);
            result.push_back('='); // 填充字符

            return result;
        }

        std::array<uint8_t, WG_KEY_LEN> key_from_base64(std::string base64) {
            std::array<uint8_t, WG_KEY_LEN> key{};
            key.fill(0);

            // 验证长度和填充字符
            if (base64.length() != WG_KEY_LEN_BASE64 - 1 || base64[WG_KEY_LEN_BASE64 - 2] != '=') {
                throw std::invalid_argument("Invalid base64 length or padding");
            }

            volatile uint8_t ret = 0;
            unsigned int i = 0;

            for (i = 0; i < WG_KEY_LEN / 3; ++i) {
                std::array < char, 4 > src;
                for (int j = 0; j < 4; ++j) {
                    src[j] = base64[i * 4 + j];
                }

                int val = decode_base64(src);
                ret |= static_cast<uint32_t>(val) >> 31;
                key[i * 3 + 0] = (val >> 16) & 0xff;
                key[i * 3 + 1] = (val >> 8) & 0xff;
                key[i * 3 + 2] = val & 0xff;
            }

            // 处理最后一个块（带填充）
            std::array < char, 4 > src = {
                base64[i * 4 + 0], base64[i * 4 + 1], base64[i * 4 + 2],
                'A' // 用 'A' 替换 '=' 进行解码
            };

            int val = decode_base64(src);
            ret |= ((static_cast<uint32_t>(val) >> 31) | (val & 0xff));
            key[i * 3 + 0] = (val >> 16) & 0xff;
            key[i * 3 + 1] = (val >> 8) & 0xff;

            // 检查是否有错误（常量时间）
            if (!(((ret - 1) >> 8) & 1)) {
                throw std::invalid_argument("Invalid base64 characters detected");
            }

            return key;
        }

        std::string key_to_hex(const std::array<uint8_t, WG_KEY_LEN> &key) {
            static thread_local std::string result;
            result.clear();
            result.reserve(WG_KEY_LEN_HEX - 1);

            for (unsigned int i = 0; i < WG_KEY_LEN; ++i) {
                // 高 4 位
                char high = 87U + (key[i] >> 4) + ((((key[i] >> 4) - 10U) >> 8) & ~38U);
                result.push_back(high);

                // 低 4 位
                char low = 87U + (key[i] & 0xf) + ((((key[i] & 0xf) - 10U) >> 8) & ~38U);
                result.push_back(low);
            }

            return result;
        }

        std::array<uint8_t, WG_KEY_LEN> key_from_hex(std::string hex) {
            std::array<uint8_t, WG_KEY_LEN> key{};
            key.fill(0);

            // 验证长度
            if (hex.length() != WG_KEY_LEN_HEX - 1) {
                throw std::invalid_argument("Invalid hex length");
            }

            volatile uint8_t ret = 0;

            for (unsigned int i = 0; i < WG_KEY_LEN_HEX - 1; i += 2) {
                // 处理第一个字符
                uint8_t c = static_cast<uint8_t>(hex[i]);
                uint8_t c_num = c ^ 48U;
                uint8_t c_num0 = (c_num - 10U) >> 8;
                uint8_t c_alpha = (c & ~32U) - 55U;
                uint8_t c_alpha0 = ((c_alpha - 10U) ^ (c_alpha - 16U)) >> 8;
                ret |= ((c_num0 | c_alpha0) - 1) >> 8;
                uint8_t c_val = (c_num0 & c_num) | (c_alpha0 & c_alpha);
                uint8_t c_acc = c_val * 16U;

                // 处理第二个字符
                c = static_cast<uint8_t>(hex[i + 1]);
                c_num = c ^ 48U;
                c_num0 = (c_num - 10U) >> 8;
                c_alpha = (c & ~32U) - 55U;
                c_alpha0 = ((c_alpha - 10U) ^ (c_alpha - 16U)) >> 8;
                ret |= ((c_num0 | c_alpha0) - 1) >> 8;
                c_val = (c_num0 & c_num) | (c_alpha0 & c_alpha);
                key[i / 2] = c_acc | c_val;
            }

            // 检查是否有错误（常量时间）
            if (!(((ret - 1) >> 8) & 1)) {
                throw std::invalid_argument("Invalid hex characters detected");
            }

            return key;
        }

        bool key_is_zero(const std::array<uint8_t, WG_KEY_LEN> &key) {
            volatile uint8_t acc = 0;

            for (unsigned int i = 0; i < WG_KEY_LEN; ++i) {
                acc |= key[i];
                // 使用编译器屏障防止优化
#if defined(__GNUC__) || defined(__clang__)
                asm volatile("" : "+r"(acc)::);
#else
                // MSVC 和其他编译器的替代方案
                volatile uint8_t *p = &acc;
                (void) (*p);
#endif
            }

            return (((acc - 1) >> 8) & 1) != 0;
        }
    }; // namespace Base64
} // namespace WireGuard