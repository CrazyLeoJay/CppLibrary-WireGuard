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
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { LLog, StreamLogMessage, SubEventCancel, VpnEventTag, VpnConfigAction, WireGuard } from 'wg_tunnel';
import { longTaskModel } from '../model/LongTaskModel';

const TAG = "EntryAbility"

export default class EntryAbility extends UIAbility {
  // VPN状态变化监听句柄
  private vpnChangeCancel?: SubEventCancel;
  // VPN流日志监听句柄
  private vpnStreamLogCancel?: SubEventCancel;
  // V2: VEA配置请求监听句柄
  private vpnConfigQueryCancel?: SubEventCancel;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      LLog.error(TAG, `设置颜色模式失败: ${JSON.stringify(err)}`);
    }
    LLog.info(TAG, 'Ability onCreate');

    // 初始化VPN事件监听（backgroundTaskManager要求UIAbilityContext，因此放在EntryAbility中）
    this.initVpnListeners();

    // 注册长时任务取消回调，打印取消原因
    try {
      backgroundTaskManager.on('continuousTaskCancel', (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
        LLog.warn(TAG, `长时任务被取消: taskId=${info.id}, reason=${info.reason}`);
      });
    } catch (error) {
    }
  }

  onDestroy(): void {
    LLog.info(TAG, 'Ability onDestroy');
    this.unsubscribeVpnChange();
    this.unsubscribeVpnStreamLogs();
    this.unsubscribeVpnConfigQuery();
    this.stopLongTaskIfNeeded();
    try {
      backgroundTaskManager.off('continuousTaskCancel');
    } catch (error) {
    }
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
  }

  onBackground(): void {
    LLog.info(TAG, 'Ability onBackground');
    // VPN运行中但长时任务被停止，重新吊起
    if (WireGuard.config.status.getConfig().isOpen() && !longTaskModel.isRunning()) {
      LLog.warn(TAG, 'VPN运行中但长时任务已停止，重新启动');
      this.startVpnKeepAlive(VpnEventTag.QUERY_STATUS);
    }
  }

  /**
   * 初始化VPN事件监听并同步状态
   *
   * 流程：
   * 1. 注册VPN状态变化监听（程序运行即注册，无需条件）
   * 2. 注册VPN流日志监听（程序运行即注册，无需条件）
   * 3. 检测VPN Extension进程是否运行，运行中则发送状态查询
   *
   * VPN进程收到查询后会通过 publishVpnChange() 回复最新状态，
   * 主应用进程在 subscribeVpnChange → syncFromVpnProcess() 中自动同步到本地。
   *
   * 长时任务生命周期由VPN状态驱动：
   * - VPN启动 → 启动长时任务（通知显示VPN状态）
   * - VPN停止 → 停止长时任务
   */
  private initVpnListeners(): void {
    this.subscribeVpnChangeIfNeeded();
    this.subscribeVpnStreamLogsIfNeeded();
    this.subscribeVpnConfigQueryIfNeeded();

    WireGuard.tools.isVpnExtensionRunning().then((running: boolean) => {
      if (running) {
        WireGuard.event.publishVpnStatusQuery();
        LLog.info(TAG, 'VPN Extension运行中，已发送状态查询请求');
      } else {
        LLog.info(TAG, 'VPN Extension未运行，无需查询状态');
      }
    }).catch((e: Error) => {
      LLog.error(TAG, `检测VPN进程状态异常: ${e.message}`);
    });
  }

  /**
   * 注册VPN状态变化监听
   *
   * 监听VPN线程运行状态和连接状态，据此管理通知和后台长时任务。
   * 通过 VpnEventTag 枚举判断事件类型：
   * - ON_CREATE / START_VPN / QUERY_STATUS → VPN线程运行中，启动保活
   * - STOP_VPN / THROW / 其他 → VPN线程停止，取消通知并停止长时任务
   */
  private subscribeVpnChangeIfNeeded(): void {
    if (this.vpnChangeCancel != undefined) {
      return;
    }
    this.vpnChangeCancel = WireGuard.event.subscribeVpnChange((params) => {
      // subscribeVpnChange内部已自动调用syncFromVpnProcess同步到本地AppStorageV2
      const tag = params.tag as VpnEventTag;
      if (params.status) {
        // 更新UI线程配置
        WireGuard.config.status.update(params.status)
      }
      LLog.info(TAG,
        `收到VPN状态变化广播: isOpen=${params.isOpen}, tag=${tag}, vpnThreadRunning=${params.vpnThreadRunning}`);

      if (params.vpnThreadRunning === true) {
        if (tag === VpnEventTag.VPN_SERVICE_STOPPED) {
          this.onVpnServiceStopped();
        } else {
          this.startVpnKeepAlive(tag, params.connectedIps);
        }
      } else {
        // VPN线程未运行 → 停止长时任务（stopBackgroundRunning会自动取消关联通知）
        this.stopLongTaskIfNeeded();
      }
    });
    LLog.info(TAG, '已注册VPN状态变化监听');
  }

  /**
   * 启动VPN保活（长时任务 + 通知）
   *
   * VPN线程运行中时调用。流程：
   *   1. 防重复：长时任务已启动则跳过，仅更新通知数据
   *   2. 启动长时任务（先启动，不等通知权限）
   *   3. 缓存连接IP（如果有）
   *   4. 处理通知权限
   *      - 已授权 → 刷新通知数据（缓存的数据一次性刷出）
   *      - 未授权 → 请求授权 → 授权后刷新通知数据
   *      - 授权失败 → 不刷新（长时任务仍在运行，后续定时器会持续尝试）
   *
   * 【数据缓存机制】
   * VPN启动后连接数据（connectedIps、streamLog）持续到来，
   * updateVpnData/updateStreamLog 始终缓存到 vpnData 中，
   * 但只在长时任务运行且通知已授权时才刷新通知。
   * 用户授权后调用 publishNotification() 即可将缓存数据一次性刷出。
   *
   * @param tag 事件标签（VpnEventTag枚举）
   * @param connectedIps 连接IP数据（可选，来自VPN状态广播）
   */
  private async startVpnKeepAlive(tag: VpnEventTag, connectedIps?: Record<number, string>): Promise<void> {
    // 缓存连接IP和配置信息
    if (connectedIps) {
      longTaskModel.updateVpnData({ connectedIps: connectedIps });
    }
    // 从RunArg缓存读取配置名和目标端点
    const dbConf = WireGuard.config.runArg.getDbConf();
    if (dbConf) {
      const endpoints: Record<number, string> = {};
      dbConf.conf.peers.forEach((peer, index) => {
        endpoints[index] = `${peer.endpoint.ipStrOrDomain}:${peer.endpoint.port}`;
      });
      longTaskModel.updateVpnData({
        configName: dbConf.name,
        targetEndpoints: endpoints,
      });
    }
    // 1. 防重复启动：长时任务已运行则仅更新数据
    if (longTaskModel.isRunning()) {
      LLog.info(TAG, `长时任务已运行，仅更新通知数据: tag=${tag}`);
      longTaskModel.publishNotification();
      return;
    }

    // 2. 启动长时任务
    try {
      await longTaskModel.startLongTask(this.context);
    } catch (e) {
      LLog.error(TAG, `启动长时任务失败: ${(e as Error).message}`);
      return;
    }

    // 3. 处理通知权限
    try {
      const enabled = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        await notificationManager.requestEnableNotification(this.context);
      }
      // 权限就绪，刷新通知（将缓存数据一次性刷出）
      longTaskModel.publishNotification();
    } catch (e) {
      const err = e as BusinessError;
      LLog.warn(TAG, `通知权限处理失败: code=${err.code}, message=${err.message}`);
      // 授权失败不刷新通知，长时任务仍在运行，后续定时器会持续尝试
    }
  }

  /**
   * 注册VPN流日志监听
   *
   * 流日志包含每个Peer的实时流量统计和握手事件，
   * 用于更新后台通知中的流量数据和最后握手时间。
   */
  private subscribeVpnStreamLogsIfNeeded(): void {
    if (this.vpnStreamLogCancel != undefined) {
      return;
    }
    this.vpnStreamLogCancel = WireGuard.event.subscribeVpnStreamLogs((log: StreamLogMessage) => {
      longTaskModel.updateStreamLog(log);
    });
    LLog.info(TAG, '已注册VPN流日志监听');
  }

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

  private onVpnServiceStopped(): void {
    LLog.info(TAG, 'VPN服务已停止（VEA进程存活），更新通知');
    longTaskModel.setServiceStopped(true);
    longTaskModel.publishNotification();
  }

  private stopLongTaskIfNeeded(): void {
    longTaskModel.stopLongTask(this.context);
  }

  private unsubscribeVpnChange(): void {
    if (this.vpnChangeCancel != undefined) {
      this.vpnChangeCancel.cancel();
      this.vpnChangeCancel = undefined;
      LLog.info(TAG, '已取消VPN状态变化监听');
    }
  }

  private unsubscribeVpnStreamLogs(): void {
    if (this.vpnStreamLogCancel != undefined) {
      this.vpnStreamLogCancel.cancel();
      this.vpnStreamLogCancel = undefined;
      LLog.info(TAG, '已取消VPN流日志监听');
    }
  }

  private unsubscribeVpnConfigQuery(): void {
    if (this.vpnConfigQueryCancel != undefined) {
      this.vpnConfigQueryCancel.cancel();
      this.vpnConfigQueryCancel = undefined;
      LLog.info(TAG, '已取消VEA配置请求监听');
    }
  }
}
