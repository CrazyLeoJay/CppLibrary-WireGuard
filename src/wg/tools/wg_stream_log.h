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
 */

/**
 * 这个工具主要用于实现VPN流的日志统计，方便检测和调试
 * Created by Leojay on 2026/7/11.
 *
 * 主要建通socket端口的读取（入栈）和写入（出栈）
 * 需要检测：
 * - 标注当前为接收方还是发送方
 * - 握手过程和结果监听
 * - 触发cookie挑战
 * - 每次请求的数据量
 * - 当前数据是接收还是发出
 *
 *
 * @author leojay`fu
 * @email crazyleojay@163.com
 * @url https://github.com/CrazyLeoJay
 */

#ifndef WG_MAIN_WG_STREAM_LOG_H
#define WG_MAIN_WG_STREAM_LOG_H
#include <functional>
#include <string>

#include "entity.h"

namespace WireGuard {
    namespace StreamLog {
        /**
         * 数据方向
         */
        enum StreamDirection : uint8_t { RECEIVE = 1, SEND = 2 };

        /**
         * 流数据计算
         * 每个Peer单独计算
         */
        struct StreamCalculate {
            uint64_t length; // 当前数据大小
            uint64_t receive_total; // 接收总数据量
            uint64_t send_total; // 发送总数据量
        };

        struct Message {
            std::chrono::system_clock::time_point timestamp; // 时间戳
            PublicKey publicKey; // 使用PublicKey作为主键
            size_t peerIndex; // 顺序索引
            MessageType messageType; // 数据类型
            StreamDirection direction; // 数据方向
            StreamCalculate sc; // 数据大小
            bool success;
            std::string msg;
        };

        typedef std::function<void(Message msg)> StreamLogPrint;
    }
} // WireGuard

#endif //WG_MAIN_WG_STREAM_LOG_H
