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
import { appManager, common } from '@kit.AbilityKit';
import { LLog } from '../tools/LLog';

/**
 * WG 工具包
 *
 * Created on 2026/7/11.
 * @author leojay`fu
 */

const TAG = "WG工具"

class WGToolsImpl {
  // 判断 VpnExtensionAbility 是否正在运行
  // 返回 true 表示正在运行，false 表示未运行
  async isVpnExtensionRunning(): Promise<boolean> {
    try {
      // 获取当前应用所有运行进程的信息
      const processInfos: appManager.ProcessInformation[] = await appManager.getRunningProcessInformation();

      // 遍历进程列表，查找进程名以 :vpn 结尾的进程
      for (const info of processInfos) {
        LLog.debug(TAG, '进程名: %{public}s, PID: %{public}d', info.processName, info.pid);
        if (info.processName.endsWith(':vpn')) {
          LLog.debug(TAG, 'VPN 进程正在运行, 进程名: %{public}s', info.processName);
          return true;
        }
      }
      LLog.debug(TAG, 'VPN 进程未运行');
      return false;
    } catch (err) {
      const error = err as BusinessError;
      LLog.error(TAG, '获取进程信息失败: %{public}s', JSON.stringify(error));
      return false;
    }
  }

  // 在 UIAbility 或页面中通过 context 获取
  async checkVpnByContext(context: common.UIAbilityContext): Promise<boolean> {
  try {
    const processInfos =
      await context.getApplicationContext().getRunningProcessInformation();

    return processInfos.some((info: appManager.ProcessInformation) =>
    info.processName.endsWith(':vpn')
    );
  } catch (err) {
    LLog.error('VpnCheck', '检查失败: %{public}s', JSON.stringify(err));
    return false;
  }
}
}

const WGTools = new WGToolsImpl();

export default WGTools