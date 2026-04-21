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

import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { LLog } from '../tools/LLog';
import { WGDeviceConfig } from '../model/entity/WGClientConfig';
import { VpnConnHelper, WireGuard } from '../model/WGHelper';

const TAG = "vpn_ability"

export default class WGVpnExtAbility extends VpnExtensionAbility {
  vpnConnection?: VpnConnHelper;

  override onCreate(want: Want): void {
    super.onCreate(want);
    // this.vpnConnection = WireGuard.makeVpnConnection(this.context);
    this.vpnConnection = new VpnConnHelper(vpnExtension.createVpnConnection(this.context));

    const params = want.parameters
    if (!params) {
      LLog.error(TAG, "没有配置")
      return
    }
    LLog.info(TAG, "WG VPN onCreate")
    const id = params["id"] as number;
    const config = params["config"] as WGDeviceConfig

    this.vpnConnection!.startServer(config).then(() => {
      // 记录正在运行的服务配置id
      WireGuard.setRunningServer(id)
    })
      .catch((e: BusinessError) => {
        LLog.error(TAG, e);
      });
  }

  override onDestroy(): void {
    super.onDestroy();
    LLog.info(TAG, "WG VPN onDestroy")
    this.vpnConnection?.stopServer().then(() => {

    })
      .finally(() => {
        // 清空正在运行的服务id
        WireGuard.setRunningServer()
      })
  }
}
