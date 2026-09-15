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
import { connection } from '@kit.NetworkKit';
import { bundleManager, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LLog, errToString } from '../tools/LLog';
import { WireGuard } from '../model/WGHelper';
import { WGDeviceConfig, WGDBConf } from '../model/entity/WGConfigEntity';
import { VpnConnHelper, makeWGConf2VpnStartConfig } from '../model/WGConnect';
import { MessageType, StreamDirection, StreamLogMessage } from '../../../../Index';
import { WGEventThrowParam } from '../error/WGEventThrow';
import WGTools from '../model/WGTools';
import VPNEventStatusParams, { VpnEventTag } from '../model/entity/VPNEventStatusParams';
import { VpnConfigAction, VpnConfigRequestParams } from '../model/entity/VpnConfigAction';
import { SubEventCancel } from '../model/WGEvent';
import { veaNotificationPublisher } from '../model/VeaNotificationPublisher';

const TAG = "vpn_ability_v2"

/** 流日志打印窗口（毫秒）：与广播聚合窗口一致，DATA类汇总打印间隔 */
const STREAM_LOG_PRINT_WINDOW_MS = 3000

/** 流日志窗口统计（用于汇总打印，不做流量统计的权威数据源） */
interface StreamLogStat {
  count: number; // 窗口内总包数
  rxPackets: number; // 窗口内接收包数
  txPackets: number; // 窗口内发送包数
  rxBytes: number; // 窗口内接收字节
  txBytes: number; // 窗口内发送字节
}

/** 重连失败的静默重试间隔：网络恢复事件会即时触发，定时器仅兑底 */
const RECONNECT_RETRY_INTERVAL_MS = 60 * 1000;

/** 配置请求轮询间隔（毫秒）：冷启动/降级场景向主进程要配置的节奏，须与类文档「3秒」一致 */
const CONFIG_QUERY_INTERVAL_MS = 3000;

/** 配置请求最大重试次数：与 CONFIG_QUERY_INTERVAL_MS 相乘即 VEA 存活窗口（≈90s） */
const CONFIG_QUERY_MAX_RETRIES = 30;

/**
 * G1/G2 自动恢复：native 哨兵串（复用既有 success=false + INVALID 流日志通道上报）。
 * - PATH_PROBE_START：看门狗 stage1 —— 90s 无接收，已发强制握手探测
 * - SOCKET_REBUILT：看门狗 stage2 —— 探测后再 90s 无接收，已重建 Socket
 */
const SENTINEL_PATH_PROBE = 'PATH_PROBE_START';
const SENTINEL_SOCKET_REBUILT = 'SOCKET_REBUILT';

/** TUN_FD_DEAD 哨兵由主进程自愈处理（销毁 VEA 重建 tun），VEA 侧不参与 */
const SENTINEL_TUN_FD_DEAD = 'TUN_FD_DEAD';

/** 自动恢复最小间隔：native 哨兵间隔本就 ≥90s，此处防网络事件风暴叠加 */
const AUTO_RECOVER_MIN_INTERVAL_MS = 60 * 1000;

/**
 * P0-1：承载切换快速通道接管窗口（毫秒）。
 * P0-b 重建 Socket 后，onNetworkChanged 的"完整重连（stopServer + start）"不应再执行——
 * 完整重连的唯一理由是"旧 socket 已不可用"，而快速通道刚换过 socket，该理由不成立。
 * 真机实证：13:36:24 快速通道修好、13:36:30.712 数据已正常收发，却在 13:36:30.720
 * 被 onNetworkChanged 的 stopServer 拆掉（中断 40 秒）。窗口取 15s 覆盖握手往返；
 * 超出窗口的真故障仍由 epoch 校验与 native 看门狗（90s+90s）兜底。
 */
const FAST_PATH_TAKEOVER_WINDOW_MS = 15000;

/**
 * P1-1：网络变化事件合并窗口上限（毫秒）。
 * 切换瞬间会连发多个网络事件，全部入队会造成多次 onNetworkChanged 交错执行；
 * 队列中已有待处理任务时合并新事件。此上限是异常兜底：若任务未能复位标志，
 * 超时后放行后续事件，避免"永久合并"导致再也不重连。
 */
const NET_CHANGE_MERGE_MAX_MS = 30 * 1000;

/**
 * P1：DNS 瞬态失败后的短退避重试间隔与次数上限。
 *
 * 为什么不能直接升级 α：承载切换的数百毫秒内出网路径本来就不可用，native 的
 * getaddrinfo 必然拿到 EAI_AGAIN——这是**预期内瞬态**，不是"DNS 服务器不可用"。
 * 真机实证：12:21:31 埋下的重解析在 12:21:39 才返回失败，此时 P0-b 早已把 Socket
 * 修好（fd 46→47、protect OK、握手已发），升级流程却依据**已被推翻的前提**
 * 执行了"整隧道重启"，把快路径 4 秒的成果一次性作废（隧道中断 3 分 38 秒）。
 * 因此失败后先短退避重试（3s × 3 次），耗尽才升级 α。
 */
const DNS_RETRY_DELAY_MS = 3000;
const DNS_RETRY_MAX = 3;

/**
 * P0：升级前的"让帧"时长。
 * autoRecover 的慢操作（DNS 重解析）期间，承载切换等回调可能已排队但尚未执行
 * （JS 线程被同步 NAPI 占用时尤为如此，回调只能等下一个宏任务）。升级前让出
 * 一个宏任务，给这些回调执行机会，再校验世代号，避免"快路径刚修好就被慢路径推翻"。
 */
const RECOVERY_EPOCH_GRACE_MS = 50;

/**
 * α 整隧道重启的指数退避序列（毫秒），末项封顶后无限重复——DDNS 可能数十分钟后才更新，
 * 必须"永不放弃"，但也不能按 90s 的快节奏反复 stop/start（重启风暴 + 心跳断档
 * 会误触发主进程的"功能死"自愈，两套机制叠加成更乱的循环）。
 * 节奏：第1次立即 → 1min → 2min → 5min → 10min → 15min（封顶，持续重试）
 */
const AUTO_RECOVER_BACKOFF_MS: number[] = [60 * 1000, 2 * 60 * 1000, 5 * 60 * 1000, 10 * 60 * 1000, 15 * 60 * 1000];

/**
 * WGVpnExtAbility V2 - 事件驱动的VPN Extension
 *
 * 与V1的区别：
 * - V1：启动时通过 want.parameters 传入配置，切换配置需重启整个Extension
 * - V2：支持want.parameters参数直传（API 22+）+ 轮询降级（API 21及容错），支持热切换/更新/重启配置，无需重启Extension
 *
 * 参数直传模式（API 22+）：
 * - runWGConfig启动VEA时通过want.parameters传递id和wgDbConf（JSON字符串）
 * - onCreate优先从want.parameters读取配置，有效则直接执行VPN连接，跳过轮询延迟
 * - API 22+设备可享受即时启动（延迟<1秒），无需等待轮询
 *
 * 轮询降级模式（API 21及参数丢失场景）：
 * - API 21设备：startVpnExtensionAbility的want.parameters不会传递到onCreate，自动降级为轮询
 * - 参数验证失败时（id缺失/无效、wgDbConf缺失/空/无法反序列化）：静默降级为轮询模式
 * - 轮询模式：3秒间隔请求配置，最多30次，通过CONFIG_QUERY/CONFIG_REQUEST事件获取配置
 *
 * 生命周期：
 * - onCreate：通知主进程VEA存活 → 订阅配置指令 → 尝试want.parameters直传 → 降级轮询
 * - onDestroy：停止VPN连接 → 通知主进程VEA关闭 → 清理资源
 *
 * - START：首次启动VPN连接
 * 配置指令（VpnConfigAction）：
 * - STOP：停止VPN服务但保留VEA进程（用于快速切换）
 * - SWITCH：切换到新配置（先停后启）
 * - RESTART：重启当前配置（DNS重解析）
 *
 * 长时任务由主进程的EntryAbility管理，跟随VEA的vpnThreadRunning状态。
 *
 * Created on 2026/8/27.
 * @author leojay`fu
 */
export default class WGVpnExtAbilityV2 extends VpnExtensionAbility {
  private vpnConnection?: VpnConnHelper;
  private currentConfig?: WGDeviceConfig;
  private currentDbConf?: WGDBConf;
  private currentConfigId?: number;
  private hasDomainEndpoint: boolean = false;
  private isReconnecting: boolean = false;
  private netConnection?: connection.NetConnection;
  // VPN 是否处于运行状态（startServer 成功后为 true，停止/重连期间为 false）
  private isVpnStarted: boolean = false;
  // 自 VPN 启动以来是否发生过网络丢失（网络恢复时用于触发重连自愈）
  private hadNetLostSinceStart: boolean = false;
  // 上次重连发起时间（毫秒），用于限频防止网络抖动导致频繁重启隧道
  private lastReconnectAtMs: number = 0;
  // 重连失败的静默重试定时器（机制Y修复：失败后不停任务不删通知，定时重试）
  private reconnectRetryTimer?: number;
  // 重连待完成标志：隧道已在失败时丢弃（vpnConnection=undefined），重试路径据此
  // 跳过stopServer直接重建；onNetworkChanged的isVpnStarted门禁据此放行重试
  private reconnectPending: boolean = false;
  // V2: 配置请求轮询
  private configQueryTimer?: number;
  private configQueryRetries: number = 0;
  // V2: 事件订阅句柄
  private configRequestCancel?: SubEventCancel;
  private vpnStatusQueryCancel?: SubEventCancel;
  // 主进程下发的通知id订阅句柄（VEA接管通知发布用）
  private notifyIdCancel?: SubEventCancel;
  // 流日志打印聚合：DATA类每包一条info会淹没hilog（实测25~65条/秒），改为3秒汇总一条
  private streamLogStat: StreamLogStat = { count: 0, rxPackets: 0, txPackets: 0, rxBytes: 0, txBytes: 0 };
  private streamLogPrintTimer: number | undefined = undefined;
  // H2修复：配置指令串行化——所有会改动 VPN 状态的指令排入同一 Promise 链依次执行，
  // 避免 STOP/SWITCH/RESTART 相互交错覆盖 vpnConnection/currentConfigId 等共享状态
  private opChain: Promise<void> = Promise.resolve();
  // H2修复：VEA 是否已进入销毁流程；销毁后拒绝一切新的配置指令
  private destroyed: boolean = false;
  // H2修复：VPN 连接是否已拆解；onDestroy 与 STOP 共用 teardownVpn，保证只拆一次
  private vpnTornDown: boolean = false;
  // G1/G2 自动恢复：α 整隧道重启的累计次数（决定退避档位），握手恢复后归零
  private autoRecoverCount: number = 0;
  // G1/G2 自动恢复：上次发起自动恢复的时间（毫秒），用于最小间隔防抖
  private lastAutoRecoverAtMs: number = 0;
  // G1/G2 自动恢复：α 退避重试定时器（存在即表示退避窗口内，避免按哨兵节奏反复重启）
  private autoRecoverTimer?: number;
  // G1/G2 自动恢复：进行中（含 β 下发端点后等待握手确认），收到握手响应即收敛
  private autoRecoverActive: boolean = false;
  // P0-b：上次已知的网络承载类型（'WiFi'/'移动数据'/…），用于识别承载切换（WiFi↔蜂窝）。
  // 首次收到能力事件只做基线记录不触发重建，避免启动瞬间误判为"切换"。
  private lastBearerKey: string = '';
  // P0-b：上次触发承载切换重建的时间（毫秒），用于本地防抖（与 native 侧 3 秒防抖对齐）
  private lastRebindAtMs: number = 0;
  // P0-1：上次"快速通道成功重建 Socket"的时刻（毫秒）。onNetworkChanged 据此在
  // FAST_PATH_TAKEOVER_WINDOW_MS 内跳过整隧道重连，避免拆掉刚修好的隧道。
  private lastFastRebindAtMs: number = 0;
  // P1-1：网络变化检查已排队的时刻（毫秒），0 表示队列中无待处理任务。
  // 正常由任务 finally 复位；另设 NET_CHANGE_MERGE_MAX_MS 过期上限，
  // 万一任务因异常未复位也不会永久吞掉后续网络事件（否则将永久不再重连）。
  private netChangeQueuedAtMs: number = 0;
  // P0：恢复世代号。任何"推翻此前故障前提"的事件（承载切换重建、连接建立、
  // 握手恢复确认、用户操作/生命周期）都使其自增；autoRecover 在慢操作（DNS 重解析）
  // 之前捕获、之后校验，世代已变即静默放弃——避免"快路径已修好、慢路径把它推翻"。
  private recoveryEpoch: number = 0;
  // P1：DNS 瞬态失败短退避重试的计数与定时器（见 DNS_RETRY_* 常量）
  private dnsRetryCount: number = 0;
  private dnsRetryTimer?: number;

  override onCreate(want: Want): void {
    super.onCreate(want);
    try {
      // 1. 先订阅事件，确保收到主进程回复
      this.vpnStatusQueryCancel = WireGuard.event.subscribeVpnStatusQuery(() => {
        VPNChangeHelperV2.queryStatus(this.currentConfig);
      });

      this.configRequestCancel = WireGuard.event.subscribeVpnConfigRequest((params) => {
        this.onConfigRequest(params);
      });

      // 订阅主进程下发的通知id：VEA用同一id发布通知内容，
      // 主进程死亡（长时任务随之回收）后可无缝接管通知刷新
      this.notifyIdCancel = WireGuard.event.subscribeVpnNotificationId((id: number) => {
        veaNotificationPublisher.setNotificationId(id);
      });

      // 2. 通知主应用进程：VEA进程已启动（主进程收到后订阅CONFIG_QUERY并回复配置）
      VPNChangeHelperV2.onCreate();

      // 3. 尝试从want.parameters直接获取配置参数（API 22+支持，API 21降级为轮询）
      if (this.tryStartFromWantParameters(want)) {
        LLog.info(TAG, "WGVpnExtAbilityV2 onCreate - 参数直传模式，跳过轮询");
      } else {
        // 参数无效或不存在，降级到轮询模式
        LLog.info(TAG, "WGVpnExtAbilityV2 onCreate - 降级轮询模式");
        this.startConfigQueryPolling();
      }

      LLog.info(TAG, "WGVpnExtAbilityV2 onCreate");
    } catch (e) {
      const t = e as BusinessError;
      LLog.error(TAG, e);
      VPNChangeHelperV2.startVpnThrow(`${t.message}\n${t.stack}`);
      this.selfTerminate();
    }
  }

  /**
   * 尝试从want.parameters中读取id和wgDbConf并直接启动VPN
   *
   * API 22+：startVpnExtensionAbility支持want.parameters传递，可直接获取配置
   * API 21及以下：want.parameters不会传递到onCreate，自动降级为轮询模式
   *
   * @param want 启动时传入的Want对象
   * @returns true=参数有效并已启动VPN，false=参数无效需降级轮询
   */
  private tryStartFromWantParameters(want: Want): boolean {
    const params = want.parameters;
    if (params == null || params == undefined) {
      return false;
    }

    // 读取id参数
    const rawId = params['id'];
    if (rawId == undefined || rawId == null) {
      return false;
    }
    const id = Number(rawId);
    if (isNaN(id)) {
      return false;
    }

    // 读取wgDbConf参数（JSON字符串）
    const rawWgDbConf = params['wgDbConf'];
    if (rawWgDbConf == undefined || rawWgDbConf == null) {
      return false;
    }
    const wgDbConfStr = String(rawWgDbConf);
    if (wgDbConfStr.length === 0) {
      return false;
    }

    // 反序列化wgDbConf并验证结构
    let wgDbConf: WGDBConf;
    try {
      wgDbConf = JSON.parse(wgDbConfStr) as WGDBConf;
      if (wgDbConf == null || wgDbConf.name == undefined || wgDbConf.conf == undefined) {
        return false;
      }
    } catch (e) {
      LLog.warn(TAG, 'want.parameters中wgDbConf反序列化失败，降级轮询');
      return false;
    }

    // 参数有效，直接执行VPN连接（H2修复：经串行链调度）
    LLog.info(TAG, 'want.parameters参数有效: id=' + id.toString());
    this.enqueueOp('START(want)', () => this.handleStartConfig(id, wgDbConf));
    return true;
  }

  override onDestroy(): void {
    super.onDestroy();
    LLog.info(TAG, "WGVpnExtAbilityV2 onDestroy");

    // H2修复：标记进入销毁流程，后续配置指令一律拒绝，避免与 onDestroy 并发交错
    this.destroyed = true;

    // 停止配置请求轮询
    this.stopConfigQueryPolling();
    // 停止重连静默重试定时器
    this.clearReconnectRetry();
    // 销毁：清空自动恢复（退避计数/定时器/进行中标记）
    this.resetAutoRecover();

    // 取消事件订阅
    if (this.configRequestCancel != undefined) {
      this.configRequestCancel.cancel();
      this.configRequestCancel = undefined;
    }
    if (this.vpnStatusQueryCancel != undefined) {
      this.vpnStatusQueryCancel.cancel();
      this.vpnStatusQueryCancel = undefined;
    }
    if (this.notifyIdCancel != undefined) {
      this.notifyIdCancel.cancel();
      this.notifyIdCancel = undefined;
    }

    // 停止通知发布（VEA销毁后无进程刷新通知，由主进程删除通知）
    veaNotificationPublisher.stop();

    // 落库尾部流日志：汇总打印最后一个不完整窗口，并下发广播聚合队列中的残留消息
    this.stopStreamLogStat();

    // 注销网络监听
    this.unregisterNetConnection();

    // H2修复：拆解 VPN 连接排入串行链，与可能尚未执行的 STOP 指令排序；
    // teardownVpn 幂等，保证 onDestroy 与 handleStopService 不会双重 stopServer
    this.enqueueOp('onDestroy', async () => {
      await this.teardownVpn();
    });

    // 通知主进程VEA关闭（终态广播，始终下发）
    VPNChangeHelperV2.stopVpn();
  }

  // ===== 配置请求轮询 =====

  private startConfigQueryPolling(): void {
    this.stopConfigQueryPolling();
    this.configQueryRetries = 0;

    // 立即发一次
    this.doConfigQuery();

    // 3秒间隔轮询（CONFIG_QUERY_INTERVAL_MS），最多 CONFIG_QUERY_MAX_RETRIES 次：
    // 存活窗口 ≈ 90s（30 × 3s，另含开头立即发送的 1 次）——与类文档「3秒间隔×最多30次」一致。
    // 注：本项由 1000ms 改为 3000ms（原实际窗口仅 ~30s），目的是保证冷启动 / 低端机
    //     主进程 >29s 未下发配置时不致首启失败（selfTerminate 提前关闭 VEA）。
    this.configQueryTimer = setInterval(() => {
      if (this.currentConfig != undefined) {
        this.stopConfigQueryPolling();
        return;
      }
      if (this.configQueryRetries >= CONFIG_QUERY_MAX_RETRIES) {
        LLog.error(TAG, `配置请求超时(${CONFIG_QUERY_MAX_RETRIES}次)，关闭VEA`);
        this.stopConfigQueryPolling();
        this.selfTerminate();
        return;
      }
      this.doConfigQuery();
    }, CONFIG_QUERY_INTERVAL_MS);
  }

  private stopConfigQueryPolling(): void {
    if (this.configQueryTimer != undefined) {
      clearInterval(this.configQueryTimer);
      this.configQueryTimer = undefined;
    }
  }

  private doConfigQuery(): void {
    this.configQueryRetries++;
    WireGuard.event.publishVpnConfigQuery();
    LLog.info(TAG, `配置请求已发送, 第${this.configQueryRetries}次`);
  }

  private selfTerminate(): void {
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((bundleInfo) => {
        vpnExtension.stopVpnExtensionAbility({
          deviceId: '',
          bundleName: bundleInfo.name,
          abilityName: 'WGVpnExtAbility',
        }).catch((e: BusinessError) => {
          LLog.error(TAG, `自关闭VEA失败: ${e.message}`);
        });
      });
  }

  // ===== 配置指令处理 =====

  private onConfigRequest(params: VpnConfigRequestParams): void {
    const action = params.action as VpnConfigAction;
    LLog.info(TAG, `收到配置指令: action=${action}, configId=${params.configId}`);

    // H2修复：VEA 已进入销毁流程，忽略后续指令
    if (this.destroyed) {
      LLog.warn(TAG, `VEA已销毁，忽略配置指令: action=${action}`);
      return;
    }

    // H2修复：所有会改动 VPN 状态的指令统一经 enqueueOp 串行调度并统一 catch，
    // 避免 async handler 的 rejection 无人接管、以及指令之间的状态交错
    switch (action) {
      case VpnConfigAction.START: {
        const startId = params.configId;
        const startConf = params.wgDbConf;
        if (startId != undefined && startConf) {
          this.enqueueOp('START', () => this.handleStartConfig(startId, startConf));
        } else {
          LLog.error(TAG, 'START指令缺少configId或wgDbConf');
        }
        break;
      }
      case VpnConfigAction.STOP:
        this.enqueueOp('STOP', () => this.handleStopService());
        break;
      case VpnConfigAction.SWITCH: {
        const switchId = params.configId;
        const switchConf = params.wgDbConf;
        if (switchId != undefined && switchConf) {
          this.enqueueOp('SWITCH', () => this.handleSwitchConfig(switchId, switchConf));
        } else {
          LLog.error(TAG, 'SWITCH指令缺少configId或wgDbConf');
        }
        break;
      }
      case VpnConfigAction.RESTART:
        this.enqueueOp('RESTART', () => this.handleRestartConfig(params.configId));
        break;
      default:
        LLog.warn(TAG, `未知action: ${action}`);
        break;
    }
  }

  /**
   * H2修复：把会改动 VPN 状态的指令排入串行链。
   * 每个任务在前一个完成后才执行，任务自身异常统一在此捕获，
   * 避免 async handler 的 rejection 逃逸（ArkTS 严格模式下可能触发未处理异常告警）。
   */
  private enqueueOp(name: string, task: () => Promise<void>): void {
    this.opChain = this.opChain
      .then(() => task())
      .catch((e: BusinessError) => {
        LLog.error(TAG, `配置指令执行异常(${name}): ${e.message}`);
      });
  }

  /**
   * H2修复：停止并释放 VPN 连接（onDestroy 与 handleStopService 共用）。
   * 幂等：重复调用只执行一次；返回 true 表示本次真正执行了拆解。
   * 注意 native 侧 close() 有 _isFinish 幂等守卫，但 destroy() 二次调用可能抛错，
   * 故用 vpnTornDown 保证 stopServer 只被调用一次。
   */
  private async teardownVpn(): Promise<boolean> {
    if (this.vpnTornDown) {
      LLog.info(TAG, 'VPN连接已拆解，跳过重复拆解');
      return false;
    }
    this.vpnTornDown = true;

    try {
      await this.vpnConnection?.stopServer();
      LLog.info(TAG, '停止VPN成功');
    } catch (e) {
      const err = e as BusinessError;
      LLog.error(TAG, `停止VPN连接异常: ${err.message}`);
    }
    this.vpnConnection = undefined;
    this.isVpnStarted = false;
    return true;
  }

  /**
   * START：首次启动VPN连接
   */
  private async handleStartConfig(configId: number, wgDbConf: WGDBConf): Promise<void> {
    // H2修复：销毁后拒绝启动
    if (this.destroyed) {
      LLog.warn(TAG, 'VEA已销毁，忽略START');
      return;
    }
    // 新一次启动：允许后续 STOP/onDestroy 再次拆解
    this.vpnTornDown = false;
    // 用户主动启动：清空上一次故障的自动恢复状态
    this.resetAutoRecover();

    // 停止轮询
    this.stopConfigQueryPolling();

    // 存储配置
    this.currentConfigId = configId;
    this.currentDbConf = wgDbConf;

    // 启动VPN（await 使串行链覆盖到 DNS 解析与启动阶段）
    await this.resolveAndStartVpn(configId, wgDbConf);
  }

  /**
   * STOP：停止VPN服务但保留VEA进程
   */
  private async handleStopService(): Promise<void> {
    LLog.info(TAG, '停止VPN服务（保留VEA进程）');
    // H2修复：VEA 已进入销毁流程时 onDestroy 已完成拆解与终态广播，此处直接跳过
    if (this.destroyed) {
      LLog.warn(TAG, 'VEA已销毁，忽略STOP');
      return;
    }
    // 用户主动停止：取消静默重试（重连中标志一并复位）
    this.reconnectPending = false;
    this.clearReconnectRetry();
    // 用户主动停止：清空自动恢复（退避计数/定时器/进行中标记）
    this.resetAutoRecover();

    // H2修复：与 onDestroy 共用幂等 teardownVpn，避免双重 stopServer
    const didTeardown = await this.teardownVpn();

    // 注销网络监听
    this.unregisterNetConnection();

    // 清理配置状态
    this.currentConfig = undefined;
    this.hasDomainEndpoint = false;
    this.isReconnecting = false;

    // 更新VPN进程本地状态
    WireGuard.config.status.vpnStop();

    // 停止通知发布：用户主动关闭VPN，通知由主进程stopLongTask删除，
    // VEA不再发布（避免已删除的通知被VEA重建）
    veaNotificationPublisher.stop();

    // 落库尾部流日志：汇总打印最后一个不完整窗口，并下发广播聚合队列中的残留消息
    this.stopStreamLogStat();

    // 通知主进程：VPN服务停止但VEA存活。
    // H2修复：仅在本次真正执行了拆解时才广播——若 onDestroy 已抢先拆解并下发
    // stopVpn（vpnThreadRunning=false），再补发 vpnThreadRunning=true 的
    // serviceStopped 会使主进程状态非单调（VEA 实际已亡却被判为存活）
    if (didTeardown) {
      VPNChangeHelperV2.serviceStopped();
    }
  }

  /**
   * SWITCH：切换到新配置（先停后启）
   */
  private async handleSwitchConfig(configId: number, wgDbConf: WGDBConf): Promise<void> {
    LLog.info(TAG, `切换VPN配置: configId=${configId}`);
    // H2修复：销毁后拒绝切换
    if (this.destroyed) {
      LLog.warn(TAG, 'VEA已销毁，忽略SWITCH');
      return;
    }
    // 切换会启动新连接：允许后续 STOP/onDestroy 再次拆解
    this.vpnTornDown = false;
    // 用户主动切换：取消静默重试（重连中标志一并复位）
    this.reconnectPending = false;
    this.clearReconnectRetry();
    // 用户主动切换：清空上一次故障的自动恢复状态
    this.resetAutoRecover();
    // 复位上一配置的流日志统计，避免新旧配置数据累加
    this.resetStreamLogStat();

    // 1. 停止旧连接
    try {
      await this.vpnConnection?.stopServer();
    } catch (e) {
      LLog.error(TAG, `停止旧VPN连接异常: ${JSON.stringify(e)}`);
    }
    this.vpnConnection = undefined;

    // 2. 注销网络监听
    this.unregisterNetConnection();

    // 3. 更新配置
    this.currentConfigId = configId;
    this.currentDbConf = wgDbConf;
    this.currentConfig = undefined;
    this.isReconnecting = false;
    this.isVpnStarted = false;

    // 4. 启动新配置（await 使串行链覆盖到 DNS 解析与启动阶段）
    await this.resolveAndStartVpn(configId, wgDbConf);
  }

  /**
   * RESTART：重启当前配置（DNS重解析）
   */
  private async handleRestartConfig(configId?: number): Promise<void> {
    LLog.info(TAG, `重启VPN配置: configId=${configId ?? this.currentConfigId}`);
    // H2修复：销毁后拒绝重启
    if (this.destroyed) {
      LLog.warn(TAG, 'VEA已销毁，忽略RESTART');
      return;
    }
    // 重启会重建连接：允许后续 STOP/onDestroy 再次拆解
    this.vpnTornDown = false;
    // 主动重启：取消静默重试（重启流程自身会重建隧道）
    this.reconnectPending = false;
    this.clearReconnectRetry();
    // 主动重启：清空自动恢复的退避状态（避免与本次重启叠加）
    this.resetAutoRecover();
    // 复位流日志统计，避免重启前后的数据累加
    this.resetStreamLogStat();

    // 如果有新configId则更新
    if (configId != undefined) {
      this.currentConfigId = configId;
    }

    // 必须有缓存的数据库配置才能重启
    if (!this.currentDbConf || this.currentConfigId == undefined) {
      LLog.warn(TAG, '无缓存配置，无法重启，发送配置请求');
      this.startConfigQueryPolling();
      return;
    }
    const restartId: number = this.currentConfigId;
    const restartConf: WGDBConf = this.currentDbConf;

    // 停止旧连接
    try {
      await this.vpnConnection?.stopServer();
    } catch (e) {
      LLog.error(TAG, `停止旧VPN连接异常: ${JSON.stringify(e)}`);
    }
    this.vpnConnection = undefined;
    this.isVpnStarted = false;
    this.currentConfig = undefined;
    this.isReconnecting = false;

    // 用缓存的配置重新启动（await 使串行链覆盖到 DNS 解析与启动阶段）
    await this.resolveAndStartVpn(restartId, restartConf);
  }

  // ===== VPN启动（复用V1核心逻辑） =====

  private async resolveAndStartVpn(id: number, wgDbConf: WGDBConf): Promise<void> {
    // M6修复：START/SWITCH/RESTART 三条路径都会汇聚到此，统一在 DNS 解析前停止配置轮询。
    // 原实现仅 handleStartConfig 停止轮询，SWITCH/RESTART 路径下定时器会在解析窗口内
    // 继续发 CONFIG_QUERY（此时 currentConfig 尚未置位，轮询不自停），最多 30 次后
    // selfTerminate 销毁 VEA，打断本应完成的切换/重启。
    this.stopConfigQueryPolling();
    try {
      const config = await makeWGConf2VpnStartConfig(wgDbConf);
      // 喂养通知数据：配置名 + 目标端点（数据源头在VEA，主进程死亡后通知仍能展示）
      const endpoints: Record<number, string> = {};
      wgDbConf.conf.peers.forEach((peer, index) => {
        endpoints[index] = `${peer.endpoint.ipStrOrDomain}:${peer.endpoint.port}`;
      });
      veaNotificationPublisher.updateConfigInfo(wgDbConf.name, endpoints);
      this.currentConfig = config;
      this.hasDomainEndpoint = this.checkHasDomainEndpoint(wgDbConf);
      this.startVpnInternal(id, config);
      // 所有配置都注册网络监听：锁屏/网络切换后的重连自愈不能只依赖域名解析变化
      LLog.info(TAG, this.hasDomainEndpoint ? "域名配置" : "非域名配置");
      this.registerNetConnection();
    } catch (e) {
      LLog.error(TAG, `DNS解析或VPN启动失败: ${JSON.stringify(e)}`);
      VPNChangeHelperV2.startVpnThrow(`${e instanceof Error ? e.message : String(e)}`);
      this.selfTerminate();
    }
  }

  /** 是否为握手类消息（低频、承载关键状态，不参与日志/广播聚合） */
  private static isHandshakeMessage(msg: StreamLogMessage): boolean {
    return msg.messageType === MessageType.HANDSHAKE_INITIATION ||
      msg.messageType === MessageType.HANDSHAKE_RESPONSE ||
      msg.messageType === MessageType.HANDSHAKE_COOKIE;
  }

  /**
   * 累加DATA类流日志统计并按需启动汇总打印定时器
   *
   * 每个数据包打一条info在忙时可达25~65条/秒，既淹没hilog也拖慢VEA；
   * 改为固定3秒节奏打一条窗口汇总，静默期（count=0）不打印避免空转刷屏。
   */
  private accumulateStreamLogStat(msg: StreamLogMessage): void {
    const stat = this.streamLogStat;
    stat.count++;
    if (msg.direction === StreamDirection.RECEIVE) {
      stat.rxPackets++;
      stat.rxBytes += msg.sc.length;
    } else {
      stat.txPackets++;
      stat.txBytes += msg.sc.length;
    }
    if (this.streamLogPrintTimer === undefined) {
      this.streamLogPrintTimer = setInterval(() => {
        this.printStreamLogStat();
      }, STREAM_LOG_PRINT_WINDOW_MS);
    }
  }

  /** 复位流日志统计与汇总定时器（切换/重启配置时调用，避免统计跨配置累加） */
  private resetStreamLogStat(): void {
    if (this.streamLogPrintTimer !== undefined) {
      clearInterval(this.streamLogPrintTimer);
      this.streamLogPrintTimer = undefined;
    }
    this.streamLogStat.count = 0;
    this.streamLogStat.rxPackets = 0;
    this.streamLogStat.txPackets = 0;
    this.streamLogStat.rxBytes = 0;
    this.streamLogStat.txBytes = 0;
  }

  /** 打印窗口内流日志汇总并清零（静默期不打印） */
  private printStreamLogStat(): void {
    const stat = this.streamLogStat;
    if (stat.count === 0) {
      return;
    }
    LLog.info(TAG,
      `Peer数据流汇总(${STREAM_LOG_PRINT_WINDOW_MS / 1000}s): 包数=${stat.count} ` +
        `接收=${stat.rxPackets}包/${stat.rxBytes}B 发送=${stat.txPackets}包/${stat.txBytes}B`);
    stat.count = 0;
    stat.rxPackets = 0;
    stat.txPackets = 0;
    stat.rxBytes = 0;
    stat.txBytes = 0;
  }

  /**
   * 停止流日志汇总打印并落库尾部数据
   *
   * VPN停止/VEA销毁时调用：先打印最后一个不完整窗口的统计，
   * 再把广播聚合队列里的残留消息发出去，避免尾部流量丢失。
   */
  private stopStreamLogStat(): void {
    if (this.streamLogPrintTimer !== undefined) {
      clearInterval(this.streamLogPrintTimer);
      this.streamLogPrintTimer = undefined;
    }
    this.printStreamLogStat();
    WireGuard.event.flushVpnStreamLogs();
  }

  private startVpnInternal(id: number, config: WGDeviceConfig, fromReconnect: boolean = false): void {
    LLog.debug(TAG, `开启配置:${JSON.stringify(config)}`);
    const myHelper = new VpnConnHelper(vpnExtension.createVpnConnection(this.context), config)
      .setStreamListener((msg) => {
        // 【必须容错】以下三段任何异常都不得阻断下游处理：
        // 尤其 publishVpnStreamLogs 是主进程"VEA数据心跳"的唯一来源，漏发会让
        // 健康VEA在90秒后被自愈判据误判为"功能死"而遭销毁重拉。
        // 握手事件与故障上报(success=false / INVALID)低频且承载关键状态，立即打印；
        // DATA事件按包打印会淹没hilog（实测25~65条/秒），改由3秒汇总打印
        try {
          const isFault: boolean = msg.success === false || msg.messageType === MessageType.INVALID;
          if (isFault) {
            const mtype: string = WGTools.getMessageTypeDesc(msg.messageType);
            LLog.warn(TAG,
              `Peer 异常流日志(index:${msg.peerIndex}/${mtype}/${msg.msg})，已上报主进程触发自愈`);
            // G1/G2：native 通路故障哨兵 → 重新解析域名端点（β），必要时退避重启（α）
            this.handleFaultSentinel(msg);
          } else if (WGVpnExtAbilityV2.isHandshakeMessage(msg)) {
            const mtype: string = WGTools.getMessageTypeDesc(msg.messageType);
            LLog.info(TAG,
              `Peer 握手(index:${msg.peerIndex}/${mtype}/Result:${msg.success}) ${msg.msg}`);
            // G4：收到对端握手响应即"通路确实恢复"，收敛自动恢复状态
            // （取消退避重试、计数归零、通知状态词回到"运行中"）
            if (msg.messageType === MessageType.HANDSHAKE_RESPONSE &&
              msg.direction === StreamDirection.RECEIVE && msg.success === true) {
              // P0：恢复流程进行中收到握手响应 = 通路确实恢复，立刻作废在途升级。
              // 这一枪覆盖"DNS 重解析/重启准备期"这段慢窗口——那时 autoRecoverActive
              // 尚未置位，finishAutoRecover 内部的门禁不会触发，必须在此补齐；
              // 否则会出现"隧道已经握手通了，几秒后却被自己发起的老升级拆掉"。
              if (this.isReconnecting && !this.autoRecoverActive) {
                this.bumpRecoveryEpoch('恢复期间收到握手响应');
              }
              this.finishAutoRecover();
            }
          } else if (msg.sc != undefined) {
            this.accumulateStreamLogStat(msg);
          }
        } catch (e) {
          LLog.error(TAG, { error: e, message: '流日志打印/统计异常，跳过' });
        }
        try {
          // 喂养通知数据：流量统计与握手时间（VEA是数据源头）
          veaNotificationPublisher.updateStreamLog(msg);
        } catch (e) {
          LLog.error(TAG, { error: e, message: '通知数据喂养异常，跳过' });
        }
        try {
          WireGuard.event.publishVpnStreamLogs(msg);
        } catch (e) {
          LLog.error(TAG, { error: e, message: '流日志广播下发异常' });
        }
      });
    this.vpnConnection = myHelper;

    // 双启动守卫：startServer为fire-and-forget，耗时若超过重连限频（5秒），
    // 网络恢复期的事件风暴可再次进入本方法替换vpnConnection；回调据此
    // 识别自己已过时，避免旧失败把新连接置空（双隧道/健康隧道被误清）
    myHelper.startServer()
      .then(() => {
        if (this.vpnConnection !== myHelper) {
          LLog.warn(TAG, "过时的startServer成功回调（连接已被更新接管），跳过");
          return;
        }
        this.isVpnStarted = true;
        this.hadNetLostSinceStart = false;
        // P0：连接已建立 = 通路前提整体更新，作废任何仍在途的旧故障恢复流程
        this.bumpRecoveryEpoch('连接建立');
        // 通知数据喂养：记录启动时间（返回值随广播下发，两端通知共用同一时间戳）
        const startTime = veaNotificationPublisher.markStarted();
        // 重连成功：清除静默重试定时器、重连待完成标志与“重连中”状态，回到正常运行态
        this.clearReconnectRetry();
        this.reconnectPending = false;
        veaNotificationPublisher.setReconnecting(false);
        const connectedIps: Record<number, string> = {};
        config.peers.forEach((peer, index) => {
          connectedIps[index] = peer.endpoint.address.ip;
        });
        veaNotificationPublisher.updateConnectedIps(connectedIps);
        VPNChangeHelperV2.startVpn(id, config, startTime);
      })
      .catch((e: BusinessError) => {
        LLog.error(TAG, `VPN Error (${e.code}): ${e.message}`);
        if (this.vpnConnection !== myHelper) {
          LLog.warn(TAG, "过时的startServer失败回调（连接已被更新接管），跳过");
          return;
        }
        if (fromReconnect) {
          // 重连失败不抛THROW不停任务不自杀（机制Y修复）：网络抖动一次就全拆
          // 一套（主进程stopBackgroundRunning删通知+VEA自杀后60s自愈重建）代价
          // 远超收益；改为保留长时任务与通知（“重连中”），静默重试。
          // 失败连接直接丢弃：重试路径无需再stopServer
          this.vpnConnection = undefined;
          this.enterReconnectRetry(e.message);
          return;
        }
        VPNChangeHelperV2.startVpnThrow(e.message);
        this.selfTerminate();
      });
  }

  // ===== 网络监听与DNS重连（复用V1逻辑） =====

  private checkHasDomainEndpoint(dbConf: WGDBConf): boolean {
    for (const peer of dbConf.conf.peers) {
      const value = peer.endpoint.ipStrOrDomain;
      if (!this.isDirectIp(value)) {
        return true;
      }
    }
    return false;
  }

  private isDirectIp(ip: string): boolean {
    const ipv4Regex = /^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$/;
    const ipv6Regex = /^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$/;
    return ipv4Regex.test(ip) || ipv6Regex.test(ip);
  }

  /**
   * H2修复：网络变化重连同样经串行链调度。
   * 原实现直接调用 onNetworkChanged（async），其内部 await stopServer 期间
   * 若并发的 STOP 指令进入，会二次 stopServer；纳入同一操作链后可避免该类交错。
   */
  private scheduleNetworkChanged(): void {
    // P1-1：切换瞬间会连发多个网络事件（netAvailable / netConnectionPropertiesChange…），
    // 全部入队会导致多次 onNetworkChanged 交错执行（真机实测单次切换触发 7 个事件：
    // netLost×1 + netAvailable×1 + netCapabilitiesChange×3 + propertiesChange×2）。
    // 仅当队列中没有待处理任务时才入队，把同一波事件合并为一次重连检查。
    if (this.netChangeQueuedAtMs > 0 &&
      Date.now() - this.netChangeQueuedAtMs < NET_CHANGE_MERGE_MAX_MS) {
      LLog.info(TAG, '网络变化检查已排队，合并本次事件');
      return;
    }
    this.netChangeQueuedAtMs = Date.now();
    this.enqueueOp('netChanged', async () => {
      try {
        await this.onNetworkChanged();
      } finally {
        this.netChangeQueuedAtMs = 0;
      }
    });
  }

  private registerNetConnection(): void {
    try {
      // 先注销旧监听，避免重复注册泄漏（如 RESTART 流程）
      this.unregisterNetConnection();
      this.netConnection = connection.createNetConnection();
      this.netConnection.on('netAvailable', () => {
        LLog.info(TAG, "网络可用变化，触发重连检查");
        this.scheduleNetworkChanged();
      });
      this.netConnection.on('netLost', () => {
        LLog.warn(TAG, "网络丢失，标记待网络恢复后重连");
        this.hadNetLostSinceStart = true;
      });
      this.netConnection.on('netCapabilitiesChange', (data: connection.NetCapabilityInfo) => {
        const type = this.getNetTypeDescription(data);
        LLog.info(TAG, `网络能力变化: ${type}`);
        // P0-b：承载类型变化（WiFi↔蜂窝）是"本地 socket 立即失效"的确定性信号，
        // 不等解析是否变化、不等看门狗 90s+90s，直接重建 socket（不重启隧道）
        this.onBearerChanged(type);
      });
      this.netConnection.on('netConnectionPropertiesChange', () => {
        LLog.info(TAG, "网络连接属性变化，触发重连检查");
        this.scheduleNetworkChanged();
      });
      this.netConnection.register(() => {
        LLog.info(TAG, "网络状态监听注册成功");
      });
    } catch (e) {
      LLog.error(TAG, `注册网络监听失败: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 承载特征串（用 4→3→2→1 的完备性归一化，而不是"先判蜂窝"的优先级）。
   *
   * 为什么不能按优先级短路：netCapabilitiesChange 上报的是**网络的能力集合**，
   * 多 bearer 并存（WiFi 与蜂窝同时可用）是常态。原实现"先判 CELLULAR"会把
   * WiFi+蜂窝 一并说成"移动数据"——于是 WiFi→蜂窝 的真实切换在两端的特征串
   * 完全相同，被 onBearerChanged 当作"承载未变"直接跳过，**P0-b 静默失效**
   * （即"快速通道明明装了却不起作用"）。
   *
   * 返回 'WiFi'/'移动数据' 单值，或 'WiFi+移动数据' 组合串；组合串参与比较，
   * 使集合层面的变化（蜂窝加入/退出）也能被识别。
   */
  private getNetTypeDescription(data: connection.NetCapabilityInfo): string {
    const bearers = data.netCap.bearerTypes;
    const hasWifi = bearers.includes(connection.NetBearType.BEARER_WIFI);
    const hasCell = bearers.includes(connection.NetBearType.BEARER_CELLULAR);
    if (hasWifi && hasCell) {
      return 'WiFi+移动数据';
    }
    if (hasWifi) {
      return 'WiFi';
    }
    if (hasCell) {
      return '移动数据';
    }
    if (bearers.includes(connection.NetBearType.BEARER_ETHERNET)) {
      return '以太网';
    }
    return '未知网络';
  }

  /**
   * P0-b：承载类型变化（WiFi↔蜂窝）→ 立即重建本地 Socket（不重启隧道）。
   *
   * 为什么必须重建：socket 由 native 创建后交给 vpnConnection.protect(fd)，它绑定在
   * "创建时的默认网络"上；WiFi 接口被移除后该 fd 立即不可用。而原先这条快速通道
   * 根本不存在——netCapabilitiesChange 只打了一行日志，于是只能等 native 看门狗
   * 90s+90s 兜底重建，这正是"WiFi→蜂窝要等很久才恢复"的根因。
   *
   * 为什么走 native 而非 stopServer/startServer：整隧道重启会销毁 VEA 进程，
   * 长时任务与通知栏都要重建（还有主进程 60s 轮询尾巴）；重建 socket 只换本地 fd，
   * 隧道/VEA/通知全部不动，恢复在毫秒~秒级。
   *
   * 触发条件（须全部满足）：已记录过上一次承载（首次仅做基线）→ WiFi/蜂窝 参与情况
   * 发生变化（承载集合的比较，见 isCarrierSwitch）→ VPN 正在运行且未销毁 →
   * 距上次重建 ≥3s（与 native 防抖一致）。
   */
  private onBearerChanged(type: string): void {
    const prev = this.lastBearerKey;
    if (type === prev) {
      return;
    }
    // 无论是否触发重建，都先记住最新承载类型作为下次比较的基线
    this.lastBearerKey = type;
    if (!prev) {
      // 首次收到能力事件（VPN 刚起）：只记录基线，避免把"初始状态"误判为切换
      return;
    }
    // WiFi/蜂窝任一"参与情况"发生变化即视为承载切换。
    // 比"prev/type 恰好等于两个单值"更宽：WiFi→'WiFi+移动数据'（蜂窝加入）同样命中，
    // 因为此时出站路径可能已切到蜂窝，本地 fd 需要重建才能跟上。
    const prevWifi = prev.includes('WiFi');
    const nowWifi = type.includes('WiFi');
    const prevCell = prev.includes('移动数据');
    const nowCell = type.includes('移动数据');
    const isCarrierSwitch = prevWifi !== nowWifi || prevCell !== nowCell;
    if (!isCarrierSwitch) {
      LLog.info(TAG, `承载类型变化（非WiFi↔蜂窝）：${prev} → ${type}，不触发重建`);
      return;
    }
    const helper = this.vpnConnection;
    if (this.destroyed || !helper) {
      LLog.warn(TAG, `承载切换（${prev}→${type}）时无活动VPN连接，跳过重建`);
      return;
    }
    // 刻意不再用 `!this.isVpnStarted` 作守卫：isVpnStarted 在"启动/整体重连"窗口内
    // 会先被置 false（onNetworkChanged 在 stopServer() 之前置 false、handleStartConfig
    // 解析域名期间等），此时连接对象仍在、本地 socket 仍绑在旧承载上——直接跳过就会
    // 漏掉这次承载切换（真机实测出现过 `承载切换（WiFi→移动数据）时VPN未运行，跳过重建`）。
    // 改由 native 自判：设备未运行 / 读取线程不可用时 forceRebindSocket 会返回 false，
    // 最坏只是一次无副作用的空调用，不会误伤正在进行的启停流程。
    const nowMs = Date.now();
    if (nowMs - this.lastRebindAtMs < 3000) {
      LLog.info(TAG, `承载切换重建距上次不足3秒（${prev}→${type}），跳过本次`);
      return;
    }
    this.lastRebindAtMs = nowMs;
    // P0：承载切换是"本地通路已换"的确定性事实 —— 此前所有在途恢复（尤其是那条
    // 依据旧通路判定、异步重解析后要升级 α 的流程）所依赖的前提就此失效，必须作废。
    // 这是"P0-b 重建即作废在途升级"的落点：本回调不经 opChain，能在 autoRecover
    // await 期间穿插执行，及时把世代号推上去。
    this.bumpRecoveryEpoch(`承载切换 ${prev}→${type}`);
    LLog.warn(TAG, `承载切换（${prev}→${type}），立即重建Socket（不重启隧道）`);
    // P0-1：接管窗口必须"触发即武装"——本回调不经 opChain，而 onNetworkChanged
    // 走的是 opChain，两者可能几乎同时进入；若等 forceRebindSocket() 的 promise
    // 返回后才记录，守卫会在这段毫秒级空档里漏挡，仍可能把刚重建的隧道拆掉。
    // 记账时刻一并留作"撤销凭证"：只有仍是本次武装的值才允许撤销。
    const armedAtMs = nowMs;
    this.lastFastRebindAtMs = armedAtMs;
    // 直接调用 native 快速通道：刻意不走 opChain，避免被在途的 DNS 解析/启停操作排队阻塞
    helper.forceRebindSocket().then((ok: boolean) => {
      if (ok) {
        LLog.warn(TAG, `承载切换Socket重建已受理（${prev}→${type}）`);
      } else {
        // 未被受理（防抖窗口内/设备未运行等）：接管并未发生，撤销武装，
        // 让后续 onNetworkChanged 的完整重连兜底（否则会静默漏挡 15 秒）
        if (this.lastFastRebindAtMs === armedAtMs) {
          this.lastFastRebindAtMs = 0;
        }
        LLog.warn(TAG, `承载切换Socket重建未被受理（${prev}→${type}），由看门狗加速兜底`);
      }
    }).catch((e: Error) => {
      if (this.lastFastRebindAtMs === armedAtMs) {
        this.lastFastRebindAtMs = 0;
      }
      LLog.error(TAG, `承载切换Socket重建异常（${prev}→${type}）: ${e.message}`);
    });
  }

  private unregisterNetConnection(): void {
    // 与 registerNetConnection 成对：注销监听时清空承载基线，
    // 使下一次启动重新建立基线（否则跨启动的承载差异会被误判为"切换"）
    this.lastBearerKey = '';
    if (this.netConnection) {
      try {
        this.netConnection.unregister(() => {
          LLog.info(TAG, "网络状态监听注销成功");
        });
      } catch (e) {
        LLog.error(TAG, `注销网络监听失败: ${JSON.stringify(e)}`);
      }
      this.netConnection = undefined;
    }
  }

  private async onNetworkChanged(): Promise<void> {
    // H2修复（续）：VEA 已进入销毁流程时拒绝重连。
    // 本方法现经 enqueueOp 串行调度，可能排在 onDestroy 之后才轮到执行；
    // 若此时仍走 startVpnInternal，会在 VEA 已销毁后重新拉起一条隧道
    // （连接泄漏 + 主进程状态错乱）。网络监听虽已在 onDestroy 注销，
    // 但"已入队"的任务仍会执行，故必须在此显式拦截。
    if (this.destroyed) {
      LLog.warn(TAG, 'VEA已销毁，忽略网络变化重连');
      return;
    }
    if (this.isReconnecting || !this.currentDbConf || this.currentConfigId == undefined) {
      return;
    }
    // reconnectPending：静默重试路径放行（startServer失败后isVpnStarted=false，
    // 若无此标志重试回调与网络恢复事件都会被下一行挡死，重试链永久断裂）
    if (!this.isVpnStarted && !this.reconnectPending) {
      // VPN 未运行（含注册监听后的首次回调），无需处理
      return;
    }
    const nowMs = Date.now();
    if (nowMs - this.lastReconnectAtMs < 5000) {
      LLog.info(TAG, "距上次重连不足5秒，跳过本次重连");
      return;
    }
    if (!this.hasDomainEndpoint && !this.hadNetLostSinceStart) {
      // IP直连配置：未发生过断网的网络波动不做重连（避免频繁重启隧道），底层看门狗兑底
      LLog.info(TAG, "网络变化（IP直连且未断网），跳过重连，由底层看门狗自愈");
      return;
    }

    this.isReconnecting = true;
    LLog.info(TAG, "网络环境变化，开始重连VPN");

    try {
      let newConfig = this.currentConfig!;
      if (this.hasDomainEndpoint) {
        newConfig = await makeWGConf2VpnStartConfig(this.currentDbConf);
        const endpointChanged = this.checkEndpointChanged(this.currentConfig!, newConfig);
        if (!endpointChanged && !this.hadNetLostSinceStart) {
          LLog.info(TAG, "域名解析结果未变化且未断网，无需重连");
          return;
        }
        if (endpointChanged) {
          LLog.info(TAG, "域名解析结果已变化，重新连接VPN");
        }
      }

      if (this.reconnectPending) {
        // 静默重试路径：失败连接已在失败时丢弃（vpnConnection=undefined），
        // 无需stopServer直接重建；同步最新DNS解析结果（DDNS场景服务器IP
        // 已变化时陈旧配置会永续失败），成功/失败仍走startVpnInternal的回调链
        this.lastReconnectAtMs = Date.now();
        this.currentConfig = newConfig;
        this.startVpnInternal(this.currentConfigId, newConfig, true);
        return;
      }

      // P0-1：快速通道刚接管过 Socket（承载切换时已重建并强制重握手），此时"完整重连"
      // 的唯一理由（旧 socket 绑定失效）已不成立；若仍执行 stopServer，会把刚修好、
      // 甚至已恢复数据收发的隧道拆掉（真机实证：拆于恢复后 8 毫秒，中断 40 秒）。
      const fastAgeMs = this.lastFastRebindAtMs > 0 ? Date.now() - this.lastFastRebindAtMs : -1;
      if (fastAgeMs >= 0 && fastAgeMs < FAST_PATH_TAKEOVER_WINDOW_MS) {
        LLog.warn(TAG, `快速通道已在 ${fastAgeMs} ms 前重建 Socket，跳过整隧道重连（不重启隧道）`);
        return;
      }
      this.lastReconnectAtMs = Date.now();
      this.isVpnStarted = false;
      await this.vpnConnection?.stopServer();
      LLog.info(TAG, "旧VPN连接已停止");
      this.vpnConnection = undefined;
      this.currentConfig = newConfig;
      this.hadNetLostSinceStart = false;
      this.startVpnInternal(this.currentConfigId, newConfig, true);
    } catch (e) {
      LLog.error(TAG, `网络变化重连异常: ${errToString(e)}`);
      if (this.vpnConnection) {
        // stopServer/DNS解析失败：旧隧道大概率仍在运行（isVpnStarted已恢复），
        // 保持运行态不做“重连中”标记（避免误报），重连交由下次网络事件触发
        this.isVpnStarted = true;
        LLog.warn(TAG, `重连准备失败但旧连接仍在运行，等待下次网络事件重试`);
        return;
      }
      // 隧道已停止但重建准备失败：进入静默重试（机制Y：保留任务与通知）
      this.enterReconnectRetry(`${e instanceof Error ? e.message : String(e)}`);
    } finally {
      this.isReconnecting = false;
    }
  }

  /**
   * 重连失败后的静默重试（机制Y修复）：
   * 保留长时任务与通知（两端状态词“重连中”），60秒后自动重试；
   * 网络恢复事件（netAvailable/propertiesChange）会即时触发onNetworkChanged。
   * 曾经的实现是startVpnThrow+selfTerminate：主进程删通知、VEA自杀后靠
   * 60s自愈重建，网络抖动一次就全拆一套，用户感知为通知反复消失。
   */
  private enterReconnectRetry(reason: string): void {
    LLog.warn(TAG, `VPN重连失败，进入静默重试（60秒后自动重试，网络恢复即时触发）: ${reason}`);
    // P0：重连失败 → 后续由重试路径承载恢复，此前在途的哨兵驱动升级已无意义
    this.bumpRecoveryEpoch('重连失败转入静默重试');
    // 断网标记保持true：确保重试与网络恢复事件不被“IP直连且未断网”检查跳过
    this.hadNetLostSinceStart = true;
    // 重连待完成标志：onNetworkChanged的isVpnStarted门禁据此放行重试
    this.reconnectPending = true;
    veaNotificationPublisher.setReconnecting(true);
    VPNChangeHelperV2.vpnReconnecting();
    if (this.reconnectRetryTimer == undefined) {
      this.reconnectRetryTimer = setTimeout(() => {
        this.reconnectRetryTimer = undefined;
        this.scheduleNetworkChanged();
      }, RECONNECT_RETRY_INTERVAL_MS);
    }
  }

  private clearReconnectRetry(): void {
    if (this.reconnectRetryTimer != undefined) {
      clearTimeout(this.reconnectRetryTimer);
      this.reconnectRetryTimer = undefined;
    }
  }

  private checkEndpointChanged(oldConfig: WGDeviceConfig, newConfig: WGDeviceConfig): boolean {
    if (oldConfig.peers.length !== newConfig.peers.length) {
      return true;
    }
    for (let i = 0; i < oldConfig.peers.length; i++) {
      const oldPeer = oldConfig.peers[i];
      const newPeer = newConfig.peers[i];
      if (oldPeer.endpoint.address.ip !== newPeer.endpoint.address.ip ||
        oldPeer.endpoint.address.isIpv4 !== newPeer.endpoint.address.isIpv4) {
        LLog.info(TAG, `Peer[${i}] 端点变化: ${oldPeer.endpoint.address.ip} -> ${newPeer.endpoint.address.ip}`);
        return true;
      }
    }
    return false;
  }

  // ===== G1/G2 自动恢复：端点漂移重解析（β）+ 整隧道重启退避（α） =====

  /**
   * native 通路故障哨兵分发（在流日志回调内调用，不得阻塞）。
   *
   * 两个哨兵都表达"UDP 通路可能已换网 / 对端地址已漂移"，"重新解析域名"是共同的第一动作：
   * - PATH_PROBE_START（看门狗 stage1）：只做 β（重解析，有变化才下发端点，不重启隧道）。
   *   无变化时保留 native 的 90s 探针窗口，不贸然重启。
   * - SOCKET_REBUILT（看门狗 stage2）：探测窗口已用完、native 已重建 Socket 仍无接收。
   *   此时若解析结果无变化，说明"重建 Socket"是无效动作（根因是地址/通路失效），
   *   退化为 α 整隧道重启（带指数退避）。
   * - TUN_FD_DEAD：由主进程 VpnSelfHealModel 自愈（销毁 VEA 重建 tun），VEA 侧不处理。
   */
  private handleFaultSentinel(msg: StreamLogMessage): void {
    if (msg.msg === SENTINEL_TUN_FD_DEAD) {
      return;
    }
    if (msg.msg !== SENTINEL_PATH_PROBE && msg.msg !== SENTINEL_SOCKET_REBUILT) {
      return;
    }
    // stage1 只允许 β；stage2 允许升级为 α 整隧道重启
    this.scheduleAutoRecover(msg.msg, msg.msg === SENTINEL_SOCKET_REBUILT, false);
  }

  /**
   * 自动恢复同样经串行链调度（与 STOP/SWITCH/RESTART 同链），
   * 避免其 stopServer/startVpnInternal 与用户指令交错改写连接状态。
   *
   * @param reason 触发原因（哨兵串 / '退避重试'），仅用于日志
   * @param allowRestart true=允许升级为整隧道重启（stage2 哨兵 / 退避定时器）
   * @param fromRetry true=由内部退避定时器驱动（自身节奏已受控，跳过最小间隔防抖）
   */
  private scheduleAutoRecover(reason: string, allowRestart: boolean, fromRetry: boolean): void {
    if (this.destroyed) {
      return;
    }
    this.enqueueOp('autoRecover', () => this.autoRecover(reason, allowRestart, fromRetry));
  }

  /**
   * 自动恢复主流程：β 优先（推端点、不重启），β 无法生效时 α 兜底（整隧道重启 + 退避）。
   *
   * @param reason 触发原因（哨兵串或"退避重试"），仅用于日志
   * @param allowRestart true=允许升级为整隧道重启（stage2 哨兵 / 退避定时器）；
   *                     false=仅做 β（stage1 哨兵，保留 native 探针窗口）
   * @param fromRetry true=退避定时器驱动，跳过最小间隔防抖（避免恰好 60s 的边界被误杀）
   */
  private async autoRecover(reason: string, allowRestart: boolean, fromRetry: boolean): Promise<void> {
    if (this.destroyed) {
      return;
    }
    if (!this.hasDomainEndpoint) {
      // IP 直连没有"重新解析"的对象；通路故障交给 native 看门狗重建 Socket / 重新 protect
      LLog.info(TAG, `自动恢复跳过（IP直连，无重解析价值）: ${reason}`);
      return;
    }
    if (this.isReconnecting || this.reconnectPending) {
      LLog.info(TAG, `自动恢复跳过（重连流程进行中）: ${reason}`);
      return;
    }
    if (!this.isVpnStarted || !this.currentConfig || !this.currentDbConf ||
      this.currentConfigId == undefined) {
      LLog.info(TAG, `自动恢复跳过（隧道未运行）: ${reason}`);
      return;
    }
    const nowMs = Date.now();
    if (!fromRetry && nowMs - this.lastAutoRecoverAtMs < AUTO_RECOVER_MIN_INTERVAL_MS) {
      // 仅对"哨兵驱动"的调用做最小间隔防抖；退避重试由自身节奏控制
      LLog.info(TAG, `自动恢复跳过（距上次不足${AUTO_RECOVER_MIN_INTERVAL_MS / 1000}秒）: ${reason}`);
      return;
    }
    this.lastAutoRecoverAtMs = nowMs;
    this.isReconnecting = true;
    // P0：捕获本次恢复的世代基线。下面这次 DNS 重解析是**秒级慢操作**（真机实测 4~8s，
    // 期间还会经历同步 NAPI 阻塞），完全可能在这段时间里被 P0-b 承载切换重建 /
    // 新连接建立 / 握手恢复确认抢先完成——那时本次升级依据的前提已经不存在了。
    const epoch = this.recoveryEpoch;
    try {
      // 1) 重新解析（β 的前提：拿到最新 DNS 结果）
      let newConfig: WGDeviceConfig;
      try {
        newConfig = await makeWGConf2VpnStartConfig(this.currentDbConf);
        // 解析成功：本次恢复不再处于"DNS 瞬态失败"状态
        this.dnsRetryCount = 0;
      } catch (e) {
        // P0：慢操作结束先校验世代 —— 通路可能早已被快路径修好，绝不能再按旧前提升级
        if (this.isRecoveryEpochStale(epoch, reason)) {
          return;
        }
        // P1：切换窗口内 DNS 出网短暂不可用属预期瞬态，短退避重试，不直接升级 α。
        // 原实现"一次解析失败即判 DNS 不可用 → 整隧道重启"正是本次 3 分 38 秒中断的成因。
        if (this.dnsRetryCount < DNS_RETRY_MAX) {
          this.dnsRetryCount++;
          LLog.warn(TAG,
            `自动恢复：重解析失败（瞬态，第${this.dnsRetryCount}/${DNS_RETRY_MAX}次），` +
              `${DNS_RETRY_DELAY_MS / 1000}秒后重试: ${errToString(e)}`);
          this.armDnsRetry(reason, allowRestart);
          return;
        }
        this.dnsRetryCount = 0;
        LLog.error(TAG, `自动恢复：重解析连续失败${DNS_RETRY_MAX}次（DNS 不可用），退化为整隧道重启: ${errToString(e)}`);
        // 升级前再让一帧并复核世代：给可能已排队的承载切换回调执行机会
        if (await this.isEscalationStale(epoch, reason)) {
          return;
        }
        await this.startFullRestart(this.currentConfig, reason);
        return;
      }

      // P0：解析期间的"让帧"与世代复核 —— 若期间发生承载切换重建/新连接建立，
      // 说明故障前提已被推翻，本次升级整体作废（绝不降级为整隧道重启）。
      if (await this.isEscalationStale(epoch, reason)) {
        return;
      }

      // 2) 找出发生漂移的 Peer（按配置顺序比较 IP，与 native peerIndex 一致）
      const changed: number[] = [];
      for (let i = 0; i < newConfig.peers.length; i++) {
        const oldPeer = this.currentConfig.peers[i];
        const newPeer = newConfig.peers[i];
        if (!oldPeer || !newPeer) {
          continue;
        }
        if (oldPeer.endpoint.address.ip !== newPeer.endpoint.address.ip ||
          oldPeer.endpoint.address.isIpv4 !== newPeer.endpoint.address.isIpv4) {
          changed.push(i);
        }
      }

      if (changed.length > 0) {
        LLog.warn(TAG,
          `自动恢复(β)：端点漂移 peers=[${changed.join(',')}]（触发=${reason}），下发新端点，不重启隧道`);
        const pushed = await this.pushPeerEndpoints(newConfig, changed);
        if (pushed) {
          // β 成功：更新本地配置视图，进入"等待握手确认"态（握手到达后 finishAutoRecover 收敛）
          this.currentConfig = newConfig;
          this.autoRecoverActive = true;
          // G4：等待确认期间也要让用户看到"重连中"，避免死隧道仍显示"运行中"
          veaNotificationPublisher.setReconnecting(true);
          VPNChangeHelperV2.vpnReconnecting();
          LLog.warn(TAG, '自动恢复(β)：新端点已下发并强制重握手，等待握手确认');
          return;
        }
        // P0：下发过程是 await 的，期间可能已被承载切换重建等方法修好通路；升级前复核
        if (await this.isEscalationStale(epoch, reason)) {
          return;
        }
        // 端点有变化但下发失败（socket 已不可用 / Peer 未找到）：β 无从生效，直接 α
        LLog.error(TAG, '自动恢复(β)：端点下发失败（socket 可能已不可用），退化为整隧道重启');
      } else if (allowRestart) {
        // 探测窗口已用完且解析结果未变化：只有整隧道重启能重建 VpnConnection +
        // 重新 protect + 重新解析（对"换网后 socket 绑定失效"同样有效）
        LLog.warn(TAG, `自动恢复(α)：探测后仍无接收且端点未变化（触发=${reason}），退化为整隧道重启`);
      } else {
        // stage1 只报告"可能漂移"：无变化时把 90s 探针窗口留给 native 看门狗，
        // 探针若也失败，stage2（SOCKET_REBUILT）会带 α 兜底
        LLog.info(TAG, '自动恢复：stage1 无端点变化，保留看门狗探针窗口，暂不重启隧道');
        return;
      }

      // 3) α：整隧道重启（带指数退避）。升级前最后一道世代闸门。
      if (await this.isEscalationStale(epoch, reason)) {
        return;
      }
      await this.startFullRestart(newConfig, reason);
    } finally {
      this.isReconnecting = false;
    }
  }

  /**
   * β：把重解析后的端点逐个下发给 native（每个漂移 Peer 一次）。
   * 任一失败即视为 β 失败（调用方退化为 α），避免"半更新"的连接状态。
   */
  private async pushPeerEndpoints(config: WGDeviceConfig, indexes: number[]): Promise<boolean> {
    const helper = this.vpnConnection;
    if (!helper) {
      LLog.error(TAG, '自动恢复(β)：vpnConnection 已不存在，无法下发端点');
      return false;
    }
    let allOk = true;
    for (const i of indexes) {
      const peer = config.peers[i];
      if (!peer) {
        allOk = false;
        continue;
      }
      try {
        const ok = await helper.updatePeerEndpoint(i, peer.endpoint.address.ip, peer.endpoint.port);
        LLog.warn(TAG,
          `自动恢复(β)：peer[${i}] 端点下发结果=${ok} -> ${peer.endpoint.address.ip}:${peer.endpoint.port}`);
        if (!ok) {
          allOk = false;
        }
      } catch (e) {
        allOk = false;
        LLog.error(TAG, `自动恢复(β)：peer[${i}] 端点下发异常: ${JSON.stringify(e)}`);
      }
    }
    return allOk;
  }

  /**
   * α：整隧道重启（stopServer + startVpnInternal）+ 挂下一次退避重试。
   *
   * 用于 β 无法生效的场景（端点未变化 / 下发失败）。整隧道重启能重建 VpnConnection、
   * 重新 protect、重新解析，对"换网后 socket 绑定失效"等 β 覆盖不到的通路故障有效。
   * 退避序列封顶 15 分钟后持续重试（永不放弃——DDNS 可能数十分钟后才更新），
   * 但绝不按哨兵节奏（90s）反复重启，避免重启风暴与心跳断档误触发主进程"功能死"自愈。
   */
  private async startFullRestart(config: WGDeviceConfig, reason: string): Promise<void> {
    if (this.destroyed || this.currentConfigId == undefined) {
      return;
    }
    if (this.autoRecoverTimer != undefined) {
      // 退避窗口内（已有未到期的重试）：不叠加新的整隧道重启
      LLog.info(TAG, `自动恢复(α)：退避窗口内，跳过本次整隧道重启: ${reason}`);
      return;
    }
    const id: number = this.currentConfigId;
    this.autoRecoverCount++;
    LLog.warn(TAG, `自动恢复(α)：整隧道重启 第${this.autoRecoverCount}次（触发=${reason}）`);
    this.autoRecoverActive = true;
    // G4：进入自动恢复即把通知状态词切到"重连中"（锁屏/后台唯一用户可见的载体）
    veaNotificationPublisher.setReconnecting(true);
    VPNChangeHelperV2.vpnReconnecting();
    this.lastAutoRecoverAtMs = Date.now();
    // 先挂退避：本次重启若仍失败（如 DDNS 未更新），退避到点后自动重试
    this.armAutoRecoverTimer();
    this.isVpnStarted = false;
    try {
      await this.vpnConnection?.stopServer();
      LLog.info(TAG, '自动恢复(α)：旧隧道已停止');
    } catch (e) {
      LLog.error(TAG, `自动恢复(α)：停止旧隧道异常: ${JSON.stringify(e)}`);
    }
    this.vpnConnection = undefined;
    this.currentConfig = config;
    // fromReconnect=true：启动失败走 enterReconnectRetry 静默重试（不抛错、不 selfTerminate），
    // 与"用户主动重启"的失败路径区分，避免一次网络异常就把长时任务与通知全拆掉
    this.startVpnInternal(id, config, true);
  }

  /**
   * 挂下一次自动恢复的退避定时器。档位由 autoRecoverCount 决定，
   * 超出序列长度后固定用末档（15 分钟）持续重试。
   */
  private armAutoRecoverTimer(): void {
    this.clearAutoRecoverTimer();
    let idx = this.autoRecoverCount - 1;
    if (idx < 0) {
      idx = 0;
    }
    if (idx > AUTO_RECOVER_BACKOFF_MS.length - 1) {
      idx = AUTO_RECOVER_BACKOFF_MS.length - 1;
    }
    const delay = AUTO_RECOVER_BACKOFF_MS[idx];
    LLog.warn(TAG, `自动恢复(α)：${Math.round(delay / 1000)}秒后自动重试（第${this.autoRecoverCount}次后）`);
    this.autoRecoverTimer = setTimeout(() => {
      this.autoRecoverTimer = undefined;
      this.scheduleAutoRecover('退避重试', true, true);
    }, delay);
  }

  private clearAutoRecoverTimer(): void {
    if (this.autoRecoverTimer != undefined) {
      clearTimeout(this.autoRecoverTimer);
      this.autoRecoverTimer = undefined;
    }
  }

  // ===== P0：恢复世代号（在途升级作废） =====

  /**
   * 使所有"在途恢复"失效。
   *
   * 语义 = "此前故障判定所依据的通路前提已被推翻"。调用后，任何在途 autoRecover
   * 会在下一个校验点静默放弃，不会把已经修好的通路再拆一次。
   *
   * 这是本方案的核心修复点：`rebindQuiet_`（native 侧）只能抑制**本次重建自身**
   * 发出的哨兵，无法作废一个**已经飞出**的升级流程。世代号补上的正是这一环。
   */
  private bumpRecoveryEpoch(reason: string): void {
    this.recoveryEpoch++;
    LLog.info(TAG, `恢复世代号 -> ${this.recoveryEpoch}（${reason}）`);
  }

  /**
   * 在途恢复是否已过期（世代号被更新 = 前提已失效）。
   * @returns true=已过期，调用方必须放弃本次恢复
   */
  private isRecoveryEpochStale(epoch: number, reason: string): boolean {
    if (epoch === this.recoveryEpoch) {
      return false;
    }
    LLog.warn(TAG,
      `自动恢复放弃（世代号 ${epoch}→${this.recoveryEpoch}，故障前提已被推翻）: ${reason}`);
    return true;
  }

  /**
   * 升级 α 前的最后一道闸：先让出一个宏任务，再校验世代号。
   *
   * 为什么要"让帧"：若 JS 线程此前被同步 NAPI（如 getaddrinfo）长时间占用，
   * 承载切换等回调会被排进宏任务队列而迟迟不执行；await 之后的续体是微任务，
   * 会抢在这些回调之前运行——直接校验就会漏判。让出一帧可确保已排队的回调先跑。
   */
  private async isEscalationStale(epoch: number, reason: string): Promise<boolean> {
    await this.delay(RECOVERY_EPOCH_GRACE_MS);
    return this.isRecoveryEpochStale(epoch, reason);
  }

  // ===== P1：DNS 瞬态失败短退避 =====

  /**
   * 挂一次"DNS 瞬态失败"后的短退避重试。
   *
   * 复用 scheduleAutoRecover（同一条串行链、同样受 destroyed 门禁），
   * 且刻意**不挂 α 退避**：本轮并未升级为整隧道重启，谈不上"重启退避"。
   */
  private armDnsRetry(reason: string, allowRestart: boolean): void {
    if (this.dnsRetryTimer != undefined) {
      return;
    }
    this.dnsRetryTimer = setTimeout(() => {
      this.dnsRetryTimer = undefined;
      if (this.destroyed) {
        return;
      }
      this.scheduleAutoRecover(`${reason}·DNS重试`, allowRestart, true);
    }, DNS_RETRY_DELAY_MS);
  }

  private clearDnsRetry(): void {
    if (this.dnsRetryTimer != undefined) {
      clearTimeout(this.dnsRetryTimer);
      this.dnsRetryTimer = undefined;
    }
    this.dnsRetryCount = 0;
  }

  /** 让出一个宏任务（给已排队的网络事件回调执行机会） */
  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /**
   * G4：自动恢复收敛（观察到对端握手响应 = 通路确实恢复）。
   * 退避计数归零、取消待重试定时器，并把通知状态词从"重连中"恢复为"运行中"。
   */
  private finishAutoRecover(): void {
    if (!this.autoRecoverActive) {
      return;
    }
    this.autoRecoverActive = false;
    this.autoRecoverCount = 0;
    this.clearAutoRecoverTimer();
    // P0：握手响应到达 = 通路确实恢复，在途的升级/重试所依据的故障前提全部失效
    this.bumpRecoveryEpoch('握手响应确认通路恢复');
    this.clearDnsRetry();
    veaNotificationPublisher.setReconnecting(false);
    // 主进程侧的"重连中"仅由 vpnThreadRunning=true 且非 RECONNECTING/STOPPED 的广播复位，
    // 故复用状态查询广播（携带原始 startTime，不会重置运行时长）
    VPNChangeHelperV2.queryStatus(this.currentConfig);
    LLog.info(TAG, '自动恢复成功：已收到握手响应，退避状态复位');
  }

  /**
   * 用户主动操作（START/SWITCH/RESTART/STOP/销毁）时清空自动恢复状态，
   * 避免上一次故障的退避计数与定时器影响新的连接生命周期。
   */
  private resetAutoRecover(): void {
    this.clearAutoRecoverTimer();
    this.clearDnsRetry();
    this.autoRecoverCount = 0;
    this.autoRecoverActive = false;
    this.lastAutoRecoverAtMs = 0;
    // P0-1：连接前提整体更换，旧的"快速通道接管时刻"一并作废——否则新连接建立后
    // 15 秒内的网络事件会被误判为"刚被快速通道接管"而跳过重连（跨生命周期残留）
    this.lastFastRebindAtMs = 0;
    // P0：用户操作/生命周期切换意味着连接前提整体更换，在途恢复必须一并作废
    this.bumpRecoveryEpoch('用户操作/生命周期切换');
  }
}

/**
 * V2 VPN状态变化辅助类
 *
 * 与V1 VPNChangeHelper的区别：
 * - 新增 serviceStopped()：VPN服务停止但VEA进程存活（vpnThreadRunning=true）
 * - startVpnThrow 不再自动关闭VEA（V2模式下VEA可能继续服务）
 */
class VPNChangeHelperV2 {
  private static cachedConnectedIps?: Record<number, string>;

  static onCreate(): void {
    WireGuard.event.publishVpnChange({ isOpen: false, tag: VpnEventTag.ON_CREATE, vpnThreadRunning: true });
  }

  static startVpn(id: number, config?: WGDeviceConfig, startTime?: number): void {
    WireGuard.config.status.vpnStartRun(id);
    const params: VPNEventStatusParams = { isOpen: true, tag: VpnEventTag.START_VPN, vpnThreadRunning: true, startTime: startTime };
    if (config) {
      const connectedIps: Record<number, string> = {};
      // 取所有peer中最小的keepalive：最保守的心跳频率评估，
      // 主进程F18功能死阈值据此自适应联动（keepalive=0时放宽90s→150s）
      let minKeepalive = Number.MAX_SAFE_INTEGER;
      config.peers.forEach((peer) => {
        const k = peer.keepaliveInterval != undefined ? peer.keepaliveInterval : 0;
        if (k < minKeepalive) { minKeepalive = k; }
      });
      params.keepaliveInterval = minKeepalive === Number.MAX_SAFE_INTEGER ? 0 : minKeepalive;
      config.peers.forEach((peer, index) => {
        connectedIps[index] = peer.endpoint.address.ip;
      });
      params.connectedIps = connectedIps;
      VPNChangeHelperV2.cachedConnectedIps = connectedIps;
    }
    WireGuard.event.publishVpnChange(params);
  }

  static vpnReconnecting(): void {
    // 重连中广播（机制Y修复）：vpnThreadRunning=true语义为“VEA存活且将恢复隧道”，
    // 主进程据此标记“重连中”状态词而保留长时任务与通知（不进停止分支）
    WireGuard.event.publishVpnChange({
      isOpen: true,
      tag: VpnEventTag.VPN_RECONNECTING,
      vpnThreadRunning: true,
      connectedIps: VPNChangeHelperV2.cachedConnectedIps,
    });
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
    // 冷启动恢复路径：主进程重启后经状态查询重建通知，必须同步连接建立时刻，
    // 否则主进程发布的通知缺失运行时长，与VEA侧交替覆盖形成存在性抖动
    if (isOpen) {
      params.startTime = veaNotificationPublisher.getStartTime();
    }
    if (config) {
      const connectedIps: Record<number, string> = {};
      // keepalive随查询回传：主进程重启后内存阈值联动值丢失，
      // 冷启动QUERY_STATUS路径补齐（否则keepalive=0用户重启后被90s旧阈值误杀一次）
      let minKeepalive = Number.MAX_SAFE_INTEGER;
      config.peers.forEach((peer) => {
        const k = peer.keepaliveInterval != undefined ? peer.keepaliveInterval : 0;
        if (k < minKeepalive) { minKeepalive = k; }
      });
      params.keepaliveInterval = minKeepalive === Number.MAX_SAFE_INTEGER ? 0 : minKeepalive;
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
