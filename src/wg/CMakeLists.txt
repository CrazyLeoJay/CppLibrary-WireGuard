cmake_minimum_required(VERSION 3.22.1)
project(wg)

add_library(${PROJECT_NAME} STATIC
        entity.h entity.cpp
        version.h
        messages.h
        crypto/crypto.h crypto/crypto.cpp
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
        crypto/encoding.hpp crypto/encoding.cpp
        crypto/nonce.cpp
        crypto/nonce.h
        tools.h tools.cpp
        pipwait.h pipwait.cpp
        tools/wg_dns.h
        tools/wg_dns.cpp
        tools/conf_file.h
        tools/conf_file.cpp
)

target_link_libraries(${PROJECT_NAME} PRIVATE sodium wg_clib logs)
target_include_directories(${PROJECT_NAME} PUBLIC .)
