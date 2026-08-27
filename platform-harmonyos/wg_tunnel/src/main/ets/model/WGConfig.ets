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
import { AppStorageV2, UIUtils } from '@kit.ArkUI';
import { LLog } from '../../../../Index';

const TAG = "WG状态"

/**
 * WireGuard 状态记录
 *
 * 【架构背景 - 进程隔离问题】
 * VPN Extension (WGVpnExtAbility) 和主应用 (EntryAbility) 运行在两个独立进程中：
 *   - 主应用进程：bundleName:site.leojay.wireguard（:main）
 *   - VPN进程：bundleName:site.leojay.wireguard:vpn
 *
 * HarmonyOS 中 AppStorageV2 的数据是进程隔离的，
 * 即主应用进程的 AppStorageV2 写入的数据，VPN进程读不到，反之亦然。
 *
 * 【为什么用 AppStorageV2 而非 PersistenceV2】
 * StatusConfig 中的字段（running、runningConfigId）都是运行时状态：
 *   - 应用关闭后VPN进程也会停止，这些值自然失效
 *   - 下次启动会通过跨进程广播重新获取最新状态
 *   - 无需磁盘持久化，AppStorageV2 的内存级存储即可（应用运行期间不被回收，退出即丢失）
 *
 * 【数据源原则 - 以VPN进程为准】
 * VPN进程是VPN运行状态的唯一权威数据源，因为：
 *   1. VPN的实际启停发生在VPN进程中（WGVpnExtAbility.onCreate/onDestroy）
 *   2. VPN进程能最准确地知道VPN是否真正在运行
 *   3. VPN Extension被系统强杀时，onDestroy可能不被调用，此时主应用进程需要通过
 *      isVpnExtensionRunning() 检测来发现状态不一致
 *
 * 【状态同步机制】
 *   - VPN进程 → 主应用进程：VPN状态变化时通过 WGEvent.publishVpnChange() 广播，
 *     主应用进程在 subscribeVpnChange() 中调用 syncFromVpnProcess() 同步到本地
 *   - 主应用进程主动查询：onForeground 时调用 publishVpnStatusQuery()，
 *     VPN进程收到后通过 publishVpnChange() 回复最新状态
 *
 * Created on 2026/7/10.
 * @author leojay`fu
 */

class WGStatusImpl {
  /**
   * @returns 获取状态配置（通过AppStorageV2内存级持久化，应用退出即丢失）
   */
  getConfig(): StatusConfig {
    // 注意以下方法都不能跨进程使用
    return AppStorageV2.connect<StatusConfig>(StatusConfig, () => new StatusConfig())!
  }

  /**
   * VPN开始运行 - 更新本地AppStorageV2状态
   *
   * 【仅VPN进程调用】在 WGVpnExtAbility VPN启动成功后调用（VPNChangeHelper.startVpn）
   * 更新后会通过 publishVpnChange() 广播通知主应用进程同步
   *
   * 状态变更：running=true, runningConfigId=id
   *
   * @param configId 当前运行的VPN配置ID
   */
  vpnStartRun(configId: number) {
    const config = this.getConfig()
    config.running = true
    config.runningConfigId = configId;
    LLog.info(TAG, `更新状态(running=true):${JSON.stringify(this.getConfig())}`)
  }

  /**
   * VPN正常停止运行 - 更新本地AppStorageV2状态
   *
   * 【仅VPN进程调用】在 WGVpnExtAbility.onDestroy 中调用（VPNChangeHelper.stopVpn）
   * 更新后会通过 publishVpnChange() 广播通知主应用进程同步
   *
   * 状态变更：running=false, runningConfigId=undefined
   */
  vpnStop() {
    const config = this.getConfig()
    config.runningConfigId = undefined;
    config.running = false;
    LLog.info(TAG, `更新状态(running=false):${JSON.stringify(this.getConfig())}`)
  }

  /**
   * VPN异常停止运行 - 仅更新running标记
   *
   * 【仅VPN进程调用】在VPN启动过程中发生异常时调用（VPNChangeHelper.startVpnThrow）
   * 与 vpnStop() 的区别：不清除 runningConfigId，保留现场便于排查问题
   *
   * 状态变更：running=false（其他字段不变）
   */
  vpnStopThrow() {
    this.getConfig().running = false;
    LLog.info(TAG, `更新状态(throw, running=false):${JSON.stringify(this.getConfig())}`)
  }

  /**
   * 【跨进程同步核心方法】从VPN进程广播同步状态到本地
   *
   * 调用时机：主应用进程在 subscribeVpnChange() 收到VPN进程广播后调用此方法，
   * 将VPN进程的最新状态写入本地 AppStorageV2，保证主应用进程的数据与VPN进程一致。
   *
   * 数据流向：VPN进程 (publishVpnChange) → CommonEvent广播 → 主应用进程 (subscribeVpnChange) → syncFromVpnProcess()
   *
   * @param dto VPN进程广播过来的StatusConfigDTO（纯数据，用于跨进程序列化）
   */
  syncFromVpnProcess(dto: StatusConfigDTO) {
    const c = this.getConfig()
    c.runningConfigId = dto.runningConfigId
    c.running = dto.running
    LLog.info(TAG, `从VPN进程同步状态: running=${c.running}, configId=${c.runningConfigId}`)
  }

  /**
   * 从DTO更新本地状态（UI层调用）
   * @param dto 纯数据传输对象
   */
  update(dto: StatusConfigDTO) {
    const c = this.getConfig()
    c.runningConfigId = dto.runningConfigId
    c.running = dto.running
  }

  isRunning(id: number): boolean {
    const config = this.getConfig();
    return config.running && id == config.runningConfigId;
  }
}


/**
 * VPN运行状态配置 - 应用内存级持久化
 *
 * 【进程隔离说明】
 * 此类使用 @ObservedV2 + @Trace + AppStorageV2 内存级持久化，
 * 但 AppStorageV2 的数据是进程隔离的，两个进程各自有独立的内存存储。
 * 因此此对象中的值只反映当前进程的本地状态，
 * 跨进程同步需要通过 WGEvent.publishVpnChange / syncFromVpnProcess 完成。
 *
 * 【为什么用 AppStorageV2 而非 PersistenceV2】
 * 这些字段都是运行时状态，应用关闭后VPN进程也停止，数据自然失效，
 * 下次启动会通过跨进程广播重新获取最新状态，无需磁盘持久化。
 *
 * 【字段状态转换规则】
 * runningConfigId / running：
 *   VPN启动成功 → running=true, runningConfigId=id（VPN进程设置，广播同步到主应用）
 *   VPN正常停止 → running=false, runningConfigId=undefined（VPN进程设置，广播同步到主应用）
 *   VPN被系统强杀 → 可能来不及更新，主应用通过 isVpnExtensionRunning() 检测发现不一致
 */
@ObservedV2
export class StatusConfig {
  @Trace runningConfigId?: number = undefined;  // 当前运行的VPN配置ID，undefined=未运行
  @Trace running: boolean = false;              // VPN是否正在运行

  /**
   * VPN 是否开启，也表示是否正在运行
   * @returns
   */
  isOpen(): boolean {
    return this.runningConfigId != undefined && this.running == true
  }

  /**
   * 转换为纯数据传输对象（用于跨进程序列化）
   *
   * 【为什么需要DTO】
   * StatusConfig 使用 @ObservedV2 + @Trace 装饰器，JSON.stringify 时 @Trace 属性名
   * 会被加 __ob_ 前缀（如 __ob_running），导致反序列化后无法读取原始属性名。
   * StatusConfigDTO 是无装饰器的纯数据类，JSON.stringify/parse 行为正常。
   *
   * @returns 不带装饰器的纯数据副本
   */
  toDTO(): StatusConfigDTO {
    const dto = new StatusConfigDTO()
    dto.runningConfigId = this.runningConfigId
    dto.running = this.running
    return dto
  }
}

/**
 * StatusConfig的纯数据传输对象（DTO）
 *
 * 【与StatusConfig的区别】
 * - StatusConfig：带 @ObservedV2 + @Trace + AppStorageV2，用于UI响应式绑定和内存持久化
 * - StatusConfigDTO：无装饰器的纯数据类，用于跨进程 JSON 序列化/反序列化
 *
 * 不带 @Trace 的属性不会被 ArkUI 框架劫持，JSON.stringify 输出原始属性名，
 * 反序列化时能正常读取 running、runningConfigId。
 */
export class StatusConfigDTO {
  runningConfigId?: number = undefined;
  running: boolean = false;
}

const WGConfig = new WGStatusImpl();

export default WGConfig;