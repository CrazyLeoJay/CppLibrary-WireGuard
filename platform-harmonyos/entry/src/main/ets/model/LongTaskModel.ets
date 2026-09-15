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
import { AppStorageV2, UIUtils, display } from '@kit.ArkUI';
import { LLog, StreamLogMessage, MessageType, WireGuard } from 'wg_tunnel';
import { NotificationUpdater } from './NotificationUpdater';

const TAG: string = 'VpnKeepAlive';
/** 活跃模式通知刷新间隔：3秒（屏幕亮/前台） */
const ACTIVE_NOTIFY_INTERVAL_MS: number = 3 * 1000;
/** 熄屏休眠模式通知刷新间隔：4分钟。
* 零流量期流量数字/握手秒数无信息增量，3秒发布纯属CPU/IPC浪费（深夜实测12.09mAh/h中约20%）；
* 4分钟在DATA_TRANSFER 10分钟判定窗口内仍有2~3次更新，安全余量充足。 */
const SCREEN_OFF_NOTIFY_INTERVAL_MS: number = 4 * 60 * 1000;

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
  /** VPN连接建立时刻（来自VEA startVpn广播，两端通知共用同一时间戳） */
  startTime?: number = undefined;
  /** 隧道重连中（VEA网络切换重建失败）：长时任务与通知保留，状态词提示“重连中” */
  reconnecting: boolean = false;
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
 * 计算运行时长描述
 * @param startTime 开始时间戳（毫秒）
 * @returns 可读时长字符串，如 "1时23分"
 */
function formatDuration(startTime: number): string {
  // 时钟回拨防御：NTP校时可能使startTime晚于当前时刻，负数时长显示为0
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

  constructor() {
    this.updater = new NotificationUpdater(() => {
      this.publishNotification();
    });
    // 注入动态间隔：每次节流判断实时查询屏幕状态
    // （亮屏/熄屏统一3秒——ea835fa实验实证熄屏低频不触发收回），无需事件驱动切换
    this.updater.setIntervalProvider(() => this.currentNotifyInterval());
  }

  /**
   * 当前通知刷新间隔：实时查询屏幕状态。
   * 亮屏/熄屏统一3秒（ea835fa实验实证：熄屏低频不触发收回，且进程冻结期
   * 定时器停摆，低频无意义）。主进程被冻结期间定时器停摆，
   * 解冻后下一次节流判断自动按当前屏幕状态恢复节奏。
   */
  private currentNotifyInterval(): number {
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

  /**
   * 全量清扫历史残留通知（以通知栏实际状态为准，不依赖内存记录）
   *
   * 【为什么需要】removeNotification依赖AppStorageV2中的notificationId，存在三个漏洞：
   * 1. restartLongTask先resetState清空记录再重启，旧通知id无从取消；
   * 2. 进程重启（装新包/被杀）后内存状态归零，通知栏旧通知仍在；
   * 3. 系统静默收回长时任务时，通知删除存在竞态。
   * 通知id由系统每次startBackgroundRunning重新分配（递增），上述任一漏洞
   * 都会让旧id通知无人认领，堆积成“只有最新一条在刷新”的历史通知。
   *
   * 保留当前活跃通知（keepId，cancel它会导致长时任务被系统停止），其余全部移除。
   */
  cleanupStaleNotifications(): void {
    const keepId = getLongTaskState().notificationId;
    notificationManager.getActiveNotifications().then((requests: Array<notificationManager.NotificationRequest>) => {
      for (const req of requests) {
        if (req.id === keepId) {
          continue;
        }
        let cancelCall: Promise<void>;
        if (req.label != undefined) {
          cancelCall = notificationManager.cancel(req.id, req.label);
        } else {
          cancelCall = notificationManager.cancel(req.id);
        }
        cancelCall.then(() => {
          LLog.info(TAG, `已清扫历史通知: id=${req.id}`);
        }).catch((err: BusinessError) => {
          if (err.code !== 1600004) {
            LLog.warn(TAG, `清扫历史通知失败: id=${req.id}, code=${err.code}`);
          }
        });
      }
    }).catch((err: BusinessError) => {
      LLog.warn(TAG, `获取活跃通知列表失败: code=${err.code}`);
    });
  }

  /**
   * 将当前通知id广播给VEA进程
   *
   * VEA收到后用同一id接管通知内容发布：主进程死亡（长时任务随之回收）时，
   * VEA可无缝重建同id通知并持续刷新流量数据。
   * 调用时机：startLongTask成功后 + VEA重建广播（ON_CREATE）时补发。
   */
  publishNotificationIdToVea(): void {
    const notifyId = getLongTaskState().notificationId;
    if (notifyId == undefined) {
      return;
    }
    WireGuard.event.publishVpnNotificationId(notifyId);
  }

  // 启动长时任务
  /**
   * 进行中的启动Promise：startLongTask的互斥闸门。
   * continuousTaskId在await createTaskRequest/startBackgroundRunning窗口内尚未赋值，
   * 仅靠id检查无法防重；cancel退避定时器（2s起）与onForeground restartLongTask
   * 并发时会产生双启动（后完成者覆盖id，先完成者被系统停掉引发cancel回调误清新id）。
   */
  private startInFlight?: Promise<void>;

  /**
   * @throws
   */
  async startLongTask(currentContext: common.UIAbilityContext): Promise<void> {
    if (this.startInFlight) {
      LLog.info(TAG, '长时任务启动进行中，复用同一Promise');
      return this.startInFlight;
    }
    this.startInFlight = this.doStartLongTask(currentContext)
      .finally(() => {
        this.startInFlight = undefined;
      });
    return this.startInFlight;
  }

  private async doStartLongTask(currentContext: common.UIAbilityContext): Promise<void> {
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
      // 运行时长数据源：不再自设startTime（重挂时重置会导致两端通知的
      // 运行时长在0分/2分钟间交替跳变），统一采用VEA startVpn广播携带的
      // 连接建立时刻（vpnData.startTime），与VEA严格同源零误差

      // 校验continuousTaskId：官方API声明为可选类型，不保证一定有值
      // 若为空则无法使用新API的update/stop，需依赖旧API降级
      if (state.continuousTaskId == undefined) {
        LLog.warn(TAG, 'startBackgroundRunning成功但continuousTaskId为空，将使用旧API降级处理');
      }

      LLog.info(TAG, `startBackgroundRunning成功, taskId=${state.continuousTaskId}, notificationId=${state.notificationId}`);

      this.publishNotification();
      this.updater.start();
      // 启动成功后全量清扫历史残留通知（当前托管通知id已确定，其余皆可安全移除）
      this.cleanupStaleNotifications();
      // 通知id下发给VEA：VEA用同一id接管通知内容发布，
      // 主进程死亡（长时任务随之回收）后VEA可无缝重建同id通知并持续刷新
      this.publishNotificationIdToVea();
    } catch (error) {
      const err = error as BusinessError;
      LLog.error(TAG, `startBackgroundRunning失败. code: ${err.code}, message: ${err.message}`);
      throw new Error(`startBackgroundRunning failed: ${err.code} - ${err.message}`);
    }
  }

  /** VEA重连状态同步（机制Y修复）：重连失败保留长时任务与通知，状态词提示“重连中” */
  setReconnecting(reconnecting: boolean): void {
    if (this.vpnData.reconnecting === reconnecting) { return; }
    this.vpnData.reconnecting = reconnecting;
    this.updater.update();
  }

  /**
   * 实况窗卡片标题（主行）：配置名 · 运行时长（紧凑）。
   * 握手移至副行（F23锁屏主/副位渲染规律的当前取舍）。
   * 停止态：配置名 已停止；重连中：配置名 重连中。
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
   * 实况窗卡片副标题（副行）：⇄握手距今秒数 · ↓↑合计流量。
   * 停止态：运行时长（与主行一致，无图标）；重连中：保留最后数据。
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
    // 正常握手周期约两分钟；链路静默（对端失联/无keepalive）时秒数如实增长
    // 时钟回拨防御：NTP校时使lastHandshakeTime晚于当前时刻时秒数显示为0
    const handshakeText = latestHandshake > 0
      ? `⇄${Math.max(0, Math.floor((Date.now() - latestHandshake) / 1000))}秒`
      : '⇄--';
    let rxTotal = 0;
    let txTotal = 0;
    this.vpnData.latestLogs.forEach((log: StreamLogMessage) => {
      rxTotal += log.sc.receiveTotal;
      txTotal += log.sc.sendTotal;
    });
    return `${handshakeText} · ↓${formatTraffic(rxTotal)} ↑${formatTraffic(txTotal)}`;
  }

   /**
   * 发布/更新自定义通知内容
   *
   * 真机实证（21:14→21:24 任务被收回）：DATA_TRANSFER 的 10 分钟进度计时器
   * 只认可实况窗类型（SYSTEM_LIVE_VIEW）的同 id 更新；MULTILINE 通知即使
   * 携带 downloadTemplate 也不被计入进度，超时后系统先收回通知再按用户删除
   * 路径取消任务（回调 reason=1，LiveDataVm onRemove 实证）。
   *
   * 任务申请时已带 SUBMODE_LIVE_VIEW_NOTIFICATION 子模式，系统代理已创建
   * 实况窗通知（id=startBackgroundRunning 返回的 notificationId）；
   * 此处发布同 id 的 SYSTEM_LIVE_VIEW 内容即规范的进度更新通道
   * （SDK: "After a system agent creates a system live view notification,
   * a third-party application can publish a notification with the same ID
   * to update the specified content"）。
   *
   * 如果长时任务未启动或通知未授权则跳过。
   */
  publishNotification(): void {
    const state = getLongTaskState();
    if (state.notificationId == undefined) {
      return;
    }

    try {
      const request: notificationManager.NotificationRequest = {
        id: state.notificationId,
        isOngoing:true,
        isUnremovable:false,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
          systemLiveView: {
            // typeCode=0：通用服务类型标识（系统实况窗内容必填字段）
            typeCode: 0,
            title: this.buildCardTitle(),
            text: this.buildCardSubtitle(),
            // capsule（锁屏顶部胶囊）按用户要求移除：胶囊会占据锁屏状态栏
            // 位置显示实况窗提醒，观感干扰；代价是锁屏卡片主文本位回落为
            // text行（配置名/握手仅在通知中心展开态可见）
            // 状态小字：重连中优先（机制Y修复的语义提示），停止态辨识度更高
            additionalText: this.vpnData.reconnecting ? '重连中'
              : (this.vpnData.serviceStopped ? '已停止' : '运行中'),
            // progress环按用户要求移除：实测无环+接口对时通知大半时间存活
            // （10分钟判定并非必现，环并非必要条件——机制X双维度分析），
            // 不再以保活名义保留视觉干扰
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
    if (data.startTime != undefined) {
      this.vpnData.startTime = data.startTime;
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

  /**
   * 长时任务被系统取消后复位任务状态（continuousTaskCancel回调调用）
   * isRunning()归位：阻断updateVpnData守卫放行导致的updater空转发布；
   * 重试达上限停止重拉后不再1600007刷屏
   */
  markTaskCancelled(): void {
    this.updater.stop();
    this.resetState();
  }

  /**
   * 强制重启长时任务（onForeground时调用）
   *
   * 【背景】真机实证：系统可能在不触发continuousTaskCancel回调的情况下
   * 静默收回长时任务（关联通知随之消失），且收回发生在主进程冻结期间时
   * 回调被丢弃、解冻后也无积压补发；此时AppStorageV2中的continuousTaskId
   * 仍为旧值，isRunning()误报“运行中”，常规重拉被跳过。
   *
   * 此方法先尝试停掉可能已失效的旧任务（系统已收回时返回9800005，忽略），
   * 复位状态后重新申请——把“用户点开应用”变成通知与长时任务的可靠恢复点。
   */
  async restartLongTask(currentContext: common.UIAbilityContext): Promise<void> {
    const state = getLongTaskState();
    if (state.continuousTaskId != undefined) {
      this.updater.stop();
      try {
        await backgroundTaskManager.stopBackgroundRunning(currentContext, state.continuousTaskId);
        LLog.info(TAG, `强制停止旧长时任务: taskId=${state.continuousTaskId}`);
      } catch (err) {
        const e = err as BusinessError;
        if (e.code === 9800005) {
          LLog.info(TAG, '旧长时任务已被系统收回（并未运行），直接重新申请');
        } else {
          LLog.warn(TAG, `停止旧长时任务失败: code=${e.code}，继续尝试重新申请`);
        }
      }
      this.resetState();
    }
    await this.startLongTask(currentContext);
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
