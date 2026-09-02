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

import native, { WireGuardDevice } from 'libwg_tunnel.so';
import { WGDBConf, WGDeviceConfig } from './entity/WGConfigEntity';
import { vpnExtension } from '@kit.NetworkKit';
import { LLog } from '../tools/LLog';
import WGAppException from '../error/WGAppException';
import { IPAddressArea, PeerConfig, StreamLogMessage } from './entity/napi_entity';
import { WireGuard } from './WGHelper';
import { dnsResolveByMode, getDnsMode } from '../tools/DnsResolve';

const TAG = "WG连接"

/**
 * 处理VPN连接
 *
 * Created on 2026/7/11.
 * @author leojay`fu
 */
export class VpnConnHelper {
  vpnConnection: vpnExtension.VpnConnection
  private client: WireGuardDevice;
  private config: WGDeviceConfig;

  constructor(vpnConnection: vpnExtension.VpnConnection, config: WGDeviceConfig) {
    this.vpnConnection = vpnConnection;
    this.config = config;
    this.client = new native.WireGuardDevice(config);
  }

  setStreamListener(listener: (msg: StreamLogMessage) => void): VpnConnHelper {
    this.client.setStreamLogListener(listener)
    return this;
  }

  /**
   * @throws
   */
  async startServer() {
    LLog.info(TAG, "start server")
    const vpnConfig = makeVpnConfig(this.config)
    LLog.info(TAG, `vpnConfig: ${JSON.stringify(vpnConfig)}`)

    // 启动并创建一个 socketFd
    LLog.info(TAG, "client initVpn")
    const socketFd = await this.client.initVpn(async (fd: number) => {
      LLog.info(TAG, `Socket FD更新: ${fd}`)
      this.vpnConnection.protect(fd).catch((e: BusinessError) => {
        LLog.error(TAG, e)
      });
    });
    if (socketFd < 0) {
      throw new WGAppException(`Socket 通道建立异常：${socketFd}`);
    }
    LLog.info(TAG, "socket 创建")
    // 保护 socket
    await this.vpnConnection.protect(socketFd);
    LLog.info(TAG, "socket 保护")

    // 生成VPN ID 多VPN服务时使用 配置到vpnConfig 中
    // const vpnId = await this.vpnConnection.generateVpnId();
    // vpnConfig.vpnId = vpnId;

    // 启动 VPN
    LLog.info(TAG, "tun create")
    const tunFd = await this.vpnConnection.create(vpnConfig)
    // 启动VPN双读取线程（socket和VPN读取）
    LLog.info(TAG, "client start fd=%d", tunFd)
    await this.client.start(tunFd);
    LLog.info(TAG, "VPN 启动成功")
  }

  /**
   * @throws
   */
  async stopServer() {
    await this.vpnConnection.destroy()
    LLog.info(TAG, "关闭VPN")
    // const client = WireGuard.device;
    // 关闭并释放资源
    await this.client.close()
    LLog.info(TAG, "关闭通道")

  }
}

/**
 * 将客户端配置转为Vpn配置
 *
 * @param config
 * @returns
 */
export function makeVpnConfig(config: WGDeviceConfig): vpnExtension.VpnConfig {
  const vpnIp = config.vpn.vpnIp!;
  const vpnAddress = vpnIp.address.ip!;
  const vpnAddressFamily = vpnIp.address.isIpv4 ? 1 : 2;
  const vpnAddressPrefixLen = vpnIp?.cidr ?? (vpnIp.address.isIpv4 ? 32 : 128)
  const dns = config.vpn.dns ?? []
  const mtu = config.vpn.mtu ?? 1400
  if (config.peers.length == 0) {
    throw new WGAppException("未配置Peer");
  }
  const routes: vpnExtension.RouteInfo[] = config.peers.map((peer) => {
    const remoteIp = peer.endpoint;
    return peer.allowedIps.map((allowed: IPAddressArea) => {
      return {
        interface: "vpn-tun",
        destination: {
          address: { address: allowed.address.ip, family: allowed.address.isIpv4 ? 1 : 2 },
          prefixLength: allowed.cidr ?? (allowed.address.isIpv4 ? 32 : 128),
        },
        gateway: {
          address: vpnAddress,
          family: vpnAddressFamily,
        },
        hasGateway: true,
        isDefaultRoute: true,
      } as vpnExtension.RouteInfo
    })
  }).flat()

  const vpnConfig: vpnExtension.VpnConfig = {
    addresses: [{
      address: { address: vpnAddress, family: vpnAddressFamily }, prefixLength: vpnAddressPrefixLen
    }],
    mtu: mtu,
    dnsAddresses: dns.map((it) => it.ip),
    routes: routes,
  }

  // 校验：trustedApplications 和 blockedApplications 互斥
  const includedApps = config.vpn.includedApplications;
  const excludedApps = config.vpn.excludedApplications;
  const hasIncluded = includedApps !== undefined && includedApps.length > 0;
  const hasExcluded = excludedApps !== undefined && excludedApps.length > 0;
  if (hasIncluded && hasExcluded) {
    throw new WGAppException('黑名单(excludedApplications)和白名单(includedApplications)不能同时有值');
  }

  // 应用过滤映射：includedApplications → trustedApplications（白名单），excludedApplications → blockedApplications（黑名单）
  if (hasIncluded) {
    vpnConfig.trustedApplications = includedApps;
  } else if (hasExcluded) {
    vpnConfig.blockedApplications = excludedApps;
  }

  return vpnConfig;
}

/**
 * 将数据库配置转为VPN启动配置，根据端点类型和解析偏好选择DNS解析策略
 * - 如果端点已经是直接IP地址，直接使用
 * - 如果端点是域名，根据 dnsMode（默认优先IPv4/优先IPv6/强制IPv6/强制IPv4）解析
 *
 * @param conf 数据库配置
 * @returns VPN设备配置
 * @throws WGAppException 域名解析失败时抛出异常
 */
export async function makeWGConf2VpnStartConfig(conf: WGDBConf): Promise<WGDeviceConfig> {
  let peers: PeerConfig[] = await Promise.all(conf.conf.peers.map(async (item) => {
    const value = item.endpoint.ipStrOrDomain;
    let ip: string;
    let isIpv4: boolean;

    if (await native.isIpAddress(value)) {
      // 直接IP地址，无需DNS解析
      ip = value;
      isIpv4 = await WireGuard.Tools.isIpv4(ip);
    } else {
      // DNS解析策略：根据 dnsMode 互斥选项解析
      const mode = getDnsMode(item.endpoint);
      ip = await dnsResolveByMode(item.endpoint.ipStrOrDomain, mode);
      ip = ip.trim();
      if (!ip) {
        throw new WGAppException(`域名解析失败: ${item.endpoint.ipStrOrDomain}`);
      }
      // C++ toIpStr() 对 IPv6 返回带方括号的格式如 [2001:db8::1]，需去除方括号
      // 否则传回 inet_pton(AF_INET6, ...) 时会解析失败
      if (ip.startsWith('[') && ip.endsWith(']')) {
        ip = ip.substring(1, ip.length - 1);
      }
      isIpv4 = await WireGuard.Tools.isIpv4(ip);
    }

    return {
      publicKey: item.publicKey,
      endpoint: {
        address: {
          ip: ip,
          isIpv4: isIpv4,
        },
        port: item.endpoint.port,
      },
      allowedIps: item.allowedIPs,
      preSharedKey: item.preSharedKey,
      keepaliveInterval: item.keepaliveInterval
   } as PeerConfig
   }))

  // 校验：excludedApplications 和 includedApplications 互斥
  validateAppFilterMutualExclusion(conf);

  return {
    name: conf.name,
    vpn: {
      vpnIp: conf.conf.inter.ipArea,
      dns: conf.conf.inter.dns,
      excludedApplications: conf.conf.inter.excludedApplications,
      includedApplications: conf.conf.inter.includedApplications,
    },
    device: {
      deviceName: conf.name,
      privateKey: conf.conf.inter.privateKey,
      listenerPort: conf.conf.inter.listenerPort,
    },
    peers: peers,
  }
}

/**
 * 校验 excludedApplications 和 includedApplications 互斥
 * 两者最多只能有一个有值，否则抛出异常
 */
function validateAppFilterMutualExclusion(conf: WGDBConf): void {
  const excluded = conf.conf.inter.excludedApplications;
  const included = conf.conf.inter.includedApplications;
  const hasExcluded = excluded !== undefined && excluded.length > 0;
  const hasIncluded = included !== undefined && included.length > 0;
  if (hasExcluded && hasIncluded) {
    throw new WGAppException('黑名单(excludedApplications)和白名单(includedApplications)不能同时有值');
  }
}