# create 2026年4月11日 21点56分 from leojayFu
# the minimum version of CMake.
cmake_minimum_required(VERSION 3.28)
project(myNpmLib)
set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include(FetchContent)

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

add_subdirectory(logs)
#add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../../../../src/wg)
#add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../../../../src/libsodium)
#add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../../../../src/tools)

FetchContent_Declare(sodium SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../src/libsodium)
FetchContent_Declare(tools SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../src/tools)
FetchContent_Declare(wg SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../src/wg)
# 自动下载、配置、构建 googletest
FetchContent_MakeAvailable(sodium)
FetchContent_MakeAvailable(tools)
FetchContent_MakeAvailable(wg)


add_library(wg_tunnel SHARED napi_init.cpp WireGuardDevice.cpp WireGuardDevice.h napi_tools.h napi_tools.cpp)
target_link_libraries(wg_tunnel PUBLIC libace_napi.z.so libhilog_ndk.z.so sodium tools logs wg)
