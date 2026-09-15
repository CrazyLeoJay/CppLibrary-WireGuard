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
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { LLog } from '../tools/LLog';
import { MessageType, StreamLogMessage } from '../../../../Index';

const TAG: string = 'VeaNotify';

/** 活跃模式通知刷新间隔：3秒（屏幕亮） */
const ACTIVE_NOTIFY_INTERVAL_MS: number = 3 * 1000;
/** 熄屏休眠模式通知刷新间隔：4分钟。
* 零流量期流量数字/握手秒数无信息增量，3秒发布纯属CPU/IPC浪费；
* 4分钟在DATA_TRANSFER 10分钟判定窗口内仍有2~3次更新，安全余量充足。 */
const SCREEN_OFF_NOTIFY_INTERVAL_MS: number = 4 * 60 * 1000;

/**
 * 流量字节数转可读字符串（与主进程 LongTaskModel.formatTraffic 保持一致）
 * @param bits 字节数
 * @returns 格式化字符串，如 "1.23 MB"
 */
function formatTraffic(bits: number): string {
  if (bits < 0) {
    return '0 B';
  }
  const bytes: number = bits / 8;
  if (bytes < 1024) {
    return `${bytes.toFixed(0)}B`;
  }
  const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];
  let val: number = bytes;
  let unitIndex: number = 0;
  while (val >= 1024 && unitIndex < units.length - 1) {
    val /= 1024;
    unitIndex++;
  }
  return `${val.toFixed(2)}${units[unitIndex]}`;
}

/**
 * 计算运行时长描述（与主进程 LongTaskModel.formatDuration 保持一致）
 * @param startTime 开始时间戳（毫秒）
 */
function formatDuration(startTime: number): string {
  // 时钟回拨防御：NTP校时可能使startTime晚于当前时刻，负数时长显示为0（与主进程同款）
  const elapsed: number = Math.max(0, Date.now() - startTime);
  const totalMinutes: number = Math.floor(elapsed / (60 * 1000));
  const hours: number = Math.floor(totalMinutes / 60);
  const minutes: number = totalMinutes % 60;
  if (hours > 0) {
    return `${hours}时${minutes}分`;
  }
  return `${minutes}分`;
}

/**
 * VEA进程侧通知数据
 * 与主进程 VpnNotificationData 同源同构（entry模块不可被wg_tunnel依赖，故独立定义）
 */
class VeaNotifyData {
  connectedIps: Record<number, string> = {};
  latestLogs: Map<number, StreamLogMessage> = new Map();
  lastHandshakeTime: Map<number, number> = new Map();
  configName?: string = undefined;
  targetEndpoints: Record<number, string> = {};
  serviceStopped: boolean = false;
  startTime?: number = undefined;
  /** 隧道重连中（网络切换重建失败）：长时任务与通知保留，状态词提示“重连中” */
  reconnecting: boolean = false;
}

/**
 * VEA进程侧通知发布器 —— 通知内容的平行写者（主进程死亡后的接管者）
 *
 * 【为什么需要VEA发布通知】
 * 主进程熄屏即被系统冻结，死亡后连长时任务一起回收，通知刷新随之中断。
 * 而VEA进程：1) 冻结豁免（真机实测锁屏期间持续运行）；
 * 2) 存活由系统VPN服务托管，不依赖主进程的长时任务；
 * 3) 通知数据的源头（流量统计/握手事件/连接IP）就在VEA。
 * 因此VEA用与托管通知相同的id发布内容：
 * - 主进程活着：两进程以同一数据源交替改写同一条通知（内容一致，幂等）
 * - 主进程死亡：托管通知被系统删除，VEA下一次发布以普通常驻通知形态
 *   重建同id通知，流量数据持续刷新（用户无感知）
 *
 * 【id来源】主进程startBackgroundRunning成功后通过VPN_NOTIFICATION_ID
 * 广播下发（restartLongTask重建长时任务后会广播新id）；VEA收到前不发布。
 *
 * 【节流】与主进程NotificationUpdater同款deadline机制：亮屏/熄屏统一3秒
 * （ea835fa实验实证）。VEA不冻结无解冻风暴，仅防高频数据轰炸与锁屏耗电。
 */
class VeaNotificationPublisher {
  /** 通知id（主进程下发的长时任务托管通知id），为空时不发布 */
  private notificationId?: number = undefined;
  private vpnData: VeaNotifyData = new VeaNotifyData();
  /** deadline倒计时器ID（setTimeout），到期后重发旧数据并重新调度 */
  private deadlineTimer?: number;
  /** 上次实际发布时间戳（节流基准） */
  private lastPublishAt: number = 0;

  /**
   * 当前节流间隔：实时查询屏幕状态（亮屏/熄屏统一3秒）
   */
  private currentInterval(): number {
    try {
      const state = display.getDefaultDisplaySync().state;
      if (state === display.DisplayState.STATE_ON) {
        return ACTIVE_NOTIFY_INTERVAL_MS;
      }
      return SCREEN_OFF_NOTIFY_INTERVAL_MS;
    } catch (e) {
      return ACTIVE_NOTIFY_INTERVAL_MS;
    }
  }

  /**
   * 收到主进程下发的通知id，立即发布一次（此后VEA接管通知内容刷新）
   */
  setNotificationId(id: number): void {
    if (this.notificationId === id) {
      return;
    }
    const oldId = this.notificationId;
    this.notificationId = id;
    if (oldId != undefined) {
      // 切换通知id：旧id已被主进程的新长时任务清扫，立即取消，
      // 防止deadline发布器在切换窗口内用旧id“复活”已清扫的通知且无人再清理
      notificationManager.cancel(oldId).catch((err: BusinessError) => {
        // 1600004=通知不存在（已被清扫），正常静默
        if (err.code !== 1600004) {
          LLog.warn(TAG, `取消旧通知失败: id=${oldId}, code=${err.code}`);
        }
      });
    }
    LLog.info(TAG, `收到通知id: ${id}，VEA接管通知发布`);
    this.refreshNow();
  }

  /**
   * 停止发布并清空状态（用户关闭VPN/VEA销毁时调用，通知由主进程负责删除）
   */
  stop(): void {
    this.cancelDeadline();
    this.notificationId = undefined;
    this.lastPublishAt = 0;
  }

  /** VPN启动成功：记录启动时间（返回给广播，主进程通知共用同一时间戳）并复位服务停止标记 */
  markStarted(): number {
    this.vpnData.startTime = Date.now();
    this.vpnData.serviceStopped = false;
    return this.vpnData.startTime;
  }

  /** 只读访问连接建立时刻（供状态查询广播携带，冷启动恢复路径同步用） */
  getStartTime(): number | undefined {
    return this.vpnData.startTime;
  }

  /** 更新连接IP（peerIndex -> 实际连接IP） */
  updateConnectedIps(ips: Record<number, string>): void {
    this.vpnData.connectedIps = ips;
    this.update();
  }

  /** 更新配置名与目标端点（来自wgDbConf） */
  updateConfigInfo(configName: string, targetEndpoints: Record<number, string>): void {
    this.vpnData.configName = configName;
    this.vpnData.targetEndpoints = targetEndpoints;
    this.update();
  }

  /** 服务停止标记（STOP指令保留VEA进程场景） */
  setServiceStopped(stopped: boolean): void {
    this.vpnData.serviceStopped = stopped;
    this.update();
  }

  /** 隧道重连中标记（机制Y修复：重连失败保留长时任务与通知，状态词提示） */
  setReconnecting(reconnecting: boolean): void {
    if (this.vpnData.reconnecting === reconnecting) { return; }
    this.vpnData.reconnecting = reconnecting;
    this.update();
  }

  /**
   * 流日志到达：更新流量统计与握手时间（握手类型消息记录最后握手时间）
   */
  updateStreamLog(log: StreamLogMessage): void {
    this.vpnData.latestLogs.set(log.peerIndex, log);
    if (log.messageType === MessageType.HANDSHAKE_INITIATION ||
      log.messageType === MessageType.HANDSHAKE_RESPONSE) {
      this.vpnData.lastHandshakeTime.set(log.peerIndex, log.timestamp);
    }
    this.update();
  }

  // ===== deadline 节流（与主进程NotificationUpdater同款机制） =====

  private update(): void {
    this.cancelDeadline();
    this.publishIfDue();
    this.scheduleDeadline();
  }

  /** 立即强制发布一次并重置计时 */
  refreshNow(): void {
    this.cancelDeadline();
    this.lastPublishAt = Date.now();
    this.publish();
    this.scheduleDeadline();
  }

  private publishIfDue(): void {
    const now = Date.now();
    if (now - this.lastPublishAt < this.currentInterval()) {
      return;
    }
    this.lastPublishAt = now;
    this.publish();
  }

  private scheduleDeadline(): void {
    this.deadlineTimer = setTimeout(() => {
      this.deadlineTimer = undefined;
      this.publishIfDue();
      this.scheduleDeadline();
    }, this.currentInterval());
  }

  private cancelDeadline(): void {
    if (this.deadlineTimer != undefined) {
      clearTimeout(this.deadlineTimer);
      this.deadlineTimer = undefined;
    }
  }

  /**
   * 发布通知（id为空时跳过；通知未授权时静默，避免打断用户）
   */
  private publish(): void {
    const notifyId = this.notificationId;
    if (notifyId == undefined) {
      return;
    }
    try {
      const request: notificationManager.NotificationRequest = {
        id: notifyId,
        isOngoing: true,
        isUnremovable: false,
        content: {
          // 与主进程LongTaskModel同款：SYSTEM_LIVE_VIEW同id更新才是系统
          // 认可的DATA_TRANSFER进度更新（MULTILINE+模板不计入，10分钟超时实证）
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
          systemLiveView: {
            // typeCode=0：通用服务类型标识（系统实况窗内容必填字段）
            typeCode: 0,
            title: this.buildCardTitle(),
            text: this.buildCardSubtitle(),
            // capsule（锁屏顶部胶囊）按用户要求移除，与主进程同款
            // 状态小字：重连中优先（重连失败保留通知的语义提示），与主进程同款
            additionalText: this.vpnData.reconnecting ? '重连中'
              : (this.vpnData.serviceStopped ? '已停止' : '运行中'),
            // progress环按用户要求移除：实测无环+接口对时通知大半时间存活
            // （10分钟判定并非必现，环并非必要条件——见机制X双维度分析），
            // 不再以保活名义保留视觉干扰
          }
        },
      };

      notificationManager.publish(request, (err: BusinessError) => {
        if (err) {
          if (err.code === 1600007) {
            // 实况窗已被系统回收（主进程死亡/任务收回）：降级为普通通知重建同id，
            // 维持"主进程死亡后VEA接管"设计；主进程重新startBackgroundRunning后
            // 系统代理重建实况窗，后续发布自动回到实况窗更新通道
            this.publishFallbackNormal(notifyId);
            return;
          }
          // 1600004 = 通知未授权，静默跳过
          if (err.code === 1600004) {
            LLog.warn(TAG, '通知未授权，跳过通知发布');
          } else {
            LLog.error(TAG, `VEA发布通知失败: code=${err.code}, message=${err.message}`);
          }
        }
      });
    } catch (e) {
      LLog.error(TAG, `VEA发布通知异常: ${e}`);
    }
  }

  /**
   * 降级重建：以普通常驻通知形态发布同id通知
   *
   * 仅在SYSTEM_LIVE_VIEW发布返回1600007（通知不存在，即系统代理尚未创建
   * 或已随任务收回）时调用——SDK约束实况窗只能由系统代理创建、三方同id更新，
   * 因此 VEA 接管场景下用 BASIC_TEXT 维持常驻提醒，避免3秒一次的发布失败刷屏。
   */
  private publishFallbackNormal(notifyId: number): void {
    try {
      const request: notificationManager.NotificationRequest = {
        id: notifyId,
        isOngoing: true,
        isUnremovable: false,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: this.buildCardTitle(),
            text: this.buildCardSubtitle(),
            additionalText: this.vpnData.reconnecting ? '重连中'
              : (this.vpnData.serviceStopped ? '已停止' : '运行中'),
          },
        },
      };
      notificationManager.publish(request, (err: BusinessError) => {
        if (err) {
          LLog.error(TAG, `VEA降级通知发布失败: code=${err.code}, message=${err.message}`);
        }
      });
    } catch (e) {
      LLog.error(TAG, `VEA降级通知发布异常: ${e}`);
    }
  }

  /**
   * 实况窗卡片标题（主行）：配置名 · 运行时长（紧凑，与主进程同款）。
   * 停止态：配置名 已停止。
   */
  private buildCardTitle(): string {
    // 配置名超长截断防御：避免挤占握手文案导致系统截断位置不可控
    const rawName = this.vpnData.configName ? this.vpnData.configName : 'WG-VPN';
    const configName = rawName.length > 12 ? `${rawName.slice(0, 12)}…` : rawName;
    if (this.vpnData.reconnecting) {
      return `${configName} 重连中`;
    }
    if (this.vpnData.serviceStopped) {
      return `${configName} 已停止`;
    }
    if (this.vpnData.startTime != undefined) {
      return `${configName} · 运行${formatDuration(this.vpnData.startTime)}`;
    }
    return configName;
  }

  /**
   * 实况窗卡片副标题（副行）：⇄握手距今秒数 · ↓↑合计流量（与主进程同款）。
   * 停止态：运行时长。
   */
  private buildCardSubtitle(): string {
    if (this.vpnData.serviceStopped) {
      return this.vpnData.startTime != undefined
        ? `运行${formatDuration(this.vpnData.startTime)}` : '已停止';
    }
    let latestHandshake = 0;
    this.vpnData.lastHandshakeTime.forEach((ts: number) => {
      if (ts > latestHandshake) {
        latestHandshake = ts;
      }
    });
    const handshakeText = latestHandshake > 0
      ? `⇄${Math.max(0, Math.floor((Date.now() - latestHandshake) / 1000))}秒` // 时钟回拨防御（与主进程同款）
      : '⇄--';
    let rxTotal = 0;
    let txTotal = 0;
    this.vpnData.latestLogs.forEach((log: StreamLogMessage) => {
      rxTotal += log.sc.receiveTotal;
      txTotal += log.sc.sendTotal;
    });
    return `${handshakeText} · ↓${formatTraffic(rxTotal)} ↑${formatTraffic(txTotal)}`;
  }
}

/**
 * VEA进程内单例
 */
export const veaNotificationPublisher: VeaNotificationPublisher = new VeaNotificationPublisher();
