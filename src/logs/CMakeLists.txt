cmake_minimum_required(VERSION 3.22.1)
project(logs)
set(CMAKE_CXX_STANDARD 14)

include_directories(.)
add_library(logs SHARED logs.h logs.cpp)