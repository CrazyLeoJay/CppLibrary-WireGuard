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
import { bundleManager, Want } from '@kit.AbilityKit';
import { LLog } from '../tools/LLog';
import { VpnConnHelper, WireGuard } from '../model/WGHelper';
import { WGDeviceConfig } from '../model/entity/WGConfigEntity';

const TAG = "vpn_ability"

export default class WGVpnExtAbility extends VpnExtensionAbility {
  vpnConnection?: VpnConnHelper;

  override onCreate(want: Want): void {
    super.onCreate(want);
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
      VPNChangeHelper.startVpn(id)
    })
      .catch((e: BusinessError) => {
        LLog.error(TAG, `VPN Error (${e.code}): ${e.message}`);
        LLog.error(TAG, e);
        // vpn 启动异常
        VPNChangeHelper.startVpnThrow(e.message)
      });
  }

  override onDestroy(): void {
    super.onDestroy();
    LLog.info(TAG, "WG VPN onDestroy")
    this.vpnConnection?.stopServer()
      .then(() => {
        LLog.info(TAG, "停止VPN成功")
      })
      .catch((err: BusinessError) => {
        VPNChangeHelper.stopVpn()
        LLog.error(TAG, err)
      })
      .finally(() => {
        // 清空正在运行的服务id
        VPNChangeHelper.stopVpn()
      })
  }
}

/**
 * Vpn 变化辅助工具
 * 需要先修改状态，然后通知全局VPN变化
 */
class VPNChangeHelper {
  static startVpn(id: number) {
    // 记录正在运行的服务配置id
    WireGuard.statusConfig.vpnStartRun(id)
    WireGuard.event.publishVpnChange({ isOpen: true });
  }

  /**
   * 停止vpn服务
   * @param id
   */
  static stopVpn() {
    // 记录正在运行的服务配置id
    WireGuard.statusConfig.vpnStop()
    WireGuard.event.publishVpnChange({ isOpen: false });
  }

  static startVpnThrow(msg?: string) {
    // 记录正在运行的服务配置id
    WireGuard.statusConfig.vpnStopThrow()
    WireGuard.event.publishVpnChange({ isOpen: false });
    WireGuard.event.publishVpnThrow(msg);

    // 获取自身包名
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((bundleInfo) => {
        const packageName = bundleInfo.name
        const abilityName = 'WGVpnExtAbility'
        return vpnExtension.stopVpnExtensionAbility({
          deviceId: '',
          bundleName: packageName,
          abilityName: abilityName,
        })
          .then(() => {
            LLog.info(TAG, "关闭 VPN Extension ability")
          })
          .catch((e: BusinessError) => {
            LLog.error(TAG, e)
          })
      });
  }
}