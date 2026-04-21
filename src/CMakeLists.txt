#cmake_minimum_required(VERSION 4.0)
cmake_minimum_required(VERSION 3.22.1)
project(wg_mobile)

set(CMAKE_CXX_STANDARD 14)
# 确保所有目标都使用 PIC
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# === 第二步：添加被测库 ===
add_subdirectory(clib)
add_subdirectory(logs)
add_subdirectory(wg)

include_directories(.)

# 移动手机端引入，需要手机端实现各自系统的logs
add_library(${PROJECT_NAME}_interface INTERFACE)
target_link_libraries(${PROJECT_NAME}_interface INTERFACE wg_clib wg logs)

add_library(${PROJECT_NAME} SHARED
        $<TARGET_OBJECTS:logs>
        $<TARGET_OBJECTS:wg_clib>
        $<TARGET_OBJECTS:wg>
)
#target_link_libraries(wg_mobile PUBLIC wg_clib wg)
target_include_directories(${PROJECT_NAME} PUBLIC
        .
        wg
        clib
        clib/blake2s
        clib/sodium
        clib/sodium/include/
)