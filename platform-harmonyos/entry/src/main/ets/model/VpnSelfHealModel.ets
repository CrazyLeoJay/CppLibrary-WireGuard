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
import { preferences } from '@kit.ArkData';
import { commonEventManager, BusinessError } from '@kit.BasicServicesKit';
import { bundleManager, common } from '@kit.AbilityKit';
import { vpnExtension, connection } from '@kit.NetworkKit';
import { LLog, WireGuard, WGDBConf, WGEventThrow, VPN_SELF_HEAL_PREFS_NAME, VPN_SELF_HEAL_KEY_LAST_OPEN_CONFIG_ID, isUserStopSuppressionActive, MessageType, StreamLogMessage } from 'wg_tunnel';

const TAG = 'VpnSelfHeal';
// 自愈持久化文件名与key已下沉到wg_tunnel单点定义：主进程关VPN时需同步清除同一份记录
//（见VPNSelfHealPrefsKey.clearSelfHealRecord），双端必须共用常量，防止魔法字符串漂移

/**
 * 定时轮询检测间隔（兜底通道，非主通道）。
 *
 * 原 60s：真机实证"WiFi→蜂窝后隧道被拆、VEA 卡死"时，感知延迟 = 静默阈值 + 最多一个
 * 轮询周期 ≈ 3 分钟，用户体感就是"断了好久自己都不连"。
 *
 * 现"进程消失"这一类故障已由事件驱动接管（见 startVpnNetWatch）：VPN 承载网络消失到
 * netLost 到达实测仅 337/367ms，比任何轮询周期都快，故轮询退居兜底，只承担它独有的
 * 两类职责：
 *   1) VEA 进程壳存活但数据心跳超时的"功能死"（VPN 网络此时并未拆除，netLost 不会来）；
 *   2) 主进程被系统冻结期间错过的网络事件（解冻后靠第一个轮询 tick 补齐）。
 *
 * 【为什么取 5s 而非 10s / 20s】轮询退居兜底后，对周期最敏感的是"VEA 自声明重连中后的
 * 卡死"：其阈值仅 30s（它承诺马上有心跳，故阈值取得很短）。最坏感知 = 阈值 + 最多一个
 * 周期：5s≈35s、10s≈40s、20s≈50s（相对 5s 恶化 43%）。这一类正是当初把中断从 3 分 38 秒
 * 压下来的关键路径，多等 5~15s 无收益。
 * 放宽到 10s/20s 省下的只是跨进程 isVpnExtensionRunning() 探测次数（12→6→3 次/分钟）。
 * 但唤醒次数不随周期变化——主进程保活本就每 3s 一跳（20 次/分钟），轮询只是搭车；该探测
 * 电耗在 μAh/小时级，淹没在 12.09 mAh/h 的实测误差下，省这 6 次/分 IPC 对用户不可感知。
 * 故取 5s：兜底感知最快、代价可忽略。
 */
const POLL_INTERVAL_MS = 5 * 1000;

/**
 * 事件驱动：订阅「VPN 承载类型网络」（BEARER_VPN=4）的消失事件，替代长周期轮询来
 * 近实时感知"VEA 进程没了 / 隧道被系统拆除"。
 *
 * 【为什么可行】真机实证（2026-09-12，见 docs/F探针实测与B收口效果-*.md）：
 * VEA 停止导致 VPN 网络拆除后，主进程在 337ms / 367ms 即收到 `[vpn] netLost`；
 * VPN 网络建立时 `netAvailable` 亦仅 60ms。而 LMK 击杀 VEA 与"用户停止 VEA"对系统
 * 而言是同一条路径（进程消失 → tun fd 关闭 → VPN 网络拆除），故 LMK 场景同样可命中。
 *
 * 【为什么必须带 settle 延迟】用户主动关闭 VPN 时也会走到这条路径。虽然关闭动作在
 * 下发 STOP 之前就已同步清掉自愈记录并置入抑制窗口（见 VpnSelfHealPrefsKey），但
 * `status.isOpen()` 要等 VEA 的 STOP_VPN 广播回来才翻 false。延后一小段再判定，
 * 让该广播先落地，可把"用户主动关闭"这条路彻底堵死（避免关掉又被自己拉起）。
 */
const VPN_NET_LOST_SETTLE_MS = 800;
/** netLost 触发探测的最小间隔：切换瞬间可能连发多个网络事件，防止探测风暴 */
const VPN_NET_LOST_PROBE_MIN_INTERVAL_MS = 2000;
/**
 * 目标网络不存在时的等待上限（传给 createNetConnection）。
 * 必须显式传：不传则目标网络长时间不可用时不会回调 netUnavailable（实测语义），
 * 与探针阶段保持一致（3000ms 已实机验证无副作用）。
 */
const VPN_NET_ACQUIRE_TIMEOUT_MS = 3000;
/** 两次恢复尝试之间的冷却时间（防止反复拉起失败形成死循环） */
const RECOVER_COOLDOWN_MS = 30 * 1000;
/** 冷启动恢复延迟（等待AbilityStage数据库初始化与系统服务就绪） */
const COLD_START_DELAY_MS = 1500;
/** 自动恢复连续失败上限（达到后停止本轮生命周期的自动尝试，手动开启成功后复位） */
const MAX_RECOVER_FAIL = 3;
/** 恢复尝试活跃窗口：指令下发后此时间内VEA自行停止视为自愈失败（而非用户主动关闭） */
const RECOVER_ACTIVE_WINDOW_MS = 60 * 1000;
/**
 * VEA数据心跳超时：超过此时间未收到VEA任何流日志广播，判定"进程壳在但功能死"。
 * VEA正常时C++心跳每3秒驱动一条流日志广播（含熧屏期）；主进程活跃期90秒收不到
 * 即可确定VEA的ArkTS线程或C++数据通路已死（真机实证场景：线程阻塞、VPN被系统
 * 拆除、图标消失，而进程壳仍在，进程级检测完全失明）。
 */
const VEA_SILENCE_TIMEOUT_MS = 90 * 1000;
/** 功能死阈值自适应联动：用户取消keepalive（=0）时空闲期仅rekey（120s周期）产生
* 流量心跳，90s固定阈值会误判功能死（90<120）；放宽至rekey周期的1.25倍。 */
const VEA_SILENCE_TIMEOUT_NO_KEEPALIVE_MS = 150 * 1000;
/** 功能死二次确认窗口：判定静默后再等此时长比对心跳时间戳是否变化。
 * 解冻瞬间过期的poll tick会立即触发，而lastVeaDataAtMs还是冻结前旧值、
 * 解冻补投的积压广播尚未处理完——直接判定会误杀健康VEA；健康VEA的
 * 心跳/补投必会在窗口内刷新时间戳，真功能死（已死90秒+）则保持不变。 */
const VEA_SILENCE_RECHECK_MS = 10 * 1000;
/**
 * VEA 已主动声明"隧道重连中"（VPN_RECONNECTING 广播）后的静默阈值。
 *
 * 为什么可以显著短于 90s/150s：那两个阈值为了不误杀"健康但空闲"的隧道而放宽
 * （空闲期只有 rekey 的 120s 周期才产生流量心跳）。但 VEA **自己声明**"我正在重连"
 * 就完全不是空闲场景了——它承诺马上会有数据心跳。此时 30s 内仍无任何心跳，
 * 只可能是 VEA/隧道真的卡死（真机实证：α 整隧道重启后 VEA JS 线程阻塞，
 * 直到 150s 阈值才被发现，占掉总中断 3 分 38 秒的绝大部分）。
 */
const VEA_RECONNECT_SILENCE_TIMEOUT_MS = 30 * 1000;
/**
 * "VEA 处于重连态"声明的有效期。超过此窗口未再收到声明，说明 VEA 已放弃该轮
 * 重连（或已销毁重建），短阈值随之失效，回落到常规静默阈值判定，避免长期误判。
 */
const VEA_RECONNECT_DECLARE_TTL_MS = 5 * 60 * 1000;
/** 强制销毁功能死VEA壳后，等待进程消失的最大等待次数与间隔。
 * 放宽到 10 次：真机实证阻塞中的 VEA 用 5s 仍可能没退干净，一轮放弃后要再等
 * 一个轮询周期+冷却（数十秒）才有下次机会，代价远高于多等 5s。 */
const VEA_KILL_WAIT_MAX_TRIES = 10;
const VEA_KILL_WAIT_INTERVAL_MS = 1000;

/**
 * VPN自愈持久化（preferences）
 *
 * 记录"最后处于运行状态的VPN配置ID"。
 * AppStorageV2的状态是内存级的，主进程被系统杀死后即丢失；
 * 此持久化是冷启动后判断"VPN本应在运行"的唯一依据。
 */
class VpnSelfHealPrefsImpl {
  private prefs: preferences.Preferences | undefined = undefined;

  /**
   * 初始化（在Ability onCreate中同步调用，
   * 必须在收到VPN状态广播前就绪，否则recordStatus会静默丢失记录）
   */
  init(context: common.Context): void {
    if (this.prefs) {
      return;
    }
    try {
      this.prefs = preferences.getPreferencesSync(context, { name: VPN_SELF_HEAL_PREFS_NAME });
      LLog.info(TAG, 'VpnSelfHealPrefs initialized');
    } catch (e) {
      LLog.error(TAG, { error: e, message: 'Failed to init VpnSelfHealPrefs' });
    }
  }

  /**
   * 读取最后运行的配置ID，无记录返回-1
   */
  getLastOpenConfigId(): number {
    if (!this.prefs) {
      return -1;
    }
    return this.prefs.getSync(VPN_SELF_HEAL_KEY_LAST_OPEN_CONFIG_ID, -1) as number;
  }

  setLastOpenConfigId(configId: number): void {
    if (!this.prefs) {
      return;
    }
    try {
      this.prefs.putSync(VPN_SELF_HEAL_KEY_LAST_OPEN_CONFIG_ID, configId);
      this.prefs.flushSync();
      LLog.info(TAG, `记录最后运行配置: configId=${configId}`);
    } catch (e) {
      LLog.error(TAG, { error: e, message: 'Failed to set lastOpenConfigId' });
    }
  }

  clearLastOpenConfigId(): void {
    if (!this.prefs) {
      return;
    }
    try {
      this.prefs.putSync(VPN_SELF_HEAL_KEY_LAST_OPEN_CONFIG_ID, -1);
      this.prefs.flushSync();
    } catch (e) {
      LLog.error(TAG, { error: e, message: 'Failed to clear lastOpenConfigId' });
    }
  }
}

export const vpnSelfHealPrefs = new VpnSelfHealPrefsImpl();

/**
 * VPN进程级自愈模型
 *
 * 解决纯血鸿蒙上主进程/VEA进程被系统策略杀死后VPN无法恢复的问题：
 * - 检测手段（三条，按感知速度排列）：
 *   1) VPN 承载网络事件（netLost）：VEA 进程消失 / 隧道被系统拆除 → VPN 网络随之拆除，
 *      实测 337/367ms 到达主进程，是"进程消失"类故障的主通道；
 *   2) 亮屏公共事件（COMMON_EVENT_SCREEN_ON）：用户点亮屏幕瞬间立即自检；
 *   3) 定时轮询兜底：覆盖 netLost 不产生的"功能死"（进程壳在、心跳停），
 *      以及进程被冻结期间错过的网络事件（解冻后第一个 tick 补齐）。
 * - 判定条件（两层）：
 *   1) 进程级：":vpn" 进程已消失；
 *   2) 功能级（轮询专属）：进程壳在但数据心跳超时（VEA_SILENCE_TIMEOUT_MS
 *      未收到任何VEA流日志广播）——覆盖"线程阻塞/隧道被系统拆除而壳仍在"
 *      的半死场景（真机实证：此场景下isOpen状态因收不到STOP广播一直为true，
 *      进程级检测完全失明，VPN断网且无任何恢复动作）。
 * - 恢复动作：复用 WireGuard.runWGConfig 完整启动路径（与UI手动开启一致）。
 * - 防护措施：30s冷却 + recovering防重入 + 连续失败上限（MAX_RECOVER_FAIL），防止拉起失败形成死循环。
 * - 结果确认：恢复指令下发后进入活跃窗口（RECOVER_ACTIVE_WINDOW_MS），窗口内VEA自行停止
 *   视为自愈失败（保留记录累计失败）；连接成功（状态广播running=true）后才提示用户。
 *
 * 生命周期由EntryAbility管理：onCreate启动、onDestroy停止。
 */
class VpnSelfHealModelImpl {
  /** 亮屏事件订阅句柄 */
  private screenOnSubscriber?: commonEventManager.CommonEventSubscriber = undefined;
  /** VPN 承载网络订阅句柄（BEARER_VPN；用于净实时感知 VEA 进程消失，见 startVpnNetWatch） */
  private vpnNetConn?: connection.NetConnection = undefined;
  /** 上次由 netLost 触发探测的时刻（毫秒），用于事件风暴防抖 */
  private lastVpnNetLostProbeAtMs: number = 0;
  /** 轮询定时器句柄 */
  private pollTimerId: number = -1;
  /** 冷启动恢复延迟定时器句柄 */
  private coldStartTimerId: number = -1;
  /** 恢复流程进行中标志（防重入） */
  private recovering: boolean = false;
  /** 上次恢复尝试时间戳（冷却窗口） */
  private lastRecoverAtMs: number = 0;
  /** 自动恢复连续失败次数（成功后复位，达上限后停止自动尝试） */
  private recoverFailCount: number = 0;
  /** 恢复指令已下发，等待VEA连接成功后提示（避免指令成功但连接失败时误导用户） */
  private pendingRecoverConfirm: boolean = false;
  /** 最近一次收到VEA数据广播的时间戳（0=从未收到；"VEA功能存活"的判据） */
  private lastVeaDataAtMs: number = 0;
  /** 当前配置的keepalive秒数（0=用户取消保活；START_VPN广播下发），F18阈值联动依据 */
  private keepaliveIntervalSeconds: number = 25;
  /** 最近一次收到 VEA「隧道重连中」声明的时间戳（0=从未声明）。
   * 声明窗口内使用 VEA_RECONNECT_SILENCE_TIMEOUT_MS 这一更短的"功能死"阈值。 */
  private lastReconnectDeclaredAtMs: number = 0;

  /** F18阈值自适应联动：keepalive>0用标准90s；=0（用户取消）时空闲期仅rekey
   * （120s周期）产生流量心跳，90<120会误判功能死，放宽至150s */
  setKeepaliveIntervalSeconds(seconds: number): void {
    const v = seconds > 0 ? seconds : 0;
    if (this.keepaliveIntervalSeconds === v) { return; }
    this.keepaliveIntervalSeconds = v;
    LLog.info(TAG, `功能死检测阈值联动keepalive=${v}s，心跳超时阈值${this.effectiveSilenceTimeoutMs() / 1000}s`);
  }

  private effectiveSilenceTimeoutMs(): number {
    return this.keepaliveIntervalSeconds > 0 ? VEA_SILENCE_TIMEOUT_MS : VEA_SILENCE_TIMEOUT_NO_KEEPALIVE_MS;
  }

  /**
   * 记录 VEA 主动声明的"隧道重连中"（VPN_RECONNECTING 广播，由 EntryAbility 转发）。
   *
   * 这是"VEA 自己承认当前不在正常态"，与"健康但空闲"有本质区别，因此可以套用
   * 更短的静默阈值（VEA_RECONNECT_SILENCE_TIMEOUT_MS）来快速判定卡死。
   */
  notifyReconnecting(): void {
    this.lastReconnectDeclaredAtMs = Date.now();
  }

  /** 是否仍处于"VEA 已声明重连"的有效窗口内 */
  private inReconnectDeclaredWindow(nowMs: number): boolean {
    return this.lastReconnectDeclaredAtMs > 0 &&
      nowMs - this.lastReconnectDeclaredAtMs < VEA_RECONNECT_DECLARE_TTL_MS;
  }
  /** 自愈监测启动时间（冷启动后lastVeaDataAtMs为0时的功能死判定基准） */
  private modelStartedAtMs: number = 0;
  /** 正在强制销毁功能死VEA（销毁会引发自杀式STOP广播，recordStatus据此区分用户关闭） */
  private killingStaleVea: boolean = false;
  /** 自杀式STOP是否已处理（同一销毁流程内只保留一次记录；第二次STOP=真实用户关闭） */
  private staleStopHandled: boolean = false;

  /**
   * 启动自愈监测（在EntryAbility onCreate中调用）
   */
  startWatching(context: common.UIAbilityContext): void {
    vpnSelfHealPrefs.init(context);
    this.modelStartedAtMs = Date.now();
    // 订阅亮屏事件：用户点亮屏幕瞬间立即自检
    try {
      this.screenOnSubscriber = commonEventManager.createSubscriberSync({
        events: [commonEventManager.Support.COMMON_EVENT_SCREEN_ON],
      });
      commonEventManager.subscribe(this.screenOnSubscriber, (err: BusinessError) => {
        if (err) {
          LLog.error(TAG, `订阅亮屏事件回调异常: code=${err.code}, message=${err.message}`);
          return;
        }
        this.checkAndRecover('screenOn');
      });
      LLog.info(TAG, '已订阅亮屏事件');
    } catch (e) {
      LLog.error(TAG, { error: e, message: '订阅亮屏事件失败' });
    }
    // 事件驱动主通道：订阅 VPN 承载网络消失（netLost），近实时感知 VEA 进程消失
    this.startVpnNetWatch();
    // 定时轮询兜底（功能死检测 + 进程冻结期间暂停，解冻后恢复）
    if (this.pollTimerId < 0) {
      this.pollTimerId = setInterval(() => {
        this.checkAndRecover('poll');
      }, POLL_INTERVAL_MS);
    }
  }

  /**
   * 停止自愈监测（在EntryAbility onDestroy中调用）
   */
  stopWatching(): void {
    if (this.screenOnSubscriber) {
      commonEventManager.unsubscribe(this.screenOnSubscriber);
      this.screenOnSubscriber = undefined;
      LLog.info(TAG, '已取消亮屏事件订阅');
    }
    this.stopVpnNetWatch();
    if (this.pollTimerId >= 0) {
      clearInterval(this.pollTimerId);
      this.pollTimerId = -1;
    }
    if (this.coldStartTimerId >= 0) {
      clearTimeout(this.coldStartTimerId);
      this.coldStartTimerId = -1;
    }
  }

  /**
   * 订阅「VPN 承载类型网络」事件（BEARER_VPN=4），近实时感知 VEA 进程消失。
   *
   * 只订阅 netLost，本身不做恢复动作——统一交给 checkAndRecover('vpnNetLost')，
   * 复用既有门禁（"VPN 本应在运行"判定、防重入、冷却、失败上限）与恢复路径，
   * 不新增第二条恢复实现。
   *
   * 与轮询的分工：本通道只覆盖"VPN 网络被拆除"（进程消失 / 隧道被系统拆除）；
   * "进程壳存活但数据心跳超时"这类功能死不产生 netLost，仍由轮询负责。
   */
  private startVpnNetWatch(): void {
    if (this.vpnNetConn != undefined) {
      return;
    }
    try {
      // 必须显式指定承载类型：默认网络不是 VPN 网络，createNetConnection() 的默认订阅
      // 不会命中 VPN 网络的消失事件（真机实证：用默认订阅收不到 VEA 停止的 netLost）
      this.vpnNetConn = connection.createNetConnection(
        { netCapabilities: { bearerTypes: [connection.NetBearType.BEARER_VPN] } },
        VPN_NET_ACQUIRE_TIMEOUT_MS);
      this.vpnNetConn.on('netLost', () => {
        this.onVpnNetLost();
      });
      this.vpnNetConn.register((err: BusinessError) => {
        if (err) {
          LLog.error(TAG, `VPN 承载网络订阅注册失败: code=${err.code}, message=${err.message}`);
        } else {
          LLog.info(TAG, '已订阅 VPN 承载网络事件（netLost）');
        }
      });
    } catch (e) {
      LLog.error(TAG, { error: e, message: '订阅 VPN 承载网络事件失败' });
    }
  }

  /** 取消 VPN 承载网络订阅（与 startVpnNetWatch 成对） */
  private stopVpnNetWatch(): void {
    if (!this.vpnNetConn) {
      return;
    }
    try {
      this.vpnNetConn.unregister((err: BusinessError) => {
        if (err) {
          LLog.warn(TAG, `VPN 承载网络订阅注销异常: code=${err.code}`);
        } else {
          LLog.info(TAG, '已取消 VPN 承载网络事件订阅');
        }
      });
    } catch (e) {
      LLog.error(TAG, { error: e, message: '取消 VPN 承载网络事件订阅失败' });
    }
    this.vpnNetConn = undefined;
  }

  /**
   * VPN 承载网络消失回调（netLost）——事件驱动主通道的入口。
   *
   * 【为什么必须延后判定】用户主动关闭 VPN 时同样会走到这里（VEA 正常销毁 → VPN 网络
   * 拆除）。此时"VPN 本应在运行"的两条判据尚未同时失效：自愈记录已在关闭指令下发前被
   * 同步清除，但内存 isOpen 要等 VEA 的 STOP_VPN 广播回来才翻 false。延后
   * VPN_NET_LOST_SETTLE_MS 让该广播先落地，再叠加抑制窗口复查，确保"用户关掉的 VPN
   * 不会被自愈重新拉起"。LMK 击杀场景没有 STOP 广播（进程被直接 SIGKILL），
   * isOpen 保持 true、记录有效，故判定照常成立。
   *
   * 【误判为无害】若 VPN 网络消失但 VEA 进程仍存活（如系统重建网络、其他 VPN 接管），
   * checkAndRecover 会探测到 VEA 在运行，且 'vpnNetLost' 不在功能死判定白名单内，
   * 不作任何动作——不存在"误杀健康隧道"的风险。
   */
  private onVpnNetLost(): void {
    const nowMs = Date.now();
    if (nowMs - this.lastVpnNetLostProbeAtMs < VPN_NET_LOST_PROBE_MIN_INTERVAL_MS) {
      return;
    }
    this.lastVpnNetLostProbeAtMs = nowMs;
    if (isUserStopSuppressionActive()) {
      LLog.info(TAG, 'VPN 承载网络消失，但处于用户主动关闭抑制窗口内，不触发自愈');
      return;
    }
    LLog.warn(TAG, `VPN 承载网络已消失（netLost），${VPN_NET_LOST_SETTLE_MS}ms 后判定 VEA 存活状态`);
    setTimeout(() => {
      // 复查抑制窗口：等待期间用户可能恰好手动关闭
      if (isUserStopSuppressionActive()) {
        LLog.info(TAG, '自愈(vpnNetLost)：等待期间检测到用户主动关闭，放弃本次判定');
        return;
      }
      this.checkAndRecover('vpnNetLost').catch((e: BusinessError) => {
        LLog.error(TAG, { error: e, message: '自愈(vpnNetLost)：恢复流程异常' });
      });
    }, VPN_NET_LOST_SETTLE_MS);
  }

  /**
   * VPN状态变化时同步持久化（在EntryAbility收到VPN状态广播处调用）
   *
   * running=true记录配置ID；running=false清除记录（用户主动关闭后不再自愈）。
   */
  recordStatus(running: boolean, configId?: number): void {
    if (running && configId != undefined) {
      if (isUserStopSuppressionActive()) {
        // 用户刚主动关闭：关闭时已同步清除记录，此时到达的running=true是VEA侧的延迟广播，
        // 写回configId会让清除落空（冷启动自愈误判）。其余副作用（失败计数/心跳基准复位）照常执行
        LLog.warn(TAG, `抑制窗口内忽略running=true写入: configId=${configId}`);
      } else {
        vpnSelfHealPrefs.setLastOpenConfigId(configId);
      }
      // VPN真实运行起来（含用户手动开启），自动恢复失败计数复位
      this.recoverFailCount = 0;
      // 重置数据心跳基准：连接刚建立，给VEA一段建立连接并开始心跳的宽限期，
      // 防止残留的旧时间戳在宽限期内被轮询误判为"功能死"而误杀健康VEA
      this.lastVeaDataAtMs = Date.now();
      // 连接已建立：退出"重连态声明"窗口，静默判定回到常规阈值
      this.lastReconnectDeclaredAtMs = 0;
      // 恢复确认：连接真正建立后才提示用户（指令下发成功不等于连接成功）
      if (this.pendingRecoverConfirm) {
        this.pendingRecoverConfirm = false;
        const msg: WGEventThrow = { type: 'info', message: 'VPN曾异常中断，已自动恢复连接' };
        WireGuard.event.publishVpnThrow(msg);
      }
    } else {
      // 隧道已停：无论何种原因，"重连态声明"窗口都不再成立，回落常规静默阈值
      this.lastReconnectDeclaredAtMs = 0;
      if (this.killingStaleVea) {
        if (!this.staleStopHandled) {
          // 功能死自愈强制销毁VEA壳引发的自杀式STOP（onDestroy广播）：
          // 不是用户关闭，保留持久化记录——重拉失败时轮询仍可凭记录重试
          this.staleStopHandled = true;
          LLog.info(TAG, '自愈：检测到销毁VEA引发的STOP，保留自愈记录');
        } else {
          // 同一销毁流程内第二次及以后的STOP = 真实用户关闭（kill窗口内用户操作），
          // 清除记录，防止下轮轮询把用户已关闭的VPN重新拉起
          vpnSelfHealPrefs.clearLastOpenConfigId();
          this.pendingRecoverConfirm = false;
          LLog.info(TAG, '自愈：kill窗口内检测到用户关闭，清除自愈记录');
        }
      } else {
        vpnSelfHealPrefs.clearLastOpenConfigId();
        // 记录清除（用户关闭/服务停止）后，残留的恢复确认提示不再有意义，避免误弹"已自动恢复"
        this.pendingRecoverConfirm = false;
      }
    }
  }

  /**
   * 记录收到VEA数据广播（在EntryAbility的subscribeVpnStreamLogs回调中调用）
   *
   * VEA正常时C++心跳每3秒驱动一条流日志广播（含熧屏期，VEA冻结豁免）；
   * 此时间戳是"VEA功能存活"的判据，供轮询检测功能死使用。
   */
  recordVeaData(): void {
    this.lastVeaDataAtMs = Date.now();
  }

  /**
   * VEA流日志到达的统一入口（在EntryAbility的subscribeVpnStreamLogs回调中调用）
   *
   * 职责一：刷新数据心跳（见 recordVeaData）。
   * 职责二：识别 native 侧主动上报的"tun fd 失效"信号。
   *
   * 【为什么需要这条信号】tun fd 失效（如系统拆除隧道、fd 被回收）后，
   * UDP keepalive/握手仍照常收发、流日志心跳持续刷新，本模型的
   * "VEA进程消失"与"数据心跳超时90s"两条判据会同时失明，应用进入
   * "图标在、通知在，但应用层全黑洞"的静默故障，只有用户手动关开才能恢复。
   * native 侧在连续重启 tun 读取线程无效后会以
   * (MessageType.INVALID, success=false, msg="TUN_FD_DEAD") 上报，此处据此触发重建。
   *
   * 【必须按 msg 精确匹配】同一通道（success=false + INVALID）还被 native 用于上报
   * 通路故障哨兵 PATH_PROBE_START / SOCKET_REBUILT，那两个由 VEA 自己重解析域名/退避重启
   * 自愈，绝不能再触发"销毁 VEA 重建"——否则 VEA 侧的自愈刚发起就被主进程拆掉。
   *
   * @param log VEA流日志消息
   */
  notifyVeaStreamLog(log: StreamLogMessage): void {
    this.recordVeaData();
    if (log.success === false && log.messageType === MessageType.INVALID && log.msg === 'TUN_FD_DEAD') {
      LLog.error(TAG, `自愈：收到native的tun fd失效上报(msg=${log.msg})，触发VEA销毁重建`);
      this.checkAndRecover('tunDead').catch((e: BusinessError) => {
        LLog.error(TAG, { error: e, message: '自愈(tunDead)：恢复流程异常' });
      });
    }
  }

  /**
   * 恢复尝试是否处于活跃窗口内（在EntryAbility收到STOP_VPN广播时调用）
   *
   * 窗口内VEA自行停止 = 自愈拉起的连接建立失败（如冷启动后服务器不可达），
   * 应计为自愈失败并保留记录，而非当作用户主动关闭清除记录。
   */
  isRecoverWindowActive(): boolean {
    return Date.now() - this.lastRecoverAtMs < RECOVER_ACTIVE_WINDOW_MS;
  }

  /**
   * 自愈恢复尝试失败回调（VEA在活跃窗口内自行停止时由EntryAbility调用）
   */
  notifyRecoverAttemptFailed(): void {
    this.pendingRecoverConfirm = false;
    this.recoverFailCount++;
    LLog.warn(TAG, `自愈：恢复尝试后VEA自行停止（第${this.recoverFailCount}次失败），保留记录等待重试`);
    if (this.recoverFailCount >= MAX_RECOVER_FAIL) {
      LLog.error(TAG, `自愈：连续失败达${MAX_RECOVER_FAIL}次，停止自动尝试`);
      const msg: WGEventThrow = { type: 'info', message: 'VPN自动恢复多次失败，已停止自动尝试，请手动开启' };
      WireGuard.event.publishVpnThrow(msg);
    }
  }

  /**
   * 冷启动恢复入口（在EntryAbility检测到VEA未运行时调用）
   *
   * 主进程被杀重启后内存状态丢失，凭持久化记录延迟触发一次恢复检测。
   */
  tryRecoverOnColdStart(): void {
    if (this.coldStartTimerId >= 0) {
      return;
    }
    this.coldStartTimerId = setTimeout(() => {
      this.coldStartTimerId = -1;
      this.checkAndRecover('coldStart');
    }, COLD_START_DELAY_MS);
  }

  /**
   * 自愈检测主入口
   *
   * 门禁："VPN本应在运行"（内存isOpen 或 持久化记录有效），
   * 且VEA进程已消失，且不在冷却窗口内。
   * 恢复配置来源优先级：内存runningConfigId → 持久化lastOpenConfigId；
   * 配置内容来源：runArg内存缓存（与运行中状态一致）→ 按ID查数据库。
   *
   * @param reason 触发原因（screenOn/poll/coldStart/tunDead），仅用于日志
   */
  async checkAndRecover(reason: string): Promise<void> {
    // acquired：本次调用是否置位了防重入标志——仅置位者在finally中复位，
    // 避免被门禁挡掉的并发调用在首个调用仍在await时误复位标志
    let acquired = false;
    try {
      const statusConfig = WireGuard.config.status.getConfig();
      const isOpenInMemory = statusConfig.isOpen();
      const lastConfigId = vpnSelfHealPrefs.getLastOpenConfigId();
      if (!isOpenInMemory && lastConfigId < 0) {
        // VPN本就不应在运行
        return;
      }
      if (this.recovering) {
        return;
      }
      if (this.recoverFailCount >= MAX_RECOVER_FAIL) {
        return;
      }
      const nowMs = Date.now();
      if (nowMs - this.lastRecoverAtMs < RECOVER_COOLDOWN_MS) {
        return;
      }
      // 防重入标志必须在首个await前置位：screenOn与轮询tick并发时，
      // 若在IPC返回后才置位，两路调用都会通过同步门禁造成双重拉起
      this.recovering = true;
      acquired = true;
      const veaRunning = await WireGuard.tools.isVpnExtensionRunning();
      if (veaRunning) {
        // 进程壳存在：以下两类"半死"场景需进一步判定并恢复。
        // - tunDead：native 主动上报 tun fd 失效（确定性故障，无需心跳判据）
        // - poll：数据心跳超时（功能死）
        // 其余原因（screenOn/onForeground/coldStart）不在此判定：解冻补投的积压广播
        // 可能尚未处理完（lastVeaDataAtMs还是冻结前的旧值），立即检测会误杀健康VEA；
        // 轮询tick距解冻已有间隔，补投早已完成，判定可靠。
        if (reason === 'tunDead') {
          // 确定性故障：native 已确认 fd 失效且连续重启无效（非心跳推断），
          // 不存在"积压广播未处理完"的误判风险，直接进入恢复——
          // 销毁该 VEA 壳后重拉，由系统重新签发 tun 句柄。
          // 冷却/防重入/失败上限仍由本方法前置门禁保证
          await this.killStaleVeaAndRecover(reason);
        } else if (reason === 'poll') {
          const baseline = this.lastVeaDataAtMs > 0 ? this.lastVeaDataAtMs : this.modelStartedAtMs;
          // VEA 自己声明过"重连中" → 不是"健康但空闲"隧道，套用更短的静默阈值：
          // 它承诺马上会有心跳，30s 仍无任何心跳即证明 VEA/隧道已卡死。
          // 这是把"隧道级死亡"的感知从 2 分半压到半分钟内的关键。
          const reconnectDeclared = this.inReconnectDeclaredWindow(nowMs);
          const silenceTimeoutMs = reconnectDeclared
            ? VEA_RECONNECT_SILENCE_TIMEOUT_MS
            : this.effectiveSilenceTimeoutMs();
          if (baseline > 0 && nowMs - baseline >= silenceTimeoutMs) {
            const silentSec = Math.round((nowMs - baseline) / 1000);
            const why = reconnectDeclared ? '（VEA已声明重连中，短阈值）' : '';
            LLog.warn(TAG,
              `自愈(${reason})：静默${silentSec}s ≥ 阈值${silenceTimeoutMs / 1000}s${why}，进入二次确认`);
            // 二次确认：解冻初期积压补投的广播/健康心跳会在窗口内刷新时间戳，
            // 真功能死（已死90秒+）则保持不变。期间recovering持续持有，新tick被挡
            const atCheck = this.lastVeaDataAtMs;
            await this.sleep(VEA_SILENCE_RECHECK_MS);
            if (this.lastVeaDataAtMs === atCheck) {
              await this.killStaleVeaAndRecover(reason);
            } else {
              LLog.info(TAG, `自愈(${reason})：二次确认期间收到VEA数据，撤销功能死判定`);
            }
          }
        }
        return;
      }
      // 确定恢复目标配置ID
      const targetId: number = statusConfig.runningConfigId != undefined ? statusConfig.runningConfigId : lastConfigId;
      if (targetId < 0) {
        LLog.warn(TAG, `自愈(${reason})：状态异常且无有效配置记录，跳过`);
        return;
      }
      // 确定配置内容：runArg缓存与目标ID一致时直接用（热数据），否则按ID查库
      let conf: WGDBConf | undefined = WireGuard.config.runArg.getDbConf();
      if (conf == undefined || WireGuard.config.runArg.getConfigId() != targetId) {
        conf = WireGuard.helper.config.getConfigForId(targetId);
      }
      if (conf == undefined) {
        LLog.warn(TAG, `自愈(${reason})：配置${targetId}已不存在，清除持久化记录`);
        vpnSelfHealPrefs.clearLastOpenConfigId();
        return;
      }
      this.lastRecoverAtMs = Date.now();
      LLog.warn(TAG, `自愈(${reason})：VPN应在运行但VEA进程已消失，自动重连 configId=${targetId}`);
      await WireGuard.runWGConfig(targetId, conf, true);
      LLog.info(TAG, `自愈(${reason})：VPN重连指令已下发，等待连接建立后提示`);
      // 成功提示延迟到recordStatus(true)确认连接建立（见pendingRecoverConfirm）
      this.pendingRecoverConfirm = true;
    } catch (e) {
      this.recoverFailCount++;
      LLog.error(TAG, { error: e, message: `自愈(${reason})：自动重连失败（第${this.recoverFailCount}次）` });
      let failMsg: string;
      if (this.recoverFailCount >= MAX_RECOVER_FAIL) {
        LLog.error(TAG, `自愈(${reason})：连续失败达${MAX_RECOVER_FAIL}次，停止自动尝试`);
        failMsg = 'VPN自动恢复多次失败，已停止自动尝试，请手动开启';
      } else {
        failMsg = 'VPN曾异常中断，自动恢复失败，将自动重试';
      }
      const msg: WGEventThrow = { type: 'normal', message: failMsg };
      WireGuard.event.publishVpnThrow(msg);
    } finally {
      if (acquired) {
        this.recovering = false;
      }
    }
  }

  /**
   * VEA功能死恢复：进程壳存在但数据心跳超时（reason==='poll'时经门禁调用）
   *
   * 恢复动作：先强制销毁VEA壳——阻塞中的VEA无法响应任何配置指令，直接
   * runWGConfig会命中15501001（VEA已在运行）被忽略、实际不恢复；销毁后等
   * 进程真正消失，再走完整启动路径（与手动开启一致）。
   *
   * 失败处理：抛出异常由checkAndRecover统一计数（达MAX_RECOVER_FAIL停止）。
   *
   * @param reason 触发原因（仅poll），用于日志
   */
  private async killStaleVeaAndRecover(reason: string): Promise<void> {
    this.killingStaleVea = true;
    this.staleStopHandled = false;
    try {
      const statusConfig = WireGuard.config.status.getConfig();
      const lastConfigId = vpnSelfHealPrefs.getLastOpenConfigId();
      const targetId: number = statusConfig.runningConfigId != undefined ? statusConfig.runningConfigId : lastConfigId;
      if (targetId < 0) {
        LLog.warn(TAG, `自愈(${reason})：功能死判定成立但无有效配置记录，跳过`);
        return;
      }
      let conf: WGDBConf | undefined = WireGuard.config.runArg.getDbConf();
      if (conf == undefined || WireGuard.config.runArg.getConfigId() != targetId) {
        conf = WireGuard.helper.config.getConfigForId(targetId);
      }
      if (conf == undefined) {
        LLog.warn(TAG, `自愈(${reason})：配置${targetId}已不存在，清除持久化记录`);
        vpnSelfHealPrefs.clearLastOpenConfigId();
        return;
      }
      const cause: string = reason === 'tunDead'
        ? 'native上报tun fd失效（重启无效）'
        : `数据心跳超时${this.effectiveSilenceTimeoutMs() / 1000}s（功能死）`;
      LLog.warn(TAG, `自愈(${reason})：VEA进程存活但${cause}，强制销毁后重拉 configId=${targetId}`);
      await this.stopVeaProcess();
      // 等待进程真正消失（阻塞中的VEA销毁可能需要数秒）
      let gone = false;
      for (let i = 0; i < VEA_KILL_WAIT_MAX_TRIES; i++) {
        await this.sleep(VEA_KILL_WAIT_INTERVAL_MS);
        if (!(await WireGuard.tools.isVpnExtensionRunning())) {
          gone = true;
          break;
        }
      }
      if (!gone) {
        throw new Error(`自愈(${reason})：VEA壳销毁后${VEA_KILL_WAIT_MAX_TRIES}s仍在运行，本轮放弃重拉`);
      }
      // 用户意图复查：自杀式STOP已观察（记录保留）→ 继续重拉；
      // 若kill窗口内发生真实用户关闭（第二次STOP清除记录，lastOpenConfigId=-1）→ 尊重用户放弃重拉。
      // 单独的isOpen()==false不构成放弃条件——自杀式STOP同样会置false
      if (!WireGuard.config.status.getConfig().isOpen() && vpnSelfHealPrefs.getLastOpenConfigId() < 0) {
        LLog.info(TAG, `自愈(${reason})：销毁期间VPN已被用户关闭，不再重拉`);
        return;
      }
      this.lastRecoverAtMs = Date.now();
      await WireGuard.runWGConfig(targetId, conf, true);
      this.pendingRecoverConfirm = true;
      LLog.info(TAG, `自愈(${reason})：功能死VEA已销毁并重新拉起，等待连接建立后确认`);
    } finally {
      this.killingStaleVea = false;
    }
  }

  /**
   * 强制销毁VEA进程（stopVpnExtensionAbility由系统VPN服务执行，
   * 不依赖目标进程自身响应，对阻塞中的VEA同样有效）
   */
  private async stopVeaProcess(): Promise<void> {
    const bundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    await vpnExtension.stopVpnExtensionAbility({
      deviceId: '',
      bundleName: bundleInfo.name,
      abilityName: 'WGVpnExtAbility',
    });
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => { resolve(); }, ms);
    });
  }
}

export const vpnSelfHealModel = new VpnSelfHealModelImpl();
