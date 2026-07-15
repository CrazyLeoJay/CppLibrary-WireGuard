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
import { AppStorageV2, PersistenceV2, UIUtils } from '@ohos.arkui.StateManagement';
import { LLog } from '../../../../Index';

const TAG = "WG状态"

/**
 * WireGuard 状态记录
 *
 * Created on 2026/7/10.
 * @author leojay`fu
 */

class WGStatusImpl {

  /**
   * @returns 获取状态配置
   */
  getConfig(): StatusConfig {
    // 注意以下方法都不能跨进程使用
    return AppStorageV2.connect<StatusConfig>(StatusConfig, () => new StatusConfig())!
    return PersistenceV2.globalConnect<StatusConfig>({
      type: StatusConfig,
      // 定义默认构造器，返回时需要调用makeObserved，才能实现自动持久化
      defaultCreator: () => UIUtils.makeObserved(new StatusConfig()),
    })!;
    // return preferences.getPreferencesSync()
  }


  /**
   * vpn开始运行
   * @param configId
   */
  vpnStartRun(configId: number) {
    const config = this.getConfig()
    config.running = true
    config.runningConfigId = configId;
    LLog.info(TAG, `更新状态:${JSON.stringify(this.getConfig())}`)
  }

  /**
   * vpn 正常停止运行
   */
  vpnStop() {
    const config = this.getConfig()
    config.runningConfigId = undefined;
    config.running = false;
    LLog.info(TAG, `更新状态:${JSON.stringify(this.getConfig())}`)
  }

  /**
   * vpn 正常停止运行
   */
  vpnStopThrow() {
    this.getConfig().running = false;
    LLog.info(TAG, `更新状态:${JSON.stringify(this.getConfig())}`)
  }

  update(config:StatusConfig){
    const c =this.getConfig()
    c.runningConfigId = config.runningConfigId
    c.running = config.running
  }

  isRunning(id: number): boolean {
    const config = this.getConfig();
    return config.running && id == config.runningConfigId;
  }
}


export class StatusConfig {
  runningConfigId?: number;
  running: boolean = false;

  isOpen(): boolean {
    return this.runningConfigId != undefined && this.running == true
  }
}

const WGConfig = new WGStatusImpl();

export default WGConfig;