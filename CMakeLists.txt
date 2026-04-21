#cmake_minimum_required(VERSION 4.0)
cmake_minimum_required(VERSION 3.22.1)
project(wg_main)

set(CMAKE_CXX_STANDARD 14)
# 确保所有目标都使用 PIC
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

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
add_subdirectory(src)
include_directories(src)

add_executable(${PROJECT_NAME} src/main.cpp)
target_link_libraries(${PROJECT_NAME} PUBLIC wg_mobile logs)

# === 第三步：添加测试子目录 ===
add_subdirectory(tests)