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
// Created on 2026/3/23.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef WIREGUARD_WGEXCEPTION_H
#define WIREGUARD_WGEXCEPTION_H
#include <cstdarg>
#include <exception>
#include <memory>
#include <string>
#include "version.h"

namespace WireGuard {
    // 错误类型，如果异常有特别处理，可以通过这个类型进行返回并进行相应的处理
    enum struct WGErrType {
        NONE,
        SOCKET_CLOSE_NO_INIT, // socket 未初始化
        SOCKET_CLOSE_SING, // socket 接收到关闭信号
        SOCKET_CLOSE_ALREADY_CLOSE, // socket 早已关闭，无法读取
    };

    class WGException : public std::exception {
    public:
        WGException() : message() {
        };

        WGException(std::string msg) : message(msg) {
        };

        WGException(WGErrType type) : type(type) {
        };

        WGException(const char *format, ...) {
            if (!format) {
                return;
            }
            va_list args;
            va_start(args, format);
            // 先计算所需缓冲区大小
            int len = vsnprintf(nullptr, 0, format, args);
            va_end(args);
            if (len <= 0) {
                //                throw std::runtime_error("Format error");
                message = format;
                return;
            }

            // 分配缓冲区
            std::unique_ptr<char[]> buffer(new char[len + 1]);

            va_start(args, format);
            int result = vsnprintf(buffer.get(), len + 1, format, args);
            va_end(args);

            if (result < 0 || result != len) {
                message = format;
                return;
            }

            message = buffer.get();
        };

        const char *what() const noexcept override { return message.c_str(); }

    private:
        std::string message{};

    public:
        WGErrType type{WGErrType::NONE};
    };
} // namespace WireGuard

#endif // WIREGUARD_WGEXCEPTION_H