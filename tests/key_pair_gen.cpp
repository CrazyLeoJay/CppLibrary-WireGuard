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
//
// Created by Leojay on 2026/4/4.
//

#include "crypto.h"
#include "gtest/gtest.h"

TEST(KeyPairTest, genPairKey) {
    WireGuard::PrivateKey privateKey;
    WireGuard::PublicKey public_key;
    WireGuard::Crypto::generatePrivateKey(privateKey);
    WireGuard::Crypto::generatePublicKey(public_key, privateKey);
    auto outPrivateKey = WireGuard::Crypto::bin32Array2Base64(privateKey);
    auto outPublicKey = WireGuard::Crypto::bin32Array2Base64(public_key);
    EXPECT_EQ(outPrivateKey.size(), 44);
    EXPECT_EQ(outPublicKey.size(), 44);
    printf("genKeyPair\nPrivateKey:%s\nPublicKey :%s", outPrivateKey.data(), outPublicKey.data());
}


