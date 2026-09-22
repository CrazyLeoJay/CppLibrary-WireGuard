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

/**
 * V2 VPN状态变化广播助手
 *
 * 职责单一：把VEA进程的VPN状态（启动/停止/异常/查询回复）封装为标准广播，
 * 发给主进程。主进程状态机（VpnKeepAliveManager）据此驱动开关意图与保活。
 *
 * 与V1 VPNChangeHelper的区别：
 * - 新增 serviceStopped()：VPN服务停止但VEA进程存活（vpnThreadRunning=true）
 * - startVpnThrow 不再自动关闭VEA（V2模式下VEA可能继续服务）
 *
 * @author leojay`fu
 */
import { WireGuard } from '../model/WGHelper';
import { WGDeviceConfig } from '../model/entity/WGConfigEntity';
import { WGEventThrowParam } from '../error/WGEventThrow';
import VPNEventStatusParams, { VpnEventTag } from '../model/entity/VPNEventStatusParams';

export class VPNChangeHelperV2 {
  private static cachedConnectedIps?: Record<number, string>;

  /** VEA进程已启动（通知主进程订阅CONFIG_QUERY并回复配置） */
  static onCreate(): void {
    WireGuard.event.publishVpnChange({ isOpen: false, tag: VpnEventTag.ON_CREATE, vpnThreadRunning: true });
  }

  static startVpn(id: number, config?: WGDeviceConfig): void {
    WireGuard.config.status.vpnStartRun(id);
    const params: VPNEventStatusParams = { isOpen: true, tag: VpnEventTag.START_VPN, vpnThreadRunning: true };
    if (config) {
      const connectedIps: Record<number, string> = {};
      config.peers.forEach((peer, index) => {
        connectedIps[index] = peer.endpoint.address.ip;
      });
      params.connectedIps = connectedIps;
      VPNChangeHelperV2.cachedConnectedIps = connectedIps;
    }
    WireGuard.event.publishVpnChange(params);
  }

  static stopVpn(): void {
    WireGuard.config.status.vpnStop();
    const params: VPNEventStatusParams = {
      isOpen: false,
      tag: VpnEventTag.STOP_VPN,
      vpnThreadRunning: false,
      connectedIps: VPNChangeHelperV2.cachedConnectedIps,
    };
    WireGuard.event.publishVpnChange(params);
  }

  /**
   * VPN服务停止但VEA进程存活
   * 主进程收到后应保持长时任务运行，仅更新通知内容
   */
  static serviceStopped(): void {
    const params: VPNEventStatusParams = {
      isOpen: false,
      tag: VpnEventTag.VPN_SERVICE_STOPPED,
      vpnThreadRunning: true,
      connectedIps: VPNChangeHelperV2.cachedConnectedIps,
    };
    WireGuard.event.publishVpnChange(params);
  }

  static startVpnThrow(msg?: WGEventThrowParam): void {
    WireGuard.config.status.vpnStopThrow();
    WireGuard.event.publishVpnThrow(msg);
    WireGuard.event.publishVpnChange({
      isOpen: false,
      tag: VpnEventTag.THROW,
      vpnThreadRunning: false,
      connectedIps: VPNChangeHelperV2.cachedConnectedIps,
    });
  }

  static queryStatus(config?: WGDeviceConfig): void {
    const isOpen = WireGuard.config.status.getConfig().isOpen();
    const params: VPNEventStatusParams = { isOpen: isOpen, tag: VpnEventTag.QUERY_STATUS, vpnThreadRunning: true };
    if (config) {
      const connectedIps: Record<number, string> = {};
      config.peers.forEach((peer, index) => {
        connectedIps[index] = peer.endpoint.address.ip;
      });
      params.connectedIps = connectedIps;
      VPNChangeHelperV2.cachedConnectedIps = connectedIps;
    } else if (VPNChangeHelperV2.cachedConnectedIps) {
      params.connectedIps = VPNChangeHelperV2.cachedConnectedIps;
    }
    WireGuard.event.publishVpnChange(params);
  }
}
