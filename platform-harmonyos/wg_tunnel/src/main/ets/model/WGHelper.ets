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
import WGConfig, { computeConfMd5 } from './WGConfig';
import WGEvent from './WGEvent';
import WGTools from './WGTools';
import { VpnConfigAction, VpnConfigRequestParams } from './entity/VpnConfigAction';
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
   * WGConfig聚合入口（status + runArg）
   */
  export const config = WGConfig;

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
   * 执行一个 WireGuard 配置（V2模式：参数直传+轮询降级）
   *
   * - isOne=true：启动VPN
   *   1. 缓存配置到 pendingConfig
   *   2. 检测VEA是否运行：
   *      - 运行中 → 直接发 SWITCH 指令（热切换，无需重启VEA）
   *      - 未运行 → 携带参数启动VEA，want.parameters传递：
   *        - id: number类型，配置ID
   *        - wgDbConf: string类型，WGDBConf的JSON.stringify序列化字符串
   *        V2 onCreate优先从want.parameters获取配置直接执行（API 22+）；
   *        API 21设备不支持want.parameters传递，自动降级为轮询模式
   *
   * - isOne=false：关闭VPN
   *   1. 清除缓存
   *   2. 通知VEA停止VPN服务
   *   3. 关闭VEA进程
   *
   * @param id 配置ID
   * @param config 数据库配置
   * @param isOne true=启动 false=关闭
   * @throws
   */
  export
  async function runWGConfig(id: number, config: WGDBConf, isOne: boolean) {
    const bundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    const packageName = bundleInfo.name;
    const abilityName = 'WGVpnExtAbility';

    if (isOne) {
      // 1. 缓存配置
      WireGuard.config.runArg.set(id, config);
      WireGuard.config.runArg.setRunningMd5(computeConfMd5(config));

      // 2. 检测VEA是否运行
      const isRunning = await WGTools.isVpnExtensionRunning();
      if (isRunning) {
        // VEA已在运行 → 热切换
        event.publishVpnConfigRequest({
          action: VpnConfigAction.SWITCH,
          configId: id,
          wgDbConf: config,
        });
        LLog.info(TAG, `VEA运行中，发送SWITCH指令: configId=${id}`);
      } else {
        // VEA未运行 → 启动VEA并携带配置参数（API 22+支持want.parameters直传，API 21降级为轮询）
        LLog.info(TAG, "VEA未运行，启动VPN（V2参数直传模式）");
        await vpnExtension.startVpnExtensionAbility({
          deviceId: '',
          bundleName: packageName,
          abilityName: abilityName,
          parameters: {
            'id': id,
            'wgDbConf': JSON.stringify(config),
          },
        })
          .catch((e: BusinessError) => {
            switch (e.code) {
              case 15501001:
                LLog.warn(TAG, { error: e, message: "服务正在运行中。。。" })
              case 201:
                LLog.warn(TAG, { error: e, message: "未授权！" })
              default:
                LLog.warn(TAG, e)
            }
            throw new WGAppException({ e: e, message: "VPN启动异常" });
          })
          .then(() => {
            LLog.info(TAG, "VPN Extension启动成功，等待VEA请求配置")
          })
      }
    } else {
      WireGuard.config.runArg.clear();
      if (await WGTools.isVpnExtensionRunning()) {
        // 先通知VEA停止VPN服务（优雅关闭连接）
        event.publishVpnConfigRequest({ action: VpnConfigAction.STOP });
        // 再关闭VEA进程
        await vpnExtension.stopVpnExtensionAbility({
          deviceId: '',
          bundleName: packageName,
          abilityName: abilityName,
        })
      } else {
        LLog.info(TAG, "VPN未开启，不执行关闭");
      }
    }
  }

  /**
   * 【V2模式】切换VPN配置
   *
   * 通知VEA切换到新配置（先停后启），无需重启VEA进程。
   * VEA必须正在运行，否则应使用 runWGConfig 启动。
   *
   * @param configId 新配置ID
   * @param wgDbConf 新数据库配置
   */
  export async function switchVpnConfig(configId: number, wgDbConf: WGDBConf): Promise<void> {
    if (!(await WGTools.isVpnExtensionRunning())) {
      LLog.warn(TAG, 'VEA未运行，无法切换配置，请先启动VPN');
      throw new WGAppException({ e: new Error("VEA未运行，无法切换配置"), message: "VEA未运行，无法切换配置" });
    }
    const newMd5 = computeConfMd5(wgDbConf);
    const currentMd5 = WireGuard.config.runArg.getRunningMd5();
    if (newMd5 === currentMd5) {
      LLog.info(TAG, `配置未变化，跳过切换: configId=${configId}, md5=${newMd5}`);
      return;
    }
    event.publishVpnConfigRequest({
      action: VpnConfigAction.SWITCH,
      configId: configId,
      wgDbConf: wgDbConf,
    });
    WireGuard.config.runArg.setRunningMd5(newMd5);
    LLog.info(TAG, `已发送切换配置指令: configId=${configId}, md5=${newMd5}`);
  }

  /**
   * 【V2模式】重启当前VPN配置
   *
   * 通知VEA重启当前配置（DNS重解析场景），无需重启VEA进程。
   *
   * @param configId 可选，指定重启的配置ID（不传则使用VEA缓存的当前配置）
   */
  export async function restartVpnConfig(configId?: number): Promise<void> {
    if (!(await WGTools.isVpnExtensionRunning())) {
      LLog.warn(TAG, 'VEA未运行，无法重启配置');
      throw new WGAppException({ e: new Error("VEA未运行，无法重启配置"), message: "VEA未运行，无法重启配置" });
    }
    const params: VpnConfigRequestParams = { action: VpnConfigAction.RESTART };
    if (configId != undefined) {
      params.configId = configId;
    }
    event.publishVpnConfigRequest(params);
    LLog.info(TAG, `已发送重启配置指令: configId=${configId ?? '使用缓存'}`);
  }

  /**
   * 【V2模式】停止VPN服务但保留VEA进程
   *
   * 适用于需要快速切换配置的场景，VEA进程继续存活。
   *
   * @param closeVea 是否同时关闭VEA进程（默认false）
   */
  export async function stopVpnService(closeVea: boolean = false): Promise<void> {
    event.publishVpnConfigRequest({ action: VpnConfigAction.STOP });
    LLog.info(TAG, '已发送停止VPN服务指令');

    if (closeVea) {
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      await vpnExtension.stopVpnExtensionAbility({
        deviceId: '',
        bundleName: bundleInfo.name,
        abilityName: 'WGVpnExtAbility',
      });
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
    return config.status.getConfig().isOpen()
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
