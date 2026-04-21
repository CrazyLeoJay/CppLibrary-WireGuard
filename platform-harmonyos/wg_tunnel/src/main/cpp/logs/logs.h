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
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".
#pragma once


#include <utility>
#ifndef WIREGUARD_LOGS_H
    #define WIREGUARD_LOGS_H

    #undef LOG_DOMAIN
    #undef LOG_TAG
    #define LOG_DOMAIN 0x3200               // 全局domain宏，标识业务领域
    #define LOG_TAG    "wireguard_c14_napi" // 全局tag宏，标识模块日志tag

//    #define WG_PRINT_SPACE_ENABLE // 定义这个参数就生效，无需配置值
//    #define SHOW_DEBUG_LOGS // 也是定义就生效

    #include <hilog/log.h>

namespace WireGuard {
    namespace Logs {
// 日志级别
        enum class LogLevel { DEBUG = 0, INFO = 1, WARN = 2, ERROR = 3 };

        template <typename Func>
        inline void print_space(Func &&func) {
    #ifdef WG_PRINT_SPACE_ENABLE // 定义这个参数就生效，无需配置值
            std::forward<Func>(func)();
    #endif
        }

    }; // namespace Logs

}; // namespace WireGuard

// ((void)OH_LOG_Print((type), LOG_DEBUG, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))
    #define LOG_DEBUG(fmt, ...)
    #ifdef SHOW_DEBUG_LOGS
        #ifdef LOG_DEBUG
            #undef LOG_DEBUG
        #endif
        #define LOG_DEBUG(fmt, ...) OH_LOG_DEBUG(LOG_APP, fmt, ##__VA_ARGS__)
    #endif

    #define LOG_INFO(fmt, ...)  OH_LOG_INFO(LOG_APP, fmt, ##__VA_ARGS__)
    #define LOG_WARN(fmt, ...)  OH_LOG_WARN(LOG_APP, fmt, ##__VA_ARGS__)
    #define LOG_ERROR(fmt, ...) OH_LOG_ERROR(LOG_APP, fmt, ##__VA_ARGS__)

#endif // WIREGUARD_LOGS_H
