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
 * VPN开关统一执行器（主界面行开关 / 预览页开关共用）
 *
 * 【开关事务化】发出信号后临时订阅明确回复，收到回复（或超时=失败）前按钮锁定
 * 并显示「开启中/关闭中/切换中」——杜绝并发操作与"命令发了没等结果"的竞态：
 * - 开启/切换的明确回复：广播 vpnThreadRunning===true 且 runningConfigId===目标id
 * - 关闭的明确回复：VPN_SERVICE_STOPPED（= VEA已完成 unlisten→destroy→close 全部拆除，
 *   即系统VPN配置已注销，此刻其他app的网络/DNS已恢复）
 * - 收到明确回复后：主进程调用 stopVpnExtensionAbility 关闭VEA进程（进程关闭权在主进程）
 * - 超时也算回复（失败）：解锁+提示；底层重试继续，迟到广播按事务忽略
 *
 * 【两道闸门，只有目标任务执行】
 * 第一道（UI层，各页面Toggle内）：点击标记（isClick/isSwitchClick）——onClick 设 true、
 * onChange 消费。ArkUI Toggle 的 onChange 在程序赋值时同样会触发，联动按钮的
 * 程序性状态变化引发的 onChange 因标记为 false 直接空跑返回，不产生任务。
 * 第二道（本服务）：任务执行前校验 StatusConfig.switchConfigId 与目标id一致
 * （按开关位区分），不一致=意图已被后到操作覆盖，作废为空操作。
 *
 * 【单飞行槽】currentOp Promise链：新任务接在前一任务落定之后执行，同一时间
 * 只有一个native操作在飞。对已完成Promise接then立即微任务执行，不会重放底层操作。
 *
 * @author leojay`fu
 */
import { UIContext, AppStorageV2, UIUtils } from '@kit.ArkUI';
import { bundleManager } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { LLog, vpnKeepAliveManager, WireGuard, WGDBConf, VpnEventTag, SubEventCancel } from 'wg_tunnel';

const TAG = 'VpnToggle'

/** 开关事务阶段（非idle=全部开关禁用，目标开关显示状态文案） */
export type TogglePhase = 'idle' | 'starting' | 'stopping' | 'switching';

/** 明确回复超时：开启/切换15s（VEA启动+握手余量）；关闭20s（destroy+广播余量） */
const START_REPLY_TIMEOUT_MS: number = 15 * 1000;
const STOP_REPLY_TIMEOUT_MS: number = 20 * 1000;

/**
 * VPN开关事务全局状态（AppStorageV2全局缓存：所有开关UI共享读写）
 *
 * 非idle=任一事务进行中，全局所有VPN开关禁用（enabled门），仅目标开关显示状态文案。
 */
@ObservedV2
export class VpnToggleState {
  /** 事务阶段 */
  @Trace phase: TogglePhase = 'idle';
  /** 当前事务目标配置id（idle时为-1） */
  @Trace targetId: number = -1;
}

/**
 * AppStorageV2全局单例：所有组件/VM读取同一实例（UI响应式）
 */
export const vpnToggleState: VpnToggleState =
  AppStorageV2.connect(VpnToggleState, () => UIUtils.makeObserved(new VpnToggleState()))!;

/** pending事务回复 */
interface PendingReply {
  phase: TogglePhase;
  targetId: number;
  resolve: (ok: boolean) => void;
  /** 超时定时器句柄：成功落定时清除，防旧事务定时器误杀新事务 */
  timer: number;
}

class VpnToggleServiceImpl {
  private currentOp?: Promise<void>;
  /** pending事务回复（同时至多一个事务） */
  private pending?: PendingReply;
  /** 明确回复监听句柄（懒注册） */
  private replyCancel?: SubEventCancel;

  /**
   * 统一开关入口（仅由真实点击路径调用：主界面行openChange / 预览页onSwitchChange，
   * 均已过点击标记守卫）
   *
   * 执行序：事务置位（phase锁定+文案）→ 意图先行 → 刷新按钮显示（联动=纯显示写入，
   * 不产生任务）→ 接入单飞行槽，执行前校验id，只有目标任务执行；任务内等待明确
   * 回复（或超时=失败），落定后解锁。
   *
   * @param context UIContext（Toast用）
   * @param targetId 点击的目标配置id
   * @param isOn true=开 false=关
   * @param dbConf 目标配置数据
   * @param onDisplayRefresh 按钮显示刷新回调（读意图重算各行/预览开关显示）
   * @param onSettled 任务落定回调（恢复开关可点状态），成功失败均回调
   */
  requestVpnToggle(context: UIContext, targetId: number, isOn: boolean, dbConf: WGDBConf,
    onDisplayRefresh: () => void, onSettled?: () => void): Promise<void> {
    // 0. 事务锁：非idle=上一事务未落定，竞争点击失败
    if (vpnToggleState.phase !== 'idle') {
      const tip = vpnToggleState.phase === 'starting' ? '开启中'
        : vpnToggleState.phase === 'stopping' ? '关闭中' : '切换中';
      context.getPromptAction().showToast({ message: `VPN${tip}，请稍候` });
      if (onSettled != undefined) {
        onSettled();   // 竞争点击立即恢复自身可点状态（全局禁用门仍生效）
      }
      return Promise.resolve();
    }

    // 1. 事务置位（先于入队：迟到广播按targetId/phase判定，无法伪造提前解锁）
    vpnToggleState.phase = isOn ? 'starting' : 'stopping';
    vpnToggleState.targetId = targetId;

    // 2. 意图先行：本地状态立即置为目标态，UI开关由意图驱动
    if (isOn) {
      WireGuard.config.status.switchOnIntent(targetId);
    } else {
      WireGuard.config.status.switchOffIntent();
    }
    onDisplayRefresh();

    // 3. 接入单飞行槽
    const task = (this.currentOp ?? Promise.resolve()).catch(() => {
    }).then(async () => {
      await this.executeWhenIdMatches(context, targetId, isOn, dbConf);
    });
    this.currentOp = task;
    task.finally(() => {
      // 事务落定（明确回复或超时）：解锁
      vpnToggleState.phase = 'idle';
      vpnToggleState.targetId = -1;
      if (onSettled != undefined) {
        onSettled();
      }
    });
    return task;
  }

  /**
   * 保存配置后的自动热切换（预览页updateData路径，非点击触发）
   *
   * 意图不变；仅当运行意图仍是本配置（开关开且id一致）时发SWITCH，
   * 把编辑后的配置应用到运行中的隧道。接入同一单飞行槽与其他操作串行。
   */
  requestConfigReloadSwitch(targetId: number, dbConf: WGDBConf): Promise<void> {
    const task = (this.currentOp ?? Promise.resolve()).catch(() => {
    }).then(async () => {
      const s = WireGuard.config.status.getConfig();
      if (!(s.isSwitchOpen && s.switchConfigId === targetId)) {
        LLog.info(TAG, `热切换跳过：运行意图非本配置(target=${targetId}, current=${s.isSwitchOpen}/${s.switchConfigId})`);
        return;
      }
      vpnToggleState.phase = 'switching';
      vpnToggleState.targetId = targetId;
      try {
        await WireGuard.switchVpnConfig(targetId, dbConf);
        const ok: boolean = await this.waitForReply('switching', targetId, START_REPLY_TIMEOUT_MS);
        if (!ok) {
          LLog.warn(TAG, '热切换确认超时（底层仍继续，迟到确认忽略）');
        }
      } catch (e) {
        LLog.error(TAG, `热切换失败: ${JSON.stringify(e)}`);
      } finally {
        vpnToggleState.phase = 'idle';
        vpnToggleState.targetId = -1;
      }
    });
    this.currentOp = task;
    return task;
  }

  /**
   * 第二道闸门：id校验 + 执行 + 等待明确回复 + 失败回滚
   *
   * 无论开关，只有 switchConfigId 与目标id一致（且开关位匹配）才执行；
   * 不匹配说明意图已被后到操作覆盖，本次作废为空操作。
   *
   * 关闭序列：先停轮询/长时任务（不再保活直接关闭）→ 发STOP → 等
   * VPN_SERVICE_STOPPED（明确回复）→ 主进程关闭VEA进程。
   */
  private async executeWhenIdMatches(context: UIContext, targetId: number, isOn: boolean,
    dbConf: WGDBConf): Promise<void> {
    const s = WireGuard.config.status.getConfig();
    const matches = isOn
      ? (s.isSwitchOpen && s.switchConfigId === targetId)
      : (!s.isSwitchOpen && s.switchConfigId === targetId);
    if (!matches) {
      LLog.info(TAG,
        `任务作废(意图已更新): target=${targetId}/${isOn ? '开' : '关'}, current=${s.isSwitchOpen}/${s.switchConfigId}`);
      return;
    }

    // 先挂明确定回复监听（临时订阅，超时=失败回复），再触发动作
    const reply: Promise<boolean> = this.waitForReply(
      isOn ? 'starting' : 'stopping', targetId,
      isOn ? START_REPLY_TIMEOUT_MS : STOP_REPLY_TIMEOUT_MS);

    try {
      if (isOn) {
        await WireGuard.runWGConfig(targetId, dbConf, true);
        vpnKeepAliveManager.onSwitchOn();
      } else {
        // 关闭序列第一步：先停轮询/长时任务（不再保活直接关闭），再发STOP
        vpnKeepAliveManager.onSwitchOff();
        await WireGuard.runWGConfig(targetId, dbConf, false);
      }

      // 等待明确回复（成功/超时=失败）
      const ok: boolean = await reply;
      if (isOn) {
        if (!ok) {
          // 超时不回滚意图：底层启动仍继续，迟到成功由广播自然更新UI
          context.getPromptAction().showToast({ message: 'VPN启动确认超时，请查看连接状态' });
        }
        return;
      }
      if (!ok) {
        context.getPromptAction().showToast({
          message: 'VPN关闭超时：系统DNS可能残留，建议开关一次WiFi/飞行模式'
        });
        return;
      }
      // 关闭明确回复到达（网络已拆干净）→ 主进程关闭VEA进程
      await this.stopVpnExtensionAbility();
    } catch (e) {
      // 回滚：仅当意图仍属本次（被后到意图覆盖时不回滚、不提示）
      const cur = WireGuard.config.status.getConfig();
      const stillMine = isOn
        ? (cur.isSwitchOpen && cur.switchConfigId === targetId)
        : (!cur.isSwitchOpen && cur.switchConfigId === targetId);
      if (stillMine) {
        WireGuard.config.status.switchOffIntent();
        vpnKeepAliveManager.onSwitchOff();
        WireGuard.event.publishVpnNoOpen();
        // 开启失败展示Toast，关闭失败不展示（用户主动关闭不应提示错误）
        if (isOn) {
          const reason = e != undefined ? String(e) : '';
          context.getPromptAction().showToast({
            message: reason.length > 0 ? 'VPN启动失败：' + reason : 'VPN启动失败'
          });
        }
      }
      LLog.error(TAG, { error: e, message: `${isOn ? "开启" : "关闭"}VPN异常` });
    }
  }

  /** 明确回复监听（懒注册一次）：按pending事务的phase/targetId判定成功 */
  private ensureReplyListener(): void {
    if (this.replyCancel != undefined) {
      return;
    }
    this.replyCancel = WireGuard.event.subscribeVpnChange((params) => {
      const p = this.pending;
      if (p == undefined) {
        return;
      }
      let ok = false;
      if (p.phase === 'stopping') {
        // 明确回复：VEA已完成 unlisten→destroy→close 全部拆除
        ok = params.tag === VpnEventTag.VPN_SERVICE_STOPPED;
      } else {
        // 开启/切换：真实运行确认（subscribeVpnChange内部已sync运行状态）
        const s = WireGuard.config.status.getConfig();
        ok = params.vpnThreadRunning === true && s.runningConfigId === p.targetId;
      }
      if (ok) {
        this.settlePending(p, true);
      }
      // 未达标广播：不消费，继续等待至超时
    });
  }

  /** 结算pending事务（成功/超时互斥；清除定时器防旧事务定时器误杀新事务） */
  private settlePending(p: PendingReply, ok: boolean): void {
    if (this.pending !== p) {
      return;
    }
    this.pending = undefined;
    clearTimeout(p.timer);
    p.resolve(ok);
  }

  /** 挂起事务回复并返回等待Promise（同时注册懒监听） */
  private waitForReply(phase: TogglePhase, targetId: number, timeoutMs: number): Promise<boolean> {
    this.ensureReplyListener();
    return new Promise<boolean>((resolve) => {
      const pending: PendingReply = {
        phase: phase, targetId: targetId, timer: 0,
        resolve: (ok: boolean): void => resolve(ok),
      };
      this.pending = pending;
      pending.timer = setTimeout(() => {
        this.settlePending(pending, false);   // 超时=失败回复
      }, timeoutMs);
    });
  }

  /**
   * 关闭VEA进程（进程关闭权在主进程）+ 关闭校验重试
   *
   * VEA收到STOP后已全聋（不再监听任何指令）：若进程滞留未关闭，下次开启的
   * 参数直传会因15501001改走SWITCH打到聋壳丢失——必须校验进程确实退出，
   * 滞留则重试关闭。
   */
  private async stopVpnExtensionAbility(): Promise<void> {
    const maxAttempts: number = 3;
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        const bundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
        await vpnExtension.stopVpnExtensionAbility({
          deviceId: '',
          bundleName: bundleInfo.name,
          abilityName: 'WGVpnExtAbility',
        });
      } catch (e) {
        LLog.error(TAG, `关闭VEA#${attempt}调用失败: ${JSON.stringify(e)}`);
      }
      // 校验进程确实退出（3s内轮询）
      const deadline: number = Date.now() + 3000;
      while (Date.now() < deadline) {
        try {
          if (!(await WireGuard.tools.isVpnExtensionRunning())) {
            LLog.info(TAG, `VEA进程已关闭(第${attempt}次尝试)`);
            return;
          }
        } catch (e) {
          // 查询失败继续轮询
        }
        await new Promise<void>((resolve) => setTimeout(resolve, 300));
      }
      LLog.warn(TAG, `关闭VEA#${attempt}后进程仍存活，重试关闭`);
    }
    LLog.error(TAG, 'VEA进程关闭校验重试耗尽，进程可能滞留（下次开启前需确认关闭）');
  }
}

export const vpnToggleService = new VpnToggleServiceImpl();
