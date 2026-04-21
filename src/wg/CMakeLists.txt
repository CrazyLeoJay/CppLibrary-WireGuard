cmake_minimum_required(VERSION 3.22.1)
project(wg)
# file(GLOB_RECURSE SOURCES_CPP "*.cpp")
# add_library(wg ${SOURCES_CPP} ${SOURCES_C} peer.h peer.cpp allowedips.h allowedips.cpp cookie.h cookie.cpp device.h device.cpp noise.h noise.cpp messages.h messages.cpp queueing.h queueing.cpp ratelimiter.h ratelimiter.cpp socket.h socket.cpp timers.h timers.cpp version.h client.h client.cpp)
# add_library(wg SHARED ${SOURCES_CPP})

add_library(${PROJECT_NAME} STATIC
        entity.h entity.cpp
        version.h
        messages.h
        crypto.h crypto.cpp
        allowedips.h allowedips.cpp
        peer.h peer.cpp
        queueing.h queueing.cpp
        ratelimiter.h ratelimiter.cpp
        timers.h timers.cpp
        WGException.h WGException.cpp
        udp_socket.h udp_socket.cpp
        keypair.h keypair.cpp
        cookie.h cookie.cpp
        device.h device.cpp
        encoding.hpp encoding.cpp
        crypto/nonce.cpp
        crypto/nonce.h
        tools/tools.h tools/tools.cpp
        tools/pipwait.h tools/pipwait.cpp
)

target_link_libraries(${PROJECT_NAME} PUBLIC sodium wg_clib logs)
target_include_directories(${PROJECT_NAME} PUBLIC .)
