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

/**
 *
 */
export interface WGDeviceConfig {
  device: DeviceConfig,
  peers: PeerConfig[],
}

export interface DeviceConfig {
  deviceName: string,
  privateKey: string,
  publicKey: string,
  listenerPort?: number, // 监听端口
  bindAddress?: IPAddress, // 多网卡情况下，需要执行要绑定的ip
  // ========== 以下为非传入Client客户端字段，在VPN网关配置 =============
  /**
   * vpn 局域网环境下，需要匹配的ip 需要掩码。
   * 如果要访问vpn局域网中其他设备，跟服务端的掩码配置一样，
   * 如果是单点访问，直接32。不写默认32
   */
  vpnIp?: IPAddress,
  dns?: string[], //
  mtu?: number, // mtu 空则为自动
}

export interface PeerConfig {
  publicKey: string,
  endpoint: WebSitePoint, // 远程端点，用于连接 需要 (ip/域名) 和 端口，在链接时需要替换为ip
  preSharedKey?: string, // 共享参数可以为 空 必要时加强安全性（ps：我觉得可以配置自动生成）
  allowedIps: IPAddress[], // 需要路由的IP段，这里需要配置掩码。判断ip值时，强制需要配置掩码
  keepaliveInterval?: number, // 单位默认s
}

/**
 * 站点：域名或者ip地址 和 端口
 * 域名和ip地址都可
 */
export interface WebSitePoint {
  ipStrOrDomain: string; // ip地址或者域名
  port: number; // 远程端口，没有默认80
}

export interface IPAddress {
  // domain:string; // 域名，有些时候，会优先配置域名，需要先解析成ip再启动，每次解析后先缓存到本地，本地可以尝试ping，或者健康检查
  ip: string; // 可以包含掩码，底层会自动解析 也可能是域名
  isIpv4: boolean;
  cidr?: number;
}