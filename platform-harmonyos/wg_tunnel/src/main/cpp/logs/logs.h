/*
 * Copyright [2026] @github-crazyleojay (crazyleojay@163.com/gmail.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

//
// Created on 2026/4/7.
// @author leojay`fu
//
#pragma once

#include <functional>
#include <utility>
#ifndef WIREGUARD_LOGS_HARMONYOS_H
    #define WIREGUARD_LOGS_HARMONYOS_H
    #include <hilog/log.h>
// 定义日志域和标签（需全局唯一）
    #undef LOG_DOMAIN
    #undef LOG_TAG
    #define LOG_DOMAIN 0x0002 // 自定义业务域（0x0000~0xFFFF）
    #define LOG_TAG    "wg_c14_harmony"

namespace WireGuard {
    namespace Logs {
        inline void print_space(const std::function<void()> &func) {
            if (WG_PRINT_SPACE_ENABLE) {
                func();
            }
        }
    }; // namespace Logs
};     // namespace WireGuard


//    #define LOG_PRINT(level, fmt, ...) ::WireGuard::Logs::log_println(level, __FILE__, __LINE__, fmt, ##__VA_ARGS__)

    #ifdef SHOW_DEBUG_LOGS
        #define LOG_DEBUG(fmt, ...) OH_LOG_DEBUG(LOG_APP, fmt, ##__VA_ARGS__)
    #else
        #define LOG_DEBUG(fmt, ...)
    #endif

    #define LOG_INFO(fmt, ...) OH_LOG_INFO(LOG_APP, fmt, ##__VA_ARGS__)

    #define LOG_WARN(fmt, ...) OH_LOG_WARN(LOG_APP, fmt, ##__VA_ARGS__)

    #define LOG_ERROR(fmt, ...) OH_LOG_ERROR(LOG_APP, fmt, ##__VA_ARGS__)

    #define LOG_SOCKET(fmt, ...) OH_LOG_DEBUG(LOG_APP, fmt, ##__VA_ARGS__)

#endif
