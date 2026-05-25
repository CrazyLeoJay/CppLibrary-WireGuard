# create 2026年4月11日 21点56分 from leojayFu
cmake_minimum_required(VERSION 3.11.0)
project(logs)
set(CMAKE_CXX_STANDARD 14)

add_library(${PROJECT_NAME} STATIC logs.h logs.cpp)
target_include_directories(${PROJECT_NAME} PUBLIC .)
target_link_libraries(${PROJECT_NAME} PRIVATE libhilog_ndk.z.so)