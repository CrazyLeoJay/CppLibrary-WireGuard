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
import { PersistenceV2, UIUtils } from '@ohos.arkui.StateManagement';

/**
 * WireGuard 状态记录
 *
 * Created on 2026/7/10.
 * @author leojay`fu
 */

class WGStatusImpl {
  config = new StatusConfig();

  /**
   * @returns 获取状态配置
   */
  getConfig(): StatusConfig {
    return PersistenceV2.globalConnect<StatusConfig>({
      type: StatusConfig,
      // 定义默认构造器，返回时需要调用makeObserved，才能实现自动持久化
      defaultCreator: () => UIUtils.makeObserved(new StatusConfig())
    })!;
  }

  /**
   * 暂存变量，表示正在运行服务
   * @param configId 如果不传入，表示置空
   */
  setRunningServer(configId?: number) {
    this.getConfig().runningConfigId = configId;
  }

  /**
   * vpn开始运行
   * @param configId
   */
  vpnStartRun(configId: number){
    this.getConfig().running = true
    this.getConfig().runningConfigId = configId;
  }


  /**
   * vpn 正常停止运行
   */
  vpnStop() {
    this.getConfig().runningConfigId = undefined;
    this.getConfig().running = false;
  }

  /**
   * vpn 正常停止运行
   */
  vpnStopThrow() {
    this.getConfig().running = false;
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