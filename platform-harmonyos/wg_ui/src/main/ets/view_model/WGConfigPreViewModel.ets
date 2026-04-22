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
 *
 */
import { DeviceConfig, PeerConfig, WGDeviceConfig } from 'wg_tunnel/src/main/ets/model/entity/WGClientConfig';
import { VpnConnHelper, WireGuard } from 'wg_tunnel/src/main/ets/model/WGHelper';
import Tools from 'wg_tunnel/src/main/ets/tools/tools';
import { pasteboard } from '@kit.BasicServicesKit';
import { LLog } from 'wg_tunnel/src/main/ets/tools/LLog';
import WGConfigPreViewParams from '../entity/WGConfigPreViewParams';

const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
const TAG = "配置查看"

@ObservedV2
export default class WGConfigPreViewModel {
  nav: NavPathStack = new NavPathStack();
  params?: WGConfigPreViewParams
  @Trace data?: WGDeviceConfig
  private helper?: VpnConnHelper;

  @Computed
  get client(): DeviceConfig | undefined {
    return this.data?.device
  }

  @Computed
  get peers(): PeerConfig[] {
    return this.data?.peers ?? []
  }

  /**
   * 用于判断当前Vpn是否运行中
   * @returns 当前Vpn是否运行中
   */
  get isVpnOpen() {
    return false;
  }

  async loadData(params: WGConfigPreViewParams) {
    this.data = WireGuard.helper.config.getConfigForId(params.id)

    LLog.info(TAG, `data ${JSON.stringify(this.data)}`);
  }

  async copy44KeyToSystem(context: UIContext, content: string) {
    if (!Tools.is44Key(content)) {
      return;
    }
    let pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, content);
    try {
      await systemPasteboard.setData(pasteData);
      LLog.info(TAG, "将公钥复制进入系统剪贴板")
      context.getPromptAction().showToast({
        message: "已复制",
      })
    } catch (error) {
      LLog.info(TAG, `将公钥复制进入系统剪贴板 异常！！！！：${error}`)
    }
  }

  /**
   * 改变Vpn配置，启动或停止
   */
  async changeVpnConfig(context: UIContext, isOn: boolean) {
    try {
      const id = this.params!.id;
      const config = this.data!;

      WireGuard.runWGConfig(context.getHostContext()!, id, config, isOn)
        .catch((e: BusinessError) => {
          LLog.error(TAG, e);
        })

      // if (!this.helper) {
      //   this.helper = WireGuard.makeVpnConnection(context);
      // }
      //
      // if (WireGuard.getRunningServer().runningConfigId) {
      //   LLog.info(TAG, `销毁VPN服务 ${id}`);
      //   await this.helper.stopServer().finally(() => {
      //     WireGuard.setRunningServer()
      //   })
      // }
      // if (isOn) {
      //   LLog.info(TAG, `启动VPN服务 ${id}`);
      //   await this.helper!.startServer(config)
      //     .finally(() => {
      //       WireGuard.setRunningServer(id)
      //     })
      // }
    } catch (e) {
      LLog.error(TAG, e);
    }
  }
}