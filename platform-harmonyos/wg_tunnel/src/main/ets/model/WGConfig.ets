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
import { WGDBConf } from './entity/WGConfigEntity';

const TAG = "WGConfig"

// ====================== Status 模块 ======================

/**
 * VPN运行状态 - AppStorageV2内存级持久化
 *
 * VPN进程和主应用进程各自有独立的AppStorageV2存储（进程隔离），
 * 跨进程同步通过 publishVpnChange / syncFromVpnProcess 完成。
 */
@ObservedV2
export class StatusConfig {
  @Trace runningConfigId?: number = undefined;
  @Trace running: boolean = false;

  isOpen(): boolean {
    return this.runningConfigId != undefined && this.running == true
  }

  /** 转为纯数据DTO，用于跨进程序列化（@Trace属性JSON.stringify会加__ob_前缀） */
  toDTO(): StatusConfigDTO {
    const dto = new StatusConfigDTO()
    dto.runningConfigId = this.runningConfigId
    dto.running = this.running
    return dto
  }
}

/** StatusConfig的纯数据传输对象，无装饰器，序列化安全 */
export class StatusConfigDTO {
  runningConfigId?: number = undefined;
  running: boolean = false;
}

function getStatusConfig(): StatusConfig {
  return AppStorageV2.connect(StatusConfig, () => UIUtils.makeObserved(new StatusConfig()))!;
}

/**
 * Status操作接口
 *
 * - vpnStartRun/vpnStop/vpnStopThrow：仅VPN进程调用
 * - syncFromVpnProcess：主应用进程收到VPN广播后同步
 */
class StatusImpl {
  getConfig(): StatusConfig {
    return getStatusConfig();
  }

  vpnStartRun(configId: number) {
    const config = this.getConfig()
    config.running = true
    config.runningConfigId = configId;
    LLog.info(TAG, `状态更新(running=true): configId=${configId}`)
  }

  vpnStop() {
    const config = this.getConfig()
    config.runningConfigId = undefined;
    config.running = false;
    LLog.info(TAG, `状态更新(running=false)`)
  }

  vpnStopThrow() {
    this.getConfig().running = false;
    LLog.info(TAG, `状态更新(throw, running=false)`)
  }

  syncFromVpnProcess(dto: StatusConfigDTO) {
    const c = this.getConfig()
    c.runningConfigId = dto.runningConfigId
    c.running = dto.running
    LLog.info(TAG, `从VPN进程同步: running=${c.running}, configId=${c.runningConfigId}`)
  }

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

// ====================== RunArg 模块 ======================

/**
 * VPN待运行配置参数 - AppStorageV2内存级持久化
 *
 * runWGConfig启动时先缓存到此处：
 * - VEA运行中 → 直接发SWITCH指令
 * - VEA未运行 → 启动VEA，VEA轮询CONFIG_QUERY，EntryAbility从此缓存读取回复START
 *
 * 使用AppStorageV2而非静态变量：应用运行期间不被系统回收，退出即丢失。
 */
@ObservedV2
export class RunArgConfig {
  @Trace pendingConfigId?: number = undefined;
  @Trace pendingDbConf?: WGDBConf = undefined;
}

function getRunArgConfig(): RunArgConfig {
  return AppStorageV2.connect(RunArgConfig, () => UIUtils.makeObserved(new RunArgConfig()))!;
}

/**
 * RunArg操作接口
 */
class RunArgImpl {
  getConfig(): RunArgConfig {
    return getRunArgConfig();
  }

  set(configId: number, wgDbConf: WGDBConf): void {
    const c = this.getConfig();
    c.pendingConfigId = configId;
    c.pendingDbConf = wgDbConf;
  }

  clear(): void {
    const c = this.getConfig();
    c.pendingConfigId = undefined;
    c.pendingDbConf = undefined;
  }

  hasConfig(): boolean {
    const c = this.getConfig();
    return c.pendingConfigId != undefined && c.pendingDbConf != undefined;
  }

  getConfigId(): number | undefined {
    return this.getConfig().pendingConfigId;
  }

  getDbConf(): WGDBConf | undefined {
    return this.getConfig().pendingDbConf;
  }
}

// ====================== WGConfig 聚合 ======================

/**
 * WGConfig - 聚合Status和RunArg两个模块
 *
 * status：VPN运行状态（running/runningConfigId）
 * runArg：待运行配置缓存（pendingConfigId/pendingDbConf）
 */
class WGConfigImpl {
  readonly status = new StatusImpl();
  readonly runArg = new RunArgImpl();
}

const WGConfig = new WGConfigImpl();

export default WGConfig;
