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
// Created by Leojay on 2026/4/4.
//

#include <gtest/gtest.h>
// #include "math_utils.h"  // 被测头文件

// 简单断言测试
TEST(MathTest, AddPositiveNumbers) {
    // EXPECT_EQ(add(2, 3), 5);
    // EXPECT_EQ(add(-1, 1), 0);
}

// 测试夹具（Fixture）用于共享 setup/teardown
class MathTestFixture : public ::testing::Test {
protected:
    void SetUp() override {
        // 每个测试前执行
    }
    void TearDown() override {
        // 每个测试后执行
    }
};

TEST_F(MathTestFixture, MultiplyByZero) {
    // EXPECT_EQ(multiply(5, 0), 0);
}