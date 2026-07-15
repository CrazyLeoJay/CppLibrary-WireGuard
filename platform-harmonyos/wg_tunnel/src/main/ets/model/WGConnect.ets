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
import { IPAddressArea, PeerConfig, SiteUrlType, StreamLogMessage } from './entity/napi_entity';
import { WireGuard } from './WGHelper';

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
  const vpnAddressPrefixLen = vpnIp?.cidr ?? 32
  const dns = config.vpn.dns ?? []
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
    mtu: 1400,
    dnsAddresses: dns.map((it) => it.ip),
    routes: routes,
  }
  return vpnConfig;
}

export async function makeWGConf2VpnStartConfig(conf: WGDBConf): Promise<WGDeviceConfig> {
  // 获取peers 如果有域名 需要将域名转成ip
  let peers: PeerConfig[] = await Promise.all(conf.conf.peers.map(async (item) => {
    const value = item.endpoint.ipStrOrDomain;
    let ip: string;
    let isIpv4 = item.endpoint.type == SiteUrlType.IPv4
    if (await native.isIpAddress(value)) {
      ip = value;
    } else {
      ip = await native.dnsToIp(item.endpoint.ipStrOrDomain);
      ip = ip.trim()
      isIpv4 = await WireGuard.Tools.isIpv4(ip)
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
  return {
    name: conf.name,
    vpn: {
      vpnIp: conf.conf.inter.ipArea,
      dns: conf.conf.inter.dns,
    },
    device: {
      deviceName: conf.name,
      privateKey: conf.conf.inter.privateKey,
      listenerPort: conf.conf.inter.listenerPort,
    },
    peers: peers,
  }
}