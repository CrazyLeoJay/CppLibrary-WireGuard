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
import { StreamDirection, MessageType } from '../../../../Index';
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
 * - V2：支持want.parameters参数直传（API 22+）+ 轮询降级（API 21及容错），支持热切换/更新/重启配置，无需重启Extension
 *
 * 参数直传模式（API 22+）：
 * - runWGConfig启动VEA时通过want.parameters传递id和wgDbConf（JSON字符串）
 * - onCreate优先从want.parameters读取配置，有效则直接执行VPN连接，跳过轮询延迟
 * - API 22+设备可享受即时启动（延迟<1秒），无需等待轮询
 *
 * 轮询降级模式（API 21及参数丢失场景）：
 * - API 21设备：startVpnExtensionAbility的want.parameters不会传递到onCreate，自动降级为轮询
 * - 参数验证失败时（id缺失/无效、wgDbConf缺失/空/无法反序列化）：静默降级为轮询模式
 * - 轮询模式：3秒间隔请求配置，最多30次，通过CONFIG_QUERY/CONFIG_REQUEST事件获取配置
 *
 * 生命周期：
 * - onCreate：通知主进程VEA存活 → 订阅配置指令 → 尝试want.parameters直传 → 降级轮询
 * - onDestroy：停止VPN连接 → 通知主进程VEA关闭 → 清理资源
 *
 * - START：首次启动VPN连接
 * 配置指令（VpnConfigAction）：
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
  private reconnectRequestCancel?: SubEventCancel;
  // 握手超时检测
  private lastHandshakeTime: Map<number, number> = new Map();
  private handshakeCheckTimer?: number;
  /** 最后一次外发活动（SEND流日志）时间戳：失效判定的武装信号 */
  private lastOutboundActivity: number = 0;
  /** 握手过期阈值：3分钟（单位ms） */
  private readonly HANDSHAKE_STALE_THRESHOLD: number = 180000;
  /** 握手检查间隔：1分钟（单位ms） */
  private readonly HANDSHAKE_CHECK_INTERVAL: number = 60000;

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

      // 订阅主进程的重连请求
      this.reconnectRequestCancel = WireGuard.event.subscribeVpnReconnectRequest(() => {
        this.onReconnectRequest();
      });

      // 2. 通知主应用进程：VEA进程已启动（主进程收到后订阅CONFIG_QUERY并回复配置）
      VPNChangeHelperV2.onCreate();

      // 3. 尝试从want.parameters直接获取配置参数（API 22+支持，API 21降级为轮询）
      if (this.tryStartFromWantParameters(want)) {
        LLog.info(TAG, "WGVpnExtAbilityV2 onCreate - 参数直传模式，跳过轮询");
      } else {
        // 参数无效或不存在，降级到轮询模式
        LLog.info(TAG, "WGVpnExtAbilityV2 onCreate - 降级轮询模式");
        this.startConfigQueryPolling();
      }

      LLog.info(TAG, "WGVpnExtAbilityV2 onCreate");
    } catch (e) {
      const t = e as BusinessError;
      LLog.error(TAG, e);
      VPNChangeHelperV2.startVpnThrow(`${t.message}\n${t.stack}`);
      this.selfTerminate();
    }
  }

  /**
   * 尝试从want.parameters中读取id和wgDbConf并直接启动VPN
   *
   * API 22+：startVpnExtensionAbility支持want.parameters传递，可直接获取配置
   * API 21及以下：want.parameters不会传递到onCreate，自动降级为轮询模式
   *
   * @param want 启动时传入的Want对象
   * @returns true=参数有效并已启动VPN，false=参数无效需降级轮询
   */
  private tryStartFromWantParameters(want: Want): boolean {
    const params = want.parameters;
    if (params == null || params == undefined) {
      return false;
    }

    // 读取id参数
    const rawId = params['id'];
    if (rawId == undefined || rawId == null) {
      return false;
    }
    const id = Number(rawId);
    if (isNaN(id)) {
      return false;
    }

    // 读取wgDbConf参数（JSON字符串）
    const rawWgDbConf = params['wgDbConf'];
    if (rawWgDbConf == undefined || rawWgDbConf == null) {
      return false;
    }
    const wgDbConfStr = String(rawWgDbConf);
    if (wgDbConfStr.length === 0) {
      return false;
    }

    // 反序列化wgDbConf并验证结构
    let wgDbConf: WGDBConf;
    try {
      wgDbConf = JSON.parse(wgDbConfStr) as WGDBConf;
      if (wgDbConf == null || wgDbConf.name == undefined || wgDbConf.conf == undefined) {
        return false;
      }
    } catch (e) {
      LLog.warn(TAG, 'want.parameters中wgDbConf反序列化失败，降级轮询');
      return false;
    }

    // 参数有效，直接执行VPN连接
    LLog.info(TAG, 'want.parameters参数有效: id=' + id.toString());
    this.handleStartConfig(id, wgDbConf);
    return true;
  }

  override async onDestroy(): Promise<void> {
    super.onDestroy();
    LLog.info(TAG, "WGVpnExtAbilityV2 onDestroy");

    // 停止握手超时检查
    this.stopHandshakeCheck();

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
    if (this.reconnectRequestCancel != undefined) {
      this.reconnectRequestCancel.cancel();
      this.reconnectRequestCancel = undefined;
    }

    // 注销网络监听
    this.unregisterNetConnection();

    // 通知主进程VEA关闭
    VPNChangeHelperV2.stopVpn();

    // 安全检查：如果vpnConnection未被销毁，则执行stopServer
    // handleStopService可能已经执行过stopServer并设置vpnConnection=undefined
    if (this.vpnConnection != undefined) {
      try {
        await this.vpnConnection.stopServer();
        LLog.info(TAG, "onDestroy: 停止VPN成功");
      } catch (err) {
        LLog.error(TAG, `onDestroy: 停止VPN异常: ${JSON.stringify(err)}`);
      }
      this.vpnConnection = undefined;
    } else {
      LLog.info(TAG, "onDestroy: vpnConnection已销毁，跳过stopServer");
    }
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
    }, 1000);
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
   *
   * 确保stopServer()完成后再将vpnConnection设为undefined，
   * 即使stopServer失败也继续清理，防止VPN路由/DNS残留。
   */
  private async handleStopService(): Promise<void> {
    LLog.info(TAG, '停止VPN服务（保留VEA进程）');

    // 停止握手超时检查
    this.stopHandshakeCheck();

    // 停止VPN连接：await确保destroy和close完成后再设为undefined
    if (this.vpnConnection != undefined) {
      try {
        await this.vpnConnection.stopServer();
        LLog.info(TAG, 'handleStopService: stopServer成功');
      } catch (e) {
        LLog.error(TAG, `handleStopService: stopServer异常，继续清理: ${JSON.stringify(e)}`);
      }
    } else {
      LLog.info(TAG, 'handleStopService: vpnConnection已为空，跳过stopServer');
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

    // 用缓存的配置重新启动。DNS解析可能因网络切换瞬断失败，先重试准备（此时
    // 尚未广播失败，避免主进程回滚），准备耗尽才一次性上报；启动失败不终止VEA
    const restartConfigId = this.currentConfigId;
    const dbConf = this.currentDbConf;
    if (restartConfigId == undefined || dbConf == undefined) {
      LLog.warn(TAG, '无缓存配置，无法重启');
      return;
    }
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
      // 重连后重启握手超时检查已在startVpnInternal内完成；重新注册网络监听
      LLog.info(TAG, this.hasDomainEndpoint ? "域名配置" : "非域名配置")
      this.registerNetConnection();
    } else {
      LLog.warn(TAG, '重启配置启动失败，VEA保持存活等待恢复');
    }
  }

  // ===== 握手超时检测与自动重连 =====

  /**
   * 启动握手超时检查定时器
   *
   * 每隔HANDSHAKE_CHECK_INTERVAL(1分钟)检查一次，
   * 如果所有peer的握手时间都超过HANDSHAKE_STALE_THRESHOLD(3分钟)，
   * 则判定隧道失效，自动触发重连。
   */
  private startHandshakeCheck(): void {
    this.stopHandshakeCheck();
    LLog.info(TAG, `启动握手超时检查: 间隔=${this.HANDSHAKE_CHECK_INTERVAL}ms, 阈值=${this.HANDSHAKE_STALE_THRESHOLD}ms`);
    this.handshakeCheckTimer = setInterval(() => {
      this.checkHandshakeStale();
    }, this.HANDSHAKE_CHECK_INTERVAL);
  }

  /**
   * 停止握手超时检查定时器
   */
  private stopHandshakeCheck(): void {
    if (this.handshakeCheckTimer != undefined) {
      clearInterval(this.handshakeCheckTimer);
      this.handshakeCheckTimer = undefined;
      LLog.info(TAG, '停止握手超时检查');
    }
  }

  /**
   * 检查握手是否过期
   *
   * 如果所有peer的最后一次握手时间都超过阈值（3分钟），
   * 则判定隧道失效，通知主进程并自动重连。
   * 防重入：如果正在重连中则跳过检查。
   */
  private checkHandshakeStale(): void {
    if (this.isReconnecting) {
      LLog.info(TAG, '正在重连中，跳过握手超时检查');
      return;
    }
    if (this.vpnConnection == undefined) {
      LLog.info(TAG, 'vpnConnection为空，跳过握手超时检查');
      return;
    }

    const now = Date.now();
    let allStale: boolean = true;

    // 检查所有peer的握手时间
    this.lastHandshakeTime.forEach((time: number, peerIndex: number) => {
      const elapsed = now - time;
      LLog.info(TAG, `握手检查: peerIndex=${peerIndex}, elapsed=${elapsed}ms, stale=${elapsed > this.HANDSHAKE_STALE_THRESHOLD}`);
      if (elapsed <= this.HANDSHAKE_STALE_THRESHOLD) {
        allStale = false;
      }
    });

    // 如果没有任何握手记录，也判定为失效
    if (this.lastHandshakeTime.size === 0) {
      LLog.warn(TAG, '无握手记录，VPN可能未完成首次握手');
      return;
    }

    // 无近期外发活动时无法区分"空闲"与"失效"（如keepalive=0的空闲隧道没有任何消息），
    // 此时跳过判定，避免对健康空闲隧道反复重连
    if (this.lastOutboundActivity <= 0 || (now - this.lastOutboundActivity) > this.HANDSHAKE_STALE_THRESHOLD) {
      LLog.info(TAG, '握手检查: 近期无外发活动（可能为空闲隧道），跳过失效判定');
      return;
    }

    if (allStale) {
      LLog.warn(TAG, '所有peer握手超时，隧道失效，触发自动重连');
      // 通知主进程隧道失效
      VPNChangeHelperV2.tunnelStale();
      // 自动重连
      this.handleRestartConfig();
    }
  }

  /**
   * 响应主进程的重连请求
   *
   * 当主进程检测到VPN隧道可能失效（如锁屏恢复后），
   * 通过VPN_RECONNECT_REQUEST事件通知VEA执行重连。
   * VEA收到后调用handleRestartConfig()重新解析DNS并重建隧道。
   */
  private onReconnectRequest(): void {
    LLog.info(TAG, '收到主进程重连请求');
    if (this.vpnConnection == undefined) {
      LLog.warn(TAG, 'vpnConnection为空，无法重连');
      return;
    }
    if (this.isReconnecting) {
      LLog.warn(TAG, '正在重连中，跳过重复重连请求');
      return;
    }
    this.handleRestartConfig();
  }

  // ===== VPN启动（复用V1核心逻辑） =====

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
        this.selfTerminate();
      }
      return false;
    }
  }

  /**
   * 启动VPN连接
   *
   * @param terminateOnFailure 启动失败是否终止VEA进程（切换/重启路径传false保活VEA）
   * @param reportFailure 失败是否广播THROW（切换路径传false：需先尝试回退旧配置，
   *                      最终状态由调用方统一上报，避免主进程提前回滚开关意图）
   */
  private async startVpnInternal(id: number, config: WGDeviceConfig, terminateOnFailure: boolean = true,
    reportFailure: boolean = true): Promise<boolean> {
    LLog.debug(TAG, `开启配置:${JSON.stringify(config)}`);
    this.vpnConnection = new VpnConnHelper(vpnExtension.createVpnConnection(this.context), config)
      .setStreamListener((msg) => {
        const direction = msg.direction == StreamDirection.RECEIVE ? "接收" : "发送";
        const mtype: string = WGTools.getMessageTypeDesc(msg.messageType);
        LLog.info(TAG,
          `Peer 数据流(index:${msg.peerIndex}/${mtype}/Result:${msg.success}) ${direction} length:${msg.sc.length}`);
        if (msg.messageType === MessageType.SOCKET_ERROR) {
          // C层上报的链路级故障（连续发送失败/读线程自愈耗尽）：立即重建隧道，
          // 比等待握手超时判定快一个量级；仍转发给主进程作为外发活动信号
          LLog.warn(TAG, `收到Socket链路异常事件：${msg.msg}，立即重建隧道`);
          WireGuard.event.publishVpnStreamLogs(msg);
          if (!this.isReconnecting) {
            this.handleRestartConfig();
          }
          return;
        }
        if (msg.direction === StreamDirection.SEND) {
          // 外发活动时间戳：失效判定仅在有发送尝试时武装（区分空闲与失效）
          this.lastOutboundActivity = Date.now();
        }
        // 记录握手时间，用于握手超时检测
        // 只记接收方向：外发握手尝试在对端不可达时仍会持续发生，不代表隧道可用
        if ((msg.messageType === MessageType.HANDSHAKE_INITIATION ||
          msg.messageType === MessageType.HANDSHAKE_RESPONSE) &&
          msg.direction === StreamDirection.RECEIVE) {
          this.lastHandshakeTime.set(msg.peerIndex, Date.now());
          LLog.info(TAG, `握手时间更新: peerIndex=${msg.peerIndex}, time=${Date.now()}`);
        }
        WireGuard.event.publishVpnStreamLogs(msg);
      });

    try {
      await this.vpnConnection.startServer()
      VPNChangeHelperV2.startVpn(id, config);
      // VPN启动成功后启动握手超时检查
      this.startHandshakeCheck();
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
        this.selfTerminate();
      }
      return false;
    }
  }

  // ===== 网络监听与DNS重连（复用V1逻辑） =====

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
    if (this.isReconnecting || !this.currentDbConf || this.currentConfigId == undefined) {
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
        // 重连后重启握手超时检查
        this.startHandshakeCheck();
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
      await this.handleRestartConfig(this.currentConfigId);
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
      isOpen: false,
      tag: VpnEventTag.STOP_VPN,
      vpnThreadRunning: false,
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
      isOpen: false,
      tag: VpnEventTag.VPN_SERVICE_STOPPED,
      vpnThreadRunning: true,
      connectedIps: VPNChangeHelperV2.cachedConnectedIps,
    };
    WireGuard.event.publishVpnChange(params);
  }

  static startVpnThrow(msg?: WGEventThrowParam): void {
    WireGuard.config.status.vpnStopThrow();
    WireGuard.event.publishVpnThrow(msg);
    WireGuard.event.publishVpnChange({
      isOpen: false,
      tag: VpnEventTag.THROW,
      vpnThreadRunning: false,
      connectedIps: VPNChangeHelperV2.cachedConnectedIps,
    });
  }

  /**
   * VPN隧道失效（握手超时）
   * 通知主进程隧道可能已断开，需要重连
   */
  static tunnelStale(): void {
    const params: VPNEventStatusParams = {
      isOpen: true,
      tag: VpnEventTag.VPN_TUNNEL_STALE,
      vpnThreadRunning: true,
      connectedIps: VPNChangeHelperV2.cachedConnectedIps,
    };
    WireGuard.event.publishVpnChange(params);
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
