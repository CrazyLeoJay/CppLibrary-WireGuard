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

/**
 * VPN会话管理器（VEA进程内）
 *
 * 【架构定位】按"稳定性完全由C层实现"的分层原则，本类只做VEA侧的会话编排：
 * - START/SWITCH/STOP/RESTART 四类指令的执行（启停连接、准备配置、清理状态）
 * - 消费C层上报的SOCKET_ERROR事件 → 重建隧道（维护异常）
 * - 网络变化监听：域名端点重解析整体重建 / IP端点轻量换fd漫游（网络调整）
 * - 流日志观测转发给主进程
 * 握手维护、socket自愈、keepalive、密钥轮换等连接稳定性完全由C层心跳线程负责。
 *
 * @author leojay`fu
 */
import { vpnExtension } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LLog } from '../tools/LLog';
import { WireGuard } from '../model/WGHelper';
import { WGDeviceConfig, WGDBConf } from '../model/entity/WGConfigEntity';
import { VpnConnHelper, makeWGConf2VpnStartConfig } from '../model/WGConnect';
import { StreamDirection, MessageType } from '../../../../Index';
import { StreamLogMessage } from '../model/entity/napi_entity';
import WGTools from '../model/WGTools';
import { VPNChangeHelperV2 } from './VPNChangeHelperV2';

const TAG = "vpn_session"

export class VpnSessionManager {
  private vpnConnection?: VpnConnHelper;
  private currentConfig?: WGDeviceConfig;
  private currentDbConf?: WGDBConf;
  private currentConfigId?: number;
  private hasDomainEndpoint: boolean = false;
  private isReconnecting: boolean = false;
  private netConnection?: connection.NetConnection;
  /** 关闭收尾进行中：拒绝关闭期间的建连/重连（防"STOP前已在途的异步操作"恢复后幽灵建连；随进程关闭作废） */
  private isStopping: boolean = false;
  /** VEA上下文：创建VpnConnection用 */
  private context?: vpnExtension.VpnExtensionContext;
  /** 进程关闭请求回调：VEA广播serviceStopped（明确回复），主进程收到后关闭进程（进程关闭权在主进程） */
  private onRequestProcessClose: () => void;

  constructor(onRequestProcessClose: () => void) {
    this.onRequestProcessClose = onRequestProcessClose;
  }

  setContext(context: vpnExtension.VpnExtensionContext): void {
    this.context = context;
  }

  /** 当前运行的设备配置（主进程状态查询回复时携带connectedIps用） */
  getCurrentConfig(): WGDeviceConfig | undefined {
    return this.currentConfig;
  }

  /** 是否已有活动配置（配置请求轮询据此停止） */
  hasActiveConfig(): boolean {
    return this.currentConfig != undefined;
  }

  /** 销毁：注销网络监听并停掉残留连接（onDestroy路径，尽力而为） */
  async shutdown(): Promise<void> {
    this.unregisterNetConnection();
    if (this.vpnConnection != undefined) {
      try {
        await this.vpnConnection.stopServer();
        LLog.info(TAG, "shutdown: 停止VPN成功");
      } catch (err) {
        LLog.error(TAG, `shutdown: 停止VPN异常: ${JSON.stringify(err)}`);
      }
      this.vpnConnection = undefined;
    } else {
      LLog.info(TAG, "shutdown: vpnConnection已为空，跳过stopServer");
    }
  }

  /** START：首次启动VPN连接 */
  start(configId: number, wgDbConf: WGDBConf): void {
    this.currentConfigId = configId;
    this.currentDbConf = wgDbConf;
    this.resolveAndStartVpn(configId, wgDbConf);
  }

  /**
   * STOP：停止VPN服务（用户关闭 → shutdown路径，进程由主进程关闭）
   *
   * 严格按序（ability层已先行注销CommonEvent指令订阅，状态机"聋掉"）：
   * 1. 注销网络监听（本层）；
   * 2. stopServer：destroy注销系统VPN配置（路由+DNS，重试预算内完成，耗尽广播残留提示）
   *    → 停止VPN服务（client.close）；
   * 3. 广播 VPN_SERVICE_STOPPED（明确回复：网络已拆干净）。
   * 本进程不再自我关闭——进程关闭权在主进程（收到VPN_SERVICE_STOPPED后
   * stopVpnExtensionAbility）。
   */
  async stop(): Promise<void> {
    LLog.info(TAG, '停止VPN服务(shutdown路径)');
    this.isStopping = true;   // 关闭收尾开始：期间的建连/重连请求一律拒绝

    // 1. 注销本层网络监听
    this.unregisterNetConnection();

    // 2. destroy（重试预算，耗尽广播残留提示）→ 停止VPN服务
    if (this.vpnConnection != undefined) {
    try {
      await this.vpnConnection.stopServer();
      LLog.info(TAG, 'stop: VPN网络已注销、VPN服务已停止');
    } catch (e) {
      LLog.error(TAG, `stop: destroy预算耗尽，VPN网络/DNS可能残留: ${JSON.stringify(e)}`);
      VPNChangeHelperV2.startVpnThrow('VPN已关闭但系统DNS可能残留，建议开关一次WiFi/飞行模式');
    }
    this.vpnConnection = undefined;
    } else {
      LLog.info(TAG, 'stop: vpnConnection已为空，跳过stopServer');
    }

    this.currentConfig = undefined;
    this.hasDomainEndpoint = false;
    this.isReconnecting = false;

    WireGuard.config.status.vpnStop();

    // 3. 广播明确回复（主进程收到后 stopVpnExtensionAbility 关闭VEA进程）
    VPNChangeHelperV2.serviceStopped();
  }

  /** SWITCH：切换到新配置（先准备新配置，成功后才停旧连接） */
  async switchTo(configId: number, wgDbConf: WGDBConf): Promise<void> {
    LLog.info(TAG, `切换VPN配置: configId=${configId}`);

    // 1. 先解析并准备新配置（DNS解析等），此期间旧连接保持可用（减少中断窗口）
    let newConfig: WGDeviceConfig | undefined;
    for (let attempt = 1; attempt <= 2; attempt++) {
      try {
        newConfig = await makeWGConf2VpnStartConfig(wgDbConf);
        break;
      } catch (e) {
        LLog.warn(TAG, `切换配置准备第${attempt}次失败: ${JSON.stringify(e)}`);
        if (attempt < 2) {
          await new Promise<void>((resolve) => setTimeout(resolve, 1500));
        }
      }
    }
    if (newConfig == undefined) {
      // 切换失败：用户意图是新配置，不回退旧配置——停掉当前连接并上报错误
      LLog.error(TAG, '切换配置准备失败，停止当前连接并上报错误');
      try {
        await this.vpnConnection?.stopServer();
      } catch (e) {
        LLog.error(TAG, `停止旧VPN连接异常: ${JSON.stringify(e)}`);
      }
      this.vpnConnection = undefined;
      this.unregisterNetConnection();
      this.currentConfig = undefined;
      this.hasDomainEndpoint = false;
      this.isReconnecting = false;
      VPNChangeHelperV2.startVpnThrow('切换配置失败：新配置准备(含DNS解析)失败');
      return;
    }

    // 2. 新配置已就绪，此时才停止旧连接
    try {
      await this.vpnConnection?.stopServer();
    } catch (e) {
      LLog.error(TAG, `停止旧VPN连接异常: ${JSON.stringify(e)}`);
    }
    this.vpnConnection = undefined;
    this.unregisterNetConnection();

    // 3. 更新配置并启动新连接。启动失败直接上报THROW（主进程回滚开关并Toast提示）；
    //    VEA进程保持存活（允许关闭但保留可加速用户下次启动重试）
    this.currentConfigId = configId;
    this.currentDbConf = wgDbConf;
    this.currentConfig = undefined;
    this.isReconnecting = false;
    const started = await this.startVpnInternal(configId, newConfig, false);
    if (started) {
      LLog.info(TAG, this.hasDomainEndpoint ? "域名配置" : "非域名配置")
      this.registerNetConnection();
    } else {
      LLog.warn(TAG, '切换后新配置启动失败，已上报错误，VEA保持存活等待用户重试');
    }
  }

  /** RESTART：重启当前配置（DNS重解析/网络调整重建） */
  async restart(configId?: number): Promise<void> {
    LLog.info(TAG, `重启VPN配置: configId=${configId ?? this.currentConfigId}`);

    if (configId != undefined) {
      this.currentConfigId = configId;
    }

    if (!this.currentDbConf || this.currentConfigId == undefined) {
      LLog.warn(TAG, '无缓存配置，无法重启');
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

    // 用缓存的配置重新启动。DNS解析可能因网络切换瞬断失败，先重试准备（此时
    // 尚未广播失败，避免主进程回滚），准备耗尽才一次性上报；启动失败不终止VEA
    const restartConfigId = this.currentConfigId;
    const dbConf = this.currentDbConf;
    let newConfig: WGDeviceConfig | undefined;
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        newConfig = await makeWGConf2VpnStartConfig(dbConf);
        break;
      } catch (e) {
        LLog.warn(TAG, `重启配置准备第${attempt}次失败: ${JSON.stringify(e)}`);
        if (attempt < 3) {
          await new Promise<void>((resolve) => setTimeout(resolve, 2000));
        }
      }
    }
    if (newConfig == undefined) {
      LLog.error(TAG, '重启配置准备重试耗尽');
      VPNChangeHelperV2.startVpnThrow('重启失败：配置准备(含DNS解析)重试耗尽');
      return;
    }
    this.currentConfig = newConfig;
    this.hasDomainEndpoint = this.checkHasDomainEndpoint(dbConf);
    // reportFailure=false：后台自动恢复的单次启动失败不广播THROW（不拉掉用户开关），
    // 主进程健康守护/看门狗会按周期继续重试；仅准备重试耗尽（持久性故障）时显式上报
    const started = await this.startVpnInternal(restartConfigId, newConfig, false, false);
    if (started) {
      // 重连后握手维护由C层心跳线程接管；重新注册网络监听
      LLog.info(TAG, this.hasDomainEndpoint ? "域名配置" : "非域名配置")
      this.registerNetConnection();
    } else {
      LLog.warn(TAG, '重启配置启动失败，VEA保持存活等待恢复');
    }
  }

  /** 主进程重连请求（健康守护判定隧道失效后触发） */
  onReconnectRequest(): void {
    LLog.info(TAG, '收到主进程重连请求');
    if (this.isStopping) {
      LLog.warn(TAG, '关闭收尾中，拒绝重连请求');
      return;
    }
    if (this.vpnConnection == undefined) {
      LLog.warn(TAG, 'vpnConnection为空，无法重连');
      return;
    }
    if (this.isReconnecting) {
      LLog.warn(TAG, '正在重连中，跳过重复重连请求');
      return;
    }
    this.restart();
  }

  // ===== 启动 =====

  private async resolveAndStartVpn(id: number, wgDbConf: WGDBConf, terminateOnFailure: boolean = true): Promise<boolean> {
    try {
      const config = await makeWGConf2VpnStartConfig(wgDbConf);
      this.currentConfig = config;
      this.hasDomainEndpoint = this.checkHasDomainEndpoint(wgDbConf);
      const started = await this.startVpnInternal(id, config, terminateOnFailure);
      if (started) {
        // 统一注册网络变化监听：
        // - 域名端点：网络变化后需重新解析DNS，整体重建隧道
        // - IP端点：底层网络切换后旧socket路径可能失效，走轻量换fd漫游
        LLog.info(TAG, this.hasDomainEndpoint ? "域名配置" : "非域名配置")
        this.registerNetConnection();
      }
      return started;
    } catch (e) {
      LLog.error(TAG, `DNS解析或VPN启动失败: ${JSON.stringify(e)}`);
      VPNChangeHelperV2.startVpnThrow(`${e instanceof Error ? e.message : String(e)}`);
      if (terminateOnFailure) {
        this.onRequestProcessClose();
      }
      return false;
    }
  }

  /**
   * 启动VPN连接
   *
   * @param terminateOnFailure 启动失败是否终止VEA进程（切换/重启路径传false保活VEA）
   * @param reportFailure 失败是否广播THROW（后台自动恢复路径传false，避免拉掉用户开关）
   */
  private async startVpnInternal(id: number, config: WGDeviceConfig, terminateOnFailure: boolean = true,
    reportFailure: boolean = true): Promise<boolean> {
    if (this.isStopping) {
      // 关闭收尾期间拒绝建连（防"STOP前已在途的异步操作"恢复后幽灵建连）
      LLog.warn(TAG, '关闭收尾中，拒绝建连');
      return false;
    }
    LLog.debug(TAG, `开启配置:${JSON.stringify(config)}`);
    this.vpnConnection = new VpnConnHelper(vpnExtension.createVpnConnection(this.context), config)
      .setStreamListener((msg) => {
        this.onStreamMessage(msg);
      });

    try {
      await this.vpnConnection.startServer()
      VPNChangeHelperV2.startVpn(id, config);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      LLog.error(TAG, `VPN Error (${err.code}): ${err.message}`);
      // 尽力清理启动失败的半成品连接（TUN/socket），避免残留
      try {
        await this.vpnConnection?.stopServer();
      } catch (stopErr) {
        LLog.warn(TAG, `清理启动失败连接异常: ${JSON.stringify(stopErr)}`);
      }
      this.vpnConnection = undefined;
      if (reportFailure) {
        VPNChangeHelperV2.startVpnThrow(err.message);
      }
      if (terminateOnFailure) {
        this.onRequestProcessClose();
      }
      return false;
    }
  }

  // ===== 流日志观测与异常消费 =====

  /**
   * C层流日志消费（观测转发 + 维护异常）
   *
   * - SOCKET_ERROR（C层链路故障上报：连续发送失败/读线程自愈耗尽/握手失联判死）：
   *   立即重建隧道（维护异常），同时转发主进程作为外发活动信号
   * - 其余流日志：仅转发主进程（观测）
   */
  private onStreamMessage(msg: StreamLogMessage): void {
    const direction = msg.direction == StreamDirection.RECEIVE ? "接收" : "发送";
    const mtype: string = WGTools.getMessageTypeDesc(msg.messageType);
    LLog.info(TAG,
      `Peer 数据流(index:${msg.peerIndex}/${mtype}/Result:${msg.success}) ${direction} length:${msg.sc.length}`);
    if (msg.messageType === MessageType.SOCKET_ERROR) {
      // C层维护职责：链路故障已由C层判定，本层立即重建隧道
      LLog.warn(TAG, `收到Socket链路异常事件：${msg.msg}，立即重建隧道`);
      WireGuard.event.publishVpnStreamLogs(msg);
      if (!this.isReconnecting) {
        this.restart();
      }
      return;
    }
    WireGuard.event.publishVpnStreamLogs(msg);
  }

  // ===== 网络监听与调整（域名端点重解析重建 / IP端点轻量漫游） =====

  private checkHasDomainEndpoint(dbConf: WGDBConf): boolean {
    for (const peer of dbConf.conf.peers) {
      const value = peer.endpoint.ipStrOrDomain;
      if (!this.isDirectIp(value)) {
        return true;
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
      // 防御性注销旧监听：重启/重连路径会再次注册，防止监听器累积
      this.unregisterNetConnection();
      this.netConnection = connection.createNetConnection();
      this.netConnection.on('netAvailable', () => {
        LLog.info(TAG, "网络可用变化，触发DNS重新解析");
        this.onNetworkChanged();
      });
      this.netConnection.on('netLost', () => {
        LLog.info(TAG, "网络丢失");
      });
      this.netConnection.on('netCapabilitiesChange', (data: connection.NetCapabilityInfo) => {
        const type = this.getNetTypeDescription(data);
        LLog.info(TAG, `网络能力变化: ${type}`);
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

  private getNetTypeDescription(data: connection.NetCapabilityInfo): string {
    const bearers = data.netCap.bearerTypes;
    if (bearers.includes(connection.NetBearType.BEARER_CELLULAR)) {
      return '移动数据';
    }
    if (bearers.includes(connection.NetBearType.BEARER_WIFI)) {
      return 'WiFi';
    }
    if (bearers.includes(connection.NetBearType.BEARER_ETHERNET)) {
      return '以太网';
    }
    return '未知网络';
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
    if (this.isStopping || this.isReconnecting || !this.currentDbConf || this.currentConfigId == undefined) {
      return;
    }

    // 域名端点：网络变化后需重新解析DNS，走整体重建
    if (this.hasDomainEndpoint) {
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
      return;
    }

    // IP端点：底层网络切换后旧socket的转发路径可能失效，走轻量漫游——
    // 仅重建底层socket fd（保留TUN/路由与会话），WireGuard在后续心跳/数据发送时
    // 自动漫游到新网络源地址；换fd失败再整体重建
    this.isReconnecting = true;
    try {
      await this.swapSocketForRoam();
    } catch (e) {
      LLog.warn(TAG, `轻量漫游失败，转整体重建: ${JSON.stringify(e)}`);
      await this.restart(this.currentConfigId);
    } finally {
      this.isReconnecting = false;
    }
  }

  /**
   * 网络切换轻量漫游：重建底层socket fd并等待重新protect完成（保留TUN/路由/会话）
   *
   * @throws 换fd或protect失败时抛出，由调用方转整体重建
   */
  private async swapSocketForRoam(): Promise<void> {
    if (this.vpnConnection == undefined) {
      throw new Error('vpnConnection为空，无法轻量漫游');
    }
    LLog.info(TAG, '网络切换：轻量重建socket漫游');
    // VpnConnHelper.swapSocket内部会等待新fd的protect完成后才返回，
    // 不存在"新fd未保护先发包"的路由回环窗口
    await this.vpnConnection.swapSocket();
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
