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
import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { LLog, SubEventCancel, WireGuard } from 'wg_tunnel';
import { longTaskModel } from '../model/LongTaskModel';

const TAG = "EntryAbility"

export default class EntryAbility extends UIAbility {
  // VPN状态变化监听句柄，用于取消订阅
  private vpnChangeCancel?: SubEventCancel;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      LLog.error(TAG, `设置颜色模式失败: ${JSON.stringify(err)}`);
    }
    LLog.info(TAG, 'Ability onCreate');
  }

  onDestroy(): void {
    LLog.info(TAG, 'Ability onDestroy');
    // 确保停止长时任务并清除定时器，防止资源泄漏
    longTaskModel.stopLongTask(this.context);
    // 取消VPN状态监听
    this.unsubscribeVpnChange();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    LLog.info(TAG, 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        LLog.error(TAG, `加载页面失败: ${JSON.stringify(err)}`);
        return;
      }
      LLog.info(TAG, '页面加载成功');
    });
  }

  onWindowStageDestroy(): void {
    LLog.info(TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    LLog.info(TAG, 'Ability onForeground');

    // ===== 步骤1：停止后台长时任务 =====
    // 应用切换到前台，停止长时任务（同时清除进度更新定时器）
    longTaskModel.stopLongTask(this.context);

    // ===== 步骤2：同步VPN进程最新状态 =====
    // 流程：先检测VPN进程是否运行 → 注册状态监听 → 请求查询
    // 注册监听确保在请求查询前已准备好接收VPN进程的回复
    this.syncVpnStatus();
  }

  onBackground(): void {
    LLog.info(TAG, 'Ability onBackground');
    if (WireGuard.isRunning()) {
      // 应用切换到后台，启动长时任务保活VPN进程
      // 使用新API签名，启动后自动开启进度更新定时器
      LLog.info(TAG, 'VPN运行中，启动长时任务');
      longTaskModel.startLongTask(this.context).catch((e: Error) => {
        LLog.error(TAG, `启动长时任务失败: ${e.message}`);
      });
    }
  }

  /**
   * 同步VPN进程最新状态
   *
   * 流程：
   * 1. 检测VPN Extension进程是否运行
   * 2. 注册VPN状态变化监听（确保能收到VPN进程的回复）
   * 3. 发送状态查询请求
   *
   * VPN进程收到查询后会通过 publishVpnChange() 回复最新状态，
   * 主应用进程在 subscribeVpnChange → syncFromVpnProcess() 中自动同步到本地。
   *
   * 注意：应用启动时不需要主动启动VPN或重连，
   * VPN进程如果仍在运行会自行维护连接状态。
   */
  private syncVpnStatus(): void {
    // 先检测VPN进程是否运行，避免无谓的查询请求
    WireGuard.tools.isVpnExtensionRunning().then((running: boolean) => {
      if (!running) {
        LLog.info(TAG, 'VPN Extension未运行，无需同步状态');
        return;
      }

      // 注册VPN状态变化监听（确保在发送查询前已就绪）
      this.subscribeVpnChange();

      // 发送查询请求，VPN进程收到后会通过publishVpnChange回复
      WireGuard.event.publishVpnStatusQuery();
      LLog.info(TAG, 'VPN Extension运行中，已发送状态查询请求');
    }).catch((e: Error) => {
      LLog.error(TAG, `检测VPN进程状态异常: ${e.message}`);
    });
  }

  /**
   * 注册VPN状态变化监听
   * 收到VPN进程广播后自动调用 syncFromVpnProcess 同步状态到本地
   */
  private subscribeVpnChange(): void {
    // 避免重复注册
    if (this.vpnChangeCancel != undefined) {
      return;
    }
    this.vpnChangeCancel = WireGuard.event.subscribeVpnChange((_params) => {
      // subscribeVpnChange内部已自动调用syncFromVpnProcess同步到本地AppStorageV2
      // 此处无需额外处理
      LLog.info(TAG, '收到VPN状态变化广播，已自动同步到本地');
    });
    LLog.info(TAG, '已注册VPN状态变化监听');
  }

  /**
   * 取消VPN状态变化监听
   */
  private unsubscribeVpnChange(): void {
    if (this.vpnChangeCancel != undefined) {
      this.vpnChangeCancel.cancel();
      this.vpnChangeCancel = undefined;
      LLog.info(TAG, '已取消VPN状态变化监听');
    }
  }
}
