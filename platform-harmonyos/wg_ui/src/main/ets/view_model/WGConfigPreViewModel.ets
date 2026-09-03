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
  SiteUrlType
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
    // 判断id是否相同，且存在
    const isIdSame = this.params?.id != undefined && state.runningConfigId == this.params?.id;
    this.isVpnOpen = isIdSame && state.isOpen()
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
   */
  async changeVpnConfig(context: UIContext, isOn: boolean) {
    // 当点击启动按钮时，需要设置异常标记为false
    this.isVPNNoGetParamThrow = false;
    try {
      const id = this.params!.id;
      const config = this.data!;

      await WireGuard.runWGConfig(id, config, isOn)
      // 这里主要是本地启动VPN，不在vpn 专属进程 便于测试。
      //
      // if (!this.helper) {
      //   this.helper = WireGuard.makeVpnConnection(context);
      // }
      //
      // if (WireGuard.getRunningServer().runningConfigId) {
      //   LLog.info(TAG, `销毁VPN服务 ${id}`);
      //   await this.helper.stopServer().finally(() => {
      //     WireGuard.setRunningServer()
      //   })
      // }
      // if (isOn) {
      //   LLog.info(TAG, `启动VPN服务 ${id}`);
      //   await this.helper!.startServer(vpnConf)
      //     .finally(() => {
      //       WireGuard.setRunningServer(id)
      //     })
      // }
    } catch (e) {
      this.isVpnOpen = false;
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

  onSwitchChange(context: UIContext, isOn: boolean) {
    if (this.isSwitchClick) {
      if (isOn) {
        LLog.info(TAG, "点击开启VPN")
        this.changeVpnConfig(context, true)
      } else {
        LLog.info(TAG, "点击关闭VPN")
        this.changeVpnConfig(context, false)
      }
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
