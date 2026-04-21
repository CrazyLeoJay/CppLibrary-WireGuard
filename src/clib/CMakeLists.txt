cmake_minimum_required(VERSION 3.22.1)
# 项目名称和语言
project(wg_clib C)
set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)  # 确保编译器必须支持 C99
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -ffunction-sections -fdata-sections") # 优化 .a 库大小
# 收集所有子目录的源文件
add_subdirectory(blake2s)
add_subdirectory(sodium)

add_library(${PROJECT_NAME} INTERFACE)
target_link_libraries(${PROJECT_NAME} INTERFACE blake2s sodium)
