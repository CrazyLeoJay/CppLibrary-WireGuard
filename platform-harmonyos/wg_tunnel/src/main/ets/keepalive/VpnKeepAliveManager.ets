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
import { common } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { connection } from '@kit.NetworkKit';
import { LLog } from '../tools/LLog';
import { WireGuard } from '../model/WGHelper';
import { VpnEventTag } from '../model/entity/VPNEventStatusParams';
import { StreamLogMessage } from '../model/entity/napi_entity';
import { SubEventCancel } from '../model/WGEvent';
import { longTaskModel, ContinuousTaskState } from './LongTaskModel';

const TAG = 'VpnKeepAliveMgr';

/**
 * VPN保活管理器 - 可复用的后台保活门面（wg_tunnel模块）
 *
 * 【职责】
 * 将"VPN后台保活机制"从具体UIAbility（EntryAbility）中剥离并封装为可复用组件：
 * 1. 绑定 UIAbilityContext（backgroundTaskManager要求UIAbilityContext）
 * 2. 订阅VPN跨进程事件（状态变化、流日志），驱动保活状态机：
 *    - VPN运行(vpnThreadRunning=true) → 启动长时任务 + 通知 + 后台隧道健康守护
 *    - VPN停止(vpnThreadRunning=false) → 停止长时任务，并确认VPN网络清理
 * 3. 后台隧道健康守护：长时任务保活主进程期间持续检测隧道活性，
 *    无需打开App即可自动重连（热重连 → 强重启VEA兜底）
 * 4. 提供 onAppForeground/onAppBackground 钩子供UIAbility生命周期调用
 *
 * 【可复用性】
 * 通过 attach(context)/detach() 与任意UIAbility绑定：
 * - EntryAbility.onCreate → attach
 * - EntryAbility.onDestroy → detach
 * - EntryAbility.onForeground → onAppForeground
 * - EntryAbility.onBackground → onAppBackground
 *
 * 【设计要点】
 * - 主进程被DATA_TRANSFER长时任务保活，锁屏/息屏期间定时器持续运行
 * - VEA进程可能被系统冻结，其内部定时器停摆，无法自检 → 主进程是唯一可靠检测点
 *
 * Created on 2026/9/7.
 * @author leojay`fu
 */
export class VpnKeepAliveManager {
  // 绑定的UIAbilityContext（backgroundTaskManager/notificationManager需要）
  private context?: common.UIAbilityContext;
  // VPN状态变化监听句柄
  private vpnChangeCancel?: SubEventCancel;
  // VPN流日志监听句柄
  private vpnStreamLogCancel?: SubEventCancel;
  // ===== 长时任务系统事件回调引用（用于on/off成对注销） =====
  private onTaskCancelCb: (info: backgroundTaskManager.ContinuousTaskCancelInfo) => void =
    (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      LLog.warn(TAG, `长时任务被系统取消: taskId=${info.id}, reason=${info.reason}`);
      // 系统已回收长时任务，若VPN仍开启则重新申请保活
      this.restartLongTaskIfVpnRunning();
    };
  private onTaskSuspendCb: (info: backgroundTaskManager.ContinuousTaskSuspendInfo) => void =
    (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
      LLog.warn(TAG, `长时任务被系统挂起: taskId=${info.continuousTaskId}, suspendState=${info.suspendState}, ` +
        `reason=${info.suspendReason}`);
      // 挂起期间进程冻结、VPN实际失去保活，若VPN仍开启则重新申请恢复激活
      this.restartLongTaskIfVpnRunning();
    };
  private onTaskActiveCb: (info: backgroundTaskManager.ContinuousTaskActiveInfo) => void =
    (info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
      LLog.info(TAG, `长时任务已激活: taskId=${info.id}`);
      this.startTunnelHealthCheck();
    };

  // 最后收到流日志的时间戳（用于判断隧道是否失效）
  private lastStreamLogTime: number = 0;
  /** 流日志过期阈值：3分钟（单位ms） */
  private readonly STREAM_LOG_STALE_THRESHOLD: number = 180000;
  // ===== 后台隧道健康守护（长时任务驱动，不依赖onForeground） =====
  /** 健康检查定时器：随长时任务启动/停止 */
  private tunnelHealthTimer?: number = undefined;
  /** 健康检查周期：60秒 */
  private readonly TUNNEL_HEALTH_CHECK_INTERVAL: number = 60 * 1000;
  /** 热重连(RECONNECT_REQUEST)最小间隔：2分钟，防止重复轰炸 */
  private readonly RECONNECT_REQUEST_MIN_INTERVAL: number = 2 * 60 * 1000;
  /** 强重启VEA兜底阈值：流日志超10分钟无更新（热重连无效，判定VEA冻结/卡死） */
  private readonly FORCE_RESTART_STALE_THRESHOLD: number = 10 * 60 * 1000;
  /** 上次发送热重连请求的时间戳 */
  private lastReconnectRequestTime: number = 0;
  /** 上次强重启VEA的时间戳 */
  private lastForceRestartTime: number = 0;
  /** 强重启VEA进行中标志：期间VEA会短暂广播STOP_VPN，需保护开关意图与保活不被误停 */
  private isForceRestarting: boolean = false;

  /**
   * 是否已绑定UIAbilityContext
   */
  isAttached(): boolean {
    return this.context != undefined;
  }

  /**
   * 长时任务是否正在运行（代理LongTaskModel）
   */
  isKeepAliveRunning(): boolean {
    return longTaskModel.isRunning();
  }

  /**
   * 【用户点击开启开关】直接启动保活（长时任务 + 通知 + 后台隧道健康守护）
   *
   * 由UI在点击开启时调用（需先经 WireGuard.config.status.switchOnIntent 置用户意图）。
   * 长时任务启动不再由VPN服务状态事件(START_VPN等)控制，而是跟随用户开关：
   * - 用户开启 → 立即启动保活，无需等待VPN进程/连接建立
   * - 用户关闭/异常 → onSwitchOff 停止保活
   */
  onSwitchOn(): void {
    if (this.context == undefined) {
      LLog.warn(TAG, 'onSwitchOn失败：context未绑定');
      return;
    }
    LLog.info(TAG, '用户开启开关，直接启动长时任务');
    this.startVpnKeepAlive(VpnEventTag.START_VPN);
  }

  /**
   * 【用户点击关闭开关】停止保活（长时任务 + 通知 + 后台隧道健康守护）
   *
   * 由UI在点击关闭时调用（需先经 WireGuard.config.status.switchOffIntent）。
   */
  onSwitchOff(): void {
    LLog.info(TAG, '用户关闭开关，停止长时任务');
    this.stopLongTaskIfNeeded();
  }

  /**
   * 意图开启时确保长时任务与守护在运行（幂等兜底）
   *
   * 供VPN事件回调使用：意图开启场景下，若保活因故未运行（如冷启动恢复、
   * 或 onSwitchOn 因系统暂未受理而失败）则补启；已运行则仅更新通知。
   *
   * @param connectedIps 事件携带的连接IP（可选，用于更新通知）
   */
  private ensureKeepAliveWhenIntendedOn(connectedIps?: Record<number, string>): void {
    if (!WireGuard.config.status.getConfig().isSwitchOpen) {
      return;
    }
    this.startVpnKeepAlive(VpnEventTag.START_VPN, connectedIps);
  }

  /**
   * 绑定UIAbilityContext并启动VPN保活事件驱动
   *
   * 由UIAbility.onCreate调用。执行：
   * 1. 注册长时任务取消监听（打印取消原因）
   * 2. 订阅VPN状态变化/流日志事件（驱动保活状态机）
   * 3. 主动查询VPN状态（若VEA运行中会回广播，自动恢复保活与通知）
   *
   * @param context UIAbilityContext
   */
  attach(context: common.UIAbilityContext): void {
    if (this.context != undefined) {
      LLog.info(TAG, '已绑定，忽略重复attach');
      return;
    }
    this.context = context;
    LLog.info(TAG, 'VPN保活管理器attach');

    // 1. 注册长时任务系统事件监听（取消/挂起/激活），感知系统真实保活状态
    try {
      backgroundTaskManager.on('continuousTaskCancel', this.onTaskCancelCb);
    } catch (error) {
    }
    try {
      backgroundTaskManager.on('continuousTaskSuspend', this.onTaskSuspendCb);
    } catch (error) {
    }
    try {
      backgroundTaskManager.on('continuousTaskActive', this.onTaskActiveCb);
    } catch (error) {
    }

    // 2. 订阅VPN事件（程序运行即注册）
    this.subscribeVpnChange();
    this.subscribeVpnStreamLogs();

    // 3. 主动查询VPN状态
    this.queryVpnStatus();
  }

  /**
   * 解除绑定并清理所有保活资源
   *
   * 由UIAbility.onDestroy调用。执行：
   * 1. 取消VPN事件订阅
   * 2. 停止长时任务与后台隧道健康守护
   * 3. 注销长时任务系统事件监听
   */
  detach(): void {
    if (this.context == undefined) {
      return;
    }
    LLog.info(TAG, 'VPN保活管理器detach');
    this.unsubscribeVpnChange();
    this.unsubscribeVpnStreamLogs();
    this.stopLongTaskIfNeeded();
    try {
      backgroundTaskManager.off('continuousTaskCancel', this.onTaskCancelCb);
    } catch (error) {
    }
    try {
      backgroundTaskManager.off('continuousTaskSuspend', this.onTaskSuspendCb);
    } catch (error) {
    }
    try {
      backgroundTaskManager.off('continuousTaskActive', this.onTaskActiveCb);
    } catch (error) {
    }
    this.context = undefined;
  }

  /**
   * UIAbility回到前台钩子
   *
   * VPN运行中时立即做一次隧道健康检查（后台守护定时器在长时任务运行期间持续执行，
   * 此处为补充即时检查，保证用户打开App时第一时间恢复）。
   */
  onAppForeground(): void {
    if (this.context == undefined) {
      return;
    }
    if (WireGuard.config.status.getConfig().isOpen()) {
      WireGuard.event.publishVpnStatusQuery();
      this.checkVpnTunnelHealth();
    }
  }

  /**
   * UIAbility退到后台钩子
   *
   * VPN运行中时确保长时任务真实有效：若长时任务被系统取消/挂起，
   * 或从未启动，则重新申请保活（而非仅凭内存ID判断）。
   */
  onAppBackground(): void {
    if (this.context == undefined) {
      return;
    }
    this.ensureKeepAliveActive();
  }

  // ===================== 长时任务有效性保障 =====================

  /**
   * 确保VPN运行期间长时任务真实有效（激活）
   *
   * 通过 probeSystemState 探测系统侧真实状态：
   * - RUNNING：已激活，确保后台隧道健康守护在运行
   * - 其他（NONE/SUSPENDED/CANCELLED）：内存ID存在但系统已失效 → 重置并重新申请
   *
   * 解决"内存continuousTaskId存在但系统已关闭/挂起"导致的VPN名义保活实则失效问题。
   */
  private async ensureKeepAliveActive(): Promise<void> {
    const ctx = this.context;
    if (ctx == undefined) {
      return;
    }
    if (!WireGuard.config.status.getConfig().isSwitchOpen) {
      return;
    }
    const state = await longTaskModel.probeSystemState(ctx);
    if (state === ContinuousTaskState.RUNNING) {
      // 已真实激活，确保健康守护在运行
      this.startTunnelHealthCheck();
      return;
    }
    LLog.warn(TAG, `开关已开但长时任务系统状态=${state}（非有效），重新申请保活`);
    // 清除可能失效的内存候选ID，允许 startLongTask 重新申请
    longTaskModel.resetTaskState();
    this.startVpnKeepAlive(VpnEventTag.QUERY_STATUS);
  }

  /**
   * 系统取消/挂起长时任务时，若开关仍开启则重新申请保活
   *
   * 由 continuousTaskCancel / continuousTaskSuspend 事件回调触发。
   */
  private restartLongTaskIfVpnRunning(): void {
    if (this.context == undefined) {
      return;
    }
    if (!WireGuard.config.status.getConfig().isSwitchOpen) {
      return;
    }
    LLog.warn(TAG, '长时任务异常（取消/挂起），重新申请保活');
    // 清除内存候选ID，使 startLongTask 可重新申请
    longTaskModel.resetTaskState();
    this.startVpnKeepAlive(VpnEventTag.QUERY_STATUS);
  }

  /**
   * 周期探测长时任务系统状态（后台隧道健康守护兜底）
   *
   * 事件监听可能偶发丢失；周期性探测确保即使错过事件，
   * 长时任务被系统取消/挂起后也能及时重新申请保活。
   */
  private async probeKeepAliveSystemState(): Promise<void> {
    const ctx = this.context;
    if (ctx == undefined) {
      return;
    }
    if (!WireGuard.config.status.getConfig().isSwitchOpen) {
      return;
    }
    const state = await longTaskModel.probeSystemState(ctx);
    if (state === ContinuousTaskState.RUNNING) {
      return;
    }
    LLog.warn(TAG, `长时任务系统状态异常=${state}，重新申请保活`);
    longTaskModel.resetTaskState();
    this.startVpnKeepAlive(VpnEventTag.QUERY_STATUS);
  }

  // ===================== VPN事件订阅 =====================

  /**
   * 主动查询VPN状态
   *
   * 若VPN Extension进程运行中，发送状态查询广播；
   * VEA收到后会publishVpnChange回复最新状态，经subscribeVpnChange自动恢复保活。
   * 若VEA未运行，仅记录日志（本地状态由后续事件/用户操作纠正）。
   */
  private queryVpnStatus(): void {
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
   * 【意图驱动的新状态机】长时任务启停不再由VPN服务状态控制（由onSwitchOn/onSwitchOff跟随用户开关），
   * 事件仅用于：校正真实运行状态(running)、冷启动意图恢复、异常回滚意图、守护兜底与网络清理确认。
   *
   * - vpnThreadRunning=true：
   *   - VPN_SERVICE_STOPPED → V2 STOP(用户关闭)后VEA存活：停守护并更新通知
   *   - VPN_TUNNEL_STALE → 隧道失效热重连
   *   - running=true(实际运行) → 若意图未开(冷启动恢复)则补意图；并确保保活兜底
   *   - running=false(如ON_CREATE中间态) → 仅确保意图开启时保活仍在(幂等)，不动意图
   * - vpnThreadRunning=false（进程关闭）：
   *   - 意图开启 → 若为强制重启中间态则保留意图与保活；否则判定异常/进程关闭 → 回滚意图并停保活
   *   - 意图已关(用户主动关闭) → 停保活(幂等)
   *   - STOP_VPN → 确认VPN网络清理完成（路由/DNS不残留，重启中间态除外）
   */
  private subscribeVpnChange(): void {
    if (this.vpnChangeCancel != undefined) {
      return;
    }
    this.vpnChangeCancel = WireGuard.event.subscribeVpnChange((params) => {
      // 注意：subscribeVpnChange内部已自动调用syncFromVpnProcess把params.status同步到本地AppStorageV2，
      // 意图字段(isSwitchOpen/switchConfigId)不会被覆盖，仅running/runningConfigId被校正。
      const tag = params.tag as VpnEventTag;
      const status = WireGuard.config.status.getConfig();
      LLog.info(TAG,
        `收到VPN状态变化广播: isOpen=${params.isOpen}, tag=${tag}, vpnThreadRunning=${params.vpnThreadRunning}, ` +
        `switchIntent=${status.isSwitchOpen}/${status.switchConfigId}`);

      if (params.vpnThreadRunning === true) {
        if (tag === VpnEventTag.VPN_SERVICE_STOPPED) {
          // V2 STOP action（用户关闭流程）→ 意图已关，停守护并更新通知
          this.onVpnServiceStopped();
          return;
        }
        if (tag === VpnEventTag.VPN_TUNNEL_STALE) {
          LLog.warn(TAG, 'VPN隧道失效（握手超时），通知VEA重连');
          this.ensureKeepAliveWhenIntendedOn(params.connectedIps);
          WireGuard.event.publishVpnReconnectRequest();
          return;
        }
        // START_VPN / QUERY_STATUS / ON_CREATE
        if (status.running === true) {
          // VPN实际运行中
          if (!status.isSwitchOpen && status.runningConfigId != undefined) {
            // 冷启动恢复：主进程新起但VPN仍在运行（用户此前开启未关闭）→ 补全用户意图
            LLog.info(TAG, `VPN实际运行但意图未开(configId=${status.runningConfigId})，冷启动恢复意图`);
            WireGuard.config.status.switchOnIntent(status.runningConfigId);
          } else if (status.isSwitchOpen && status.switchConfigId != status.runningConfigId &&
            status.runningConfigId != undefined) {
            // 运行中的配置与意图不一致（如热切换后广播）→ 意图对齐实际运行配置
            WireGuard.config.status.switchOnIntent(status.runningConfigId);
          }
          // 意图开启时确保保活兜底（防 onSwitchOn 丢失/冷启动）
          this.ensureKeepAliveWhenIntendedOn(params.connectedIps);
        } else {
          // running=false（ON_CREATE/查询到服务未运行等中间态）：
          // 不修改用户意图（启动中/恢复中等场景开关保持），意图开启时确保保活仍在
          this.ensureKeepAliveWhenIntendedOn(params.connectedIps);
        }
      } else {
        // ===== VPN进程关闭(vpnThreadRunning=false) =====
        if (status.isSwitchOpen) {
          if (this.isForceRestarting) {
            // 强重启恢复的中间态：保留意图与保活，等待随后的START_VPN重建
            LLog.warn(TAG, `强重启中间态(VEA关闭,tag=${tag})，保留意图与保活`);
            return;
          }
          // 意图开启但进程关闭且非主动恢复 → 判定为异常/进程被杀
          LLog.warn(TAG, `VPN进程关闭但开关仍开(tag=${tag})，判定异常，回滚开关意图并停止保活`);
          WireGuard.config.status.switchOffIntent();
          this.stopLongTaskIfNeeded();
        } else {
          // 意图已关（用户主动关闭流程）→ 停保活（幂等）
          this.stopLongTaskIfNeeded();
        }
        // VPN关闭后确认网络清理完成（检查VPN bearerType是否已移除）
        if (tag === VpnEventTag.STOP_VPN) {
          this.confirmVpnNetworkCleanup();
        }
      }
    });
    LLog.info(TAG, '已注册VPN状态变化监听');
  }

  /**
   * 注册VPN流日志监听
   *
   * 流日志包含每个Peer的实时流量统计和握手事件，
   * 用于更新后台通知中的流量数据和最后握手时间，
   * 并更新时间戳供隧道健康守护判断隧道活性。
   */
  private subscribeVpnStreamLogs(): void {
    if (this.vpnStreamLogCancel != undefined) {
      return;
    }
    this.vpnStreamLogCancel = WireGuard.event.subscribeVpnStreamLogs((log: StreamLogMessage) => {
      longTaskModel.updateStreamLog(log);
      // 更新最后收到流日志的时间（隧道健康守护依赖此判断隧道是否失效）
      this.lastStreamLogTime = Date.now();
    });
    LLog.info(TAG, '已注册VPN流日志监听');
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

  // ===================== 保活状态机 =====================

  /**
   * 启动VPN保活（长时任务 + 通知 + 后台隧道健康守护）
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
   * @param tag 事件标签（VpnEventTag枚举）
   * @param connectedIps 连接IP数据（可选，来自VPN状态广播）
   */
  private async startVpnKeepAlive(tag: VpnEventTag, connectedIps?: Record<number, string>): Promise<void> {
    const ctx = this.context;
    if (ctx == undefined) {
      LLog.warn(TAG, '启动保活失败：context未绑定');
      return;
    }

    // 重新激活保活：复位V2 STOP残留的"服务已停止"通知标记
    longTaskModel.setServiceStopped(false);

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
    // 1. 防重复启动：内存候选ID存在时仍需确认系统真实状态
    //    若系统已取消/挂起长时任务（内存ID空转），需放弃候选重新申请，而非错误跳过
    if (longTaskModel.isRunning()) {
      const sysState = await longTaskModel.probeSystemState(ctx);
      if (sysState === ContinuousTaskState.RUNNING) {
        LLog.info(TAG, `长时任务已有效运行，仅更新通知数据: tag=${tag}`);
        longTaskModel.publishNotification();
        // 确保后台隧道健康守护已启动（幂等，锁屏期间持续检测隧道）
        this.startTunnelHealthCheck();
        return;
      }
      LLog.warn(TAG, `长时任务候选存在但系统状态=${sysState}，重新申请保活: tag=${tag}`);
      longTaskModel.resetTaskState();
    }

    // 2. 启动长时任务
    try {
      await longTaskModel.startLongTask(ctx);
    } catch (e) {
      LLog.error(TAG, `启动长时任务失败: ${(e as Error).message}`);
      return;
    }
    // 长时任务启动成功 → 同步启动后台隧道健康守护
    this.startTunnelHealthCheck();

    // 3. 处理通知权限
    try {
      const enabled = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        await notificationManager.requestEnableNotification(ctx);
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
   * VPN服务已停止但VEA进程存活（V2 STOP action）
   */
  private onVpnServiceStopped(): void {
    LLog.info(TAG, 'VPN服务已停止（VEA进程存活），更新通知');
    // VPN服务已停止（isOpen=false），无需再检测隧道健康（下次START会自动重启守护）
    this.stopTunnelHealthCheck();
    longTaskModel.setServiceStopped(true);
    longTaskModel.publishNotification();
  }

  private stopLongTaskIfNeeded(): void {
    const ctx = this.context;
    if (ctx == undefined) {
      return;
    }
    // 长时任务停止 → 同步停止后台隧道健康守护
    this.stopTunnelHealthCheck();
    longTaskModel.stopLongTask(ctx);
  }

  // ===================== 后台隧道健康守护 =====================

  /**
   * 启动后台隧道健康检查定时器（幂等）
   *
   * 必须由长时任务驱动：主进程被DATA_TRANSFER长时任务保活，
   * 锁屏/息屏期间主进程的定时器仍持续运行，从而实现"无需打开App，
   * 只要长时任务在，就持续检测VPN隧道是否失效并自动重连"。
   *
   * 为什么不在VEA内部做唯一检测源：
   * VEA进程可能被系统冻结，其内部定时器同样停摆，无法自检。
   */
  private startTunnelHealthCheck(): void {
    if (this.tunnelHealthTimer != undefined) {
      return;
    }
    // 立即执行一次，然后周期检查
    this.checkVpnTunnelHealth();
    this.tunnelHealthTimer = setInterval(() => {
      // 1. 隧道活性检查（流日志过时 → 热重连/强重启VEA）
      this.checkVpnTunnelHealth();
      // 2. 长时任务系统状态兜底探测（系统取消/挂起长时任务时重新申请保活）
      this.probeKeepAliveSystemState();
    }, this.TUNNEL_HEALTH_CHECK_INTERVAL);
    LLog.info(TAG, `后台隧道健康守护已启动，检查周期=${this.TUNNEL_HEALTH_CHECK_INTERVAL / 1000}s`);
  }

  /**
   * 停止后台隧道健康检查定时器
   */
  private stopTunnelHealthCheck(): void {
    if (this.tunnelHealthTimer != undefined) {
      clearInterval(this.tunnelHealthTimer);
      this.tunnelHealthTimer = undefined;
      LLog.info(TAG, '后台隧道健康守护已停止');
    }
  }

  /**
   * 隧道健康检查（周期性执行）
   *
   * 判定依据：VPN运行期间，若长时间（>3分钟）未收到任何流日志/握手数据，
   * 则认为隧道疑似失效（VEA被冻结或WireGuard隧道已断）。
   *
   * 恢复策略（两级）：
   * 1. 热重连：发送RECONNECT_REQUEST，VEA若存活则执行handleRestartConfig重建隧道
   * 2. 强重启：热重连后仍超10分钟无数据（VEA冻结收不到事件），强制重启VEA进程
   *
   * 有节流：热重连至少间隔2分钟；强重启至少间隔2分钟，避免无效轰炸。
   */
  private checkVpnTunnelHealth(): void {
    if (!WireGuard.config.status.getConfig().isOpen()) {
      return;
    }
    if (this.lastStreamLogTime <= 0) {
      return;
    }
    const now: number = Date.now();
    const idleMs: number = now - this.lastStreamLogTime;
    if (idleMs <= this.STREAM_LOG_STALE_THRESHOLD) {
      return; // 隧道健康（近期有数据流动）
    }
    LLog.warn(TAG, `隧道健康检查: ${Math.floor(idleMs / 1000)}s无流日志，判定隧道疑似失效`);

    if (idleMs > this.FORCE_RESTART_STALE_THRESHOLD &&
      (now - this.lastForceRestartTime) > this.RECONNECT_REQUEST_MIN_INTERVAL) {
      // 热重连无效，VEA可能被冻结/卡死 → 强制重启VEA
      this.lastForceRestartTime = Date.now();
      this.forceRestartVpnService();
    } else if ((now - this.lastReconnectRequestTime) > this.RECONNECT_REQUEST_MIN_INTERVAL) {
      // 热重连
      LLog.warn(TAG, '隧道健康检查: 发送RECONNECT_REQUEST热重连');
      WireGuard.event.publishVpnReconnectRequest();
      this.lastReconnectRequestTime = Date.now();
    }
  }

  /**
   * 强制重启VEA进程（兜底恢复）
   *
   * 场景：VEA被系统冻结，收不到RECONNECT_REQUEST等CommonEvent，
   * 热重连无法生效。此时通过系统API先stopVpnExtensionAbility再startVpnExtensionAbility，
   * 利用runArg缓存的配置从零重建VPN连接。
   *
   * 依赖状态机：stop → VEA onDestroy广播STOP_VPN → 主进程停长时任务；
   * 随后start → VEA onCreate启动 → 广播START_VPN → 主进程重启长时任务+健康守护。
   */
  private async forceRestartVpnService(): Promise<void> {
    const configId: number | undefined = WireGuard.config.runArg.getConfigId();
    const dbConf = WireGuard.config.runArg.getDbConf();
    if (configId == undefined || dbConf == undefined) {
      LLog.warn(TAG, '强重启VEA失败：runArg无缓存配置，无法自动恢复');
      return;
    }
    LLog.warn(TAG, `强重启VEA: configId=${configId}`);
    // 置恢复标志：期间VEA会广播STOP_VPN(vpnThreadRunning=false)，
    // 状态机据此保留开关意图与保活，避免把"主动恢复"误判为"异常进程关闭"而回滚开关。
    this.isForceRestarting = true;
    try {
      // 1. 关闭（内部会先STOP等待确认，再stopVpnExtensionAbility）
      await WireGuard.runWGConfig(configId, dbConf, false);
      // 2. 等待VEA完全退出，避免启动竞态（start时若检测到VEA仍在运行会走SWITCH而非重启）
      await new Promise<void>((resolve) => setTimeout(resolve, 2000));
      // 3. 重新启动（VEA未运行 → startVpnExtensionAbility带参直传）
      await WireGuard.runWGConfig(configId, dbConf, true);
      LLog.info(TAG, '强重启VEA-启动指令已发送');
    } catch (e) {
      LLog.error(TAG, `强重启VEA异常: ${(e as Error).message}`);
    } finally {
      this.isForceRestarting = false;
    }
  }

  // ===================== VPN网络清理确认 =====================

  /**
   * VPN关闭后确认网络清理完成
   *
   * 检查当前网络的bearerTypes是否仍包含VPN类型(4)，
   * 如果残留则等待2秒后重试检测，最多3次。
   * 确保VPN路由和DNS配置已被系统完全清理。
   */
  private async confirmVpnNetworkCleanup(): Promise<void> {
    const maxRetries: number = 3;
    const retryInterval: number = 2000;
    for (let i = 0; i < maxRetries; i++) {
      try {
        const netHandle = connection.getDefaultNetSync();
        if (netHandle.netId === 0) {
          LLog.info(TAG, `VPN网络清理确认: 无默认网络(${i + 1}/${maxRetries})，跳过检查`);
          return;
        }
        const capInfo = await connection.getNetCapabilities(netHandle);
        const hasVpnBearer = capInfo.bearerTypes.includes(connection.NetBearType.BEARER_VPN);
        if (!hasVpnBearer) {
          LLog.info(TAG, `VPN网络清理确认: VPN bearer已移除(${i + 1}/${maxRetries})`);
          return;
        }
        LLog.warn(TAG, `VPN网络清理确认: VPN bearer仍存在(${i + 1}/${maxRetries})，等待重试`);
      } catch (e) {
        LLog.warn(TAG, `VPN网络清理确认: 检查异常(${i + 1}/${maxRetries}): ${(e as BusinessError).message}`);
      }
      if (i < maxRetries - 1) {
        await new Promise<void>((resolve) => setTimeout(resolve, retryInterval));
      }
    }
    LLog.warn(TAG, 'VPN网络清理确认: 重试耗尽，VPN bearer可能未清理');
  }
}

/**
 * VPN保活管理器全局单例
 *
 * 通过wg_tunnel导出，UIAbility（如EntryAbility）import后调用attach/detach即可接入保活。
 */
export const vpnKeepAliveManager: VpnKeepAliveManager = new VpnKeepAliveManager();
