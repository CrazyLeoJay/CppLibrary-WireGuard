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
import { BusinessError } from '@kit.BasicServicesKit';
import { LLog, SubEventCancel, VpnConfigAction, WGEventThrow, WireGuard, WGSettingsPrefs, vpnKeepAliveManager } from 'wg_tunnel';
import {
  dispatchAppBackground,
  dispatchAppCreate,
  dispatchAppDestroy,
  dispatchAppForeground,
  dispatchMainWindowReady,
  setChannelPaidEnabled,
} from 'wg_ui';

const TAG = "EntryAbility"

/**
 * 应用主Ability
 *
 * 职责：
 * - 对接wg_tunnel的VPN保活管理器（vpnKeepAliveManager）：attach/detach + 前后台钩子
 *   VPN保活机制（长时任务 + 通知 + 后台隧道健康守护）已封装在wg_tunnel/keepalive，
 *   本Ability不再持有保活实现，仅通过引用接入，保证可复用性。
 * - 管理VEA配置请求监听（CONFIG_QUERY）：VEA启动请求配置时用runArg缓存回复
 * - VPN异常Toast展示：通过subscribeVpnThrow订阅VPN异常事件，在任意页面弹出Toast展示错误原因
 *   - 'normal'类型且message非空 → "VPN连接异常：{message}"
 *   - 'none'类型 → "VPN连接异常，原因未知"
 *   - 'normal'类型且message为空 → "VPN连接异常"
 *   - 'want_no_get_args'类型不展示Toast（保留WGConfigPreView红色横幅）
 */
export default class EntryAbility extends UIAbility {
  // V2: VEA配置请求监听句柄
  private vpnConfigQueryCancel?: SubEventCancel;
  // VPN异常事件监听句柄
  private vpnThrowCancel?: SubEventCancel;
  // 缓存的UIContext，用于在EntryAbility中弹出Toast
  private uiContext?: UIContext;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      LLog.error(TAG, `设置颜色模式失败: ${JSON.stringify(err)}`);
    }
    LLog.info(TAG, 'Ability onCreate');

    // 初始化设置偏好（WGSettingsPrefs 用于开发者模式、默认过滤模式等设置项的持久化）
    WGSettingsPrefs.init(this.context).catch((e: BusinessError) => {
      LLog.warn(TAG, `WGSettingsPrefs 初始化失败: ${(e as BusinessError).message}`);
    });

    // 接入wg_tunnel的VPN保活管理器：
    // backgroundTaskManager要求UIAbilityContext，因此在EntryAbility中传入context并attach
    vpnKeepAliveManager.attach(this.context);

    // 定制功能装配（付费隔离点）：悬浮球/卡片同步等经 wg_ui 通用注册表分发，
    // 渠道开关：free target 资源覆盖 paid_features_enabled=false（免费包付费功能全停）
    try {
      setChannelPaidEnabled(this.context.resourceManager.getBooleanByName('paid_features_enabled'));
    } catch (err) {
      setChannelPaidEnabled(true);
    }
    dispatchAppCreate(this.context);

    // 订阅VEA配置请求与VPN异常事件（UI层职责，与保活机制解耦）
    this.subscribeVpnConfigQueryIfNeeded();
    this.subscribeVpnThrowIfNeeded();
  }

  onDestroy(): void {
    LLog.info(TAG, 'Ability onDestroy');
    // 解除VPN保活管理器（内部取消VPN事件订阅并停止长时任务/健康守护）
    vpnKeepAliveManager.detach();
    this.unsubscribeVpnConfigQuery();
    this.unsubscribeVpnThrow();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    LLog.info(TAG, 'Ability onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        LLog.error(TAG, `加载页面失败: ${JSON.stringify(err)}`);
        return;
      }
      LLog.info(TAG, '页面加载成功');
      // loadContent完成后才能安全获取UIContext，否则窗口状态异常(1300002)
      try {
        this.uiContext = windowStage.getMainWindowSync().getUIContext();
        LLog.info(TAG, 'UIContext缓存成功');
      } catch (e) {
        LLog.error(TAG, `获取UIContext失败: ${(e as BusinessError).message}`);
      }
      // 主窗口就绪：定制窗口类功能（悬浮球上屏等）经注册表分发
      dispatchMainWindowReady();
    });
  }

  onWindowStageDestroy(): void {
    LLog.info(TAG, 'Ability onWindowStageDestroy');
    dispatchAppDestroy();
  }

  onForeground(): void {
    LLog.info(TAG, 'Ability onForeground');
    // 交保活管理器处理：VPN运行中立即查询状态并做一次隧道健康检查
    vpnKeepAliveManager.onAppForeground();
    // 定制前台钩子（如悬浮球授权返回自动补开）
    dispatchAppForeground();
  }

  onBackground(): void {
    LLog.info(TAG, 'Ability onBackground');
    // 交保活管理器处理：VPN运行中但长时任务被停止时重新吊起
    vpnKeepAliveManager.onAppBackground();
    // 定制后台钩子（如悬浮球常驻任务兜底）
    dispatchAppBackground();
  }

  /**
   * 注册VEA配置请求监听
   *
   * 【V2模式】VEA进程启动后通过CONFIG_QUERY请求配置，
   * 主进程收到后从runArg缓存读取待启动配置并下发START指令。
   */
  private subscribeVpnConfigQueryIfNeeded(): void {
    if (this.vpnConfigQueryCancel != undefined) {
      return;
    }
    this.vpnConfigQueryCancel = WireGuard.event.subscribeVpnConfigQuery(() => {
      LLog.info(TAG, '收到VEA配置请求(CONFIG_QUERY)');
      if (WireGuard.config.runArg.hasConfig()) {
        WireGuard.event.publishVpnConfigRequest({
          action: VpnConfigAction.START,
          configId: WireGuard.config.runArg.getConfigId(),
          wgDbConf: WireGuard.config.runArg.getDbConf(),
        });
        LLog.info(TAG, `已回复配置: configId=${WireGuard.config.runArg.getConfigId()}`);
      } else {
        LLog.warn(TAG, '无待启动配置，无法回复CONFIG_QUERY');
      }
    });
    LLog.info(TAG, '已注册VEA配置请求监听');
  }

  /**
   * 注册VPN异常事件监听
   *
   * 监听VPN运行过程中的异常断开事件（WGEventThrow），通过Toast向用户展示错误原因。
   * - type为'normal'且message非空 → 展示"VPN连接异常：{message}"
   * - type为'none' → 展示"VPN连接异常，原因未知"
   * - type为'normal'且message为空 → 展示"VPN连接异常"
   * - type为'want_no_get_args' → 不展示Toast（保留WGConfigPreView的红色横幅）
   * - uiContext未就绪 → 静默忽略
   */
  private subscribeVpnThrowIfNeeded(): void {
    if (this.vpnThrowCancel != undefined) {
      return;
    }
    this.vpnThrowCancel = WireGuard.event.subscribeVpnThrow((param: WGEventThrow) => {
      LLog.warn(TAG, `收到VPN异常事件: type=${param.type}, message=${param.message}`);
      // want_no_get_args由WGConfigPreView红色横幅处理，不重复Toast
      if (param.type === 'want_no_get_args') {
        return;
      }
      // uiContext未就绪时静默忽略
      if (!this.uiContext) {
        LLog.warn(TAG, 'UIContext未就绪，无法展示VPN异常Toast');
        return;
      }
      // 根据type和message构建Toast内容
      let toastMessage: string;
      if (param.type === 'normal' && param.message.length > 0) {
        toastMessage = 'VPN连接异常：' + param.message;
      } else if (param.type === 'none') {
        toastMessage = 'VPN连接异常，原因未知';
      } else {
        // type为'normal'但message为空，或其他未知类型
        toastMessage = 'VPN连接异常';
      }
      try {
        this.uiContext.getPromptAction().showToast({ message: toastMessage });
      } catch (error) {
      }
    });
    LLog.info(TAG, '已注册VPN异常事件监听');
  }

  private unsubscribeVpnConfigQuery(): void {
    if (this.vpnConfigQueryCancel != undefined) {
      this.vpnConfigQueryCancel.cancel();
      this.vpnConfigQueryCancel = undefined;
      LLog.info(TAG, '已取消VEA配置请求监听');
    }
  }

  private unsubscribeVpnThrow(): void {
    if (this.vpnThrowCancel != undefined) {
      this.vpnThrowCancel.cancel();
      this.vpnThrowCancel = undefined;
      LLog.info(TAG, '已取消VPN异常事件监听');
    }
  }
}
