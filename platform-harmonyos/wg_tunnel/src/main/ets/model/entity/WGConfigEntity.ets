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

import { DeviceConfig, IPAddress, IPAddressArea, PeerConfig, WGConf } from './napi_entity';
import native from 'libwg_tunnel.so';

/**
 * 额外补充的vpn配置
 */
export interface VPNConfig {
  /**
   * vpn 局域网环境下，需要匹配的ip 需要掩码。
   * 如果要访问vpn局域网中其他设备，跟服务端的掩码配置一样，
   * 如果是单点访问，直接32。不写默认32
   */
  vpnIp?: IPAddressArea,
  dns?: IPAddress[], //
  mtu?: number, // mtu 空则为自动
}

/**
 * 启动vpn需要的配置
 */
export interface WGDeviceConfig {
  name: string; // 配置名称
  vpn: VPNConfig, // vpn调用补充配置
  device: DeviceConfig,
  peers: PeerConfig[],
}

/**
 * 数据库中存储的数据
 * 相对于配置文件，只是多了一个名称，后面进行拓展
 */
export interface WGDBConf {
  name: string; // 配置名称
  conf: WGConf, // 配置文件，包含了vpn配置
}

export async function makeWGConf2VpnStartConfig(conf: WGDBConf): Promise<WGDeviceConfig> {
  // 获取peers 如果有域名 需要将域名转成ip
  let peers: PeerConfig[] = await Promise.all(conf.conf.peers.map(async (item) => {
    const value = item.endpoint.ipStrOrDomain;
    let ip: string;
    if (await native.isIpAddress(value)) {
      ip = value;
    } else {
      ip = await native.dnsToIp(item.endpoint.ipStrOrDomain);
    }
    return {
      publicKey: item.publicKey,
      endpoint: {
        address: {
          ip: ip,
          isIpv4: true,
        },
        port: item.endpoint.port,
      },
      allowedIps: item.allowedIPs,
      preSharedKey: item.preSharedKey,
      keepaliveInterval: item.keepaliveInterval
    } as PeerConfig
  }))
  return {
    name: conf.name,
    vpn: {
      vpnIp: conf.conf.inter.ipArea,
      dns: conf.conf.inter.dns,
    },
    device: {
      privateKey: conf.conf.inter.privateKey,
      listenerPort: conf.conf.inter.listenerPort,
    },
    peers: peers,
  }
}