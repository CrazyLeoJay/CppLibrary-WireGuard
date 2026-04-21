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


#include "crypto.h"
#include "crypto/nonce.h"
#include "gtest/gtest.h"

const WireGuard::PrivateKey client_private{
    WireGuard::Crypto::base642Bin32Array("CKvZGm8S0HoQUwvUIsZ8wd39Bqt/5Z5vaJNuKX4LHGI=")
};
const WireGuard::PublicKey client_public{
    WireGuard::Crypto::base642Bin32Array("gN9lnPxypH67F7KystwjDdpwNsT007AV8s/MOOc0QGM=")
};
const WireGuard::PublicKey server_private{
    WireGuard::Crypto::base642Bin32Array("6CPPJCvfaej0+lwY5amd5pKJ0WLT0JuSv0VyPnMimVE=")
};
const WireGuard::PublicKey server_public{
    WireGuard::Crypto::base642Bin32Array("sMDHZrFHvyZKaYe1NYCy9+r2iR2DSQlcIFVFpeAh32A=")
};

namespace WireGuard {
    TEST(TOOLS, b64_2_hex) {
        std::string b64Str = "MDswPQmFaailKxTHciByyx5Sira4ryctoqjNrRKu828=";
        auto bin = Crypto::base642Bin32Array(b64Str);
        auto hex = Crypto::bin2Hex(bin.data(), bin.size());
        printf("%s", hex.c_str());
    }
}
