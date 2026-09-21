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
import { VpnConfigAction } from '../model/entity/VpnConfigAction';
import VPNEventStatusParams, { VpnEventTag } from '../model/entity/VPNEventStatusParams';
import { MessageType, StreamDirection, StreamLogMessage } from '../model/entity/napi_entity';
import { SubEventCancel } from '../model/WGEvent';
import { longTaskModel, ContinuousTaskState } from './LongTaskModel';
import { SingleFlightLoop } from './SingleFlightLoop';

const TAG = 'VpnKeepAliveMgr';

// ==================== 调参定义（按模块分组，构造可注入覆盖） ====================

/** 检查循环参数 */
export interface LoopParams {
  /** 空闲最长等待：超过触发周期检查轮 */
  maxWaitMs: number;

  /** 最小轮间隔：两轮之间的硬性下限 */
  minGapMs: number;
}

/** 控制面新鲜度模块参数 */
export interface FreshnessParams {
  /** 通知新鲜度阈值：超过视为控制面失联 */
  staleMs: number;

  /** 状态查询回复的临时监听超时 */
  replyTimeoutMs: number;

  /** 存活确认后的探测抑制窗口 */
  probeSuppressMs: number;
}

/** 隧道数据面模块参数 */
export interface TunnelParams {
  /** 入站失联阈值（外发武装下判死） */
  inboundStaleMs: number;

  /** 外发武装窗口 */
  outboundWindowMs: number;

  /** 热重连最小间隔 */
  reconnectMinIntervalMs: number;

  /** 强重启兜底阈值（热重连无效后） */
  forceRestartStaleMs: number;
}

/** 长时任务重建模块参数 */
export interface ReapplyParams {
  /** 指数退避基础间隔 */
  baseIntervalMs: number;

  /** 指数退避上限 */
  maxIntervalMs: number;
}

/** 修复策略模块参数 */
export interface RepairParams {
  /** 连续修复失败上限（超过回滚开关并提示） */
  failLimit: number;
}

/** 保活检查调参集合（按模块分组） */
export interface KeepAliveParams {
  /** 检查循环节拍 */
  loop: LoopParams;

  /** 控制面新鲜度 */
  freshness: FreshnessParams;

  /** 隧道数据面 */
  tunnel: TunnelParams;

  /** 长时任务重建 */
  reapply: ReapplyParams;

  /** 修复策略 */
  repair: RepairParams;

  /** 开关宽限窗：刚开启后VEA中间态关闭广播不视为进程死亡 */
  switchGraceMs: number;
}

/** 默认调参 */
export const DEFAULT_KEEP_ALIVE_PARAMS: KeepAliveParams = {
  loop: { maxWaitMs: 60 * 1000, minGapMs: 3 * 1000 },
  freshness: {
    staleMs: 90 * 1000,
    replyTimeoutMs: 5 * 1000,
    probeSuppressMs: 5 * 60 * 1000,
  },
  tunnel: {
    inboundStaleMs: 180 * 1000,
    outboundWindowMs: 120 * 1000,
    reconnectMinIntervalMs: 2 * 60 * 1000,
    forceRestartStaleMs: 10 * 60 * 1000,
  },
  reapply: { baseIntervalMs: 30 * 1000, maxIntervalMs: 10 * 60 * 1000 },
  repair: { failLimit: 3 },
  switchGraceMs: 8 * 1000,
};

// ==================== 模块对象（各模块的参数+运行状态，按模块分组） ====================

/** 控制面新鲜度模块：VEA通知监听与失联判定 */
class FreshnessModule {
  readonly staleMs: number;
  readonly replyTimeoutMs: number;
  readonly probeSuppressMs: number;
  /** 最后一次收到VEA通知的时间戳（流日志+状态广播任一即刷新） */
  lastNotifyTime: number = 0;
  /** 上次状态回复确认存活的时间戳（探测抑制基准） */
  lastAliveConfirmTime: number = 0;
  /** 状态查询的pending回复resolver（临时监听，由subscribeVpnChange消费） */
  replyResolver?: (params: VPNEventStatusParams) => void;

  constructor(p: FreshnessParams) {
    this.staleMs = p.staleMs;
    this.replyTimeoutMs = p.replyTimeoutMs;
    this.probeSuppressMs = p.probeSuppressMs;
  }
}

/** 隧道数据面模块：入站/外发观测与两级恢复节奏 */
class TunnelModule {
  readonly inboundStaleMs: number;
  readonly outboundWindowMs: number;
  readonly reconnectMinIntervalMs: number;
  readonly forceRestartStaleMs: number;
  /** 最后收到流日志的时间戳（用于判断隧道是否有任何活动） */
  lastStreamLogTime: number = 0;
  /** 最后一次成功入站（RECEIVE且success）的时间戳：隧道活性的唯一可信依据 */
  lastInboundTime: number = 0;
  /** 最后一次外发活动（SEND流日志或SOCKET_ERROR事件）的时间戳：判死的武装信号 */
  lastOutboundTime: number = 0;
  /** 上次热重连请求时间戳 */
  lastReconnectRequestTime: number = 0;
  /** 上次强重启VEA时间戳 */
  lastForceRestartTime: number = 0;

  constructor(p: TunnelParams) {
    this.inboundStaleMs = p.inboundStaleMs;
    this.outboundWindowMs = p.outboundWindowMs;
    this.reconnectMinIntervalMs = p.reconnectMinIntervalMs;
    this.forceRestartStaleMs = p.forceRestartStaleMs;
  }
}

/** 长时任务重建模块：指数退避节奏与失败计数 */
class ReapplyModule {
  readonly baseIntervalMs: number;
  readonly maxIntervalMs: number;
  /** 上次重新申请保活的时间戳 */
  lastTime: number = 0;
  /** 重新申请保活连续失败次数（成功归零），用于指数退避 */
  failures: number = 0;

  constructor(p: ReapplyParams) {
    this.baseIntervalMs = p.baseIntervalMs;
    this.maxIntervalMs = p.maxIntervalMs;
  }
}

/** 修复策略模块：连续失败计数 */
class RepairModule {
  readonly failLimit: number;
  /** 连续修复失败计数（收到运行确认清零） */
  consecutiveFails: number = 0;

  constructor(p: RepairParams) {
    this.failLimit = p.failLimit;
  }
}

/** VPN控制面/数据面观察结果（observeVpn，只读观测，修复由checkRound串行执行） */
interface ObservedVpn {
  needRestartProcess: boolean; // 进程死/冻结 → 重启进程
  needRestartService: boolean; // 进程活、服务挂起 → 重启服务
}

/** 长时任务观察结果（observeLongTask） */
interface ObservedLongTask {
  needRecreate: boolean; // 被系统关闭/挂起 → 重建
}

/** DNS残留诊断结果 */
interface DnsDiagnosis {
  residue: boolean;   // true=检测到残留
  detail: string;     // 观测明细（系统DNS/VPN DNS/bearer）
}

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
 * - 所有保活触发源经SingleFlightLoop检查循环汇聚：单飞行串行执行检查轮，
 *   空闲60s周期兜底，执行期信号合并/丢弃——杜绝await空窗并发注册多个长时任务
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
      this.checkLoop.signal('sysCancel');
    };
  private onTaskSuspendCb: (info: backgroundTaskManager.ContinuousTaskSuspendInfo) => void =
    (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
      LLog.warn(TAG, `长时任务被系统挂起: taskId=${info.continuousTaskId}, suspendState=${info.suspendState}, ` +
        `reason=${info.suspendReason}`);
      // 挂起期间进程冻结、VPN实际失去保活，若VPN仍开启则重新申请恢复激活
      this.checkLoop.signal('sysCancel');
    };
  private onTaskActiveCb: (info: backgroundTaskManager.ContinuousTaskActiveInfo) => void =
    (info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
      LLog.info(TAG, `长时任务已激活: taskId=${info.id}`);
      this.checkLoop.start();
    };
  // ==================== 模块化调参与状态（按模块分组） ====================
  /** 注入的原始调参（loop重建与switchGraceMs等根级参数来源） */
  private readonly params: KeepAliveParams;
  /** 控制面新鲜度模块（参数+状态） */
  private readonly freshness: FreshnessModule;
  /** 隧道数据面模块（参数+状态） */
  private readonly tunnel: TunnelModule;
  /** 长时任务重建模块（参数+状态） */
  private readonly reapply: ReapplyModule;
  /** 修复策略模块（参数+状态） */
  private readonly repair: RepairModule;
  // ===== 保活检查循环：等待(信号|空闲60s)→checkRound 单飞行调度 =====
  // 为什么由主进程循环驱动检测：主进程被DATA_TRANSFER长时任务保活，
  // 锁屏/息屏期间主进程定时器持续运行；VEA进程可能被系统冻结，其内部
  // 定时器停摆无法自检，主进程是唯一可靠检测点。
  private readonly checkLoop: SingleFlightLoop;

  constructor(params: KeepAliveParams = DEFAULT_KEEP_ALIVE_PARAMS) {
    this.params = params;
    this.freshness = new FreshnessModule(params.freshness);
    this.tunnel = new TunnelModule(params.tunnel);
    this.reapply = new ReapplyModule(params.reapply);
    this.repair = new RepairModule(params.repair);
    // 注入自定义调参：重建循环以应用自定义节拍
    this.checkLoop = new SingleFlightLoop(
      (source: string): Promise<void> => this.checkRound(source),
      params.loop.maxWaitMs,
      params.loop.minGapMs
    );
  }

  // ==================== 其他状态 ====================
  /** 强重启VEA进行中标志：期间VEA会短暂广播STOP_VPN，需保护开关意图与保活不被误停 */
  private isForceRestarting: boolean = false;

  /**
   * 是否已绑定UIAbilityContext
   */
  isAttached(): boolean {
    return this.context != undefined;
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
    if (!WireGuard.config.status.getConfig().isSwitchOpen) {
      // 意图已被关闭（如快速开关交错、异步启动晚完成）：不启动保活，防止僵尸长时任务
      LLog.info(TAG, 'onSwitchOn时开关意图已关闭，跳过启动保活');
      return;
    }
    LLog.info(TAG, '用户开启开关，启动保活检查');
    // 检查循环：信号唤醒执行一轮检查+激活（单飞行，执行中重复触发自动丢弃）
    this.checkLoop.signal('switchOn');
    // 重置通知新鲜度基准与修复计数：启动确认不再是独立看门狗，
    // "启动后长时间收不到VEA通知"由检查轮的统一失联判定兜底
    this.freshness.lastNotifyTime = Date.now();
    this.repair.consecutiveFails = 0;
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
    if (connectedIps != undefined) {
      // 连接IP先落通知数据缓存（发布由通知循环节流择机，内容取最新）
      longTaskModel.updateVpnData({ connectedIps: connectedIps });
    }
    this.checkLoop.signal('broadcast');
  }

  // ===================== 保活检查与激活 =====================

  /**
   * 一轮保活检查（检查循环的执行体，单飞行串行内执行）
   *
   * 所有触发源（switchOn / 系统取消挂起回调 / 空闲周期 / 退后台 / 广播 / 回前台）
   * 经 checkLoop.signal 汇聚于此。结构：意图门 → Promise.all 并行双任务——
   * "VPN检查+结果处理"与"长时任务检查+结果处理"各自在任务内闭环完成。
   *
   * @param source 触发来源（日志定位；'idle'=空闲周期轮，其余为事件/用户源）
   */
  private async checkRound(source: string): Promise<void> {
    const ctx = this.context;
    if (ctx == undefined) {
      return;
    }
    if (!WireGuard.config.status.getConfig().isSwitchOpen) {
      return;
    }
    await Promise.all([
      this.checkAndRepairVpn().catch((e: Error): void => {
        LLog.error(TAG, `VPN检查/修复任务异常: ${e.message}`);
      }),
      this.checkAndRepairLongTask(source, ctx).catch((e: Error): void => {
        LLog.error(TAG, `长时任务检查/修复任务异常: ${e.message}`);
      }),
    ]);
  }

  /** VPN任务闭环：观察控制面 → 修复（重启进程/重启服务） → 数据面隧道恢复 */
  private async checkAndRepairVpn(): Promise<void> {
    const vpn: ObservedVpn = await this.observeVpn();
    if (vpn.needRestartProcess) {
      await this.repairVpnProcess();
      return;
    }
    if (vpn.needRestartService) {
      await this.repairVpnService();
      return;
    }
    // 数据面隧道失效（有通知但入站死+外发武装）：既有热重连→强重启两级恢复
    this.checkVpnTunnelHealth();
  }

  /** 长时任务闭环：观察系统状态 → 被系统关闭/挂起则重建（空闲轮退避，事件源立即） */
  private async checkAndRepairLongTask(source: string, ctx: common.UIAbilityContext): Promise<void> {
    const task: ObservedLongTask = await this.observeLongTask(ctx);
    if (task.needRecreate) {
      await this.reapplyKeepAlive(source !== 'idle');
      await this.reconcileExtraTasks();
    } else {
      // 长时任务有效：确保循环在跑（幂等，覆盖冷启动恢复路径）并对账清理孤儿
      this.checkLoop.start();
      await this.reconcileExtraTasks();
    }
  }

  /**
   * 对账多余长时任务：历史并发注册产生的多个startBackgroundRunning会在系统中
   * 留下孤儿长时任务（状态仅跟踪其中一条id）。此处停止所有非当前跟踪id的任务，
   * 保证系统中本应用的长时任务恒等于当前跟踪的那一条。
   */
  private async reconcileExtraTasks(): Promise<void> {
    const ctx = this.context;
    if (ctx == undefined) {
      return;
    }
    try {
      const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
        await backgroundTaskManager.getAllContinuousTasks(ctx, true);
      const trackedId = longTaskModel.getContinuousTaskId();
      for (const info of tasks) {
        if (info.continuousTaskId != trackedId) {
          LLog.warn(TAG, `对账：停止多余长时任务 id=${info.continuousTaskId}（当前跟踪=${trackedId}）`);
          await backgroundTaskManager.stopBackgroundRunning(ctx, info.continuousTaskId);
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      LLog.warn(TAG, `对账多余长时任务失败: code=${err.code}, message=${err.message}`);
    }
  }

  // ===================== 通知新鲜度双观察（Promise.all并行，只读不修复） =====================

  /**
   * 观察VPN控制面健康
   *
   * 超过NOTIFY_STALE_MS未收到任何VEA通知（流日志+状态广播）→ 控制面失联。
   * 失联可能是进程死/冻结，也可能是keepalive=0空闲隧道的合法静默——
   * 用"状态查询+临时监听回复"消歧，不在此处直接判定。
   */
  private async observeVpn(): Promise<ObservedVpn> {
    const o: ObservedVpn = { needRestartProcess: false, needRestartService: false };
    const now: number = Date.now();
    if (now - this.freshness.lastNotifyTime <= this.freshness.staleMs) {
      return o; // 通知新鲜：控制面健康
    }
    if (this.isForceRestarting) {
      return o; // 强重启进行中，等待自行恢复
    }
    if (this.freshness.lastAliveConfirmTime > 0 &&
      now - this.freshness.lastAliveConfirmTime < this.freshness.probeSuppressMs) {
      LLog.info(TAG, `控制面检查: 已${Math.floor((now - this.freshness.lastNotifyTime) / 1000)}s无通知，` +
        `${Math.floor((now - this.freshness.lastAliveConfirmTime) / 1000)}s前刚确认存活（抑制窗口内），跳过`);
      return o;
    }
    LLog.warn(TAG,
      `控制面检查: ${Math.floor((now - this.freshness.lastNotifyTime) / 1000)}s未收到任何VEA通知，查询消歧`);
    const reply = await this.queryVeaStatusWithReply();
    if (reply == null) {
      // 超时无回复：VEA运行中但不应答=冻结（未运行会本地自答回复QUERY_NO_RUNNING）
      LLog.warn(TAG, '控制面失联消歧: 状态查询超时无回复，判定VEA冻结，需重启进程');
      o.needRestartProcess = true;
    } else if (reply.tag === VpnEventTag.QUERY_NO_RUNNING) {
      // 本地自答：VEA进程未运行
      LLog.warn(TAG, '控制面失联消歧: VEA进程未运行，需重启进程');
      o.needRestartProcess = true;
    } else if (reply.vpnThreadRunning === true) {
      // 存活且服务在跑：keepalive=0空闲隧道的合法静默
      this.freshness.lastAliveConfirmTime = Date.now();
      LLog.info(TAG, '控制面失联消歧: VEA存活且服务运行中（空闲静默），无需处理');
    } else {
      // 存活但VPN服务挂起 → 重启服务
      LLog.warn(TAG, '控制面失联消歧: VEA存活但服务未运行，需重启服务');
      o.needRestartService = true;
    }
    return o;
  }

  /**
   * 观察长时任务系统状态
   */
  private async observeLongTask(ctx: common.UIAbilityContext): Promise<ObservedLongTask> {
    const state = await longTaskModel.probeSystemState(ctx);
    if (state !== ContinuousTaskState.RUNNING) {
      LLog.warn(TAG, `长时任务观察: 系统状态=${state}，需重建`);
    }
    return { needRecreate: state !== ContinuousTaskState.RUNNING };
  }

  /**
   * 发送状态查询并等待回复（临时监听，超时返回null）
   *
   * 回复来源：VEA运行中→VEA回复真实状态；VEA未运行→publishVpnStatusQuery
   * 本地自答回复QUERY_NO_RUNNING。回复由subscribeVpnChange统一消费转发。
   */
  private queryVeaStatusWithReply(): Promise<VPNEventStatusParams | null> {
    return new Promise<VPNEventStatusParams | null>((resolve) => {
      let settled: boolean = false;
      this.freshness.replyResolver = (params: VPNEventStatusParams): void => {
        if (settled) {
          return;
        }
        settled = true;
        this.freshness.replyResolver = undefined;
        resolve(params);
      };
      setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        this.freshness.replyResolver = undefined;
        resolve(null);
      }, this.freshness.replyTimeoutMs);
      WireGuard.event.publishVpnStatusQuery();
    });
  }

  /** 消费pending状态回复（subscribeVpnChange每条广播调用一次） */
  private consumeStatusReply(params: VPNEventStatusParams): void {
    const resolver = this.freshness.replyResolver;
    if (resolver == undefined) {
      return;
    }
    this.freshness.replyResolver = undefined;
    resolver(params);
  }

  /** 修复：VEA进程死/冻结 → 强制重启（连续失败超限则回滚开关并提示） */
  private async repairVpnProcess(): Promise<void> {
    this.repair.consecutiveFails++;
    if (this.repair.consecutiveFails > this.repair.failLimit) {
      LLog.error(TAG, `连续${this.repair.consecutiveFails - 1}次修复后仍无VEA运行确认，回滚开关并提示失败原因`);
      WireGuard.event.publishVpnThrow('VPN启动失败：VPN进程异常退出');
      WireGuard.config.status.switchOffIntent();
      this.stopLongTaskIfNeeded();
      WireGuard.event.publishVpnNoOpen();
      this.repair.consecutiveFails = 0;
      return;
    }
    LLog.warn(TAG, `修复VPN进程: 第${this.repair.consecutiveFails}次，强制重启VEA`);
    await this.forceRestartVpnService();
  }

  /** 修复：VEA存活但服务挂起 → 重启服务（VEA运行中，runWGConfig走热切换路径；连续失败超限回滚） */
  private async repairVpnService(): Promise<void> {
    this.repair.consecutiveFails++;
    if (this.repair.consecutiveFails > this.repair.failLimit) {
      LLog.error(TAG, `连续${this.repair.consecutiveFails - 1}次修复后服务仍未恢复，回滚开关并提示失败原因`);
      WireGuard.event.publishVpnThrow('VPN启动失败：VPN服务未能恢复');
      WireGuard.config.status.switchOffIntent();
      this.stopLongTaskIfNeeded();
      WireGuard.event.publishVpnNoOpen();
      this.repair.consecutiveFails = 0;
      return;
    }
    const configId: number | undefined = WireGuard.config.runArg.getConfigId();
    const dbConf = WireGuard.config.runArg.getDbConf();
    if (configId == undefined || dbConf == undefined) {
      LLog.warn(TAG, '修复VPN服务: runArg无缓存配置，无法重启服务');
      return;
    }
    LLog.warn(TAG, `修复VPN服务: 第${this.repair.consecutiveFails}次，VEA运行中重启服务`);
    await WireGuard.runWGConfig(configId, dbConf, true);
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
      // 立即触发一轮检查（信号唤醒；若恰有轮次在执行则合并丢弃，该轮已覆盖）
      this.checkLoop.signal('foreground');
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
    this.checkLoop.signal('background');
  }

  /**
   * 重新申请保活（空闲周期轮带指数退避）
   *
   * 系统取消/挂起长时任务后立即重新申请是VPN刚需，但若申请被系统持续拒绝
   * （如策略不允许、参数异常），高频重试会与系统策略形成对抗空耗电。
   * 空闲周期轮（force=false）连续失败时按 30s→60s→120s…指数退避（上限10分钟）；
   * 事件/用户源（force=true）绕过退避立即申请。
   * 申请后按实际结果更新失败计数，成功归零。
   */
  private async reapplyKeepAlive(force: boolean): Promise<void> {
    const now = Date.now();
    const backoff = Math.min(this.reapply.baseIntervalMs * Math.max(1, this.reapply.failures),
      this.reapply.maxIntervalMs);
    if (!force && this.reapply.lastTime > 0 && (now - this.reapply.lastTime) < backoff) {
      LLog.info(TAG, `重新申请保活被退避抑制(连续失败${this.reapply.failures}次, 退避${backoff / 1000}s)`);
      return;
    }
    this.reapply.lastTime = now;
    await this.startVpnKeepAlive();
    if (longTaskModel.isRunning()) {
      this.reapply.failures = 0;
    } else {
      this.reapply.failures++;
    }
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
      // 任何VEA广播都是控制面存活信号：刷新新鲜度基准 + 消费pending状态查询回复
      this.freshness.lastNotifyTime = Date.now();
      this.consumeStatusReply(params);
      const tag = params.tag as VpnEventTag;
      const status = WireGuard.config.status.getConfig();
      LLog.info(TAG,
        `收到VPN状态变化广播: isOpen=${params.isOpen}, tag=${tag}, vpnThreadRunning=${params.vpnThreadRunning}, ` +
          `switchIntent=${status.isSwitchOpen}/${status.switchConfigId}`);

      if (tag === VpnEventTag.QUERY_NO_RUNNING) {
        // 仅表示"查询时VEA未运行"的信息事件（发布时不带vpnThreadRunning），
        // 不能落入下方"进程关闭"分支误回滚开关意图（如启动窗口期回前台触发查询）
        LLog.info(TAG, 'QUERY_NO_RUNNING：VEA未运行，忽略，不影响开关意图');
        return;
      }

      if (params.vpnThreadRunning === true) {
        // 运行确认到达=修复成功：清零连续修复失败计数
        this.repair.consecutiveFails = 0;
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
            if (status.hasLocalOff) {
              // 本进程内用户明确关闭过开关 → 这不是冷启动恢复，
              // 而是用户关闭后在途的启动指令完成（如快速开关后参数直传启动晚到），必须拆除
              LLog.warn(TAG, `VPN运行但本进程有过用户关闭意图(tag=${tag})，判定陈旧启动，下发STOP并关闭VEA`);
              this.teardownStaleStart();
              return;
            }
            // 冷启动恢复：主进程新起但VPN仍在运行（用户此前开启未关闭）→ 补全用户意图
            LLog.info(TAG, `VPN实际运行但意图未开(configId=${status.runningConfigId})，冷启动恢复意图`);
            WireGuard.config.status.switchOnIntent(status.runningConfigId);
          }
          // 注意：running配置与意图配置不一致时不改写用户意图（用户意图权威，
          // 由启动确认看门狗驱动VEA向意图收敛），广播只反映事实
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
          // 开关刚开启的宽限期内（切换/启动进行中），VEA的中间态关闭广播
          // （如旧配置STOP_VPN晚到）不视为进程死亡；显式的THROW启动失败仍照常回滚
          if (tag !== VpnEventTag.THROW &&
            (Date.now() - status.lastSwitchOnTime) < this.params.switchGraceMs) {
            LLog.info(TAG, `开关宽限期内收到${tag}关闭广播，视为切换中间态，保留意图与保活`);
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
   * 拆除陈旧启动建立的VPN
   *
   * 场景：用户快速开→关后，在途的启动指令（如API22+参数直传启动）晚到并建立了隧道。
   * 此时用户的关闭流程已执行过（意图已关、保活已停），但当时的STOP未能命中尚未
   * 启动的VEA，因此这里补发STOP——VEA确认任务关闭后自行关闭进程，收敛到用户意图。
   */
  private teardownStaleStart(): void {
    WireGuard.event.publishVpnConfigRequest({ action: VpnConfigAction.STOP });
    LLog.info(TAG, '已下发陈旧启动拆除指令，VEA确认后自行关闭');
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
      // 流日志也是VEA存活信号（哪怕SOCKET_ERROR也证明进程活着在尝试）
      this.freshness.lastNotifyTime = Date.now();
      longTaskModel.updateStreamLog(log);
      // 更新最后收到流日志的时间（隧道健康守护依赖此判断是否有任何活动）
      const now = Date.now();
      this.tunnel.lastStreamLogTime = now;
      if (log.messageType === MessageType.SOCKET_ERROR) {
        // 链路异常事件计入外发活动：证明发送侧仍在尝试，武装失效判定
        this.tunnel.lastOutboundTime = now;
      } else {
        if (log.direction === StreamDirection.SEND) {
          // 外发活动（心跳/数据/握手尝试，无论成败）武装失效判定
          this.tunnel.lastOutboundTime = now;
        }
        if (log.direction === StreamDirection.RECEIVE && log.success) {
          // 成功入站是隧道活性的唯一可信依据（外发握手尝试不代表对端可达）
          this.tunnel.lastInboundTime = now;
        }
      }
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
   * 启动VPN保活（长时任务 + 通知 + 检查循环）
   *
   * 由保活检查轮（reapplyKeepAlive）调用：调用前已在本轮probe确认
   * 长时任务系统状态非RUNNING，此处只需清掉内存残留候选后重新申请。
   * 流程：复位通知数据 → 确保候选无残留 → 启动长时任务 → 启动检查循环 → 通知权限。
   *
   * @param connectedIps 连接IP数据（可选，来自VPN状态广播）
   */
  private async startVpnKeepAlive(connectedIps?: Record<number, string>): Promise<void> {
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
    // 内存候选残留但系统侧已失效（本轮probe已确认非RUNNING）→ 重置后重新申请
    if (longTaskModel.isRunning()) {
      longTaskModel.resetTaskState();
    }

    // 2. 启动长时任务
    try {
      await longTaskModel.startLongTask(ctx);
    } catch (e) {
      LLog.error(TAG, `启动长时任务失败: ${(e as Error).message}`);
      return;
    }
    // 长时任务启动成功 → 检查循环进入空闲周期（幂等）
    this.checkLoop.start();

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
    // VPN服务已停止（isOpen=false）：检查循环停止（下次激活自动重启），通知循环保活锚点
    this.checkLoop.stop();
    longTaskModel.setServiceStopped(true);
    longTaskModel.publishNotification();
    // 明确回复到达（网络已拆干净）：确认系统DNS/网络已恢复
    this.confirmVpnNetworkCleanup();
  }

  private stopLongTaskIfNeeded(): void {
    const ctx = this.context;
    if (ctx == undefined) {
      return;
    }
    // 长时任务停止 → 检查循环同步停止
    this.checkLoop.stop();
    longTaskModel.stopLongTask(ctx);
  }

  // ===================== 后台隧道健康守护 =====================

  /**
   * 隧道健康检查（检查循环每轮顺带执行，自门控）
   *
   * 【定位】最外层兜底，非隧道内判定的重复：隧道内的失效判定与自愈由C层
   * 心跳线程完成（握手失联判死→SOCKET_ERROR→VEA重建）。本检查覆盖的是
   * "VEA进程死亡/冻结导致C层无法上报"的场景——此时流日志整体停更，
   * 由主进程观测发现并触发强重启。
   *
   * 【判死双条件】
   * 1. 连续3分钟无成功入站（RECEIVE且success）——外发握手尝试不代表对端可达，
   *    只有成功入站（握手响应/数据）才能证明隧道真实可用；
   * 2. 近2分钟内有外发活动（SEND流日志/SOCKET_ERROR事件）——keepalive=0且空闲的隧道
   *    没有外发信号，无法区分"空闲"与"失效"，此时不做判定，避免无意义重连空转。
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
    if (this.tunnel.lastStreamLogTime <= 0) {
      return; // 启动初期尚未收到任何流日志，不做判定
    }
    const now: number = Date.now();
    const inboundIdleMs: number = now - this.tunnel.lastInboundTime;
    if (inboundIdleMs <= this.tunnel.inboundStaleMs) {
      return; // 近期有成功入站，隧道健康
    }
    if ((now - this.tunnel.lastOutboundTime) > this.tunnel.outboundWindowMs) {
      // 无入站且无外发：keepalive=0的空闲隧道，无法区分空闲与失效，跳过
      LLog.info(TAG, `隧道健康检查: ${Math.floor(inboundIdleMs / 1000)}s无入站且近${this.tunnel.outboundWindowMs /
        1000}s无外发（空闲隧道），跳过判定`);
      return;
    }
    LLog.warn(TAG, `隧道健康检查: ${Math.floor(inboundIdleMs / 1000)}s无成功入站且外发活跃，判定隧道疑似失效`);

    if (inboundIdleMs > this.tunnel.forceRestartStaleMs &&
      (now - this.tunnel.lastForceRestartTime) > this.tunnel.reconnectMinIntervalMs) {
      // 热重连无效，VEA可能被冻结/卡死 → 强制重启VEA
      this.tunnel.lastForceRestartTime = Date.now();
      this.forceRestartVpnService();
    } else if ((now - this.tunnel.lastReconnectRequestTime) > this.tunnel.reconnectMinIntervalMs) {
      // 热重连
      LLog.warn(TAG, '隧道健康检查: 发送RECONNECT_REQUEST热重连');
      WireGuard.event.publishVpnReconnectRequest();
      this.tunnel.lastReconnectRequestTime = Date.now();
    }
  }

  /**
   * 强制重启VEA进程（兜底恢复）
   *
   * 场景：VEA被系统冻结，收不到RECONNECT_REQUEST等CommonEvent，
   * 热重连无法生效。此时发STOP（VEA确认后自行关闭进程），等待其退出后
   * 利用runArg缓存的配置从零重建VPN连接。
   *
   * 依赖状态机：stop → VEA广播STOP_VPN → 主进程停长时任务；
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
      // 1. 关闭：通知式，VEA确认任务关闭后自行关闭进程。
      //    关闭异常（如指令丢失）不阻断后续重启，故独立捕获
      try {
        await WireGuard.runWGConfig(configId, dbConf, false);
      } catch (stopErr) {
        LLog.warn(TAG, `强重启VEA-关闭失败(继续重启流程): ${(stopErr as Error).message}`);
      }
      // 2. 轮询等待VEA完全退出（避免启动竞态：start时若检测到VEA仍在运行会走SWITCH而非重启）
      const deadline = Date.now() + 6000;
      while (Date.now() < deadline) {
        if (!(await WireGuard.tools.isVpnExtensionRunning())) {
          break;
        }
        await new Promise<void>((resolve) => setTimeout(resolve, 500));
      }
      // 3. 重启前复查用户意图：关闭流程可能在本重启期间执行（runArg已被清空），
      //    此时若继续启动，会把用户已关闭的VPN重新拉起并重新缓存runArg
      if (!WireGuard.config.status.getConfig().isSwitchOpen) {
        LLog.warn(TAG, '强重启VEA-重启前检测到开关已关闭，中止启动');
        return;
      }
      // 4. 重新启动（VEA未运行 → startVpnExtensionAbility带参直传）
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
   * 仅检测默认网络是否仍挂VPN bearer——bearer移除即系统已完整注销VPN网络
   * （路由+DNS随网络注销恢复）。
   * 不比对DNS列表：用户配置的VPN DNS常与物理网络DNS重合（公共DNS/路由器DNS），
   * 交集命中不代表残留（实测误报）。重试耗尽仍挂VPN bearer → THROW提示开关WiFi
   * （真残留：系统未注销VPN网络）。
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
    LLog.error(TAG, 'VPN网络清理确认: 重试耗尽，VPN网络未注销');
    WireGuard.event.publishVpnThrow('VPN已关闭但系统网络未完全注销，建议开关一次WiFi/飞行模式');
  }

  // ===================== DNS残留诊断与修复（设置页「修复DNS」按钮） =====================

  /**
   * 诊断系统DNS残留（只读）
   *
   * 残留判定=默认网络仍挂VPN bearer（系统未注销VPN网络）。
   * 不比对DNS列表：用户配置的VPN DNS常与物理网络DNS重合（公共DNS/路由器DNS），
   * 交集命中不代表残留——系统DNS列表仅进detail供人工核对。
   */
  async diagnoseDnsResidue(): Promise<DnsDiagnosis> {
    const result: DnsDiagnosis = { residue: false, detail: '' };
    const netHandle = connection.getDefaultNetSync();
    if (netHandle.netId === 0) {
      // 无默认网络：可能正是关闭VPN后的残留坏状态
      result.residue = true;
      result.detail = '设备当前没有可用网络';
      return result;
    }
    const caps = await connection.getNetCapabilities(netHandle);
    const vpnBearer = caps.bearerTypes.includes(connection.NetBearType.BEARER_VPN);
    const props = await connection.getConnectionProperties(netHandle);
    const dnses: string[] = props.dnses.map((d: connection.NetAddress): string => d.address);
    result.residue = vpnBearer;
    result.detail = `系统DNS=[${dnses.join(', ')}], VPN bearer=${vpnBearer}`;
    return result;
  }

  /**
   * 修复DNS残留（设置页「修复DNS」按钮）：诊断 → 尽力修复 → 复检 → 指引
   *
   * 主进程无写系统DNS的API，能做的修复动作：
   * 1. VEA存活 → 重发STOP触发destroy重试（shutdown序列与重试预算见VpnSessionManager）；
   * 2. reportNetConnected(物理网络)——系统提供的唯一"通知网络刷新"入口；
   * 3. 复检×2，仍残留返回'manual'（UI指引开关WiFi/飞行模式，替代重启手机）。
   *
   * @returns 'clean'=无残留 | 'vpn-on'=VPN运行中无需修复 | 'repaired'=已修复 | 'manual'=需手动干预
   */
  async repairDnsResidue(): Promise<string> {
    if (WireGuard.config.status.getConfig().isSwitchOpen) {
      LLog.info(TAG, 'DNS修复: VPN运行中，DNS经隧道转发属正常，无需修复');
      return 'vpn-on';
    }
    let d = await this.diagnoseDnsResidue();
    if (!d.residue) {
      return 'clean';
    }
    LLog.warn(TAG, `DNS修复: 检测到残留(${d.detail})，尝试修复`);
    // 1. VEA存活 → 重发STOP触发destroy重试
    try {
      if (await WireGuard.tools.isVpnExtensionRunning()) {
        WireGuard.event.publishVpnConfigRequest({ action: VpnConfigAction.STOP });
      }
    } catch (e) {
      LLog.warn(TAG, `DNS修复: 触发VEA销毁失败: ${(e as Error).message}`);
    }
    // 2. 通知系统物理网络可用，促使刷新默认网/解析配置
    try {
      const netHandle = connection.getDefaultNetSync();
      if (netHandle.netId !== 0) {
        await connection.reportNetConnected(netHandle);
      }
    } catch (e) {
      LLog.warn(TAG, `DNS修复: reportNetConnected失败: ${(e as Error).message}`);
    }
    // 3. 复检×2（2s/3s间隔，给系统刷新时间）
    await new Promise<void>((resolve) => setTimeout(resolve, 2000));
    d = await this.diagnoseDnsResidue();
    if (!d.residue) {
      return 'repaired';
    }
    await new Promise<void>((resolve) => setTimeout(resolve, 3000));
    d = await this.diagnoseDnsResidue();
    if (!d.residue) {
      return 'repaired';
    }
    LLog.error(TAG, `DNS修复: 复检仍残留(${d.detail})`);
    return 'manual';
  }
}

/**
 * VPN保活管理器全局单例
 *
 * 通过wg_tunnel导出，UIAbility（如EntryAbility）import后调用attach/detach即可接入保活。
 */
export const vpnKeepAliveManager: VpnKeepAliveManager = new VpnKeepAliveManager();
