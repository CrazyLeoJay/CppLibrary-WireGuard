#cmake_minimum_required(VERSION 4.0)
cmake_minimum_required(VERSION 3.22.1)
project(wg_mobile)

set(CMAKE_CXX_STANDARD 14)
# 确保所有目标都使用 PIC
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# === 第二步：添加被测库 ===
add_subdirectory(clib)
# src/logs/CMakeLists.txt
if(NOT TARGET logs)
    add_subdirectory(logs)
    # 其他设置...
endif()
add_subdirectory(wg)

## 移动手机端引入，需要手机端实现各自系统的logs
add_library(${PROJECT_NAME}_a INTERFACE main.cpp)
target_link_libraries(${PROJECT_NAME}_a INTERFACE wg_clib wg logs)

add_library(${PROJECT_NAME} SHARED main.cpp)
target_link_libraries(${PROJECT_NAME}
        PUBLIC wg
        PRIVATE wg_clib logs
)
