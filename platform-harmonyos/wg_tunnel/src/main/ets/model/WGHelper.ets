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
import native from 'libwg_tunnel.so';
import { DatabaseHelper } from './db/wgdb';
import { Context } from '@ohos.abilityAccessCtrl';
import WGDao from './db/WGDao';
import { WGDBConf, WGDeviceConfig } from './entity/WGConfigEntity';
import { vpnExtension } from '@kit.NetworkKit';
import { UIContext } from '@kit.ArkUI';
import { LLog } from '../tools/LLog';
import { bundleManager, common } from '@kit.AbilityKit';
import { KeyPair, WGConf } from './entity/napi_entity';
import ParamsRegex from './ParamsRegex';
import WGConfig from './WGConfig';
import WGEvent from './WGEvent';
import WGTools from './WGTools';
import { makeWGConf2VpnStartConfig, VpnConnHelper } from './WGConnect';

const TAG = "wgHelper"

/**
 * WireGuard 辅助类
 * @author leojay`fu
 */
class WGHelper {
  get config() {
    return new WGDao(WireGuard.db.orm)
  }

  async dbConfig2ConfFileContent(config: WGDBConf): Promise<string> {
    return await native.wgConfToOfficialStr(config.conf)
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
    db.init(context);
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

  export const db = new DatabaseHelper();

  export const regex = new ParamsRegex();

  export const event = WGEvent;

  /**
   * 状态配置
   */
  export const statusConfig = WGConfig;

  /**
   * 工具类
   */
  export const tools = WGTools

  /*
  主要功能
   */
  /**
   * 创建一个 vpn链接
   * @param cxt
   * @returns
   */
  export function makeVpnConnection(cxt: vpnExtension.VpnExtensionContext | UIContext,
    config: WGDeviceConfig): VpnConnHelper {
    let context: vpnExtension.VpnExtensionContext
    if (cxt instanceof UIContext) {
      context = cxt.getHostContext() as common.VpnExtensionContext;
    } else {
      context = cxt;
    }
    return new VpnConnHelper(vpnExtension.createVpnConnection(context), config)
  }

  /**
   *
   * @returns 获取一个密钥对
   */
  export async function makeKeyPair(): Promise<KeyPair> {
    return await native.makeKeyPair();
  }

  /**
   * 根据私钥计算公钥
   * 都是Base64之后的值
   * @param privateKey 私钥
   * @returns 公钥
   */
  export async function genPublicKey(privateKey: string): Promise<string> {
    return await native.genPublicKey(privateKey);
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
  async function runWGConfig(id: number, config: WGDBConf, isOne: boolean) {
    // let want: Want = {};
    // 获取自身包名
    let bundleInfo = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    const packageName = bundleInfo.name
    const abilityName = 'WGVpnExtAbility'

    if (isOne) {
      // 如果有运行的,需要先停止
      if (await WGTools.isVpnExtensionRunning()) {
        await vpnExtension.stopVpnExtensionAbility({
          deviceId: '',
          bundleName: packageName,
          abilityName: abilityName,
        })
      }

      // 这个配置将会发送到VPN服务进程，去配置、启动VPN服务
      const vpnConf = await makeWGConf2VpnStartConfig(config);
      LLog.info(TAG, `创建VPN配置：${JSON.stringify(vpnConf)}`)

      LLog.info(TAG, "启动 vpn")
      await vpnExtension.startVpnExtensionAbility({
        deviceId: '',
        bundleName: packageName,
        abilityName: abilityName,
        parameters: {
          id: id,
          config: vpnConf,
        },
      })
      // .catch((e: BusinessError) => {
      //   // switch (e.code) {
      //   //   case 15501001:
      //   //     LLog.warn(TAG, { error: e, message: "服务正在运行中。。。" })
      //   //   case 201:
      //   //     LLog.warn(TAG, { error: e, message: "未授权！" })
      //   //   default:
      //   //     LLog.warn(TAG, e)
      //   // }
      //   throw new WGAppException({ e: e, message: "VPN启动异常" });
      // })
        .then(() => {
          LLog.info(TAG, "vpn start notify")
          // statusConfig.setRunningServer(id)
        })
    } else {
      await vpnExtension.stopVpnExtensionAbility({
        deviceId: '',
        bundleName: packageName,
        abilityName: abilityName,
      })
    }
  }

  /*
   * 其他功能
   */

  /**
   * 讲配置文件转为实际可以读取的配置
   * @param content
   */
  export async function readWgConf(content: string): Promise<WGConf> {
    let result = await native.readWGConf(content);
    // LLog.info(TAG, `扫描：${JSON.stringify(result)}`)
    return result;
  }

  export namespace Tools {
    export async function isIpv4(ip: string): Promise<boolean> {
      return await native.isIpv4(ip);
    }

    export async function isIpv6(ip: string): Promise<boolean> {
      return await native.isIpv6(ip);
    }

    /**
     * 是否为IP地址
     * @param ip
     * @returns
     */
    export async function isIpAddress(ip: string): Promise<boolean> {
      return await native.isIpAddress(ip);
    }

    /**
     * 是否为域名
     * @param ip
     * @returns
     */
    export async function isValidDomain(domain: string): Promise<boolean> {
      return await native.isValidDomain(domain);
    }
  }

  export namespace Paths {

    /**
     * zip文件处理缓存目录
     */
    export const zip_cache = `zip`

    /**
     * @returns 获取到临时的zip解压地址（用后需要删除）
     */
    export function getZipDecodeTmpDir(context: Context): string {
      const root = context.cacheDir
      return `${root}/${zip_cache}/decompress/${Date.now()}`
    }

    /**
     * 获取缓存的zip压缩目录
     * @param context
     * @returns
     */
    export function getZipEncodeTmpDir(context: Context): string {
      const root = context.cacheDir
      return `${root}/${zip_cache}/encode/${Date.now()}`
    }
  }

}
