cmake_minimum_required(VERSION 3.22.1)
project(logs)
set(CMAKE_CXX_STANDARD 14)

include(FetchContent)
FetchContent_Declare(
        fmt
        URL https://github.com/fmtlib/fmt/archive/refs/tags/12.1.0.zip
)
FetchContent_MakeAvailable(fmt)

add_library(${PROJECT_NAME} STATIC logs.h logs.cpp)
target_include_directories(${PROJECT_NAME} PUBLIC .)
target_link_libraries(${PROJECT_NAME} PUBLIC fmt::fmt)