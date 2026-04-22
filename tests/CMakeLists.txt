#cmake_minimum_required(VERSION 3.22.1)
#project(wg_main)
#
#set(CMAKE_CXX_STANDARD 14)


# 创建测试可执行文件
add_executable(test_main test_main.cpp
        key_pair_gen.cpp
        test_noise_handshake.cpp
        test_tools.cpp
        test_noise.cpp
        test_params.h
        test_dns.cpp
)

# 链接被测库 + GTest 主函数
target_link_libraries(test_main
        wg
        logs
        sodium
        GTest::gtest_main   # 自动提供 main() 函数
)

# === 关键：自动发现并注册所有 TEST() ===
include(GoogleTest)
gtest_discover_tests(test_main)