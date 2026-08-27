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
 * VPN状态事件标签枚举
 *
 * 标识VPN状态广播的事件来源，主应用进程可据此判断事件类型并采取不同行为：
 * - ON_CREATE：VPN Extension进程启动（onCreate回调），此时连接尚未建立
 * - START_VPN：VPN连接建立成功
 * - STOP_VPN：VPN正常停止（onDestroy回调）
 * - THROW：VPN运行异常，连接断开
 * - QUERY_STATUS：查询VPN状态的回复
 * - QUERY_NO_RUNNING：查询时VPN进程未运行
 * - NO_START_VPN：VPN未能启动
 */
export enum VpnEventTag {
  /** VPN Extension进程启动（onCreate） */
  ON_CREATE = 'onCreate',
  /** VPN连接建立成功 */
  START_VPN = 'startVpn',
  /** VPN正常停止 */
  STOP_VPN = 'stopVpn',
  /** VPN运行异常 */
  THROW = 'throw',
  /** 查询状态回复 */
  QUERY_STATUS = 'queryStatus',
  /** 查询时VPN未运行 */
  QUERY_NO_RUNNING = 'queryNoRunning',
  /** VPN未能启动 */
  NO_START_VPN = 'noStartVpn',
}

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
 *
 * 【为什么status用StatusConfigDTO而非StatusConfig】
 * 跨进程序列化通过 JSON.stringify/parse 传递，StatusConfig 的 @Trace 属性名会被加
 * __ob_ 前缀导致反序列化失败，StatusConfigDTO 是无装饰器的纯数据类，序列化正常。
 *
 * 【关于记录是否主动关闭问题】
 * 由于用户还可以主动杀后台进行关闭行为，所以主要谈保活，不考虑重启。
 *
 * 【tag字段说明】
 * tag为VpnEventTag枚举值，跨进程序列化时为字符串，反序列化后需手动还原为枚举：
 *   const tag = params.tag as VpnEventTag;
 *
 * Created on 2026/7/10.
 * @author leojay`fu
 */
export default interface VPNEventStatusParams {
  isOpen: boolean,                       // VPN是否处于开启状态
  tag?: string,                          // 事件标签（VpnEventTag枚举值，序列化后为字符串）
  status?: StatusConfigDTO,              // VPN运行状态（纯数据DTO，用于跨进程序列化）
  connectedIps?: Record<number, string>, // peerIndex -> 实际连接的IP地址（域名端点DNS解析后的IP）
  vpnThreadRunning?: boolean,            // VPN线程是否正在运行（onCreate时为true，onDestroy/关闭时为false）
}
