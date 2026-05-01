cmake_minimum_required(VERSION 3.22.1)
project(logs)
set(CMAKE_CXX_STANDARD 14)

include(FetchContent)
FetchContent_Declare(
        fmt
        GIT_REPOSITORY https://github.com/fmtlib/fmt.git
        #        GIT_TAG        10.0.0 # 建议指定一个稳定版本
        GIT_TAG        12.1.0 # 建议指定一个稳定版本
)
FetchContent_MakeAvailable(fmt)

add_library(${PROJECT_NAME} STATIC logs.h logs.cpp)
target_include_directories(${PROJECT_NAME} PUBLIC .)
target_link_libraries(${PROJECT_NAME} PUBLIC fmt::fmt)