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

#include "logs.h"

#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <iostream>
#include <memory>
#include <ostream>
#include <regex>
#include <mutex>

// ANSI 颜色代码
#define RESET       "\033[0m"
#define BLACK       "\033[30m"
#define RED         "\033[31m"
#define GREEN       "\033[32m"
#define YELLOW      "\033[33m"
#define BLUE        "\033[34m"
#define MAGENTA     "\033[35m"
#define CYAN        "\033[36m"
#define WHITE       "\033[37m"
#define BOLD_RED    "\033[1;31m"
#define BOLD_GREEN  "\033[1;32m"

// 可继续添加背景色等
std::mutex printlogMutex;

void WireGuard::Logs::log_println(LogLevel level, const char *file, int line, const char *fmt, ...) {
    std::lock_guard<std::mutex> lock(printlogMutex);
    std::string message{"no message"};
    try {
        if (fmt) {
            message = (std::regex_replace(fmt, std::regex(R"(%\{[^}]*\})"), "%"));
            auto maxLen = std::min(static_cast<std::int32_t>(message.size() * 3), 65535);
            std::vector<char> buffer(maxLen);
            va_list args;
            va_start(args, fmt);
            int len = vsnprintf(buffer.data(), maxLen, message.data(), args);
            va_end(args);
            if (len < 0) {
                std::cout << GREEN << file << "(" << line << ")" << "\t" << "log vsnprintf error:"<< len << RESET << std::endl;
                return ;
            }

            if (len >= maxLen) {
                // 缓冲区不足，重新分配足够空间（+1 用于 '\0'）
                buffer.resize(len + 1);
                va_start(args, fmt);
                vsnprintf(buffer.data(), buffer.size(), message.c_str(), args);
                va_end(args);
            }

            message = std::string(buffer.data(), len);
        }
    } catch (const std::regex_error &e) {
        std::cerr << "Regex error: " << e.what()
                << " (code: " << e.code() << ")" << std::endl;
    } catch (const std::exception &e) {
        printf("error: %s\n", e.what());
    }


    switch (level) {
        case LogLevel::DEBUG:
            std::cout << GREEN << file << "(" << line << ")" << "\t" << message << RESET << std::endl;
            break;
        case LogLevel::INFO:
            std::cout << BLUE << file << "(" << line << ")" << "\t" << message << RESET << std::endl;
            break;
        case LogLevel::WARN:
            std::cout << YELLOW << file << "(" << line << ")" << "\t" << message << RESET << std::endl;
            break;
        case LogLevel::ERROR:
            std::cout << RED << file << "(" << line << ")" << "\t" << message << RESET << std::endl;
            break;
    }
}
