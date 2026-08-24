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
import { VpnConnHelper } from './WGConnect';
import WGAppException from '../error/WGAppException';

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
   * DNS解析在VPN Extension内部完成，无需在主进程预解析
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

      LLog.info(TAG, "启动 vpn")
      await vpnExtension.startVpnExtensionAbility({
        deviceId: '',
        bundleName: packageName,
        abilityName: abilityName,
        parameters: {
          id: id,
          wgDbConf: config,
        },
      })
        .catch((e: BusinessError) => {
          // switch (e.code) {
          //   case 15501001:
          //     LLog.warn(TAG, { error: e, message: "服务正在运行中。。。" })
          //   case 201:
          //     LLog.warn(TAG, { error: e, message: "未授权！" })
          //   default:
          //     LLog.warn(TAG, e)
          // }
          throw new WGAppException({ e: e, message: "VPN启动异常" });
        })
        .then(() => {
          LLog.info(TAG, "vpn start notify")
        })
    } else {
      // ===== 用户主动关闭VPN =====
      // 1. 在主应用进程中设置 userManuallyStopped=true，阻止后续自动重连
      statusConfig.vpnStopByUser()
      // 2. 通过跨进程广播通知VPN进程和其他订阅者：用户主动关闭了VPN
      //    VPN进程的 subscribeVpnChange 会收到此广播，并通过 syncFromVpnProcess 同步标记
      //    这样VPN进程也知道用户是主动关闭的，而非系统强杀
      event.publishVpnChange({ isOpen: false, tag: "user stop vpn", userManuallyStopped: true })
      // 3. 停止VPN Extension进程
      if (await WireGuard.tools.isVpnExtensionRunning()) {
        await vpnExtension.stopVpnExtensionAbility({
          deviceId: '',
          bundleName: packageName,
          abilityName: abilityName,
        })
      } else {
        LLog.info(TAG, "vpn 未开启，不执行关闭")
      }
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

  export function isRunning(): boolean {
    return statusConfig.getConfig().isOpen()
  }

  /**
   * 【自动重连核心判断】判断是否需要自动重连VPN
   *
   * 判断逻辑（以VPN进程数据为准）：
   *   1. VPN Extension仍在运行 → 发送查询广播同步最新状态，不需要重连
   *   2. VPN Extension不在运行 + 本地running=true + userManuallyStopped=false → 需要自动重连
   *      （说明VPN是被系统强杀而非用户主动关闭）
   *   3. VPN Extension不在运行 + 本地running=false → VPN已正常停止，不需要重连
   *   4. VPN Extension不在运行 + userManuallyStopped=true → 用户主动关闭，不需要重连
   *
   * 【关于本地状态的可靠性】
   * 本地 AppStorageV2 中的 running/userManuallyStopped 值是通过
   * subscribeVpnChange → syncFromVpnProcess 从VPN进程同步过来的，
   * 代表了VPN进程上次广播时的权威状态。
   * 如果VPN Extension被系统强杀且未来得及发送广播，
   * 本地 running 可能仍为 true（这正是我们需要自动重连的信号）。
   *
   * @returns true=需要自动重连
   */
  export async function shouldAutoReconnect(): Promise<boolean> {
    const vpnRunning = await WGTools.isVpnExtensionRunning()

    if (vpnRunning) {
      // VPN Extension仍在运行，发送查询广播请求VPN进程同步最新状态到本地
      // VPN进程收到 VPN_STATUS_QUERY 后会调用 queryStatus() → publishVpnChange()
      // subscribeVpnChange 中会自动调用 syncFromVpnProcess() 同步到本地
      LLog.info(TAG, "自动重连检测: VPN Extension仍在运行, 发送状态查询同步")
      event.publishVpnStatusQuery()
      return false
    }

    // VPN Extension不在运行，检查本地持久化状态（上次从VPN进程同步过来的值）
    const config = statusConfig.getConfig()
    if (!config.running) {
      // VPN已正常停止（VPN进程的onDestroy → stopVpn → publishVpnChange 已同步running=false）
      LLog.info(TAG, "自动重连检测: running=false, 不需要重连")
      return false
    }
    if (config.userManuallyStopped) {
      // 用户主动关闭了VPN（主应用进程的vpnStopByUser → publishVpnChange已同步标记）
      LLog.info(TAG, "自动重连检测: 用户主动关闭, 不需要重连")
      return false
    }

    // VPN Extension不在运行，但本地记录 running=true 且非用户主动关闭
    // 说明VPN进程被系统强杀（来不及发广播更新running=false），需要自动重连
    LLog.info(TAG, "自动重连检测: running=true, 非用户关闭, VPN Extension已停止 => 需要自动重连")
    return true
  }

  /**
   * 【自动重连执行】尝试自动重连VPN
   *
   * 从本地持久化的 runningConfigId 读取上次运行的配置ID，
   * 从数据库读取完整配置，调用 runWGConfig() 重启VPN Extension。
   *
   * 重连失败时设置 userManuallyStopped=true 防止反复重连（避免无限重试循环）
   *
   * @returns true=重连成功, false=重连失败
   */
  export async function tryReconnectVpn(): Promise<boolean> {
    const config = statusConfig.getConfig()
    const configId = config.runningConfigId
    if (configId == undefined) {
      LLog.error(TAG, "自动重连失败: runningConfigId为空")
      // 设置标记防止反复重连（无有效配置ID，重连无意义）
      statusConfig.vpnStopByUser()
      event.publishVpnThrow({ type: 'normal', message: "自动重连失败：未找到运行中的配置" })
      return false
    }

    try {
      LLog.info(TAG, `开始自动重连, configId=${configId}`)
      const wgDbConf = helper.config.getConfigForId(configId)
      if (!wgDbConf) {
        LLog.error(TAG, `自动重连失败: 未找到配置 id=${configId}`)
        // 设置标记防止反复重连（配置已被删除，重连无意义）
        statusConfig.vpnStopByUser()
        event.publishVpnThrow({ type: 'normal', message: "自动重连失败：配置不存在" })
        return false
      }

      // 调用 runWGConfig 启动VPN Extension
      // VPN启动成功后 VPNChangeHelper.startVpn 会：
      //   1. 调用 vpnStartRun(id) 清除 userManuallyStopped
      //   2. 调用 clearManuallyStopped()
      //   3. 调用 publishVpnChange() 广播通知主应用进程同步
      await runWGConfig(configId, wgDbConf, true)
      LLog.info(TAG, "自动重连VPN Extension启动成功")
      return true
    } catch (e) {
      LLog.error(TAG, `自动重连VPN异常: ${JSON.stringify(e)}`)
      // 重连失败，设置标记防止反复重连（避免无限重试循环消耗资源）
      statusConfig.vpnStopByUser()
      event.publishVpnThrow({ type: 'normal', message: "自动重连VPN失败" })
      return false
    }
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

    /**
     * 将数据长度转换为带单位的字符串
     *
     * @param len 数据长度
     */
    export function bitsToString(len: number): string {
      if (len < 0) {
        return '0 b';
      }
      if (len < 1024) {
        return `${len} b`;
      }
      let bytes: number = len / 8;
      const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];
      let unitIndex: number = 0;
      while (bytes >= 1024 && unitIndex < units.length - 1) {
        bytes /= 1024;
        unitIndex++;
      }
      return `${bytes.toFixed(2)} ${units[unitIndex]}`;
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
