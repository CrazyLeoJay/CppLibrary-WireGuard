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
// Created on 2026/4/9.
// @author leojay`fu
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef WIREGUARD_NAPI_TOOLS_H
#define WIREGUARD_NAPI_TOOLS_H

/**
 * Napi 实现工具类
 */
#include "tools/conf_file.h"
#include <node_api.h>

namespace NapiTools {
    struct TsfnContext {
        napi_ref callbackRef;
    };

    struct ThreadData {
        napi_threadsafe_function tsfn;
    };

    napi_value createNvForWGConf(napi_env &env, WireGuard::Tools::WGConf &conf);

    std::string napiGetString(napi_env &env, napi_value obj);

    napi_value makeNapiBool(napi_env &env, const bool &value);
    napi_value makeNapiString(napi_env &env, const std::string &value);
}; // namespace NapiTools

#endif // WIREGUARD_NAPI_TOOLS_H
