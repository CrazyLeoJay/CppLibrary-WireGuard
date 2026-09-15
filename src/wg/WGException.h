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
            // OHOS hilog 格式符（%{public}s / %{private}d 等）不被 vsnprintf 识别，
            // 会令其返回 -1 而把参数整段丢弃；先归一化为标准格式符再格式化
            const std::string fmt = normalizeFormat(format);
            va_list args;
            va_start(args, format);
            // 先计算所需缓冲区大小
            int len = vsnprintf(nullptr, 0, fmt.c_str(), args);
            va_end(args);
            if (len < 0) {
                message = fmt;
                return;
            }

            // 分配缓冲区
            std::unique_ptr<char[]> buffer(new char[len + 1]);

            va_start(args, format);
            int result = vsnprintf(buffer.get(), len + 1, fmt.c_str(), args);
            va_end(args);

            if (result < 0) {
                message = fmt;
                return;
            }

            message.assign(buffer.get(), static_cast<size_t>(result));
        };

        const char *what() const noexcept override { return message.c_str(); }

    private:
        std::string message{};

        /**
         * 将 OHOS 日志格式符归一化为标准 printf 格式符：
         *   "%{public}s" -> "%s"、" %{private}d" -> "%d"、"%{public}lu" -> "%lu"
         * 仅保留一个 '%'，丢弃 {public}/{private} 标记，其余（长度修饰符/转换符）原样保留。
         * 这样 vsnprintf 才能正确替换参数，避免异常信息退化为未替换的格式串。
         */
        static std::string normalizeFormat(const char *format) {
            const std::string src(format);
            std::string out;
            out.reserve(src.size());
            for (size_t i = 0; i < src.size(); ++i) {
                if (src[i] == '%' && i + 1 < src.size() && src[i + 1] == '{') {
                    const size_t closeBrace = src.find('}', i + 2);
                    if (closeBrace != std::string::npos) {
                        out.push_back('%');
                        i = closeBrace; // 跳过 "{...}" 标记
                        continue;
                    }
                }
                out.push_back(src[i]);
            }
            return out;
        }

    public:
        WGErrType type{WGErrType::NONE};
    };
} // namespace WireGuard

#endif // WIREGUARD_WGEXCEPTION_H


// 异常抛出宏，自动包含文件名、行号和函数名
#define THROW_WG_EXCEPTION(format, ...) \
throw WireGuard::WGException("[%s:%d] %s - " format, __FILE__, __LINE__, __func__, ##__VA_ARGS__)

#define THROW_WG_EXCEPTION_SIMPLE(msg) \
throw WireGuard::WGException("[%s:%d] %s - %s", __FILE__, __LINE__, __func__, msg)