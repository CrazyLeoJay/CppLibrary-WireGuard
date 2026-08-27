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
import { BusinessError } from '@kit.BasicServicesKit';
import { LLog } from '../tools/LLog';
import { WireGuard } from '../model/WGHelper';
import { WGDeviceConfig, WGDBConf } from '../model/entity/WGConfigEntity';
import { VpnConnHelper, makeWGConf2VpnStartConfig } from '../model/WGConnect';
import { StreamDirection } from '../../../../Index';
import { WGEventThrowParam } from '../error/WGEventThrow';
import WGTools from '../model/WGTools';
import VPNEventStatusParams, { VpnEventTag } from '../model/entity/VPNEventStatusParams';
import { VpnConfigAction, VpnConfigRequestParams } from '../model/entity/VpnConfigAction';
import { SubEventCancel } from '../model/WGEvent';

const TAG = "vpn_ability_v2"

/**
 * WGVpnExtAbility V2 - 事件驱动的VPN Extension
 *
 * 与V1的区别：
 * - V1：启动时通过 want.parameters 传入配置，切换配置需重启整个Extension
 * - V2：启动时不传配置，onCreate后通过事件请求配置；支持热切换/更新/重启配置，无需重启Extension
 *
 * 生命周期：
 * - onCreate：通知主进程VEA存活 → 订阅配置指令 → 轮询请求配置
 * - onDestroy：停止VPN连接 → 通知主进程VEA关闭 → 清理资源
 *
 * 配置指令（VpnConfigAction）：
 * - START：首次启动VPN连接
 * - STOP：停止VPN服务但保留VEA进程（用于快速切换）
 * - SWITCH：切换到新配置（先停后启）
 * - RESTART：重启当前配置（DNS重解析）
 *
 * 长时任务由主进程的EntryAbility管理，跟随VEA的vpnThreadRunning状态。
 *
 * Created on 2026/8/27.
 * @author leojay`fu
 */
export default class WGVpnExtAbilityV2 extends VpnExtensionAbility {
  private vpnConnection?: VpnConnHelper;
  private currentConfig?: WGDeviceConfig;
  private currentDbConf?: WGDBConf;
  private currentConfigId?: number;
  private hasDomainEndpoint: boolean = false;
  private isReconnecting: boolean = false;
  private netConnection?: connection.NetConnection;

  // V2: 配置请求轮询
  private configQueryTimer?: number;
  private configQueryRetries: number = 0;
  // V2: 事件订阅句柄
  private configRequestCancel?: SubEventCancel;
  private vpnStatusQueryCancel?: SubEventCancel;

  override onCreate(want: Want): void {
    super.onCreate(want);
    try {
      // 1. 先订阅事件，确保收到主进程回复
      this.vpnStatusQueryCancel = WireGuard.event.subscribeVpnStatusQuery(() => {
        VPNChangeHelperV2.queryStatus(this.currentConfig);
      });

      this.configRequestCancel = WireGuard.event.subscribeVpnConfigRequest((params) => {
        this.onConfigRequest(params);
      });

      // 2. 通知主应用进程：VEA进程已启动（主进程收到后订阅CONFIG_QUERY并回复配置）
      VPNChangeHelperV2.onCreate();

      // 3. 启动配置请求轮询
      this.startConfigQueryPolling();

      LLog.info(TAG, "WGVpnExtAbilityV2 onCreate");
    } catch (e) {
      const t = e as BusinessError;
      LLog.error(TAG, e);
      VPNChangeHelperV2.startVpnThrow(`${t.message}\n${t.stack}`);
      this.selfTerminate();
    }
  }

  override onDestroy(): void {
    super.onDestroy();
    LLog.info(TAG, "WGVpnExtAbilityV2 onDestroy");

    // 停止配置请求轮询
    this.stopConfigQueryPolling();

    // 取消事件订阅
    if (this.configRequestCancel != undefined) {
      this.configRequestCancel.cancel();
      this.configRequestCancel = undefined;
    }
    if (this.vpnStatusQueryCancel != undefined) {
      this.vpnStatusQueryCancel.cancel();
      this.vpnStatusQueryCancel = undefined;
    }

    // 注销网络监听
    this.unregisterNetConnection();

    // 通知主进程VEA关闭
    VPNChangeHelperV2.stopVpn();

    // 停止VPN连接
    this.vpnConnection?.stopServer()
      .then(() => {
        LLog.info(TAG, "停止VPN成功");
      })
      .catch((err: BusinessError) => {
        LLog.error(TAG, err);
      });
  }

  // ===== 配置请求轮询 =====

  private startConfigQueryPolling(): void {
    this.stopConfigQueryPolling();
    this.configQueryRetries = 0;

    // 立即发一次
    this.doConfigQuery();

    // 3秒间隔轮询
    this.configQueryTimer = setInterval(() => {
      if (this.currentConfig != undefined) {
        this.stopConfigQueryPolling();
        return;
      }
      if (this.configQueryRetries >= 30) {
        LLog.error(TAG, '配置请求超时(30次)，关闭VEA');
        this.stopConfigQueryPolling();
        this.selfTerminate();
        return;
      }
      this.doConfigQuery();
    }, 3000);
  }

  private stopConfigQueryPolling(): void {
    if (this.configQueryTimer != undefined) {
      clearInterval(this.configQueryTimer);
      this.configQueryTimer = undefined;
    }
  }

  private doConfigQuery(): void {
    this.configQueryRetries++;
    WireGuard.event.publishVpnConfigQuery();
    LLog.info(TAG, `配置请求已发送, 第${this.configQueryRetries}次`);
  }

  private selfTerminate(): void {
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((bundleInfo) => {
        vpnExtension.stopVpnExtensionAbility({
          deviceId: '',
          bundleName: bundleInfo.name,
          abilityName: 'WGVpnExtAbility',
        }).catch((e: BusinessError) => {
          LLog.error(TAG, `自关闭VEA失败: ${e.message}`);
        });
      });
  }

  // ===== 配置指令处理 =====

  private onConfigRequest(params: VpnConfigRequestParams): void {
    const action = params.action as VpnConfigAction;
    LLog.info(TAG, `收到配置指令: action=${action}, configId=${params.configId}`);

    switch (action) {
      case VpnConfigAction.START:
        if (params.configId != undefined && params.wgDbConf) {
          this.handleStartConfig(params.configId, params.wgDbConf);
        } else {
          LLog.error(TAG, 'START指令缺少configId或wgDbConf');
        }
        break;
      case VpnConfigAction.STOP:
        this.handleStopService();
        break;
      case VpnConfigAction.SWITCH:
        if (params.configId != undefined && params.wgDbConf) {
          this.handleSwitchConfig(params.configId, params.wgDbConf);
        } else {
          LLog.error(TAG, 'SWITCH指令缺少configId或wgDbConf');
        }
        break;
      case VpnConfigAction.RESTART:
        this.handleRestartConfig(params.configId);
        break;
      default:
        LLog.warn(TAG, `未知action: ${action}`);
        break;
    }
  }

  /**
   * START：首次启动VPN连接
   */
  private handleStartConfig(configId: number, wgDbConf: WGDBConf): void {
    // 停止轮询
    this.stopConfigQueryPolling();

    // 存储配置
    this.currentConfigId = configId;
    this.currentDbConf = wgDbConf;

    // 启动VPN
    this.resolveAndStartVpn(configId, wgDbConf);
  }

  /**
   * STOP：停止VPN服务但保留VEA进程
   */
  private async handleStopService(): Promise<void> {
    LLog.info(TAG, '停止VPN服务（保留VEA进程）');

    // 停止VPN连接
    try {
      await this.vpnConnection?.stopServer();
    } catch (e) {
      LLog.error(TAG, `停止VPN连接异常: ${JSON.stringify(e)}`);
    }
    this.vpnConnection = undefined;

    // 注销网络监听
    this.unregisterNetConnection();

    // 清理配置状态
    this.currentConfig = undefined;
    this.hasDomainEndpoint = false;
    this.isReconnecting = false;

    // 更新VPN进程本地状态
    WireGuard.config.status.vpnStop();

    // 通知主进程：VPN服务停止但VEA存活
    VPNChangeHelperV2.serviceStopped();
  }

  /**
   * SWITCH：切换到新配置（先停后启）
   */
  private async handleSwitchConfig(configId: number, wgDbConf: WGDBConf): Promise<void> {
    LLog.info(TAG, `切换VPN配置: configId=${configId}`);

    // 1. 停止旧连接
    try {
      await this.vpnConnection?.stopServer();
    } catch (e) {
      LLog.error(TAG, `停止旧VPN连接异常: ${JSON.stringify(e)}`);
    }
    this.vpnConnection = undefined;

    // 2. 注销网络监听
    this.unregisterNetConnection();

    // 3. 更新配置
    this.currentConfigId = configId;
    this.currentDbConf = wgDbConf;
    this.currentConfig = undefined;
    this.isReconnecting = false;

    // 4. 启动新配置
    this.resolveAndStartVpn(configId, wgDbConf);
  }

  /**
   * RESTART：重启当前配置（DNS重解析）
   */
  private async handleRestartConfig(configId?: number): Promise<void> {
    LLog.info(TAG, `重启VPN配置: configId=${configId ?? this.currentConfigId}`);

    // 如果有新configId则更新
    if (configId != undefined) {
      this.currentConfigId = configId;
    }

    // 必须有缓存的数据库配置才能重启
    if (!this.currentDbConf || this.currentConfigId == undefined) {
      LLog.warn(TAG, '无缓存配置，无法重启，发送配置请求');
      this.startConfigQueryPolling();
      return;
    }

    // 停止旧连接
    try {
      await this.vpnConnection?.stopServer();
    } catch (e) {
      LLog.error(TAG, `停止旧VPN连接异常: ${JSON.stringify(e)}`);
    }
    this.vpnConnection = undefined;
    this.currentConfig = undefined;
    this.isReconnecting = false;

    // 用缓存的配置重新启动
    this.resolveAndStartVpn(this.currentConfigId, this.currentDbConf);
  }

  // ===== VPN启动（复用V1核心逻辑） =====

  private async resolveAndStartVpn(id: number, wgDbConf: WGDBConf): Promise<void> {
    try {
      const config = await makeWGConf2VpnStartConfig(wgDbConf);
      this.currentConfig = config;
      this.hasDomainEndpoint = this.checkHasDomainEndpoint(config);
      this.startVpnInternal(id, config);
      if (this.hasDomainEndpoint) {
        this.registerNetConnection();
      }
    } catch (e) {
      LLog.error(TAG, `DNS解析或VPN启动失败: ${JSON.stringify(e)}`);
      VPNChangeHelperV2.startVpnThrow(`${e instanceof Error ? e.message : String(e)}`);
      this.selfTerminate();
    }
  }

  private startVpnInternal(id: number, config: WGDeviceConfig): void {
    LLog.debug(TAG, `开启配置:${JSON.stringify(config)}`);
    this.vpnConnection = new VpnConnHelper(vpnExtension.createVpnConnection(this.context), config)
      .setStreamListener((msg) => {
        const direction = msg.direction == StreamDirection.RECEIVE ? "接收" : "发送";
        const mtype: string = WGTools.getMessageTypeDesc(msg.messageType);
        LLog.info(TAG, `Peer 数据流(index:${msg.peerIndex}/${mtype}/Result:${msg.success}) ${direction} length:${msg.sc.length}`);
        WireGuard.event.publishVpnStreamLogs(msg);
      });

    this.vpnConnection.startServer()
      .then(() => {
        VPNChangeHelperV2.startVpn(id, config);
      })
      .catch((e: BusinessError) => {
        LLog.error(TAG, `VPN Error (${e.code}): ${e.message}`);
        VPNChangeHelperV2.startVpnThrow(e.message);
        this.selfTerminate();
      });
  }

  // ===== 网络监听与DNS重连（复用V1逻辑） =====

  private checkHasDomainEndpoint(config: WGDeviceConfig): boolean {
    for (const peer of config.peers) {
      if (peer.endpoint) {
        const ip = peer.endpoint.address.ip;
        if (!this.isDirectIp(ip)) {
          return true;
        }
      }
    }
    return false;
  }

  private isDirectIp(ip: string): boolean {
    const ipv4Regex = /^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$/;
    const ipv6Regex = /^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$/;
    return ipv4Regex.test(ip) || ipv6Regex.test(ip);
  }

  private registerNetConnection(): void {
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

  private unregisterNetConnection(): void {
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

  private async onNetworkChanged(): Promise<void> {
    if (this.isReconnecting || !this.currentDbConf || this.currentConfigId == undefined) {
      return;
    }
    if (!this.hasDomainEndpoint) {
      return;
    }

    this.isReconnecting = true;
    LLog.info(TAG, "网络环境变化，开始重新解析域名并重连VPN");

    try {
      const newConfig = await makeWGConf2VpnStartConfig(this.currentDbConf);

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
      this.startVpnInternal(this.currentConfigId, newConfig);
    } catch (e) {
      LLog.error(TAG, `网络变化重连异常: ${JSON.stringify(e)}`);
    } finally {
      this.isReconnecting = false;
    }
  }

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
}

/**
 * V2 VPN状态变化辅助类
 *
 * 与V1 VPNChangeHelper的区别：
 * - 新增 serviceStopped()：VPN服务停止但VEA进程存活（vpnThreadRunning=true）
 * - startVpnThrow 不再自动关闭VEA（V2模式下VEA可能继续服务）
 */
class VPNChangeHelperV2 {
  private static cachedConnectedIps?: Record<number, string>;

  static onCreate(): void {
    WireGuard.event.publishVpnChange({ isOpen: false, tag: VpnEventTag.ON_CREATE, vpnThreadRunning: true });
  }

  static startVpn(id: number, config?: WGDeviceConfig): void {
    WireGuard.config.status.vpnStartRun(id);
    const params: VPNEventStatusParams = { isOpen: true, tag: VpnEventTag.START_VPN, vpnThreadRunning: true };
    if (config) {
      const connectedIps: Record<number, string> = {};
      config.peers.forEach((peer, index) => {
        connectedIps[index] = peer.endpoint.address.ip;
      });
      params.connectedIps = connectedIps;
      VPNChangeHelperV2.cachedConnectedIps = connectedIps;
    }
    WireGuard.event.publishVpnChange(params);
  }

  static stopVpn(): void {
    WireGuard.config.status.vpnStop();
    const params: VPNEventStatusParams = {
      isOpen: false, tag: VpnEventTag.STOP_VPN, vpnThreadRunning: false,
      connectedIps: VPNChangeHelperV2.cachedConnectedIps,
    };
    WireGuard.event.publishVpnChange(params);
  }

  /**
   * VPN服务停止但VEA进程存活
   * 主进程收到后应保持长时任务运行，仅更新通知内容
   */
  static serviceStopped(): void {
    const params: VPNEventStatusParams = {
      isOpen: false, tag: VpnEventTag.VPN_SERVICE_STOPPED, vpnThreadRunning: true,
      connectedIps: VPNChangeHelperV2.cachedConnectedIps,
    };
    WireGuard.event.publishVpnChange(params);
  }

  static startVpnThrow(msg?: WGEventThrowParam): void {
    WireGuard.config.status.vpnStopThrow();
    WireGuard.event.publishVpnThrow(msg);
    WireGuard.event.publishVpnChange({
      isOpen: false, tag: VpnEventTag.THROW, vpnThreadRunning: false,
      connectedIps: VPNChangeHelperV2.cachedConnectedIps,
    });
  }

  static queryStatus(config?: WGDeviceConfig): void {
    const isOpen = WireGuard.config.status.getConfig().isOpen();
    const params: VPNEventStatusParams = { isOpen: isOpen, tag: VpnEventTag.QUERY_STATUS, vpnThreadRunning: true };
    if (config) {
      const connectedIps: Record<number, string> = {};
      config.peers.forEach((peer, index) => {
        connectedIps[index] = peer.endpoint.address.ip;
      });
      params.connectedIps = connectedIps;
      VPNChangeHelperV2.cachedConnectedIps = connectedIps;
    } else if (VPNChangeHelperV2.cachedConnectedIps) {
      params.connectedIps = VPNChangeHelperV2.cachedConnectedIps;
    }
    WireGuard.event.publishVpnChange(params);
  }
}
