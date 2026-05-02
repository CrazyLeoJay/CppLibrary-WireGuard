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
import { pasteboard } from '@kit.BasicServicesKit';
import WGConfigPreViewParams from '../entity/WGConfigPreViewParams';
import {
  ConnectState, LLog, Tools, VpnConnHelper, WGConfPeer, WGDBConf, WireGuard
} from 'wg_tunnel';
import { JSON } from '@kit.ArkTS';

const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
const TAG = "配置查看"

@ObservedV2
export default class WGConfigPreViewModel {
  nav: NavPathStack = new NavPathStack();
  params?: WGConfigPreViewParams
  @Trace data?: WGDBConf
  /**
   * 用于判断当前Vpn是否运行中
   * @returns 当前Vpn是否运行中
   */
  @Trace isVpnOpen: boolean = false;

  constructor() {
    const state: ConnectState = WireGuard.getRunningServer();
    this.isVpnOpen = this.params != undefined && state.runningConfigId == this.params?.id
  }

  @Computed
  get client(): WGDBConf | undefined {
    return this.data
  }

  @Computed
  get peers(): WGConfPeer[] {
    return this.data?.conf.peers ?? []
  }


  async loadData(params: WGConfigPreViewParams) {
    this.params = params;
    this.data = WireGuard.helper.config.getConfigForId(params.id)
    LLog.info(TAG, `data ${JSON.stringify(this.data)}`);
  }

  async updateData() {
    if (this.params) {
      this.loadData(this.params);
    }
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

  helper?: VpnConnHelper;

  /**
   * 改变Vpn配置，启动或停止
   */
  async changeVpnConfig(context: UIContext, isOn: boolean) {
    try {
      const id = this.params!.id;
      const config = this.data!;
      // 转化实体
      const vpnConf = await WireGuard.toVpnStartConfig(config);
      LLog.info(TAG, `创建VPN配置：${JSON.stringify(vpnConf)}`)

      WireGuard.runWGConfig(context.getHostContext()!, id, vpnConf, isOn)
        .catch((e: BusinessError) => {
          LLog.error(TAG, e);
        })
      //
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
      //   await this.helper!.startServer(vpnConf)
      //     .finally(() => {
      //       WireGuard.setRunningServer(id)
      //     })
      // }
    } catch (e) {
      this.isVpnOpen = false;
      context.getPromptAction().showToast({
        message: `VPN开启失败：${e}}`
      })
      LLog.error(TAG, {
        error: e,
        message: "开启VPN异常"
      });
    }
  }
}