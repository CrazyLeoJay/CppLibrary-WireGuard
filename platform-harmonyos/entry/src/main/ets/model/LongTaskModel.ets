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
import { LLog, StreamLogMessage, MessageType } from 'wg_tunnel';

const TAG: string = 'VpnKeepAlive';

// 8分钟间隔更新通知进度，留2分钟缓冲避免超过10分钟限制
const PROGRESS_UPDATE_INTERVAL_MS: number = 8 * 60 * 1000;

/**
 * VPN通知内容数据 - 纯数据类，用于构建通知文本
 *
 * 在主应用进程中维护，由VPN状态变化和流日志事件更新。
 * VPN连接的IP地址来自VPNEventStatusParams.connectedIps（跨进程广播），
 * 流量统计和握手时间来自StreamLogMessage（跨进程广播）。
 */
export class VpnNotificationData {
  /** peerIndex -> 实际连接的IP地址（域名端点DNS解析后的IP） */
  connectedIps: Record<number, string> = {};
  /** peerIndex -> 最新流日志（包含累计流量数据） */
  latestLogs: Map<number, StreamLogMessage> = new Map();
  /** peerIndex -> 最后握手时间（来自握手类型的StreamLogMessage.timestamp） */
  lastHandshakeTime: Map<number, number> = new Map();
  /** VPN配置名称（可选，用于通知标题区分） */
  configName?: string = undefined;
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
  // 进度更新定时器
  private progressTimer?: number;
  // VPN通知数据（运行时缓存，非持久化）
  private vpnData: VpnNotificationData = new VpnNotificationData();

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

      // 发布初始通知内容
      this.publishNotification();

      // 启动进度更新定时器（通过通知内容更新满足DATA_TRANSFER的进度更新要求）
      this.startProgressTimer();
    } catch (error) {
      const err = error as BusinessError;
      LLog.error(TAG, `startBackgroundRunning失败. code: ${err.code}, message: ${err.message}`);
      throw new Error(`startBackgroundRunning failed: ${err.code} - ${err.message}`);
    }
  }

  /**
   * 启动进度更新定时器
   * DATA_TRANSFER 模式不支持 updateBackgroundRunning，通过 notificationManager.publish 更新通知内容
   * 来满足10分钟内必须有进度更新的要求
   */
  private startProgressTimer(): void {
    this.stopProgressTimer();
    this.progressTimer = setInterval(() => {
      const state = getLongTaskState();
      if (state.continuousTaskId != undefined) {
        this.publishNotification();
        LLog.info(TAG, "定时器触发：更新通知内容");
      }
    }, PROGRESS_UPDATE_INTERVAL_MS);
    LLog.info(TAG, `进度更新定时器已启动, 间隔=${PROGRESS_UPDATE_INTERVAL_MS / 1000}秒`);
  }

  /**
   * 停止进度更新定时器
   */
  private stopProgressTimer(): void {
    if (this.progressTimer != undefined) {
      clearInterval(this.progressTimer);
      this.progressTimer = undefined;
      LLog.info(TAG, "进度更新定时器已停止");
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

    // 运行时长
    if (state.startTime != undefined) {
      lines.push(`运行时长: ${formatDuration(state.startTime)}`);
    }

    // 按peerIndex排序，确保通知中Peer顺序稳定
    const peerIndices: number[] = Array.from(this.vpnData.latestLogs.keys()).sort((a, b) => a - b);

    if (peerIndices.length === 0 && Object.keys(this.vpnData.connectedIps).length > 0) {
      // 有连接IP但暂无流量数据
      for (const index of Object.keys(this.vpnData.connectedIps)) {
        const peerIndex = Number(index);
        const ip = this.vpnData.connectedIps[peerIndex];
        lines.push(`Peer[${peerIndex}]: ${ip}`);
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

      lines.push(`Peer[${peerIndex}]: ${ip} ↓${rx} ↑${tx} 握手:${handshakeStr}`);
    }

    // 无数据时的占位提示
    if (lines.length === 1 && state.startTime != undefined) {
      // 只有运行时长一行，说明VPN刚启动还没有数据
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
        isUnremovable:false,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_MULTILINE,
          multiLine: {
            title: 'WireGuard VPN 运行中',
            text: lines.length > 0 ? lines[0] : 'VPN运行中',
            briefText: 'VPN运行中',
            longTitle: 'WireGuard VPN',
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
    // 仅在长时任务运行中时更新通知
    const state = getLongTaskState();
    if (state.continuousTaskId != undefined) {
      this.publishNotification();
    }
  }

  /**
   * 更新流日志数据并刷新通知
   *
   * @param log VPN流日志消息（包含流量统计和握手时间）
   */
  updateStreamLog(log: StreamLogMessage): void {
    // 更新该Peer的最新流量数据
    this.vpnData.latestLogs.set(log.peerIndex, log);

    // 如果是握手消息，记录握手时间
    if (log.messageType === MessageType.HANDSHAKE_INITIATION ||
      log.messageType === MessageType.HANDSHAKE_RESPONSE) {
      this.vpnData.lastHandshakeTime.set(log.peerIndex, log.timestamp);
    }

    // 仅在长时任务运行中时更新通知
    const state = getLongTaskState();
    if (state.continuousTaskId != undefined) {
      this.publishNotification();
    }
  }

  /**
   * 清除VPN通知数据
   * 在VPN停止时调用，清空缓存数据
   */
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

    // 先清除定时器
    this.stopProgressTimer();

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
