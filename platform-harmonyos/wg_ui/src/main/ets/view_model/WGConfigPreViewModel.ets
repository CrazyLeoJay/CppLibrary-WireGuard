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
import { pasteboard } from '@kit.BasicServicesKit';
import WGConfigPreViewParams from '../entity/WGConfigPreViewParams';
import {
  LLog,
  StreamLogMessage,
  Tools,
  WGConfPeer,
  WGDBConf,
  WireGuard,
  getDnsMode,
  dnsResolveByMode,
  formatDnsError,
  SiteUrlType,
  vpnKeepAliveManager
} from 'wg_tunnel';
import { JSON } from '@kit.ArkTS';
import { AppStorageV2, UIContext } from '@kit.ArkUI';

const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
const TAG = "配置查看"

@ObservedV2
export default class WGConfigPreViewModel {
  nav: NavPathStack = new NavPathStack();
  params?: WGConfigPreViewParams
  @Trace data?: WGDBConf
  /**
   * 用于判断当前Vpn是否运行中
   * @returns 当前Vpn是否运行中
   */
  @Trace isVpnOpen: boolean = false;
  @Trace logData: WGStreamLogsData = AppStorageV2.connect(WGStreamLogsData, () => new WGStreamLogsData())!;
  @Trace connectedIps: Record<number, string> = {}; // peerIndex -> 实际连接的IP地址
  @Trace peerDnsTestResult: string[] = []; // peerIndex -> 解析测试结果（数组整体重建触发UI刷新）
  /**
   * 是否发生为获取参数异常
   */
  @Trace isVPNNoGetParamThrow: boolean = false;

  constructor() {
    this.updateStatus();
  }

  updateStatus() {
    const state = WireGuard.config.status.getConfig();
    // 开关显示跟随"用户意图"：开关开启且意图配置ID匹配本预览配置即视为开，
    // 不受VPN启动/运行中间广播(running)影响；只有异常/用户关闭(intent回false)才关
    const switchId = state.isSwitchOpen ? state.switchConfigId : undefined;
    const id = this.params?.id;
    this.isVpnOpen = switchId != undefined && id != undefined && switchId == id;
    LLog.info(TAG, `isVpnOpen=${this.isVpnOpen} status: ${JSON.stringify(state)}`)
  }

  @Computed
  get configName(): string {
    return this.data?.name ?? "未命名"
  }

  @Computed
  get client(): WGDBConf | undefined {
    return this.data
  }

  @Computed
  get peers(): WGConfPeer[] {
    return this.data?.conf.peers ?? []
  }

  @Computed
  get getWlanIp(): string {
    return `${this.data?.conf.inter?.ipArea.address.ip}/${this.data?.conf.inter.ipArea?.cidr ??
      (this.data?.conf.inter.ipArea?.address.isIpv4 ? 32 : 128)}`
  }

  get dns(): string {
    return this.data?.conf.inter.dns?.map((it) => it.ip).join(", ") ?? "(未定义)"
  }

  async loadData(params: WGConfigPreViewParams) {
    this.params = params;
    this.data = WireGuard.helper.config.getConfigForId(params.id)
    LLog.info(TAG, `data ${JSON.stringify(this.data)}`);
  }

  async updateData() {
    if (this.params) {
      await this.loadData(this.params);
      if (this.data && WireGuard.config.status.isRunning(this.params.id)) {
        try {
          await WireGuard.switchVpnConfig(this.params.id, this.data);
        } catch (e) {
          LLog.error(TAG, `切换VPN配置失败: ${JSON.stringify(e)}`);
        }
      }
    } else {
      LLog.info(TAG, "没有获取到当前配置ID")
    }
  }

  async copy44KeyToSystem(context: UIContext, content: string) {
    if (!Tools.is44Key(content)) {
      return;
    }
    let pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, content);
    try {
      await systemPasteboard.setData(pasteData);
      LLog.info(TAG, "将公钥复制进入系统剪贴板")
      context.getPromptAction().showToast({
        message: "已复制",
      })
    } catch (error) {
      LLog.info(TAG, `将公钥复制进入系统剪贴板 异常！！！！：${error}`)
    }
  }

  /**
   * 改变Vpn配置，启动或停止
   *
   * 意图驱动流程：点击立即置开关意图与UI显示 → 启动/关闭VPN进程
   * → 开启成功发起即启动长时任务、关闭即停止长时任务；异常则回滚意图并停长时任务。
   */
  async changeVpnConfig(context: UIContext, isOn: boolean) {
    // 当点击启动按钮时，需要设置异常标记为false
    this.isVPNNoGetParamThrow = false;
    const id = this.params?.id;
    const config = this.data;
    if (id == undefined || config == undefined) {
      return;
    }
    const status = WireGuard.config.status.getConfig();
    // 防重复：该配置已是用户意图开启状态
    if (isOn && status.isSwitchOpen && status.switchConfigId == id) {
      return;
    }
    // 1. 立即置开关意图与UI显示（意图先行）
    if (isOn) {
      WireGuard.config.status.switchOnIntent(id);
      this.isVpnOpen = true;
    } else {
      WireGuard.config.status.switchOffIntent();
      this.isVpnOpen = false;
    }
    try {
      // 2. 启动/关闭VPN进程
      await WireGuard.runWGConfig(id, config, isOn)
      // 3. 开启：成功发起启动即启动长时任务；关闭：停止长时任务
      if (isOn) {
        vpnKeepAliveManager.onSwitchOn();
      } else {
        vpnKeepAliveManager.onSwitchOff();
      }
    } catch (e) {
      // 启动/关闭异常 → 回滚意图：开关为关、停止长时任务
      WireGuard.config.status.switchOffIntent();
      this.isVpnOpen = false;
      vpnKeepAliveManager.onSwitchOff();
      WireGuard.event.publishVpnNoOpen()
      // 开启失败展示Toast，关闭操作不展示（用户主动关闭不应提示错误）
      if (isOn) {
        const reason = e != undefined ? String(e) : '';
        context.getPromptAction().showToast({ message: reason.length > 0 ? 'VPN启动失败：' + reason : 'VPN启动失败' })
      }
      LLog.error(TAG, { error: e, message: `${isOn ? "开启" : "关闭"}VPN异常` });
    }
  }


  isSwitchClick: boolean = false;
  @Trace isSwitchEnable: boolean = true;

  onSwitchChange(context: UIContext, isOn: boolean) {
    this.isSwitchEnable = false
    if (this.isSwitchClick) {
      if (isOn) {
        LLog.info(TAG, "点击开启VPN")
        // 等启停流程（含异常回滚）完成后再恢复开关可点，防止快速连点造成操作交错
        this.changeVpnConfig(context, true).finally(() => {
          this.isSwitchEnable = true
        })
      } else {
        LLog.info(TAG, "点击关闭VPN")
        this.changeVpnConfig(context, false).finally(() => {
          this.isSwitchEnable = true
        })
      }
    } else {
      this.isSwitchEnable = true
    }
    this.isSwitchClick = false
  }

  setSwitchClick() {
    this.isSwitchClick = true
  }

  updateStreamParams(log: StreamLogMessage) {
    if (this.isVpnOpen) { // 如果vpn开启才需要更新，后续应该添加接口的 私钥 比对，判断日志是否为当前日志的日志。可以在注册时就指定。
      this.logData.updateLogMessage(log);
      LLog.debug(TAG, `stream log: index=${log.peerIndex} receive=${log.sc.receiveTotal} send=${log.sc.sendTotal ?? 0}`)
    }
  }

  receiveData(index: number): string {
    return WireGuard.Tools.bitsToString(this.logData.getLatestLogForPeer(index)?.sc.receiveTotal ?? 0)
  }

  sendData(index: number): string {
    return WireGuard.Tools.bitsToString(this.logData.getLatestLogForPeer(index)?.sc.sendTotal ?? 0)
  }

  /**
   * 测试指定 Peer 的域名解析（只读测试，不修改配置）
   * @param context UIContext，用于 Toast 提示
   * @param index Peer 索引
   * @throws
   */
  async testPeerDnsResolve(context: UIContext, index: number) {
    const peer = this.data?.conf.peers[index];
    if (!peer) {
      return;
    }
    if (peer.endpoint.type != SiteUrlType.Domain) {
      context.getPromptAction().showToast({ message: "对端地址不是域名，无需DNS解析" });
      return;
    }
    const mode = getDnsMode(peer.endpoint);
    try {
      const ip = await dnsResolveByMode(peer.endpoint.ipStrOrDomain, mode);
      // @Trace 数组需整体重建才触发 UI 刷新
      const newResult: string[] = this.peerDnsTestResult.slice();
      newResult[index] = ip;
      this.peerDnsTestResult = newResult;
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      const newResult: string[] = this.peerDnsTestResult.slice();
      newResult[index] = formatDnsError(err);
      this.peerDnsTestResult = newResult;
    }
  }

  updateLogViewData(log: StreamLogMessage, sortAes: boolean) {
    if (sortAes) {
      this.logData.logs.push(log);
    } else {
      this.logData.logs.unshift(log);
    }
  }
}


@ObservedV2
export class WGStreamLogsData {
  @Trace logs: StreamLogMessage[] = []
  @Trace lastLogForMap: Map<number, StreamLogMessage> = new Map(); // // 上一条日志，一直表示最新,不过需要根据peer区分

  updateLogMessage(log: StreamLogMessage) {
    this.lastLogForMap.set(log.peerIndex, log)
  }

  getLatestLogForPeer(index: number): StreamLogMessage | undefined {
    return this.lastLogForMap.get(index)
  }

  clear() {
    this.logs = [];
    this.lastLogForMap.clear();
  }
}

export interface IconBtnParam {
  tag: string
  res: Resource
}

@ObservedV2
export class IconSwitchBtnParam {
  @Trace on: boolean = false // 按钮是否开启
  onParam: IconBtnParam
  offParam: IconBtnParam
  onChange?: (on: boolean) => void

  constructor(on: boolean, onParam: IconBtnParam, offParam: IconBtnParam, onChange?: (on: boolean) => void) {
    this.on = on
    this.onParam = onParam
    this.offParam = offParam
    this.onChange = onChange
  }

  @Computed
  get param(): IconBtnParam {
    if (this.on) {
      return this.onParam
    } else {
      return this.offParam;
    }
  }

  @Monitor('on')
  changeListener() {
    this.onChange?.(this.on)
  }
}
