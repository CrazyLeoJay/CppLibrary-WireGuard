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
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LLog } from 'wg_tunnel';

const TAG: string = 'VpnKeepAlive';
const DOMAIN: number = 0x0000;

/**
 * 后台
 *
 * Created on 2026/7/27.
 * @author leojay`fu
 */
class LongTaskModel {
  private isStart: boolean = false;

  // 启动长时任务
  /**
   * @throws
   */
  async startLongTask(currentContext: common.UIAbilityContext): Promise<void> {
    const msg = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
    const packageName = msg.name

    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          // 应用的包名
          bundleName: packageName,
          // 扩展的Ability文件名称
          // abilityName: 'WGVpnExtAbility',
          abilityName: 'EntryAbility',
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };

    try {
      if (this.isStart) {
        hilog.info(DOMAIN, TAG, 'Background Task has already started');
        return;
      }
      await wantAgent.getWantAgent(wantAgentInfo).then(async (wantAgentObj: WantAgent) => {
        backgroundTaskManager.startBackgroundRunning(
          currentContext,
          backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
          wantAgentObj
        ).then(() => {
          this.isStart = true;
          hilog.info(DOMAIN, TAG, 'startBackgroundRunning succeeded');
        }).catch((error: BusinessError) => {
          hilog.error(DOMAIN, TAG,
            `startBackgroundRunning failed. code: ${error.code}, message: ${error.message}`);
        });
      });
    } catch (error) {
      hilog.error(DOMAIN, TAG, `getWantAgent failed. error: ${JSON.stringify(error)}`);
    }
  }

  // 停止长时任务
  stopLongTask(currentContext: common.UIAbilityContext): void {
    if (!this.isStart) {
      hilog.info(DOMAIN, TAG, 'Background Task has not started');
      return;
    }
    backgroundTaskManager.stopBackgroundRunning(currentContext).then(() => {
      this.isStart = false;
      hilog.info(DOMAIN, TAG, 'stopBackgroundRunning succeeded');
      LLog.info(TAG, "取消后台长时任务：成功")
    }).catch((error: BusinessError) => {
      if (error.code == 9800005) {
        LLog.info(TAG, "取消后台长时任务：后台任务并未运行")
        return
      }
      hilog.error(DOMAIN, TAG,
        `stopBackgroundRunning failed. code: ${error.code}, message: ${error.message}`);
    });
  }
}

export const longTaskModel: LongTaskModel = new LongTaskModel();
