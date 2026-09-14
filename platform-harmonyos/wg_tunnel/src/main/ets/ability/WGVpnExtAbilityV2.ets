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
 * WGVpnExtAbility V2 - VPN扩展能力壳（仅生命周期与指令分发）
 *
 * 【架构定位】本类是VEA进程入口的薄壳，连接逻辑全部在 VpnSessionManager：
 * - onCreate：注册未捕获异常监听 → 订阅事件（状态查询/配置指令/重连请求）→
 *   通知主进程VEA存活 → 参数直传启动或降级轮询
 * - onDestroy：停止轮询 → 取消订阅 → 会话收尾 → 通知主进程VEA关闭
 * - 指令分发：START/SWITCH/STOP/RESTART 委托 VpnSessionManager
 *
 * 【异常边界】C层异常在NAPI胶水层捕获转ArkTS；ArkTS未捕获异常经
 * errorManager监听在进程死亡前尽力广播THROW（native崩溃由主进程看门狗兜底）
 *
 * 配置指令（VpnConfigAction）：
 * - START：首次启动VPN连接
 * - STOP：停止VPN服务但保留VEA进程（用于快速切换）
 * - SWITCH：切换到新配置（先停后启）
 * - RESTART：重启当前配置（DNS重解析）
 *
 * 启动模式：
 * - 参数直传（API 22+）：want.parameters携带id+wgDbConf，即时启动
 * - 轮询降级（API 21/参数丢失）：1秒间隔CONFIG_QUERY，最多30次
 *
 * 长时任务由主进程的EntryAbility管理；握手/socket维护/keepalive由C层内核负责。
 *
 * Created on 2026/8/27.
 * @author leojay`fu
 */
import { bundleManager, errorManager, Want } from '@kit.AbilityKit';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LLog } from '../tools/LLog';
import { WireGuard } from '../model/WGHelper';
import { WGDBConf } from '../model/entity/WGConfigEntity';
import { VpnConfigAction, VpnConfigRequestParams } from '../model/entity/VpnConfigAction';
import { SubEventCancel } from '../model/WGEvent';
import { VPNChangeHelperV2 } from './VPNChangeHelperV2';
import { VpnSessionManager } from './VpnSessionManager';

const TAG = "vpn_ability_v2"

export default class WGVpnExtAbilityV2 extends VpnExtensionAbility {
  // V2: 配置请求轮询
  private configQueryTimer?: number;
  private configQueryRetries: number = 0;
  // V2: 事件订阅句柄
  private configRequestCancel?: SubEventCancel;
  private vpnStatusQueryCancel?: SubEventCancel;
  private reconnectRequestCancel?: SubEventCancel;
  // 未捕获异常监听句柄：进程死亡前尽力上报（满足"所有失败必须有报错"）
  private errorObserver?: errorManager.GlobalObserver;
  // VPN会话管理器：连接生命周期/流日志消费/网络监听调整
  private session: VpnSessionManager = new VpnSessionManager(() => {
    this.selfTerminate();
  });

  override onCreate(want: Want): void {
    super.onCreate(want);
    try {
      // 0. 注册未捕获异常监听：进程因ArkTS未捕获异常死亡前尽力广播失败原因，
      //    主进程收到后回滚开关并Toast提示（native崩溃无法广播，由主进程看门狗兜底检测）
      this.errorObserver = (err: errorManager.GlobalError) => {
        LLog.error(TAG, `VEA未捕获异常: ${err.message ?? '未知'}`);
        try {
          VPNChangeHelperV2.startVpnThrow(`VPN进程内部异常: ${err.message ?? '未知'}`);
        } catch (e) {
          // 上报失败只能留日志（进程即将死亡）
          LLog.error(TAG, `未捕获异常上报失败: ${JSON.stringify(e)}`);
        }
      };
      errorManager.on('globalErrorOccurred', this.errorObserver);

      // 会话管理器接入VEA上下文
      this.session.setContext(this.context);

      // 1. 先订阅事件，确保收到主进程回复
      this.vpnStatusQueryCancel = WireGuard.event.subscribeVpnStatusQuery(() => {
        VPNChangeHelperV2.queryStatus(this.session.getCurrentConfig());
      });

      this.configRequestCancel = WireGuard.event.subscribeVpnConfigRequest((params) => {
        this.onConfigRequest(params);
      });

      // 订阅主进程的重连请求
      this.reconnectRequestCancel = WireGuard.event.subscribeVpnReconnectRequest(() => {
        this.session.onReconnectRequest();
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
    this.session.start(id, wgDbConf);
    return true;
  }

  override async onDestroy(): Promise<void> {
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
    if (this.reconnectRequestCancel != undefined) {
      this.reconnectRequestCancel.cancel();
      this.reconnectRequestCancel = undefined;
    }

    // 注销未捕获异常监听
    if (this.errorObserver != undefined) {
      try {
        errorManager.off('globalErrorOccurred', this.errorObserver);
      } catch (e) {
      }
      this.errorObserver = undefined;
    }

    // 会话收尾：注销网络监听 + 停掉残留连接
    await this.session.shutdown();

    // 通知主进程VEA关闭
    VPNChangeHelperV2.stopVpn();
  }

  // ===== 配置请求轮询 =====

  private startConfigQueryPolling(): void {
    this.stopConfigQueryPolling();
    this.configQueryRetries = 0;

    // 立即发一次
    this.doConfigQuery();

    // 1秒间隔轮询
    this.configQueryTimer = setInterval(() => {
      if (this.session.hasActiveConfig()) {
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

  // ===== 配置指令分发 =====

  private onConfigRequest(params: VpnConfigRequestParams): void {
    const action = params.action as VpnConfigAction;
    LLog.info(TAG, `收到配置指令: action=${action}, configId=${params.configId}`);

    switch (action) {
      case VpnConfigAction.START:
        if (params.configId != undefined && params.wgDbConf) {
          this.stopConfigQueryPolling();
          this.session.start(params.configId, params.wgDbConf);
        } else {
          LLog.error(TAG, 'START指令缺少configId或wgDbConf');
        }
        break;
      case VpnConfigAction.STOP:
        this.session.stop();
        break;
      case VpnConfigAction.SWITCH:
        if (params.configId != undefined && params.wgDbConf) {
          this.session.switchTo(params.configId, params.wgDbConf);
        } else {
          LLog.error(TAG, 'SWITCH指令缺少configId或wgDbConf');
        }
        break;
      case VpnConfigAction.RESTART:
        this.session.restart(params.configId);
        break;
      default:
        LLog.warn(TAG, `未知action: ${action}`);
        break;
    }
  }
}
