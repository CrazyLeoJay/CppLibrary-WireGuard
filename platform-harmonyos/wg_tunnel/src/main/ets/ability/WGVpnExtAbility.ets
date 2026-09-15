/*
 * Copyright [2026] @github-crazyleojay (crazyleojay@163.com/gmail.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { bundleManager, Want } from '@kit.AbilityKit';
import { LLog } from '../tools/LLog';
import { WireGuard } from '../model/WGHelper';
import { WGDeviceConfig, WGDBConf } from '../model/entity/WGConfigEntity';
import { VpnConnHelper, makeWGConf2VpnStartConfig } from '../model/WGConnect';
import { StreamDirection } from '../../../../Index';
import { WGEventThrowParam } from '../error/WGEventThrow';
import WGTools from '../model/WGTools';
import VPNEventStatusParams, { VpnEventTag } from '../model/entity/VPNEventStatusParams';

const TAG = "vpn_ability"

export default class WGVpnExtAbility extends VpnExtensionAbility {
  vpnConnection?: VpnConnHelper;
  private currentConfig?: WGDeviceConfig;
  private currentConf?: WGDBConf;
  private currentConfigId?: number;
  // 网络状态监听连接
  private netConnection?: connection.NetConnection;
  // 防止重连重入的标志
  private isReconnecting: boolean = false;
  // 当前配置是否包含域名端点（需要DNS解析）
  private hasDomainEndpoint: boolean = false;

  override onCreate(want: Want): void {
    super.onCreate(want);
    try {
      // 通知主应用进程：VPN线程已启动（此时连接尚未建立，用于提前请求通知授权）
      VPNChangeHelper.onCreate()

      const params = want.parameters
      if (!params) {
        LLog.error(TAG, "没有配置")
        VPNChangeHelper.startVpnThrow("没有获取到配置")
        return
      }
      WireGuard.event.subscribeVpnStatusQuery(() => {
        VPNChangeHelper.queryStatus(this.currentConfig)
      })

      LLog.info(TAG, "WG VPN onCreate")
      const id = params["id"] as number;

      const wgDbConf = params["wgDbConf"] as WGDBConf;
      if (!wgDbConf) {
        LLog.error(TAG, "VPN 启动时未发现配置")
        VPNChangeHelper.startVpnThrow({
          type: 'want_no_get_args',
          message: "未获取到配置"
        })
        return;
      }

      this.currentConf = wgDbConf;
      this.currentConfigId = id;

      // 在 VPN Extension 内部解析DNS并启动VPN
      this.resolveAndStartVpn(id, wgDbConf);
    } catch (e) {
      const t = e as BusinessError
      LLog.error(TAG, e);
      VPNChangeHelper.startVpnThrow(`${e.message}\n${t.stack}`)
    }
  }

  /**
   * 解析DNS并启动VPN
   * DNS解析失败时会通过 publishVpnThrow 通知UI，VPN不会启动
   * @param id 配置ID
   * @param wgDbConf 数据库配置
   */
  private async resolveAndStartVpn(id: number, wgDbConf: WGDBConf) {
    try {
      const config = await makeWGConf2VpnStartConfig(wgDbConf);
      this.currentConfig = config;
      this.hasDomainEndpoint = this.checkHasDomainEndpoint(wgDbConf);
      this.startVpnInternal(id, config);
      if (this.hasDomainEndpoint) {
        this.registerNetConnection();
      }
    } catch (e) {
      LLog.error(TAG, `DNS解析或VPN启动失败: ${JSON.stringify(e)}`);
      VPNChangeHelper.startVpnThrow(`${e instanceof Error ? e.message : String(e)}`);
    }
  }

  private checkHasDomainEndpoint(dbConf: WGDBConf): boolean {
    for (const peer of dbConf.conf.peers) {
      const value = peer.endpoint.ipStrOrDomain;
      if (!this.isDirectIp(value)) {
        return true;
      }
    }
    return false;
  }

  /**
   * 判断字符串是否为直接IP地址（IPv4或IPv6），非域名
   * @param ip 待判断的字符串
   * @returns 是否为IP地址
   */
  private isDirectIp(ip: string): boolean {
    const ipv4Regex = /^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$/;
    const ipv6Regex = /^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$/;
    return ipv4Regex.test(ip) || ipv6Regex.test(ip);
  }

  /**
   * 启动VPN连接的内部方法：创建VPN连接、设置流监听、启动服务
   * @param id 配置ID
   * @param config VPN设备配置
   */
  private startVpnInternal(id: number, config: WGDeviceConfig) {
    LLog.debug(TAG, `开启配置:${JSON.stringify(config)}`);
    this.vpnConnection = new VpnConnHelper(vpnExtension.createVpnConnection(this.context), config)
      .setStreamListener((msg) => {
        const direction = msg.direction == StreamDirection.RECEIVE ? "接收" : "发送"
        const mtype: string = WGTools.getMessageTypeDesc(msg.messageType);
        LLog.info(TAG,
          `Peer 数据流(index:${msg.peerIndex}/${mtype}/Result:${msg.success}) ${direction} length:${msg.sc.length} `)
        WireGuard.event.publishVpnStreamLogs(msg)
      });

    this.vpnConnection.startServer()
      .then(() => {
        VPNChangeHelper.startVpn(id, config)
      })
      .catch((e: BusinessError) => {
        LLog.error(TAG, `VPN Error (${e.code}): ${e.message}`);
        LLog.error(TAG, e);
        VPNChangeHelper.startVpnThrow(e.message)
      });
  }

  /**
   * 注册网络状态变化监听，当网络可用或连接属性变化时触发DNS重新解析
   */
  private registerNetConnection() {
    try {
      this.netConnection = connection.createNetConnection();
      this.netConnection.on('netAvailable', () => {
        LLog.info(TAG, "网络可用变化，触发DNS重新解析");
        this.onNetworkChanged();
      });
      this.netConnection.on('netLost', () => {
        LLog.info(TAG, "网络丢失");
      });
      this.netConnection.on('netCapabilitiesChange', () => {
        LLog.info(TAG, "网络能力变化");
      });
      this.netConnection.on('netConnectionPropertiesChange', () => {
        LLog.info(TAG, "网络连接属性变化，触发DNS重新解析");
        this.onNetworkChanged();
      });
      this.netConnection.register(() => {
        LLog.info(TAG, "网络状态监听注册成功");
      });
    } catch (e) {
      LLog.error(TAG, `注册网络监听失败: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 注销网络状态变化监听，释放资源
   */
  private unregisterNetConnection() {
    if (this.netConnection) {
      try {
        this.netConnection.unregister(() => {
          LLog.info(TAG, "网络状态监听注销成功");
        });
      } catch (e) {
        LLog.error(TAG, `注销网络监听失败: ${JSON.stringify(e)}`);
      }
      this.netConnection = undefined;
    }
  }

  /**
   * 网络环境变化时的处理：重新解析域名，如果端点IP变化则重连VPN
   * 使用 isReconnecting 标志防止重入
   */
  private async onNetworkChanged() {
    if (this.isReconnecting || !this.currentConf || !this.currentConfigId) {
      return;
    }
    if (!this.hasDomainEndpoint) {
      return;
    }

    this.isReconnecting = true;
    LLog.info(TAG, "网络环境变化，开始重新解析域名并重连VPN");

    try {
      const newConfig = await makeWGConf2VpnStartConfig(this.currentConf);

      const endpointChanged = this.checkEndpointChanged(this.currentConfig!, newConfig);
      if (!endpointChanged) {
        LLog.info(TAG, "域名解析结果未变化，无需重连");
        this.isReconnecting = false;
        return;
      }

      LLog.info(TAG, "域名解析结果已变化，重新连接VPN");

      await this.vpnConnection?.stopServer();
      LLog.info(TAG, "旧VPN连接已停止");

      this.currentConfig = newConfig;
      this.startVpnInternal(this.currentConfigId!, newConfig);
    } catch (e) {
      LLog.error(TAG, `网络变化重连异常: ${JSON.stringify(e)}`);
    } finally {
      this.isReconnecting = false;
    }
  }

  /**
   * 比较新旧配置的端点IP是否发生变化，用于决定是否需要重连
   * @param oldConfig 旧VPN设备配置
   * @param newConfig 新VPN设备配置
   * @returns 端点是否发生变化
   */
  private checkEndpointChanged(oldConfig: WGDeviceConfig, newConfig: WGDeviceConfig): boolean {
    if (oldConfig.peers.length !== newConfig.peers.length) {
      return true;
    }
    for (let i = 0; i < oldConfig.peers.length; i++) {
      const oldPeer = oldConfig.peers[i];
      const newPeer = newConfig.peers[i];
      if (oldPeer.endpoint.address.ip !== newPeer.endpoint.address.ip ||
        oldPeer.endpoint.address.isIpv4 !== newPeer.endpoint.address.isIpv4) {
        LLog.info(TAG, `Peer[${i}] 端点变化: ${oldPeer.endpoint.address.ip} -> ${newPeer.endpoint.address.ip}`);
        return true;
      }
    }
    return false;
  }

  override onDestroy(): void {
    super.onDestroy();
    LLog.info(TAG, "WG VPN onDestroy")
    this.unregisterNetConnection();
    VPNChangeHelper.stopVpn()
    this.vpnConnection?.stopServer()
      .then(() => {
        LLog.info(TAG, "停止VPN成功")
      })
      .catch((err: BusinessError) => {
        LLog.error(TAG, err)
      })
      .finally(() => {})
  }

}

/**
 * Vpn 变化辅助工具
 * 需要先修改状态，然后通知全局VPN变化
 */
class VPNChangeHelper {
  /** 缓存的连接IP，stopVpn等场景无法获取config时使用上次缓存值 */
  private static cachedConnectedIps?: Record<number, string>;

  /**
   * VPN Extension onCreate回调
   *
   * VPN Extension进程启动时调用，通知主应用进程VPN线程已开始运行。
   * 此时VPN连接尚未建立，isOpen=false，但vpnThreadRunning=true表示进程已就绪。
   * 主应用进程收到vpnThreadRunning=true后可提前请求通知授权。
   */
  static onCreate() {
    WireGuard.event.publishVpnChange({ isOpen: false, tag: VpnEventTag.ON_CREATE, vpnThreadRunning: true });
  }

  /**
   * 通知VPN启动成功
   *
   * 【仅在VPN进程调用】VPN连接建立成功后调用
   * 执行流程：
   *   1. vpnStartRun(id) - 更新VPN进程本地状态：running=true, runningConfigId=id
   *   2. publishVpnChange() - 跨进程广播通知主应用进程同步上述状态
   *
   * @param id 配置ID
   * @param config VPN设备配置（用于提取连接IP）
   */
  static startVpn(id: number, config?: WGDeviceConfig) {
    // 1. 更新VPN进程本地状态（VPN进程的AppStorageV2）
    WireGuard.config.status.vpnStartRun(id)
    // 2. 构造广播参数并发布（主应用进程会通过subscribeVpnChange→syncFromVpnProcess同步）
    const params: VPNEventStatusParams = { isOpen: true, tag: VpnEventTag.START_VPN, vpnThreadRunning: true }
    if (config) {
      const connectedIps: Record<number, string> = {}
      config.peers.forEach((peer, index) => {
        connectedIps[index] = peer.endpoint.address.ip
      })
      params.connectedIps = connectedIps
      VPNChangeHelper.cachedConnectedIps = connectedIps
    }
    WireGuard.event.publishVpnChange(params);
  }

  /**
   * 停止VPN服务
   *
   * 【仅在VPN进程调用】WGVpnExtAbility.onDestroy 中调用
   * 执行流程：
   *   1. vpnStop() - 更新VPN进程本地状态：running=false, runningConfigId=undefined
   *   2. publishVpnChange() - 跨进程广播通知主应用进程同步上述状态
   */
  static stopVpn() {
    // 1. 更新VPN进程本地状态
    WireGuard.config.status.vpnStop()
    // 2. 广播通知主应用进程同步，携带缓存的connectedIps和vpnThreadRunning=false
    const params: VPNEventStatusParams = {
      isOpen: false, tag: VpnEventTag.STOP_VPN, vpnThreadRunning: false,
      connectedIps: VPNChangeHelper.cachedConnectedIps,
    }
    WireGuard.event.publishVpnChange(params);
  }

  static startVpnThrow(msg?: WGEventThrowParam) {
    WireGuard.config.status.vpnStopThrow()
    WireGuard.event.publishVpnThrow(msg);
    WireGuard.event.publishVpnChange({
      isOpen: false, tag: VpnEventTag.THROW, vpnThreadRunning: false,
      connectedIps: VPNChangeHelper.cachedConnectedIps,
    });

    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((bundleInfo) => {
        const packageName = bundleInfo.name
        const abilityName = 'WGVpnExtAbility'
        return vpnExtension.stopVpnExtensionAbility({
          deviceId: '',
          bundleName: packageName,
          abilityName: abilityName,
        })
          .then(() => {
            LLog.info(TAG, "异常后正常关闭 VPN Extension ability")
          })
          .catch((e: BusinessError) => {
            LLog.error(TAG, e)
          })
      });
  }

  /**
   * 查询VPN状态，返回时携带每个Peer实际连接的IP（来自VPN进程）
   * @param config 当前VPN设备配置（用于提取连接IP）
   */
  static queryStatus(config?: WGDeviceConfig) {
    const isOpen = WireGuard.config.status.getConfig().isOpen()
    const params: VPNEventStatusParams = { isOpen: isOpen, tag: VpnEventTag.QUERY_STATUS, vpnThreadRunning: true }
    if (config) {
      const connectedIps: Record<number, string> = {}
      config.peers.forEach((peer, index) => {
        connectedIps[index] = peer.endpoint.address.ip
      })
      params.connectedIps = connectedIps
      VPNChangeHelper.cachedConnectedIps = connectedIps
    } else if (VPNChangeHelper.cachedConnectedIps) {
      // 无config时使用缓存值
      params.connectedIps = VPNChangeHelper.cachedConnectedIps
    }
    WireGuard.event.publishVpnChange(params);
  }
}
