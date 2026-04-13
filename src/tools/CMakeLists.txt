# 指定 CMake 最低版本
#cmake_minimum_required(VERSION 3.10)

# 项目名称和语言
project(tools C)
set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)  # 确保编译器必须支持 C99

# 添加可执行文件
#add_executable(myapp main.c)
add_library(tools STATIC
        blake2s/blake2.h blake2s/blake2-impl.h
        blake2s/blake2s-ref.c
        blake2s/blake2b-ref.c blake2s/blake2bp-ref.c blake2s/blake2sp-ref.c blake2s/blake2xb-ref.c
        blake2s/blake2xs-ref.c
        blake2s/genkat-c.c blake2s/genkat-json.c
)