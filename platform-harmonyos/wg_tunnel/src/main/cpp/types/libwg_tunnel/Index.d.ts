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
import { DeviceRegisterConfig, KeyPair, StreamLogMessage, WGConf } from '../../../ets/model/entity/napi_entity';

export const makeKeyPair: () => Promise<KeyPair>;

export const genPrivateKey: () => Promise<string>;

export function genPublicKey(privateKey: string): Promise<string>;

export function readWGConf(conf: string): Promise<WGConf>;

export function wgConfToOfficialStr(conf: WGConf): Promise<string>;

export function isIpv4(ip: string): Promise<boolean>;

export function isIpv6(ip: string): Promise<boolean>;

/**
 * 是否为IP地址，ipv4或者ipv6
 * @param ip
 * @returns
 */
export function isIpAddress(ip: string): Promise<boolean>;

/**
 * 是否为域名
 * @param domain
 * @returns
 */
export function isValidDomain(domain: string): Promise<boolean>;

/**
 * 是否为base64位的Key
 * @param key
 * @returns
 */
export function isValidBase64Key(key: string): Promise<boolean>;

/**
 * 将域名转为IP，优先解析IPv4，如果失败则解析IPv6
 */
export function dnsToIp(domain: string): Promise<string>;

/**
 * 将域名转为IP，指定IP类型
 * @param domain 域名
 * @param type IP类型：4=IPv4, 6=IPv6
 */
export function dnsToIpWithType(domain: string, type: number): Promise<string>;

/**
 * @author leojay`fu
 */
export class WireGuardDevice {

  constructor(config: DeviceRegisterConfig);

  /**
   * 创建链接，并且获取 socket的描述符
   *
   * @param config 链接配置
   * @param listener socket fd 切换通知
   * @returns socket 连接符
   */
  // @ts-ignore
  async initVpn(listener: (fd: number) => void): Promise<number>;

  /**
   * 添加数据流监听接口
   * @param listener
   * @returns
   */
  // @ts-ignore
  async setStreamLogListener(listener: (msg: StreamLogMessage) => void): Promise<void>;

  // @ts-ignore
  async start(tunFd: number): Promise<void>;

  /**
   * 更新指定 Peer 的网络端点（DDNS 漂移自愈：重新解析域名后下发新地址，不重启隧道）。
   *
   * @param index Peer 顺序索引（与配置 peers 下标、流日志 peerIndex 一致）
   * @param ip 新的 IP 地址字符串（IPv4/IPv6）
   * @param port 新的端口
   * @returns true=端点已变化、已更新并强制重握手一次；false=未生效，调用方应退化为整隧道重启
   */
  // @ts-ignore
  async updatePeerEndpoint(index: number, ip: string, port: number): Promise<boolean>;

  /**
   * 网络承载切换（WiFi↔蜂窝）快速通道：立即重建本地 Socket 并强制重新握手。
   *
   * 与看门狗故障兜底重建的区别：不发布故障哨兵、不重启隧道，
   * 因此不会触发上层重新解析域名或升级为整隧道重启（α），
   * 恢复耗时在毫秒~秒级且不影响长时任务/通知。
   *
   * @returns true=已受理并请求重建；false=设备未运行 / 读取线程不可用 / 防抖期内被忽略
   */
  // @ts-ignore
  async forceRebindSocket(): Promise<boolean>;

  // @ts-ignore
  async close(): Promise<void>;
}

