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
 * Created by Leojay on 2026/4/6.
 *
 * @author leojay`fu
 * @email crazyleojay@163.com
 * @url https://github.com/CrazyLeoJay
 */

#ifndef WG_MAIN_TEST_PARAMS_H
#define WG_MAIN_TEST_PARAMS_H
#include <array>
#include <cstdint>
#include <stdexcept>

#include "../src/wg/crypto/crypto.h"


namespace WireGuard {
    inline std::array<std::uint8_t, 32> b642bin(const std::string &src) {
        return WireGuard::crypto::base642Bin32Array(src);
    };

    // 假设输入是 "0x" 开头的十六进制字符串，且长度（不含 0x）是偶数
    inline std::vector<uint8_t> hexStringToArray(const std::string &hex) {
        std::string data;
        if (hex.substr(0, 2) != "0x") {
            data = hex;
        } else {
            data = hex.substr(2);
        }
        size_t LEN = (data.length()) / 2; // 减去 "0x" 后除以 2 得到字节数
        if (data.size() != 2 * LEN) {
            throw std::invalid_argument("Hex string length does not match array size");
        }

        std::vector<uint8_t> bytes{};
        bytes.reserve(LEN);
        for (size_t i = 0; i < LEN; ++i) {
            std::string byte = data.substr(2 * i, 2);
            bytes[i] = static_cast<uint8_t>(std::stoul(byte, nullptr, 16));
        }
        return bytes;
    }


    const WireGuard::PrivateKey client_private{b642bin("CKvZGm8S0HoQUwvUIsZ8wd39Bqt/5Z5vaJNuKX4LHGI=")};
    const WireGuard::PublicKey client_public{b642bin("gN9lnPxypH67F7KystwjDdpwNsT007AV8s/MOOc0QGM=")};
    const WireGuard::PublicKey server_private{b642bin("6CPPJCvfaej0+lwY5amd5pKJ0WLT0JuSv0VyPnMimVE=")};
    const WireGuard::PublicKey server_public{b642bin("sMDHZrFHvyZKaYe1NYCy9+r2iR2DSQlcIFVFpeAh32A=")};
    const WireGuard::PublicKey ephemeral_private{b642bin("eDal3qo5FbXZTspeM6kxztQ7i3yMJjKplVk6NL3rg0s=")};
    const WireGuard::PublicKey ephemeral_public{b642bin("1rzA6eYgIhK8aeFxuEHRzqvHfJE244/88Y4fkX/WfRs=")};
    // PrivateKey:eDal3qo5FbXZTspeM6kxztQ7i3yMJjKplVk6NL3rg0s=
    // PublicKey :1rzA6eYgIhK8aeFxuEHRzqvHfJE244/88Y4fkX/WfRs=
}
#endif //WG_MAIN_TEST_PARAMS_H
