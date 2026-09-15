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
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { bundleManager, common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { AppStorageV2, UIUtils } from '@kit.ArkUI';
import { LLog, StreamLogMessage, MessageType, WireGuard } from 'wg_tunnel';
import { NotificationUpdater } from './NotificationUpdater';

const TAG: string = 'VpnKeepAlive';

/**
 * 长时任务被系统取消后的自愈退避序列（毫秒）
 *
 * 系统可能连续取消（如息屏后长时任务通知被上层清理），无间隔重申请会变成忙循环；
 * 首次1秒即满足"取消后5秒内恢复"的目标，之后逐步退避，最多重试序列长度次。
 */
const SELF_HEAL_BACKOFF_MS: number[] = [1000, 2000, 5000, 10000, 10000];

/**
 * 延时（自愈退避用）
 *
 * @param ms 毫秒
 */
function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/**
 * VPN通知内容数据 - 纯数据类，用于构建通知文本
 *
 * 在主应用进程中维护，由VPN状态变化和流日志事件更新。
 * VPN连接的IP地址来自VPNEventStatusParams.connectedIps（跨进程广播），
 * 流量统计和握手时间来自StreamLogMessage（跨进程广播）。
 */
export class VpnNotificationData {
  connectedIps: Record<number, string> = {};
  latestLogs: Map<number, StreamLogMessage> = new Map();
  lastHandshakeTime: Map<number, number> = new Map();
  /** VPN配置名称 */
  configName?: string = undefined;
  /** 目标端点地址列表（peerIndex -> ipStrOrDomain:port） */
  targetEndpoints: Record<number, string> = {};
  /** VPN服务已停止但VEA进程存活（V2模式STOP action） */
  serviceStopped: boolean = false;
}

/**
 * 长时任务运行状态实体 - 应用内存级持久化
 *
 * 使用 AppStorageV2 + @ObservedV2 + @Trace 实现应用内存级持久化，
 * 数据在应用运行期间不会被系统回收，但退出应用后自动销毁。
 *
 * 之所以选择 AppStorageV2 而非普通类属性：
 * - 普通类属性在系统内存紧张时可能随 LongTaskModel 实例被回收
 * - AppStorageV2 由框架管理生命周期，应用运行期间始终可用
 *
 * Created on 2026/8/25.
 * @author leojay`fu
 */
@ObservedV2
export class LongTaskState {
  /** 长时任务ID，用于新API的stop和update */
  @Trace continuousTaskId?: number = undefined;
  /** 通知ID，用于更新通知内容 */
  @Trace notificationId?: number = undefined;
  /** 记录长时任务启动时间，用于计算已运行时长 */
  @Trace startTime?: number = undefined;
}

/**
 * 获取LongTaskState单例（AppStorageV2内存级持久化）
 * @returns LongTaskState实例
 */
function getLongTaskState(): LongTaskState {
  return AppStorageV2.connect(LongTaskState, () => UIUtils.makeObserved(new LongTaskState()))!;
}

/**
 * 流量字节数转可读字符串
 * @param bits 字节数
 * @returns 格式化字符串，如 "1.23 MB"
 */
function formatTraffic(bits: number): string {
  if (bits < 0) {
    return '0 B';
  }
  const bytes: number = bits / 8;
  if (bytes < 1024) {
    return `${bytes.toFixed(0)} B`;
  }
  const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];
  let val: number = bytes;
  let unitIndex: number = 0;
  while (val >= 1024 && unitIndex < units.length - 1) {
    val /= 1024;
    unitIndex++;
  }
  return `${val.toFixed(2)} ${units[unitIndex]}`;
}

/**
 * 时间戳格式化为可读时间
 * @param timestamp 毫秒时间戳
 * @returns 格式化时间字符串
 */
function formatTime(timestamp: number): string {
  const date = new Date(timestamp);
  const hours = date.getHours().toString().padStart(2, '0');
  const minutes = date.getMinutes().toString().padStart(2, '0');
  const seconds = date.getSeconds().toString().padStart(2, '0');
  return `${hours}:${minutes}:${seconds}`;
}

/**
 * 计算运行时长描述
 * @param startTime 开始时间戳（毫秒）
 * @returns 可读时长字符串，如 "1时23分"
 */
function formatDuration(startTime: number): string {
  const elapsed: number = Date.now() - startTime;
  const totalMinutes: number = Math.floor(elapsed / (60 * 1000));
  const hours: number = Math.floor(totalMinutes / 60);
  const minutes: number = totalMinutes % 60;
  if (hours > 0) {
    return `${hours}时${minutes}分`;
  }
  return `${minutes}分`;
}

/**
 * 后台长时任务管理
 * 使用ContinuousTaskRequest新API签名，支持进度更新定时器保活
 * 集成通知内容管理，在通知中展示VPN连接状态、流量和握手时间
 *
 * Created on 2026/7/27.
 * @author leojay`fu
 */
class LongTaskModel {
  private updater: NotificationUpdater;
  private vpnData: VpnNotificationData = new VpnNotificationData();
  /** 自愈流程进行中标记：系统连续取消时避免并发重申请 */
  private selfHealing: boolean = false;

  constructor() {
    this.updater = new NotificationUpdater(() => {
      this.publishNotification();
    });
  }

  /**
   * 构建ContinuousTaskRequest（公共方法）
   *
   * 统一构建长时任务所需的ContinuousTaskRequest，避免startLongTask和updateProgress中重复代码。
   * 内部包含WantAgent创建、后台模式、子模式设置，包名通过bundleManager获取。
   *
   * @param _context Context，用于构建WantAgent
   * @returns 构建好的ContinuousTaskRequest对象
   * @throws for wantAgent.getWantAgent
   */
  private async createTaskRequest(_context: common.UIAbilityContext):
    Promise<backgroundTaskManager.ContinuousTaskRequest> {
    const bundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: bundleInfo.name,
        abilityName: 'EntryAbility',
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    const wantAgentObj: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);

    const request = new backgroundTaskManager.ContinuousTaskRequest();
    request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER];
    request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION];
    request.wantAgent = wantAgentObj;
    request.continuousTaskId = getLongTaskState().continuousTaskId
    request.combinedTaskNotification = false // DATA_TRANSFER 类型不允许合并
    return request;
  }

  /**
   * 重置长时任务状态
   * 在stop成功或确认未运行后调用，将AppStorageV2中的状态恢复为初始值
   */
  private resetState(): void {
    const state = getLongTaskState();
    state.continuousTaskId = undefined;
    state.notificationId = undefined;
    state.startTime = undefined;
  }

  /**
   * 判断长时任务是否正在运行
   * @returns true=长时任务已启动且未停止
   */
  isRunning(): boolean {
    return getLongTaskState().continuousTaskId != undefined;
  }

  /**
   * 主动移除长时任务关联的通知
   *
   * 在以下时机调用，防止出现多个通知窗口：
   * - startLongTask 启动前：取消上次残留的旧通知
   * - stopLongTask 停止时：立即移除通知，不依赖 stopBackgroundRunning 的系统清理
   */
  private removeNotification(): void {
    const state = getLongTaskState();
    if (state.notificationId != undefined) {
      const oldId = state.notificationId;
      notificationManager.cancel(oldId).then(() => {
        LLog.info(TAG, `已移除旧通知: id=${oldId}`);
      }).catch((err: BusinessError) => {
        if (err.code !== 1600004) {
          LLog.warn(TAG, `移除旧通知失败: id=${oldId}, code=${err.code}`);
        }
      });
    }
  }

  // 启动长时任务
  /**
   * @throws
   */
  async startLongTask(currentContext: common.UIAbilityContext): Promise<void> {
    const state = getLongTaskState();

    try {
      if (state.continuousTaskId != undefined) {
        LLog.info(TAG, '后台长时任务已启动，无需重复启动');
        return;
      }

      // 启动前取消旧通知，防止出现多个通知
      this.removeNotification();

      const request = await this.createTaskRequest(currentContext);

      const notification: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(currentContext, request);

      state.continuousTaskId = notification.continuousTaskId;
      state.notificationId = notification.notificationId;
      state.startTime = Date.now();

      // 校验continuousTaskId：官方API声明为可选类型，不保证一定有值
      // 若为空则无法使用新API的update/stop，需依赖旧API降级
      if (state.continuousTaskId == undefined) {
        LLog.warn(TAG, 'startBackgroundRunning成功但continuousTaskId为空，将使用旧API降级处理');
      }

      LLog.info(TAG, `startBackgroundRunning成功, taskId=${state.continuousTaskId}, notificationId=${state.notificationId}`);

      this.publishNotification();
      this.updater.start();
    } catch (error) {
      const err = error as BusinessError;
      LLog.error(TAG, `startBackgroundRunning失败. code: ${err.code}, message: ${err.message}`);
      throw new Error(`startBackgroundRunning failed: ${err.code} - ${err.message}`);
    }
  }

  /**
   * 长时任务被系统取消后的自愈入口
   *
   * 触发时机：backgroundTaskManager.on('continuousTaskCancel')（由EntryAbility注册并转发）
   *
   * 处理顺序（顺序不可调换）：
   *   1. 停止通知更新器（取消后不再按旧状态发布通知）
   *   2. resetState() 清理缓存状态 —— 关键：isRunning() 读的是缓存，
   *      不清则恒为 true，startLongTask() 会直接 return，永远无法自愈
   *   3. VPN仍在运行时，按退避序列重新申请长时任务（最多 SELF_HEAL_BACKOFF_MS.length 次）
   *
   * @param currentContext UIAbilityContext，用于重新申请长时任务
   * @param reason 系统给出的取消原因（ContinuousTaskCancelReason）
   */
  async onContinuousTaskCancelled(currentContext: common.UIAbilityContext, reason: number): Promise<void> {
    // 1. 先停更新器
    this.updater.stop();
    // 2. 清缓存状态（让 isRunning() 归假，否则重申请会被"已启动"分支挡掉）
    this.resetState();
    LLog.warn(TAG, `已清理长时任务状态(reason=${reason})，准备重新申请`);

    // 3. VPN已停止就不必重申请（用户主动断开）
    if (!WireGuard.isRunning()) {
      LLog.info(TAG, 'VPN未运行，无需重新申请长时任务');
      return;
    }
    // 4. 连续取消场景：已有自愈流程在跑就不再另起一个
    if (this.selfHealing) {
      LLog.info(TAG, '自愈流程进行中，跳过重复启动');
      return;
    }

    this.selfHealing = true;
    try {
      for (let i = 0; i < SELF_HEAL_BACKOFF_MS.length; i++) {
        await sleep(SELF_HEAL_BACKOFF_MS[i]);
        if (!WireGuard.isRunning()) {
          LLog.info(TAG, `VPN已停止，终止自愈(第${i + 1}次尝试前)`);
          return;
        }
        try {
          await this.startLongTask(currentContext);
          LLog.info(TAG, `自愈成功：已重新申请长时任务 taskId=${getLongTaskState().continuousTaskId}`);
          return;
        } catch (error) {
          LLog.error(TAG, `自愈重试${i + 1}失败: ${(error as Error).message}`);
        }
      }
      LLog.error(TAG, `自愈失败：连续${SELF_HEAL_BACKOFF_MS.length}次重新申请长时任务均未成功`);
    } finally {
      this.selfHealing = false;
    }
  }

  /**
   * 长时任务真实状态体检（API 20+，需 ohos.permission.KEEP_BACKGROUND_RUNNING）
   *
   * isRunning() 读的是 AppStorageV2 缓存，若系统取消了任务而取消回调未送达（或送达较晚），
   * 缓存会失真。本方法向系统查询本应用真实的长时任务列表并回写缓存；
   * 查询失败（权限/系统异常）时退化为缓存判断，不抛异常、不影响主流程。
   *
   * @param currentContext UIAbilityContext
   * @returns 系统侧是否仍有本应用的长时任务
   */
  async refreshRunningState(currentContext: common.UIAbilityContext): Promise<boolean> {
    const state = getLongTaskState();
    try {
      const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
        await backgroundTaskManager.getAllContinuousTasks(currentContext);
      if (tasks.length === 0) {
        if (state.continuousTaskId != undefined) {
          LLog.warn(TAG, `体检：系统侧已无长时任务，清理缓存 taskId=${state.continuousTaskId}`);
        }
        this.resetState();
        return false;
      }
      const matched: backgroundTaskManager.ContinuousTaskInfo | undefined = tasks.find(
        (task: backgroundTaskManager.ContinuousTaskInfo) => task.continuousTaskId === state.continuousTaskId);
      const task: backgroundTaskManager.ContinuousTaskInfo = matched != undefined ? matched : tasks[0];
      if (state.continuousTaskId != task.continuousTaskId) {
        LLog.warn(TAG, `体检：回写长时任务状态 taskId=${task.continuousTaskId}, notificationId=${task.notificationId}`);
      }
      state.continuousTaskId = task.continuousTaskId;
      state.notificationId = task.notificationId;
      if (state.startTime == undefined) {
        state.startTime = Date.now();
      }
      return true;
    } catch (error) {
      const err = error as BusinessError;
      LLog.warn(TAG, `体检失败，退化为缓存状态: code=${err.code}, message=${err.message}`);
      return this.isRunning();
    }
  }

  /**
   * 构建通知内容文本行
   * 基于当前vpnData中的连接IP、流量统计、握手时间生成多行文本
   *
   * @returns 多行文本数组，每行对应一个Peer的状态信息
   */
  private buildNotificationLines(): string[] {
    const lines: string[] = [];
    const state = getLongTaskState();

    if (this.vpnData.serviceStopped) {
      if (this.vpnData.configName) {
        lines.push(`配置: ${this.vpnData.configName}`);
      }
      lines.push('VPN服务已停止');
      if (state.startTime != undefined) {
        lines.push(`运行时长: ${formatDuration(state.startTime)}`);
      }
      lines.push('VEA进程保持存活，可快速切换配置');
      return lines;
    }

    // 配置名
    if (this.vpnData.configName) {
      lines.push(`${this.vpnData.configName}`);
    }

    if (state.startTime != undefined) {
      lines.push(`运行时长: ${formatDuration(state.startTime)}`);
    }

    // 按peerIndex排序，确保通知中Peer顺序稳定
    const peerIndices: number[] = Array.from(this.vpnData.latestLogs.keys()).sort((a, b) => a - b);

    if (peerIndices.length === 0 && Object.keys(this.vpnData.connectedIps).length > 0) {
      for (const index of Object.keys(this.vpnData.connectedIps)) {
        const peerIndex = Number(index);
        const ip = this.vpnData.connectedIps[peerIndex];
        const endpoint = this.vpnData.targetEndpoints[peerIndex];
        const label = endpoint ? `→${endpoint}` : '';
        lines.push(`Peer[${peerIndex}]: ${ip}${label}`);
      }
    }

    for (const peerIndex of peerIndices) {
      const log = this.vpnData.latestLogs.get(peerIndex);
      if (!log) {
        continue;
      }
      const ip = this.vpnData.connectedIps[peerIndex] ?? '未知';
      const rx = formatTraffic(log.sc.receiveTotal);
      const tx = formatTraffic(log.sc.sendTotal);

      const handshakeTs = this.vpnData.lastHandshakeTime.get(peerIndex);
      const handshakeStr = handshakeTs != undefined ? formatTime(handshakeTs) : '无';

      const endpoint = this.vpnData.targetEndpoints[peerIndex];
      const label = endpoint ? `→${endpoint}` : '';
      // lines.push(`Peer[${peerIndex}]: ${ip}${label} ↓${rx} ↑${tx} 握手:${handshakeStr}`);
      lines.push(`Peer[${peerIndex}]: ↓${rx} ↑${tx} 握手:${handshakeStr}`);
    }

    // 无数据时的占位提示
    if (lines.length <= 2 && state.startTime != undefined) {
      lines.push('等待连接数据...');
    }

   return lines;
   }

   /**
   * 发布/更新自定义通知内容
   * 使用notificationManager.publish发布多行文本通知，
   * 展示VPN连接状态、流量统计、握手时间等信息。
   *
   * 通知ID使用长时任务返回的notificationId，与后台任务通知关联。
   * 如果长时任务未启动或通知未授权则跳过。
   */
  publishNotification(): void {
    const state = getLongTaskState();
    if (state.notificationId == undefined) {
      return;
    }

    try {
      const lines: string[] = this.buildNotificationLines();

      const request: notificationManager.NotificationRequest = {
        id: state.notificationId,
        isOngoing:true,
        // 标记为不可清除：息屏/被上层清理会直接取消长时任务（reason=1），进而导致VPN后台掉线
        // TODO(待真机确认): 应用侧用长时任务的 notificationId 覆盖系统通知，是否会把系统通知降级为可清除；
        //  若确认降级，则改用 backgroundTaskManager.updateBackgroundRunning()，或改用独立通知id（见交接单 §3.3.3）
        isUnremovable:true,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_MULTILINE,
          multiLine: {
            title: this.vpnData.configName ? `${this.vpnData.configName} - VPN运行中` : 'WireGuard VPN 运行中',
            text: lines.length > 0 ? lines[0] : 'VPN运行中',
            briefText:  'VPN运行中',
            longTitle:  'WireGuard VPN',
            lines: lines,
          }
        },
      };

      notificationManager.publish(request, (err: BusinessError) => {
        if (err) {
          // 1600004 = 通知未授权，静默跳过（不弹权限请求，避免打断用户）
          if (err.code === 1600004) {
            LLog.warn(TAG, '通知未授权，跳过通知发布');
          } else {
            LLog.error(TAG, `发布VPN通知失败: code=${err.code}, message=${err.message}`);
          }
        }
      });
    } catch (e) {
      LLog.error(TAG, `发布VPN通知异常: ${e}`);
    }
  }

  /**
   * 更新VPN通知数据并刷新通知
   *
   * 在VPN状态变化（connectedIps变更）或流日志到达时调用。
   * 更新本地缓存的数据后自动刷新通知内容。
   *
   * @param data VPN通知数据（部分字段可选，只更新提供的字段）
   */
  updateVpnData(data: Partial<VpnNotificationData>): void {
    if (data.connectedIps != undefined) {
      this.vpnData.connectedIps = data.connectedIps;
    }
    if (data.configName != undefined) {
      this.vpnData.configName = data.configName;
    }
    if (data.targetEndpoints != undefined) {
      this.vpnData.targetEndpoints = data.targetEndpoints;
    }
    if (getLongTaskState().continuousTaskId != undefined) {
      this.updater.update();
    }
  }

  /**
   * 更新流日志数据并刷新通知
   *
   * @param log VPN流日志消息（包含流量统计和握手时间）
   */
  updateStreamLog(log: StreamLogMessage): void {
    this.vpnData.latestLogs.set(log.peerIndex, log);
    if (log.messageType === MessageType.HANDSHAKE_INITIATION ||
      log.messageType === MessageType.HANDSHAKE_RESPONSE) {
      this.vpnData.lastHandshakeTime.set(log.peerIndex, log.timestamp);
    }
    if (getLongTaskState().continuousTaskId != undefined) {
      this.updater.update();
    }
  }

  setServiceStopped(stopped: boolean): void {
    this.vpnData.serviceStopped = stopped;
  }

  clearVpnData(): void {
    this.vpnData = new VpnNotificationData();
  }


  // 停止长时任务
  stopLongTask(currentContext: common.UIAbilityContext): void {
    const state = getLongTaskState();
    if (state.continuousTaskId == undefined) {
      LLog.info(TAG, '后台长时任务未启动');
      return;
    }

    this.updater.stop();

    // 清除VPN通知数据
    this.clearVpnData();

    // 主动取消通知，防止残留多个通知窗口
    this.removeNotification();

    if (state.continuousTaskId != undefined) {
      // 使用新API签名：stopBackgroundRunning(context, continuousTaskId)
      backgroundTaskManager.stopBackgroundRunning(currentContext, state.continuousTaskId).then(() => {
        this.resetState();
        LLog.info(TAG, 'stopBackgroundRunning成功');
        LLog.info(TAG, "取消后台长时任务：成功")
      }).catch((error: BusinessError) => {
        if (error.code == 9800005) {
          LLog.info(TAG, "取消后台长时任务：后台任务并未运行")
          this.resetState();
          return
        }
        LLog.error(TAG, `stopBackgroundRunning失败. code: ${error.code}, message: ${error.message}`);
      });
    } else {
      // 降级：使用旧API（continuousTaskId为空时走此分支）
      backgroundTaskManager.stopBackgroundRunning(currentContext).then(() => {
        this.resetState();
        LLog.info(TAG, 'stopBackgroundRunning成功');
        LLog.info(TAG, "取消后台长时任务：成功")
      }).catch((error: BusinessError) => {
        if (error.code == 9800005) {
          LLog.info(TAG, "取消后台长时任务：后台任务并未运行")
          this.resetState();
          return
        }
        LLog.error(TAG, `stopBackgroundRunning失败. code: ${error.code}, message: ${error.message}`);
      });
    }
  }
}

export const longTaskModel: LongTaskModel = new LongTaskModel();
