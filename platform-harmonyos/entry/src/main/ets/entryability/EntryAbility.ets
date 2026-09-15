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
import { LLog, StreamLogMessage, SubEventCancel, VpnEventTag, VpnConfigAction, WGEventThrow, WireGuard, WGSettingsPrefs } from 'wg_tunnel';
import { longTaskModel } from '../model/LongTaskModel';
import { vpnSelfHealModel } from '../model/VpnSelfHealModel';

const TAG = "EntryAbility"
// 长时任务自动重拉参数：指数退避基数、窗口期内重试上限、连续取消判定窗口
const LONG_TASK_RETRY_BASE_MS = 2000;
const LONG_TASK_RETRY_MAX = 5;
const LONG_TASK_CANCEL_WINDOW_MS = 60 * 1000;
// α 重连重建长时任务的最小间隔：拦住同一次 α 事件的重复广播，避免通知 id 快速跳变
const RECONNECT_REBUILD_MIN_INTERVAL_MS = 30 * 1000;

/**
 * 应用主Ability
 *
 * 职责：
 * - 管理VPN事件监听（状态变化、流日志、配置请求、异常事件）
 * - 管理VPN保活（长时任务 + 通知）
 * - VPN异常Toast展示：通过subscribeVpnThrow订阅VPN异常事件，在任意页面弹出Toast展示错误原因
 *   - 'info'类型 → 直接展示message（自愈恢复等通知类，不加异常前缀）
 *   - 'normal'类型且message非空 → "VPN连接异常：{message}"
 *   - 'none'类型 → "VPN连接异常，原因未知"
 *   - 'normal'类型且message为空 → "VPN连接异常"
 *   - 'want_no_get_args'类型不展示Toast（保留WGConfigPreView红色横幅）
 * - 正常VPN关闭（STOP_VPN / VPN_SERVICE_STOPPED）通过subscribeVpnChange处理，不触发异常Toast
 */
export default class EntryAbility extends UIAbility {
  // VPN状态变化监听句柄
  private vpnChangeCancel?: SubEventCancel;
  // VPN流日志监听句柄
  private vpnStreamLogCancel?: SubEventCancel;
  // V2: VEA配置请求监听句柄
  private vpnConfigQueryCancel?: SubEventCancel;
  // VPN异常事件监听句柄
  private vpnThrowCancel?: SubEventCancel;
  // 缓存的UIContext，用于在EntryAbility中弹出Toast
  private uiContext?: UIContext;
  // 长时任务自动重拉：窗口期内取消计数、上次取消时间、延迟定时器句柄
  private longTaskRetryCount: number = 0;
  private lastLongTaskCancelMs: number = 0;
  private longTaskRetryTimerId: number = -1;
  // α 重连重建长时任务：上次重建时间（防抖基准，避免退避重试反复重建通知）
  private lastReconnectRebuildMs: number = 0;

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

    // 初始化VPN事件监听（backgroundTaskManager要求UIAbilityContext，因此放在EntryAbility中）
    this.initVpnListeners();

    // 注册长时任务取消回调，打印取消原因
    try {
      backgroundTaskManager.on('continuousTaskCancel', (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
        LLog.warn(TAG, `长时任务被取消: taskId=${info.id}, reason=${info.reason}`);
        // 先复位任务状态：isRunning()归位、updater停止空转发布（重试达上限期间不再1600007刷屏）
        longTaskModel.markTaskCancelled();
        // VPN仍在运行说明是系统策略收回而非用户关闭，自动重新申请（带退避与上限）
        this.scheduleLongTaskRetry();
      });
    } catch (error) {
    }

    // 启动VPN进程自愈监测（VPN承载网络事件 + 亮屏事件 + 定时轮询，检测VEA死亡并自动重连）
    vpnSelfHealModel.startWatching(this.context);
  }

  onDestroy(): void {
    LLog.info(TAG, 'Ability onDestroy');
    this.unsubscribeVpnChange();
    this.unsubscribeVpnStreamLogs();
    this.unsubscribeVpnConfigQuery();
    this.unsubscribeVpnThrow();
    this.stopLongTaskIfNeeded();
    // 停止VPN自愈监测与长时任务重拉定时器
    vpnSelfHealModel.stopWatching();
    if (this.longTaskRetryTimerId >= 0) {
      clearTimeout(this.longTaskRetryTimerId);
      this.longTaskRetryTimerId = -1;
    }
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
      // loadContent完成后才能安全获取UIContext，否则窗口状态异常(1300002)
      try {
        this.uiContext = windowStage.getMainWindowSync().getUIContext();
        LLog.info(TAG, 'UIContext缓存成功');
      } catch (e) {
        LLog.error(TAG, `获取UIContext失败: ${(e as BusinessError).message}`);
      }
    });
  }

  onWindowStageDestroy(): void {
    LLog.info(TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    LLog.info(TAG, 'Ability onForeground');
    // 主进程解冻回到前台的瞬间立即自检：若夜间VEA已死，此刻重拉最快。
    // 注意：冻结期间亮屏事件收不到，onForeground是解冻后最可靠的恢复触发点。
    vpnSelfHealModel.checkAndRecover('onForeground');
    // 长时任务可能已被系统静默收回（不触发continuousTaskCancel回调，
    // 真机实证：通知消失即长时任务被收回，VEA独立存活故VPN仍正常）。
    // 回前台强制重启长时任务+通知，把“点开应用”变成可靠恢复点。
    if (WireGuard.config.status.getConfig().isOpen()) {
      // 与startVpnKeepAlive/scheduleLongTaskRetry两处调用点同约定：捕获重拉失败，
      // 避免unhandled rejection静默吞掉前台恢复点（有onBackground与轮询兑底）
      longTaskModel.restartLongTask(this.context).catch((e: Error) => {
        LLog.error(TAG, `前台恢复长时任务失败: ${e.message}`);
      });
    }
    // 回前台无条件清扫历史残留通知（并入原VPN关闭分支语义）：
    // keepId取当前活跃通知id（长时任务未运行时为undefined=全清），对在跑任务安全；
    // 覆盖restartLongTask绕过cancel/装新包内存归零/系统收回竞态/α重连托管失效等
    // 各路径遗留的孤儿通知，保证"用户点开应用"必定清干净
    longTaskModel.cleanupStaleNotifications();
  }

  /**
   * α 整隧道重启期间重建长时任务与通知托管关系（G4 补充）
   *
   * 【为什么需要】α 重启通常伴随 VEA 进程重建（真机实证：旧 PID 39469 → 新 42880），
   * 但主进程长时任务(taskId)与通知 id 沿用旧值，而系统实况窗代理与长时任务的托管
   * 绑定随 VEA 进程更替失效 → 实况窗被反复回收（每 3s 一次 Remove live card），
   * 通知退化为孤儿残留在通知栏，直到用户回前台 onForeground 的 restartLongTask 才
   * 清除（用户现象："残留一条 VPN 通知，重开 App 就消失"）。
   * 此处主动重建长时任务：系统重新创建实况窗代理，startLongTask 内部再把新通知 id
   * 下发给 VEA（setNotificationId 顺带取消旧 id），使托管关系与实况窗形态一并恢复。
   *
   * 【防抖】同一次 α 事件可能伴随多次广播；退避重试也会再次进入本路径。以
   * RECONNECT_REBUILD_MIN_INTERVAL_MS 限频，避免通知 id 快速跳变闪烁。
   */
  private rebuildLongTaskOnReconnect(): void {
    if (!longTaskModel.isRunning()) {
      // 长时任务未运行：通知本就不该存在，交由长时任务自身路由（不在此处重建）
      return;
    }
    const now = Date.now();
    if (now - this.lastReconnectRebuildMs < RECONNECT_REBUILD_MIN_INTERVAL_MS) {
      LLog.info(TAG, 'α重连：距上次重建长时任务过近，本次跳过（防抖）');
      return;
    }
    this.lastReconnectRebuildMs = now;
    LLog.info(TAG, 'α重连：重建长时任务以恢复通知托管（实况窗代理重建）');
    longTaskModel.restartLongTask(this.context).catch((e: Error) => {
      LLog.error(TAG, `α重连重建长时任务失败: ${e.message}`);
    });
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
    this.subscribeVpnThrowIfNeeded();

    WireGuard.tools.isVpnExtensionRunning().then((running: boolean) => {
      if (running) {
        WireGuard.event.publishVpnStatusQuery();
        LLog.info(TAG, 'VPN Extension运行中，已发送状态查询请求');
      } else {
        LLog.info(TAG, 'VPN Extension未运行，无需查询状态');
        // 冷启动自愈：持久化记录显示VPN上次在运行 → 延迟自动重连
        vpnSelfHealModel.tryRecoverOnColdStart();
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
        // 自愈持久化：仅权威来源可写/清记录（主进程被杀后冷启动恢复依据）。
        // running=true任意来源都记录；running=false仅STOP_VPN/VPN_SERVICE_STOPPED（VPN真实停止）才清除，
        // QUERY_NO_RUNNING/ON_CREATE携带的是广播发起进程自身的空状态，误清会导致冷启动自愈失效
        if (params.status.running) {
          vpnSelfHealModel.recordStatus(true, params.status.runningConfigId);
        } else if (tag === VpnEventTag.STOP_VPN || tag === VpnEventTag.VPN_SERVICE_STOPPED) {
          // 自愈活跃窗口内的停止 = 自愈拉起的连接建立失败，计失败保留记录；
          // 窗口外 = 用户主动关闭或服务正常停止，清除记录
          if (vpnSelfHealModel.isRecoverWindowActive()) {
            vpnSelfHealModel.notifyRecoverAttemptFailed();
          } else {
            vpnSelfHealModel.recordStatus(false, params.status.runningConfigId);
          }
        }
      }
      LLog.info(TAG,
        `收到VPN状态变化广播: isOpen=${params.isOpen}, tag=${tag}, vpnThreadRunning=${params.vpnThreadRunning}`);

      if (params.vpnThreadRunning === true) {
        if (tag === VpnEventTag.VPN_SERVICE_STOPPED) {
          this.onVpnServiceStopped();
        } else if (tag === VpnEventTag.VPN_RECONNECTING) {
          // VEA隧道重连中（机制Y修复）：长时任务与通知保留，状态词提示“重连中”；
          // 不进startVpnKeepAlive避免误判恢复，自愈链路不参与（VEA存活自会重试）
          longTaskModel.setReconnecting(true);
          // 自愈模型据此改用更短的"功能死"静默阈值（VEA自己承认不在正常态，
          // 30s 无数据心跳即为卡死）。声明窗口有 TTL，超期自动回落常规阈值。
          vpnSelfHealModel.notifyReconnecting();
          // G4补充：α整隧道重启通常伴随VEA进程重建，主进程长时任务(taskId)与通知id
          // 沿用旧值 → 系统实况窗代理与长时任务的托管绑定随进程更替失效，实况窗被
          // 反复回收，通知退化为孤儿残留在通知栏（真机实证：α后id=16残留，重开App
          // 才清除）。重建长时任务使系统重新创建实况窗代理并下发新id给VEA，恢复托管。
          this.rebuildLongTaskOnReconnect();
        } else {
          // 同步VEA侧的连接建立时刻：两端通知的运行时长/计时器使用同一时间戳，
          // 消除主进程重挂导致的运行时长交替跳变（startLongTask不再自设startTime）。
          // 不限START_VPN：QUERY_STATUS（冷启动恢复路径）携带时同样同步；
          // 连接存在即复位停止态与重连态（冻结期丢STOP_VPN广播时serviceStopped残留的兑底）——
          // 复位必须先于updateVpnData：后者守卫通过会立即发布，先复位才不会
          // 把过期的“已停止”状态词发出去
          longTaskModel.setReconnecting(false);
          if (params.startTime != undefined) {
            longTaskModel.setServiceStopped(false);
            longTaskModel.updateVpnData({ startTime: params.startTime });
          }
          // F18阈值自适应联动：keepalive=0（用户取消）时空闲期仅rekey产生流量心跳，
          // 90s固定阈值会误判功能死；START_VPN携带配置值，动态放宽至150s
          if (params.keepaliveInterval != undefined) {
            vpnSelfHealModel.setKeepaliveIntervalSeconds(params.keepaliveInterval);
          }
          this.startVpnKeepAlive(tag, params.connectedIps);
        }
        // VEA重建（ON_CREATE）且长时任务仍运行：startLongTask不会再次执行，
        // 补发通知id给新VEA实例接管通知发布
        if (tag === VpnEventTag.ON_CREATE && longTaskModel.isRunning()) {
          longTaskModel.publishNotificationIdToVea();
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
   * 长时任务被系统取消后的自动重拉
   *
   * 夜间省电策略可能收回dataTransfer长时任务，导致主进程失去保活资格进而被杀。
   * VPN运行中收到取消回调时按指数退避（2s/4s/8s/16s/32s）重新申请。
   * 对抗防护：两次取消间隔小于LONG_TASK_CANCEL_WINDOW_MS视为系统连续收回，
   * 计数延续累加，达上限后停止；间隔较长说明长时任务已稳定运行过一段时间，
   * 计数重新开始——因此“重拉成功后立即再被取消”的循环会快速触及上限，
   * 而正常长期运行后的一次性取消不会累积。用户主动关闭VPN不重拉。
   */
  private scheduleLongTaskRetry(): void {
    if (!WireGuard.config.status.getConfig().isOpen()) {
      // VPN已停止（用户主动关闭或服务停止），不重拉并复位计数
      this.longTaskRetryCount = 0;
      return;
    }
    const nowMs = Date.now();
    if (nowMs - this.lastLongTaskCancelMs < LONG_TASK_CANCEL_WINDOW_MS) {
      this.longTaskRetryCount++;
    } else {
      this.longTaskRetryCount = 1;
    }
    this.lastLongTaskCancelMs = nowMs;
    if (this.longTaskRetryCount > LONG_TASK_RETRY_MAX) {
      LLog.error(TAG, `长时任务在窗口期内连续被取消${this.longTaskRetryCount}次，停止重拉`);
      return;
    }
    const delay = LONG_TASK_RETRY_BASE_MS * Math.pow(2, this.longTaskRetryCount - 1);
    if (this.longTaskRetryTimerId >= 0) {
      clearTimeout(this.longTaskRetryTimerId);
    }
    this.longTaskRetryTimerId = setTimeout(() => {
      this.longTaskRetryTimerId = -1;
      // 等待期间VPN可能已被关闭
      if (!WireGuard.config.status.getConfig().isOpen()) {
        this.longTaskRetryCount = 0;
        return;
      }
      if (longTaskModel.isRunning()) {
        // 已被其他路径拉起，无需重拉（计数保留，不影响连续取消检测）
        return;
      }
      LLog.warn(TAG, `长时任务重拉（窗口内第${this.longTaskRetryCount}次）`);
      this.startVpnKeepAlive(VpnEventTag.QUERY_STATUS).catch((e: BusinessError) => {
        LLog.error(TAG, `长时任务重拉异常: ${(e as BusinessError).message}`);
      });
    }, delay);
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
      // 统一入口：刷新VEA数据心跳 + 识别native上报的tun fd失效信号（见VpnSelfHealModel）
      vpnSelfHealModel.notifyVeaStreamLog(log);
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
      if (param.type === 'info') {
        // 自愈恢复等通知类信息，不加异常前缀
        toastMessage = param.message;
      } else if (param.type === 'normal' && param.message.length > 0) {
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

  private unsubscribeVpnThrow(): void {
    if (this.vpnThrowCancel != undefined) {
      this.vpnThrowCancel.cancel();
      this.vpnThrowCancel = undefined;
      LLog.info(TAG, '已取消VPN异常事件监听');
    }
  }
}
