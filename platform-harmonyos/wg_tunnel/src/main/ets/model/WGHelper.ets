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
import native, { KeyPair } from 'libwg_tunnel.so';
import { DatabaseHelper } from './db/wgdb';
import { Context } from '@ohos.abilityAccessCtrl';
import WGDao from './db/WGDao';
import { WGDeviceConfig } from './entity/WGClientConfig';
import { vpnExtension } from '@kit.NetworkKit';
import { AppStorageV2, UIContext } from '@kit.ArkUI';
import ConnectState from './entity/ConnectState';
import { LLog } from '../tools/LLog';
import WGAppException from '../error/WGAppException';
import { bundleManager, common } from '@kit.AbilityKit';

const TAG = "wgHelper"

/**
 * WireGuard 辅助类
 * @author leojay`fu
 */
class WGHelper {
  db = new DatabaseHelper();

  get config() {
    return new WGDao(this.db.orm)
  }
}

/**
 * @author leojay`fu
 */
export namespace WireGuard {
  /**
   * 初始化
   * @param context
   */
  export function init(context: Context) {
    helper.db.init(context);
  }

  /**
   * 销毁
   * @param context
   */
  export function destroy(context: Context) {
    // try {
    //   device.close().catch((e: BusinessError) => {
    //     LLog.info(TAG, e);
    //   })
    // } catch (err) {
    //   LLog.error(TAG, err)
    // }
  }

  export const helper = new WGHelper();

  // export const device = new native.WireGuardDevice();

  /*
  主要功能
   */
  /**
   * 创建一个 vpn链接
   * @param cxt
   * @returns
   */
  export function makeVpnConnection(cxt: vpnExtension.VpnExtensionContext | UIContext): VpnConnHelper {
    let context: vpnExtension.VpnExtensionContext
    if (cxt instanceof UIContext) {
      context = cxt.getHostContext() as common.VpnExtensionContext;
    } else {
      context = cxt;
    }
    return new VpnConnHelper(vpnExtension.createVpnConnection(context))
  }

  /**
   *
   * @returns 获取一个密钥对
   */
  export function makeKeyPair(): KeyPair {
    return native.makeKeyPair();
  }

  /**
   * 根据私钥计算公钥
   * 都是Base64之后的值
   * @param privateKey 私钥
   * @returns 公钥
   */
  export function genPublicKey(privateKey: string): string {
    return native.genPublicKey(privateKey);
  }

  /**
   * 执行一个 WireGuard 配置
   * - 先检查是否正在运行，如果运行别的，先停止
   * - 执行新配置
   *
   * @param id
   * @param config
   * @throws
   */
  export
  async function runWGConfig(context: Context, id: number, config: WGDeviceConfig, isOne: boolean) {
    // let want: Want = {};
    // 获取自身包名
    let bundleInfo = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    const packageName = bundleInfo.name
    const abilityName = 'WGVpnExtAbility'

    vpnExtension.stopVpnExtensionAbility({
      deviceId: '',
      bundleName: packageName,
      abilityName: abilityName,
    })

    if (isOne) {
      const TAG = "run wg"
      LLog.info(TAG, "启动 vpn")
      await vpnExtension.startVpnExtensionAbility({
        deviceId: '',
        bundleName: packageName,
        abilityName: abilityName,
        parameters: {
          id: id,
          config: config,
        }
      })
        .then(() => {
          LLog.info(TAG, "vpn start notify")
        })
        .catch((e: BusinessError) => {
          switch (e.code) {
            case 15501001:
              LLog.warn(TAG, { error: e, message: "服务正在运行中。。。" })
              break;
            case 201:
              LLog.warn(TAG, { error: e, message: "未授权！" })
              break;
            default:
              LLog.warn(TAG, e)
              break;
          }
        })
    }
  }

  /*
   * 其他功能
   */


  /**
   * 暂存变量，表示正在运行服务
   * @param configId 如果不传入，表示置空
   */
  export function setRunningServer(configId?: number) {
    getRunningServer().runningConfigId = configId;
  }

  export function getRunningServer(): ConnectState {
    return AppStorageV2.connect<ConnectState>(ConnectState, () => new ConnectState())!;
  }
}

/**
 * @author leojay`fu
 */
export class VpnConnHelper {
  vpnConnection: vpnExtension.VpnConnection
  private client = new native.WireGuardDevice();

  constructor(vpnConnection: vpnExtension.VpnConnection) {
    this.vpnConnection = vpnConnection;
  }

  async startServer(config: WGDeviceConfig) {
    try {
      LLog.info(TAG, "start server")
      const vpnConfig = makeVpnConfig(config)
      LLog.info(TAG, `vpnConfig: ${JSON.stringify(vpnConfig)}`)

      // 启动并创建一个 socketFd
      LLog.info(TAG, "client initVpn")
      const socketFd = await this.client.initVpn(config, async (fd: number) => {
        LLog.info(TAG, `Socket FD更新: ${fd}`)
        this.vpnConnection.protect(fd).catch((e: BusinessError) => {
          LLog.error(TAG, e)
        });
      });
      if (socketFd < 0) {
        throw new WGAppException(`Socket 通道建立异常：${socketFd}`);
      }
      // LLog.info(TAG, "socket 创建")
      // 保护 socket
      await this.vpnConnection.protect(socketFd);
      // LLog.info(TAG, "socket 保护")

      // 生成VPN ID 多VPN服务时使用 配置到vpnConfig 中
      // const vpnId = await this.vpnConnection.generateVpnId();
      // vpnConfig.vpnId = vpnId;

      // 启动 VPN
      // LLog.info(TAG, "tun create")
      const tunFd = await this.vpnConnection.create(vpnConfig)
      // 启动VPN双读取线程（socket和VPN读取）
      LLog.info(TAG, "client start fd=%d", tunFd)
      await this.client.start(tunFd);
      LLog.info(TAG, "VPN 启动成功")
    } catch (error) {
      LLog.error(TAG, {
        error: error,
        message: "Vpn启动失败"
      })
    }
  }

  async stopServer() {
    try {
      await this.vpnConnection.destroy()
      LLog.info(TAG, "关闭VPN")
      // const client = WireGuard.device;
      // 关闭并释放资源
      await this.client.close()
      LLog.info(TAG, "关闭通道")
    } catch (error) {
      LLog.info(TAG, {
        error: error,
        message: "停止VPN服务失败",
      })
    }

  }
}

/**
 * 将客户端配置转为Vpn配置
 *
 * @param config
 * @returns
 */
export function makeVpnConfig(config: WGDeviceConfig): vpnExtension.VpnConfig {
  const vpnIp = config.device.vpnIp!;
  const vpnAddress = vpnIp.ip!;
  const vpnAddressFamily = vpnIp.isIpv4 ? 1 : 2;
  const vpnAddressPrefixLen = config.device.vpnIp?.cidr ?? 32
  const dns = config.device.dns ?? []
  if (config.peers.length == 0) {
    throw new WGAppException("未配置Peer");
  }
  const routes: vpnExtension.RouteInfo[] = config.peers.map((peer) => {
    const remoteIp = peer.endpoint.address.ip;
    return peer.allowedIps.map((allowed) => {
      return {
        interface: "vpn-tun",
        destination: {
          address: { address: allowed.ip, family: allowed.isIpv4 ? 1 : 2 },
          prefixLength: allowed.cidr ?? (allowed.isIpv4 ? 32 : 128),
        },
        gateway: {
          address: remoteIp,
          family: 1
        },
        hasGateway: true,
        isDefaultRoute: false,
      } as vpnExtension.RouteInfo
    })
  }).flat()

  const vpnConfig: vpnExtension.VpnConfig = {
    addresses: [{
      address: { address: vpnAddress, family: vpnAddressFamily }, prefixLength: vpnAddressPrefixLen
    }],
    mtu: 1400,
    dnsAddresses: dns,
    routes: routes,
  }
  return vpnConfig;
}
