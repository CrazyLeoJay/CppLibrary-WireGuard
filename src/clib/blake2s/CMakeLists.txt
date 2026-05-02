# 指定 CMake 最低版本
cmake_minimum_required(VERSION 3.10)

# 项目名称和语言
project(blake2s C)
set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)  # 确保编译器必须支持 C99

# 添加可执行文件
add_library(${PROJECT_NAME} STATIC
        blake2.h
        blake2-impl.h

        blake2s-ref.c

#        blake2b-ref.c
#        blake2bp-ref.c
#        blake2sp-ref.c
#        blake2xb-ref.c
#
#        blake2xs-ref.c
#
#        genkat-c.c
#        genkat-json.c
)
target_include_directories(${PROJECT_NAME} PUBLIC .)