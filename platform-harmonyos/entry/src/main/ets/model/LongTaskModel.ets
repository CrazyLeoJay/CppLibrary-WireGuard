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
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppStorageV2, UIUtils } from '@kit.ArkUI';
import { LLog } from 'wg_tunnel';

const TAG: string = 'VpnKeepAlive';

// 8分钟间隔更新通知进度，留2分钟缓冲避免超过10分钟限制
const PROGRESS_UPDATE_INTERVAL_MS: number = 8 * 60 * 1000;

/**
 * 长时任务运行状态实体 - 应用内存级持久化
 *
 * 使用 AppStorageV2 + @ObservedV2 + @Trace 实现应用内存级持久化，
 * 数据在应用运行期间不会被系统回收，但退出应用后自动销毁。
 *
 * 与 PersistenceV2 的区别：
 * - AppStorageV2：仅存内存，应用退出即丢失，适合运行时临时状态
 * - PersistenceV2：写入磁盘，应用重启后仍存在，适合需要持久化的配置
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
 * 后台长时任务管理
 * 使用ContinuousTaskRequest新API签名，支持进度更新定时器保活
 *
 * Created on 2026/7/27.
 * @author leojay`fu
 */
class LongTaskModel {
  // 进度更新定时器
  private progressTimer?: number;

  /**
   * 构建ContinuousTaskRequest（公共方法）
   *
   * 统一构建长时任务所需的ContinuousTaskRequest，避免startLongTask和updateProgress中重复代码。
   * 内部包含WantAgent创建、后台模式、子模式设置，包名从context.abilityInfo.bundleName获取。
   *
   * @param context UIAbilityContext，用于提取包名并构建WantAgent
   * @returns 构建好的ContinuousTaskRequest对象
   * @throws for wantAgent.getWantAgent
   */
  private async createTaskRequest(context: common.UIAbilityContext):
    Promise<backgroundTaskManager.ContinuousTaskRequest> {
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: context.abilityInfo.bundleName,
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
      LLog.info(TAG, `后台长时任务启动成功, taskId=${state.continuousTaskId}`);

      // 仅当continuousTaskId有效时才启动进度更新定时器
      // （updateBackgroundRunning需要continuousTaskId，旧API无update方法）
      if (state.continuousTaskId != undefined) {
        this.startProgressTimer(currentContext);
      }
    } catch (error) {
      const err = error as BusinessError;
      LLog.error(TAG, `startBackgroundRunning失败. code: ${err.code}, message: ${err.message}`);
      throw new Error(`startBackgroundRunning failed: ${err.code} - ${err.message}`);
    }
  }

  /**
   * 启动进度更新定时器
   * 每8分钟调用updateBackgroundRunning更新通知进度，满足DATA_TRANSFER类型10分钟进度更新要求
   */
  private startProgressTimer(context: common.UIAbilityContext): void {
    this.stopProgressTimer();
    this.progressTimer = setInterval(() => {
      this.updateProgress(context).catch((e: BusinessError) => {
        LLog.error(TAG, `更新长时任务进度失败: ${e.code}, ${e.message}`);
      });
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
   * 更新长时任务通知进度
   * 调用updateBackgroundRunning更新通知内容（显示VPN运行状态及已运行时间）
   */
  async updateProgress(context: common.UIAbilityContext): Promise<void> {
    const state = getLongTaskState();
    if (state.continuousTaskId == undefined) {
      LLog.warn(TAG, "长时任务未启动，无法更新进度");
      return;
    }

    try {
      const request = await this.createTaskRequest(context);
      request.continuousTaskId = state.continuousTaskId;

      const notification = await backgroundTaskManager.updateBackgroundRunning(context, request);
      // 更新notificationId（可能变化）
      state.notificationId = notification.notificationId;
      LLog.info(TAG, "长时任务进度更新成功");
    } catch (error) {
      const err = error as BusinessError;
      LLog.error(TAG, `updateBackgroundRunning failed. code: ${err.code}, message: ${err.message}`);
    }
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
