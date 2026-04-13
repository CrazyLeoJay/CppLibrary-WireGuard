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
// Created on 2026/3/20.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef WIREGUARD_VERSION_H
#define WIREGUARD_VERSION_H

// 定义日志域和标签（需全局唯一）
#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001  // 自定义业务域（0x0000~0xFFFF）
#define LOG_TAG "wireguard_c14"

#include "logs/logs.h"


/**
 * @file version.h
 * @brief WireGuard C++核心库的版本信息定义
 * 
 * 本文件定义了WireGuard C++实现的版本信息，
 * 用于运行时版本检查和调试信息显示。
 * 
 * 版本格式：MAJOR.MINOR.PATCH-suffix
 * - MAJOR: 主版本号，不兼容的API变更
 * - MINOR: 次版本号，向后兼容的功能新增
 * - PATCH: 修订版本号，向后兼容的问题修正
 * - suffix: 特殊标识（如-cpp表示C++端口）
 */

/**
 * @brief WireGuard C++核心库的完整版本字符串
 * 
 * 格式： "1.0.0-cpp"
 * 用于显示和日志记录。
 */
#define WIREGUARD_VERSION "1.0.0-cpp"

/**
 * @brief WireGuard C++核心库的主版本号
 * 
 * 主版本号用于重大API变更的标识。
 * 当前版本：1
 */
#define WIREGUARD_VERSION_MAJOR 1

/**
 * @brief WireGuard C++核心库的次版本号
 * 
 * 次版本号用于向后兼容的功能新增。
 * 当前版本：0
 */
#define WIREGUARD_VERSION_MINOR 0

/**
 * @brief WireGuard C++核心库的修订版本号
 * 
 * 修订版本号用于向后兼容的问题修正。
 * 当前版本：0
 */
#define WIREGUARD_VERSION_PATCH 0

#endif //WIREGUARD_VERSION_H