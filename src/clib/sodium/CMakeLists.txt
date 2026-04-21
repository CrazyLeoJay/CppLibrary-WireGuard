# 手动收集 libsodium 源文件（简化版，实际需按平台选择）
file(GLOB_RECURSE SODIUM_SOURCES
        ./*.c
        ./**/*.c
)

# 排除测试和无关文件
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "test|minimal")

set(VERSION 1.0.21)
include_directories(
        include
        include/sodium
        include/sodium/private
)
add_library(sodium STATIC ${SODIUM_SOURCES})
# 忽略所有警告信息
target_compile_options(sodium PRIVATE -w)
target_include_directories(sodium PUBLIC include)