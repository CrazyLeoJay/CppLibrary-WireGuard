cmake_minimum_required(VERSION 3.22.1)
project(logs)
set(CMAKE_CXX_STANDARD 14)

# 如果 fmt 尚未导入，则导入
if(NOT TARGET fmt::fmt)
    include(FetchContent)
    FetchContent_Declare(
            fmt
            URL "${CMAKE_CURRENT_SOURCE_DIR}/../../thirty_libs/fmt-12.2.0.zip"
    )
    FetchContent_MakeAvailable(fmt)
endif()

add_library(${PROJECT_NAME} STATIC logs.h logs.cpp)
target_include_directories(${PROJECT_NAME} PUBLIC .)
target_link_libraries(${PROJECT_NAME} PUBLIC fmt::fmt)