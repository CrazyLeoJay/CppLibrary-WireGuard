#cmake_minimum_required(VERSION 4.0)
cmake_minimum_required(VERSION 3.22.1)
project(wg_main)
cmake_policy(SET CMP0135 NEW)

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
#        URL https://github.com/google/googletest/archive/refs/tags/v1.14.0.zip
        URL "${CMAKE_CURRENT_SOURCE_DIR}/thirty_libs/googletest-1.14.0.zip"
        # 或使用 Git（可能较慢）：
        # GIT_REPOSITORY https://github.com/google/googletest.git
        # GIT_TAG        release-1.14.0
)
# 自动下载、配置、构建 googletest
FetchContent_MakeAvailable(googletest)

# 使用 FetchContent 获取 fmt 库
FetchContent_Declare(
        fmt
        URL "${CMAKE_CURRENT_SOURCE_DIR}/thirty_libs/fmt-12.2.0.zip"
)
# 设置 fmt 构建选项
set(FMT_USE_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
set(FMT_INSTALL OFF CACHE BOOL "" FORCE)
set(FMT_DOC OFF CACHE BOOL "" FORCE)
set(FMT_TEST OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(fmt)

# === 第二步：添加被测库 ===
add_subdirectory(src)
include_directories(src)

add_executable(${PROJECT_NAME} src/main.cpp)
target_link_libraries(${PROJECT_NAME} PUBLIC wg_mobile logs)

# === 第三步：添加测试子目录 ===
add_subdirectory(tests)