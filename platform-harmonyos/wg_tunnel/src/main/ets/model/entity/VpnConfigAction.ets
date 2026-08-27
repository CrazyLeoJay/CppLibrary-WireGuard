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
import { WGDBConf } from './WGConfigEntity';

/**
 * VPN配置操作类型枚举
 *
 * 主应用进程通过 VPN_CONFIG_REQUEST 事件向 VEA 进程下发配置指令，
 * action 字段标识指令类型，VEA据此执行对应操作。
 *
 * - START：首次启动VPN连接（VEA启动后或VPN服务停止后）
 * - STOP：停止VPN服务但不关闭VEA进程（保留进程用于快速切换）
 * - SWITCH：切换到新配置（先停后启，无需重启VEA进程）
 * - RESTART：重启当前配置（DNS重解析场景，如网络变化后重新解析域名端点）
 *
 * 跨进程序列化后为字符串，反序列化后需手动还原：
 *   const action = params.action as VpnConfigAction;
 */
export enum VpnConfigAction {
  /** 启动VPN连接 */
  START = 'start',
  /** 停止VPN服务（不关闭VEA进程） */
  STOP = 'stop',
  /** 切换到新配置（先停后启） */
  SWITCH = 'switch',
  /** 重启当前配置（DNS重解析） */
  RESTART = 'restart',
}

/**
 * VPN配置请求参数 - 主应用进程向VEA进程下发配置指令的载体
 *
 * 通过 VPN_CONFIG_REQUEST 事件跨进程传递，JSON序列化/反序列化。
 * 纯数据接口，不含装饰器，序列化安全。
 *
 * Created on 2026/8/27.
 * @author leojay`fu
 */
export interface VpnConfigRequestParams {
  /** 操作类型（VpnConfigAction枚举值，序列化后为字符串） */
  action: string;
  /** 配置ID（start/switch/restart时必传） */
  configId?: number;
  /** 数据库配置（start/switch时必传，restart时可选——不传则使用VEA缓存的配置） */
  wgDbConf?: WGDBConf;
}
