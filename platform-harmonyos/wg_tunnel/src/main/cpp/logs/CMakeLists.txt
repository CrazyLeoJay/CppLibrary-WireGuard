# create 2026年4月11日 21点56分 from leojayFu
cmake_minimum_required(VERSION 3.11.0)
project(logs)
set(CMAKE_CXX_STANDARD 14)

add_library(logs SHARED logs.h logs.cpp)
target_include_directories(${PROJECT_NAME} PUBLIC .)