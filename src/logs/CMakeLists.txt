cmake_minimum_required(VERSION 3.22.1)
project(logs)
set(CMAKE_CXX_STANDARD 14)

add_library(${PROJECT_NAME} STATIC logs.h logs.cpp)
target_include_directories(${PROJECT_NAME} PUBLIC .)