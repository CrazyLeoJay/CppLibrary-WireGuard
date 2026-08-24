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
import { StatusConfigDTO } from '../WGConfig';

/**
 * VPN 状态参数 - 用于跨进程（VPN进程 ↔ 主应用进程）广播传递VPN状态
 *
 * 【架构背景】
 * VPN Extension (WGVpnExtAbility) 运行在独立进程 (:vpn)，
 * 主应用 (EntryAbility) 运行在主进程 (:main)，
 * 两个进程的 AppStorageV2 数据是隔离的，无法直接共享。
 * 因此通过 CommonEventManager 跨进程广播此参数来同步VPN状态。
 *
 * 【数据流向】
 * - VPN进程 → 主应用进程：VPN启动成功/停止/异常时，VPN进程通过 publishVpnChange() 广播此参数
 * - 主应用进程 → VPN进程：主应用通过 publishVpnStatusQuery() 请求VPN进程广播最新状态
 * - 主应用进程 → 主应用进程：用户主动关闭VPN时，主应用通过 publishVpnChange() 广播 userManuallyStopped=true
 *
 * 【为什么status用StatusConfigDTO而非StatusConfig】
 * 跨进程序列化通过 JSON.stringify/parse 传递，StatusConfig 的 @Trace 属性名会被加
 * __ob_ 前缀导致反序列化失败，StatusConfigDTO 是无装饰器的纯数据类，序列化正常。
 *
 * Created on 2026/7/10.
 * @author leojay`fu
 */
export default interface VPNEventStatusParams {
  isOpen: boolean,                   // VPN是否处于开启状态
  tag?: string,                      // 事件标签，用于区分事件来源（如 "startVpn"/"stop vpn"/"throw"等）
  status?: StatusConfigDTO,          // VPN运行状态（纯数据DTO，用于跨进程序列化）
  connectedIps?: Record<number, string>, // peerIndex -> 实际连接的IP地址（域名端点DNS解析后的IP）
  userManuallyStopped?: boolean      // 【跨进程同步标记】用户是否主动关闭了VPN
                                       // true = 用户主动关闭，主应用进程和VPN进程都应感知，阻止自动重连
                                       // 此标记由以下场景设置：
                                       //   1. 主应用进程：用户在UI关闭VPN时，通过广播通知VPN进程
                                       //   2. VPN进程：VPN启动成功时清除(clearManuallyStopped)，并通过广播同步给主应用进程
}
