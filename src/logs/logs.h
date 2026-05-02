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
#ifndef WIREGUARD_LOGS_H
#define WIREGUARD_LOGS_H

#ifndef WG_PRINT_SPACE_ENABLE // 定义打印空间是否执行打印，放在打印空间的函数，可以省略参数传入时构造
#define WG_PRINT_SPACE_ENABLE true
#endif

#include <functional>
#include <iostream>
#include <regex>
#include <mutex>

#include "fmt/format.h"
#include "fmt/printf.h"
#include "fmt/xchar.h"


// ANSI 颜色代码
#define RESET      "\033[0m"
#define BLACK      "\033[30m"
#define RED        "\033[31m"
#define GREEN      "\033[32m"
#define YELLOW     "\033[33m"
#define BLUE       "\033[34m"
#define MAGENTA    "\033[35m"
#define CYAN       "\033[36m"
#define WHITE      "\033[37m"
#define BOLD_RED   "\033[1;31m"
#define BOLD_GREEN "\033[1;32m"

namespace WireGuard {
    namespace Logs {
        // 日志级别
        enum class LogLevel { DEBUG = 0, INFO = 1, WARN = 2, ERROR = 3 };

        inline void printLog(LogLevel level, const std::string &message) {
            switch (level) {
                case LogLevel::DEBUG:
                    std::cout << GREEN << message << RESET << std::endl;
                    break;
                case LogLevel::INFO:
                    std::cout << BLUE << message << RESET << std::endl;
                    break;
                case LogLevel::WARN:
                    std::cout << YELLOW << message << RESET << std::endl;
                    break;
                case LogLevel::ERROR:
                    std::cout << RED << message << RESET << std::endl;
                    break;
            }
        }

        template<typename... Args>
        inline void
        default_log_handler(const LogLevel level, const char *file, int line, const char *fmt, Args &&... args) {
            auto regexFmt = (std::regex_replace(fmt, std::regex(R"(%\{[^}]*\})"), "%"));
            auto message = fmt::sprintf(regexFmt, std::forward<Args>(args)...);
            auto outMessage = fmt::format("{:s}({:d})\t{:s}", file, line, message.c_str());
            printLog(level, outMessage);
        }

        template<typename... Args>
        inline std::string log_to_string(const char *fmt, Args &&... args) {
            auto regexFmt = (std::regex_replace(fmt, std::regex(R"(%\{[^}]*\})"), "%"));
            return fmt::sprintf(regexFmt, std::forward<Args>(args)...);
        }

        using LogHandler = std::function<void(LogLevel level, const char *file, int line, const std::string &message)>;

        void setLogHandler(const LogHandler &handler);

        LogHandler getLogHandler();

        template<typename... Args>
        inline void log_println(LogLevel level, const char *file, int line, const char *fmt, Args &&... args) {
            auto regexFmt = (std::regex_replace(fmt, std::regex(R"(%\{[^}]*\})"), "%"));
            auto message = fmt::sprintf(regexFmt, std::forward<Args>(args)...);
            getLogHandler()(level, file, line, message);
        }

        inline void print_space(const std::function<void()> &func) {
            //            if (WG_PRINT_SPACE_ENABLE) {
            func();
            //            }
        }
    }; // namespace Logs
}; // namespace WireGuard

// 编译期关闭 DEBUG 日志（Release 模式）

#ifndef LOG_PRINT
#define LOG_PRINT(level, fmt, ...) ::WireGuard::Logs::log_println(level, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
#endif

#ifndef LOG_DEBUG
#ifdef NDEBUG
#define LOG_DEBUG(...)
#else
#define LOG_DEBUG(fmt, ...) LOG_PRINT(::WireGuard::Logs::LogLevel::DEBUG, fmt, ##__VA_ARGS__)
#endif
#endif

#ifndef LOG_INFO
#define LOG_INFO(fmt, ...) LOG_PRINT(::WireGuard::Logs::LogLevel::INFO, fmt, ##__VA_ARGS__)
#endif

#ifndef LOG_WARN
#define LOG_WARN(fmt, ...) LOG_PRINT(::WireGuard::Logs::LogLevel::WARN, fmt, ##__VA_ARGS__)
#endif

#ifndef LOG_ERROR
#define LOG_ERROR(fmt, ...) LOG_PRINT(::WireGuard::Logs::LogLevel::ERROR, fmt, ##__VA_ARGS__)
#endif

// ((void)OH_LOG_Print((type), LOG_DEBUG, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))

#endif // WIREGUARD_LOGS_H
