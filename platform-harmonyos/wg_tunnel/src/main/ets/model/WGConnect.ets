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
import { dnsResolveByMode, getDnsMode, getDnsScope } from '../tools/DnsResolve';

const TAG = "WG连接"

/** Promise超时包装：超时拒绝，正常完成透传结果/异常 */
function withTimeout<T>(task: Promise<T>, ms: number, what: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${what}超时(${ms}ms)`)), ms);
    task.then((v: T) => {
      clearTimeout(timer);
      resolve(v);
    }, (e: Error) => {
      clearTimeout(timer);
      reject(e);
    });
  });
}

/** destroy 单次尝试超时 */
const DESTROY_ATTEMPT_MS: number = 3000;
/** destroy 重试总预算：耗尽外抛异常交调用方广播残留提示 */
const DESTROY_BUDGET_MS: number = 15000;

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
  /** 最近一次fd的protect任务：swapSocket等待其完成后才返回，密封"新fd未保护先发包"窗口 */
  private latestProtectTask?: Promise<void>;

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
   * 运行时重建底层socket（保留会话与epoll），并等待新fd的protect完成。
   * 用于网络切换后的轻量漫游：WireGuard会自动漫游到新网络源地址，无需整体重建VPN连接。
   *
   * C层swapSocket返回前会同步触发fd变更回调（NAPI主线程直调），此处等待回调中
   * 发起的protect(newFd)完成后才返回，密封"新fd未保护先发包"的路由回环窗口。
   * 剩余暴露仅为C层心跳/TUN线程在protect IPC延迟内的毫秒级发送，且只发生在
   * 网络刚切换的瞬断期，按可接受的在途丢包处理。
   *
   * @returns 新的socket fd
   * @throws WGAppException 重建失败；protect失败时随Promise拒绝抛出（调用方可转整体重建兜底）
   */
  async swapSocket(): Promise<number> {
    const fd = await this.client.resetSocket()
    if (fd < 0) {
      throw new WGAppException(`Socket重建异常：${fd}`)
    }
    if (this.latestProtectTask != undefined) {
      await this.latestProtectTask
      this.latestProtectTask = undefined
    }
    LLog.info(TAG, `swapSocket完成，新fd=${fd}`)
    return fd
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
      // 记录protect任务供swapSocket等待；单独附catch避免未处理的Promise拒绝
      const task = this.vpnConnection.protect(fd)
      this.latestProtectTask = task
      task.catch((e: BusinessError) => {
        LLog.error(TAG, `protect(fd=${fd})失败: ${JSON.stringify(e)}`)
      })
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
   * 停止VPN服务（shutdown收尾）
   *
   * 顺序：destroy（注销系统VPN配置：路由+DNS——唯一拆除入口，失败/超时重试，
   * 预算耗尽抛出异常交调用方广播残留提示，绝不静默放弃）→ client.close()（停止VPN服务）。
   * 进程退出会丢弃在途的destroy IPC造成系统DNS/路由残留（其他app断网需重启），
   * 因此本方法必须完成后调用方才能继续后续流程。
   *
   * @throws WGAppException destroy 在预算内未完成
   */
  async stopServer(): Promise<void> {
    // 1. 注销系统VPN配置（重试直至完成或预算耗尽）
    const deadline: number = Date.now() + DESTROY_BUDGET_MS;
    let attempt: number = 0;
    let destroyed: boolean = false;
    while (Date.now() < deadline) {
      attempt++;
      try {
        await withTimeout(this.vpnConnection.destroy(), DESTROY_ATTEMPT_MS, `destroy#${attempt}`);
        destroyed = true;
        LLog.info(TAG, `vpnConnection.destroy成功(第${attempt}次尝试)：系统VPN配置已注销`);
        break;
      } catch (e) {
        LLog.error(TAG, `destroy#${attempt}失败: ${JSON.stringify(e)}`);
        await new Promise<void>((resolve) => setTimeout(resolve, 300));
      }
    }
    if (!destroyed) {
      throw new WGAppException(`vpnConnection.destroy在${DESTROY_BUDGET_MS}ms预算内未完成，系统VPN网络/DNS可能残留`);
    }
    // 2. 停止VPN服务（C层：停线程+关UDP socket）
    try {
      await withTimeout(this.client.close(), 3000, 'client.close');
      LLog.info(TAG, 'VPN服务已停止');
    } catch (e) {
      LLog.error(TAG, `client.close失败(网络已注销，忽略): ${JSON.stringify(e)}`);
    }
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
  // Interface Address 支持无掩码配置（cidr=-1 表示未指定），
  // 创建VPN时归一化为默认掩码（IPv4 /32、IPv6 /128），否则 prefixLength=-1 导致create失败
  const vpnAddressPrefixLen = (vpnIp.cidr != undefined && vpnIp.cidr >= 0)
    ? vpnIp.cidr : (vpnIp.address.isIpv4 ? 32 : 128);
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
          prefixLength: (allowed.cidr != undefined && allowed.cidr >= 0)
            ? allowed.cidr : (allowed.address.isIpv4 ? 32 : 128),
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
      const scope = getDnsScope(item.endpoint);
      ip = await dnsResolveByMode(item.endpoint.ipStrOrDomain, mode, scope);
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