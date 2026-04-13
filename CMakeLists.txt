#cmake_minimum_required(VERSION 4.0)
cmake_minimum_required(VERSION 3.22.1)
project(wg_main)

set(CMAKE_CXX_STANDARD 14)

# 启用测试（必须）
include(CTest)
enable_testing()

# === 第一步：通过 FetchContent 下载并构建 googletest ===
include(FetchContent)

FetchContent_Declare(
        googletest
        URL https://github.com/google/googletest/archive/refs/tags/v1.14.0.zip
        # 或使用 Git（可能较慢）：
        # GIT_REPOSITORY https://github.com/google/googletest.git
        # GIT_TAG        release-1.14.0
)
# 自动下载、配置、构建 googletest
FetchContent_MakeAvailable(googletest)

# === 第二步：添加被测库 ===
add_subdirectory(src/libsodium)
add_subdirectory(src/tools)
add_subdirectory(src/logs)
add_subdirectory(src/wg)

include_directories(
        src/
        src/logs
)

add_executable(wg_main src/main.cpp)
target_link_libraries(wg PUBLIC sodium tools logs)
target_link_libraries(wg_main PUBLIC sodium tools logs wg)

# === 第三步：添加测试子目录 ===
add_subdirectory(tests)