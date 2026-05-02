# create 2026年4月11日 21点56分 from leojayFu
# the minimum version of CMake.
cmake_minimum_required(VERSION 3.28)
project(wg_tunnel)
set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
include(FetchContent)

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

add_compile_definitions(WG_PRINT_SPACE_ENABLE SHOW_DEBUG_LOGS)

include_directories(
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/include
)

add_subdirectory(logs)
include_directories(logs)

FetchContent_Declare(wg_mobile SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../src)
FetchContent_MakeAvailable(wg_mobile)



add_library(${PROJECT_NAME} SHARED
    napi_init.cpp
    WireGuardDevice.cpp WireGuardDevice.h
    napi_tools.h napi_tools.cpp
)

target_link_libraries(${PROJECT_NAME} PUBLIC
    libace_napi.z.so libhilog_ndk.z.so
    wg_mobile
)
