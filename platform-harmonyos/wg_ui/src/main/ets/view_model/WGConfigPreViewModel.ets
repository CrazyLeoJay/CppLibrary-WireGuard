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
  getDnsScope,
  dnsResolveByMode,
  formatDnsError,
  SiteUrlType,
  DnsScope
} from 'wg_tunnel';
import { vpnToggleService } from './VpnToggleService';
import { JSON } from '@kit.ArkTS';
import { AppStorageV2, UIContext } from '@kit.ArkUI';

const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
const TAG = "配置查看"

/** 从 AllSettled 解析结果取值：fulfilled 取 value，否则取 fallback */
function settledValue(r: PromiseSettledResult<string>, fallback: string): string {
  return r.status === 'fulfilled' ? r.value : fallback;
}

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
      // 保存后自动热切换（保留）：接入单飞行槽，链内校验运行意图=本配置才发SWITCH；
      // 两页面并发时后到意图生效，本任务若id不匹配自动作废
      if (this.data) {
        await vpnToggleService.requestConfigReloadSwitch(this.params.id, this.data);
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

  isSwitchClick: boolean = false;
  @Trace isSwitchEnable: boolean = true;

  /**
   * 预览页开关点击处理（第一道闸门：isSwitchClick 手势守卫——仅真实点击进入，
   * 程序性赋值引发的 onChange 因标记 false 空跑返回；主界面被动刷新亦不触发本方法）
   *
   * 与主界面共用 vpnToggleService：意图先行 → updateStatus 刷显示（纯显示写入）→
   * 单飞行槽内 id 校验后执行，只有目标任务执行。
   */
  onSwitchChange(context: UIContext, isOn: boolean) {
    this.isSwitchEnable = false
    if (this.isSwitchClick) {
      this.isSwitchClick = false
      // 当点击启动按钮时，需要设置异常标记为false
      this.isVPNNoGetParamThrow = false;
      const id = this.params?.id;
      const config = this.data;
      if (id == undefined || config == undefined) {
        this.isSwitchEnable = true
        return;
      }
      vpnToggleService.requestVpnToggle(context, id, isOn, config,
        () => {
          this.updateStatus();
        },
        () => {
          this.isSwitchEnable = true
        });
    } else {
      this.isSwitchEnable = true
    }
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
      // 本地（系统DNS）与广域网（公网DNS）两路并行解析，双双标记展示
      const settled = await Promise.allSettled([
        dnsResolveByMode(peer.endpoint.ipStrOrDomain, mode, DnsScope.PREFER_LOCAL),
        dnsResolveByMode(peer.endpoint.ipStrOrDomain, mode, DnsScope.PREFER_WAN),
      ]);
      const local: string = settledValue(settled[0], '解析失败');
      const wan: string = settledValue(settled[1], '解析失败');
      // @Trace 数组需整体重建才触发 UI 刷新
      const newResult: string[] = this.peerDnsTestResult.slice();
      newResult[index] = `本地: ${local}\n广域网: ${wan}`;
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
