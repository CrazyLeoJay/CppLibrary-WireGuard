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
import {
  MessageType,
  SiteUrlType,
  StreamDirection,
  StreamLogMessage,
  Timestamp,
  WGConfPeer,
  WGDBConf,
  WGEventThrow,
  getDnsMode,
  dnsModeDesc,
  AppFilterMode
} from 'wg_tunnel';
import { WireGuard } from 'wg_tunnel/src/main/ets/model/WGHelper';
import { LLog } from 'wg_tunnel/src/main/ets/tools/LLog';
import WGConfigPreViewParams from '../entity/WGConfigPreViewParams';
import WGConfigPreViewModel, { IconSwitchBtnParam } from '../view_model/WGConfigPreViewModel';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { WireGuardNav } from '../../../../Index';
import { SubEventCancel } from 'wg_tunnel/src/main/ets/model/WGEvent';

const TAG = "配置预览"

@Builder
function WGConfigPreViewBuilder() {
  WGConfigPreViewNavDest();
}

@Preview
@ComponentV2
export struct WGConfigPreViewNavDest {
  @Local vm: WGConfigPreViewModel = new WGConfigPreViewModel();
  @Local subTitle: string = "配置预览"

  aboutToAppear(): void {
  }

  build() {
    NavDestination() {
      WGConfigPreView({ vm: this.vm })

      // Swiper() {
      //   SwiperTitleLineView({
      //     rightTag: "左滑查看日志"
      //   }) {
      //     WGConfigPreView({ vm: this.vm })
      //   }
      //
      //   SwiperTitleLineView({
      //     leftTag: "右滑回到主页"
      //   }) {
      //     WGConfigPreViewStreamLogView({ vm: this.vm })
      //   }
      // }
      // .loop(false)
      // .width('100%')
      // .height('100%')
      // .onSelected((index) => {
      //   this.subTitle = index == 0 ? "配置预览" : "VPN日志"
      // })
    }
    // .hideTitleBar(true)
    .title(`WireGuard：${this.vm.configName}`)
    // .title({
    //   main: `WireGuard：${this.vm.configName}`,
    //   sub: this.subTitle,
    // })
    .onBackPressed(() => {
      this.vm.nav.pop({});
      return true;
    })
    .onReady((data) => {
      if (data.pathStack instanceof NavPathStack) {
        this.vm.nav = data.pathStack
      }

      if (data.pathInfo.param) {
        const params = data.pathInfo.param as WGConfigPreViewParams;
        this.vm.params = params;
        this.vm.loadData(params);
        WireGuard.event.publishVpnStatusQuery();
      } else {
        LLog.warn(TAG, "未得到参数！")
        this.vm.nav.pop({});
        return;
      }
    })
    .menus([
      {
        value: "編輯",
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.pencil_waveform')),
        action: () => {
          WireGuardNav.navDescToNewWGConfigView(this.vm.nav, { id: this.vm.params!.id, config: this.vm.data }, () => {
            LLog.info(TAG, "更新数据")
            this.vm.updateData()
          })
        }
      }
    ])
  }
}

@ComponentV2
export default struct WGConfigPreView {
  @Param @Require vm: WGConfigPreViewModel;
  throwEvent = WireGuard.event.subscribeVpnThrow((param: WGEventThrow) => {
    LLog.warn(TAG, `接收到VPN异常：${JSON.stringify(param)}}`)
    if (param.type == 'want_no_get_args') {
      // 如果时参数为空的异常，需要提示用户重新启动，有可能是系统问题
      this.vm.isVPNNoGetParamThrow = true
    }
  })
  listener = WireGuard.event.subscribeVpnStreamLogs((log) => {
    this.vm.updateStreamParams(log)
  })
  closeListener = WireGuard.event.subscribeVpnChange((state) => {
    if (!state.isOpen) {
      this.vm.logData.clear()
    }
  })

  aboutToDisappear(): void {
    this.throwEvent.cancel()
    this.listener.cancel()
    this.closeListener.cancel()
  }

  build() {
    if (this.vm.isVPNNoGetParamThrow) {
      Column({ space: '8vp' }) {
        Row() {
          Text(
            "启动异常，没有读取到参数。如果您是第一次碰到这个异常，请尝试重新开启是否能解决。后续将不会有这个问题。\n这个异常是第一次启动VPN时，需要用户确认，用户确认后，系统会自动生成新的启动参数导致后台服务接收错误，此时只需要重新开启即可。\n如还有问题，可以通过设置中的指导提交问题反馈。\n点击这个消息可以关闭本消息。")
            .width('100%')
            .cardBackgroundStyle()
            .backgroundColor('#ffff7676')
            .margin({ left: '16vp', right: '16vp' })
            .fontColor('#fff')
            .layoutWeight(1)
            .onClick(() => {
              this.vm.isVPNNoGetParamThrow = false
            })
        }

        this.buildMain()
      }
      .width('100%')
      .height('100%')
    } else {
      this.buildMain()
    }
  }

  @Builder
  buildMain() {
    List({ space: '16vp' }) {
      ListItem() {
        InterfaceCardView({ vm: this.vm, data: this.vm.client })
      }

      Repeat(this.vm.peers)
        .each((it) => {
          ListItem() {
            PeerCardView({ vm: this.vm, data: it.item, index: it.index })
          }
        })
    }
    .height('100%')
    .width('100%')
  }
}

@Styles
function cardBackgroundStyle() {
  .backgroundColor($r('app.color.wg_new_card_background_color'))
  .borderRadius('16vp')
  .padding('16vp')
  .margin({ left: '16vp', right: '16vp' })
  .align(Alignment.Start)
}

const ConfigColumnSpace = '4vp'

/**
 * 本地接口编辑卡片
 */
@ComponentV2
struct InterfaceCardView {
  @Param @Require vm: WGConfigPreViewModel
  @Param @Require data: WGDBConf
  @Local publicKey: string = ""
  vpnEvent: SubEventCancel = WireGuard.event.subscribeVpnChange((params) => {
    LLog.info(TAG, `配置发生变化: ${JSON.stringify(params)}`)
    const status = params.status
    if (params.connectedIps) {
      this.vm.connectedIps = params.connectedIps
    }
    this.vm.updateStatus()
  })
  vpnThrow: SubEventCancel = WireGuard.event.subscribeVpnThrow((msg) => {
    LLog.info(TAG, `VPN 异常：${msg}`)
  })

  async aboutToAppear(): Promise<void> {
    this.publicKey = await WireGuard.genPublicKey(this.data.conf.inter.privateKey)
    this.vm.updateStatus();
  }

  aboutToDisappear(): void {
    this.vpnEvent.cancel()
    this.vpnThrow.cancel()
  }

  get filterMode(): AppFilterMode {
    const included = this.data.conf.inter.includedApplications;
    const excluded = this.data.conf.inter.excludedApplications;
    if (included && included.length > 0) {
      return AppFilterMode.INCLUDED;
    }
    if (excluded && excluded.length > 0) {
      return AppFilterMode.EXCLUDED;
    }
    return AppFilterMode.NONE;
  }

  get filterAppsText(): string {
    if (this.filterMode === AppFilterMode.INCLUDED) {
      return this.data.conf.inter.includedApplications?.join(', ') ?? '';
    }
    if (this.filterMode === AppFilterMode.EXCLUDED) {
      return this.data.conf.inter.excludedApplications?.join(', ') ?? '';
    }
    return '';
  }

  get filterApps(): string[] {
    if (this.filterMode === AppFilterMode.INCLUDED) {
      return this.data.conf.inter.includedApplications ?? [];
    }
    if (this.filterMode === AppFilterMode.EXCLUDED) {
      return this.data.conf.inter.excludedApplications ?? [];
    }
    return [];
  }

  /** 获取包名对应的应用名（从 appFilterMeta 中读取） */
  getAppName(bundleName: string): string | undefined {
    return this.data.conf.inter.appFilterMeta?.[bundleName]?.appName;
  }

  /** 判断包名是否为分享添加 */
  isAppShared(bundleName: string): boolean {
    return this.data.conf.inter.appFilterMeta?.[bundleName]?.isShared ?? false;
  }

  build() {
    Stack() {
      Column({ space: '16vp' }) {
        Text("本地（Interface）")
          .width('100%')
          .layoutGravity(LocalizedAlignment.START)
          .align(Alignment.Start)
        Column({ space: ConfigColumnSpace }) {
          Text('名称').width('100%').TagStyle()
          Text(this.data.name!!).width('100%').TagContentStyle()
        }

        Column({ space: ConfigColumnSpace }) {
          Text('公钥').width('100%').TagStyle()
          Text(this.publicKey!!)
            .width('100%')
            .TagContentStyle()
            .TextOnlyLineEllipsisStyle()
        }
        .onClick(() => {
          if (this.publicKey.length > 0) {
            this.vm.copy44KeyToSystem(this.getUIContext(), this.publicKey)
          }
        })

        Column({ space: ConfigColumnSpace }) {
          Text('局域网IP地址').width('100%').TagStyle()
          Text(this.vm.getWlanIp!!).width('100%').TagContentStyle()
        }

        Column({ space: ConfigColumnSpace }) {
          Text('DNS服务器').width('100%').TagStyle()
          Text(this.vm.dns!!).width('100%').TagContentStyle()
        }

        // 应用过滤摘要
        if (this.filterMode !== AppFilterMode.NONE) {
          Column({ space: ConfigColumnSpace }) {
            Row({ space: '8vp' }) {
              Text('应用过滤').TagStyle()
              Text(this.filterMode === AppFilterMode.EXCLUDED ? '黑名单' : '白名单')
                .fontSize('12fp')
                .fontColor(Color.White)
                .backgroundColor($r('app.color.wg_new_card_item_select_color'))
                .borderRadius('8vp')
                .padding({
                  left: '6vp',
                  right: '6vp',
                  top: '2vp',
                  bottom: '2vp'
                })
            }
            .width('100%')

            // 显示每个包名及其图标和应用名
            if (this.filterApps.length > 0) {
              Column({ space: '8vp' }) {
                Repeat(this.filterApps)
                  .each((it) => {
                    Row({ space: '6vp' }) {
                      // 图标：分享条目用 share.svg，手动条目用占位符号
                      if (this.isAppShared(it.item)) {
                        Image($r('app.media.share'))
                          .width('20vp')
                          .height('20vp')
                          .fillColor($r('app.color.share_debug_accent'))
                      } else {
                        SymbolGlyph($r('sys.symbol.square_grid_2x2'))
                          .fontSize('20fp')
                          .fontColor([Color.Gray])
                      }
                      if (this.getAppName(it.item)) {
                        Column({ space: '1vp' }) {
                          Text(this.getAppName(it.item)!)
                            .fontSize('14fp')
                            .fontWeight(FontWeight.Medium)
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                          Text(it.item)
                            .fontSize('11fp')
                            .fontColor($r('app.color.share_secondary_text'))
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                        }
                        .layoutWeight(1)
                        .alignItems(HorizontalAlign.Start)
                      } else {
                        Text(it.item)
                          .fontSize('14fp')
                          .layoutWeight(1)
                      }
                      if (this.isAppShared(it.item)) {
                        Text('分享')
                          .fontSize('10fp')
                          .fontColor($r('app.color.share_debug_accent'))
                          .border({ width: 1, color: $r('app.color.share_debug_accent'), radius: 4 })
                          .padding({
                            left: '4vp',
                            right: '4vp',
                            top: '1vp',
                            bottom: '1vp'
                          })
                      }
                    }
                    .width('100%')
                  })
              }
              .width('100%')
            }
          }
        }
      }
      .cardBackgroundStyle()

      Toggle({
        type: ToggleType.Switch,
        isOn: this.vm.isVpnOpen!!,
      })
        .layoutGravity(LocalizedAlignment.TOP_END)
        .margin({
          top: '24vp',
          right: '40vp',
        })
        .enabled(this.vm.isSwitchEnable)
        .onChange((isOn) => {
          this.vm.onSwitchChange(this.getUIContext(), isOn)
        })
        .onClick((event) => {
          this.vm.setSwitchClick();
        })
    }
  }
}

/**
 * Peer 编辑卡片
 */
@ComponentV2
struct PeerCardView {
  @Param @Require vm: WGConfigPreViewModel
  @Param @Require data: WGConfPeer
  @Param @Require index: number
  private TAG = "";

  build() {
    Column({ space: "16vp" }) {
      Text(`远程(Peer)-${this.index + 1}`).width('100%')
      Column({ space: ConfigColumnSpace }) {
        Text('公钥').width('100%').TagStyle()
        Text(this.data.publicKey!!)
          .width('100%')
          .TagContentStyle()
          .TextOnlyLineEllipsisStyle()
      }
      .onClick(() => {
        this.vm.copy44KeyToSystem(this.getUIContext(), this.data.publicKey)
      })

      if (this.data.preSharedKey) {
        Column({ space: ConfigColumnSpace }) {
          Text('预共享密钥').width('100%').TagStyle()
          Text(this.data.preSharedKey!!)
            .width('100%')
            .TagContentStyle()
            .TextOnlyLineEllipsisStyle()
        }
        .onClick(() => {
          this.vm.copy44KeyToSystem(this.getUIContext(), this.data.preSharedKey!)
        })
      }

      Column({ space: ConfigColumnSpace }) {
        Text('路由的IP地址（段）').width('100%').TagStyle()
        Text(`${this.data.allowedIPs.map((it) => `${it.address.ip}/${it.cidr ?? (it.address.isIpv4 ? 32 : 128)}`)
          .join(", ")}`)
          .width('100%')
          .TagContentStyle()
      }

      Column({ space: ConfigColumnSpace }) {
        Text(`对端`).width('100%').TagStyle()
        if (this.data.endpoint.type == SiteUrlType.IPv6) {
          Text(`[${this.data.endpoint.ipStrOrDomain}]:${this.data.endpoint.port}`).width('100%').TagContentStyle()
        } else {
          Text(`${this.data.endpoint.ipStrOrDomain}:${this.data.endpoint.port}`).width('100%').TagContentStyle()
        }
      }

      // 仅域名时展示解析偏好（只读）与解析测试
      if (this.data.endpoint.type == SiteUrlType.Domain) {
        Column({ space: ConfigColumnSpace }) {
          Text('DNS解析偏好').width('100%').TagStyle()
          Text(dnsModeDesc(getDnsMode(this.data.endpoint))).width('100%').TagContentStyle()
        }

        Row({ space: '8vp' }) {
          Button("解析测试", { type: ButtonType.Normal })
            .fontSize('14fp')
            .fontColor(Color.White)
            .backgroundColor($r('app.color.wg_new_card_item_select_color'))
            .borderRadius('8vp')
            .height('32vp')
            .padding({ left: '16vp', right: '16vp' })
            .onClick(() => {
              this.vm.testPeerDnsResolve(this.getUIContext(), this.index)
            })
          if (this.vm.peerDnsTestResult[this.index]) {
            Text(this.vm.peerDnsTestResult[this.index])
              .fontSize('14fp')
              .layoutWeight(1)
          }
        }
        .width('100%')
      }

      if (this.vm.isVpnOpen && this.data.endpoint.type == SiteUrlType.Domain
        && this.vm.connectedIps[this.index]) {
        Column({ space: ConfigColumnSpace }) {
          Text('当前连接的 IP').width('100%').TagStyle()
          Text(this.vm.connectedIps[this.index]).width('100%').TagContentStyle()
        }
      }

      Column({ space: ConfigColumnSpace }) {
        Text(`连接保活时间`).width('100%').TagStyle()
        if (this.data.keepaliveInterval) {
          Text(`每隔 ${this.data.keepaliveInterval ?? 0} 秒`).width('100%').TagContentStyle()
        } else {
          Text(`不发送心跳包`).width('100%').TagContentStyle()
        }
      }

      if (this.vm.isVpnOpen) {
        Column({ space: ConfigColumnSpace }) { //  动态数据
          Text(`流量`).width('100%').TagStyle()
          Text(`接受：${this.vm.receiveData(this.index)} 发送：${this.vm.sendData(this.index)}`)
            .width('100%')
            .TagContentStyle()
        }
      }

    }
    .cardBackgroundStyle()
  }
}

@Extend(Text)
function TagStyle() {
  .fontSize('13fp')
  // .fontColor($r('app.color.tag'))
}

@Extend(Text)
function TagContentStyle() {
  .fontSize('18fp')
  .layoutGravity(LocalizedAlignment.START)
  .align(Alignment.Start)
}

@Extend(Text)
function TextOnlyLineEllipsisStyle() {
  .maxLines(1)
  .ellipsisMode(EllipsisMode.END)
  .wordBreak(WordBreak.BREAK_ALL)
  .textOverflow({ overflow: TextOverflow.Ellipsis })
}

@Builder
function MyBuilderFunction(): void {
}

@ComponentV2
struct SwiperTitleLineView {
  @Param leftTag?: string = undefined
  @Param rightTag?: string = undefined
  @BuilderParam childView: () => void = MyBuilderFunction

  build() {
    Column() {
      Row() {
        if (this.leftTag) {
          Row() {
            SymbolGlyph($r('sys.symbol.left_turn'))
              .fontColor([$r('app.color.symbol_color')])
            Text(this.leftTag)
          }
        }
        Blank().layoutWeight(1)
        if (this.rightTag) {
          Row() {
            Text(this.rightTag)
            SymbolGlyph($r('sys.symbol.right_turn'))
              .fontColor([$r('app.color.symbol_color')])
          }
        }
      }
      .width('100%')
      .padding({
        left: '16vp',
        right: '16vp',
        top: '8vp',
        bottom: '8vp',
      })
      .layoutWeight(0)

      Row() {
        this.childView()
      }
      .width('100%')
      .height('100%')
      .layoutWeight(1)
    }
  }
}

const date_format = new Intl.DateTimeFormat('zh-CN', {});

/**
 * 预览配置界面的 Stream 流 日志
 */
@ComponentV2
export struct WGConfigPreViewStreamLogView {
  @Param @Require vm: WGConfigPreViewModel;
  listener = WireGuard.event.subscribeVpnStreamLogs((log) => {
    this.vm.updateLogViewData(log, this.logSort.on)
  })

  aboutToDisappear(): void {
    this.listener.cancel()
  }

  @Local logSort: IconSwitchBtnParam = new IconSwitchBtnParam(true,
    { tag: "正序", res: $r('sys.symbol.chevron_down_2_circle') },
    { tag: "倒叙", res: $r('sys.symbol.chevron_up_2_circle') },
    (on) => {
      LLog.info(TAG, `改变排序：${on}`)
      // this.vm.logData.logs = this.vm.logData.logs.reverse()
      this.vm.logData.logs.sort((a, b) => {
        return a.timestamp - b.timestamp;
      })
    }
  )

  build() {
    Column() {
      Row() {
        Blank().layoutWeight(1)
        this.buildFunItem(this.logSort)
      }
      .width('100%')
      .layoutWeight(0)
      .padding({ left: '16vp', right: '16vp' })

      if (this.vm.logData.logs.length == 0) {
        Stack() {
          Text("还没有获取到日志数据")
        }
        .width('100%')
        .height('100%')
      } else {

        List() {
          Repeat(this.vm.logData.logs)
            .each((item) => {
              this.buildRow(item.item)
            })
            .virtualScroll({ totalCount: this.vm.logData.logs.length })
        }
        .width('100%')
        .height('100%')
        .layoutWeight(1)
      }
    }

  }

  @Builder
  buildFunItem(param: IconSwitchBtnParam) {
    Column({ space: '4vp' }) {
      SymbolGlyph(param.param.res)
        .fontSize('24fp')
      Text(param.param.tag)
        .fontSize('10fp')
    }
    .padding('8vp')
    .onClick(() => {
      param.on = !param.on;
    })
  }

  @Builder
  buildRow(log: StreamLogMessage) {
    Row({ space: '8vp' }) {
      Text(`${Timestamp.from(log.timestamp).format('yyyy-MM-dd HH:mm:ss SSS')}`).layoutWeight(0)
      Text(`${log.peerIndex + 1}`).layoutWeight(0)
      Text(`${log.direction == StreamDirection.RECEIVE ? "接收" : "发送"}`).layoutWeight(0)
      Text(`${this.getMessageTypeString(log.messageType)}`).layoutWeight(0)
    }
    .padding({
      left: '8vp',
      right: '8vp',
    })
  }

  getMessageTypeString(type: MessageType): string {
    switch (type) {
      case MessageType.HANDSHAKE_INITIATION:
        return "握手初始化"
      case MessageType.HANDSHAKE_RESPONSE:
        return "握手响应"
      case MessageType.HANDSHAKE_COOKIE:
        return "Cookie"
      case MessageType.DATA:
        return "数据"
      default:
        return "未知数据"
    }
  }
}


