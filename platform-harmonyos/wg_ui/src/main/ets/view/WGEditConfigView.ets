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
import WGEditConfigViewModel from '../view_model/WGEditConfigViewModel';
import { SymbolGlyphModifier } from '@ohos.arkui.modifier';
import { DiyTextInput as WgCardTextInput } from './component/DiyTextInput';
import PeerEditConfig from 'wg_tunnel/src/main/ets/model/entity/PeerEditConfig';
import WGEditConfigParams from '../entity/WGEditConfigParams';
import { LLog, DnsResolveMode } from 'wg_tunnel';

const TAG = "编辑界面";

@Builder
export function WGEditConfigViewBuilder() {
  WGEditConfigViewNavDest();
}

@Preview
@ComponentV2
export struct WGEditConfigViewNavDest {
  vm: WGEditConfigViewModel = new WGEditConfigViewModel();

  build() {
    NavDestination() {
      WGNewConfigView({ vm: this.vm });
    }
    .onReady((info) => {
      if (info.pathStack instanceof NavPathStack) {
        this.vm.nav = info.pathStack
      }
      const data = info.pathInfo.param as WGEditConfigParams | undefined
      if (data) {
        // 如果数据存在就去加载
        this.vm.initEditData(data).catch((e: BusinessError) => {
          LLog.warn(TAG, e)
        })
      }
    })
    .title("创建 WireGuard 隧道")
    .hideBackButton(false)
    .menus([
      {
        value: "保存",
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.save')),
        action: () => {
          this.vm.save(this.getUIContext());
        }
      }
    ])
  }
}

@Styles
function cardBackgroundStyle() {
  .backgroundColor($r('app.color.wg_new_card_background_color'))
  .borderRadius('16vp')
  .padding('16vp')
  .margin({ left: '16vp', right: '16vp' })
}

/**
 * 新增WG配置
 */

@ComponentV2
export struct WGNewConfigView {
  @Param vm: WGEditConfigViewModel = new WGEditConfigViewModel();
  defaultCardBgColor = $r('app.color.wg_new_card_background_color');

  build() {
    List({
      space: '32vp'
    }) {
      ListItem() {
        // 本地接口编辑界面
        InterfaceEditCardView({ vm: this.vm })
      }

      Repeat(this.vm.peers)
        .each((it) => {
          ListItem() {
            PeerEditCardView({ vm: this.vm, index: it.index, data: it.item })
          }
        })

      ListItem() {
        Row() {
          Text('添加节点')
            .onClick(() => {
              this.vm.addNewPeer();
            })
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .width('100%')
            .padding('16vp')
        }
        .cardBackgroundStyle()
      }
    }
    .width('100%')
    .height('100%')
  }
}

/**
 * 本地接口编辑卡片
 */
@ComponentV2
struct InterfaceEditCardView {
  @Param @Require vm: WGEditConfigViewModel

  build() {
    Column({ space: '16vp' }) {
      Text("本地（Interface）")
        .width('100%')
        .layoutGravity(LocalizedAlignment.START)
        .align(Alignment.Start)
      WgCardTextInput({ inputId: "input1", tag: "名称", inputValue: this.vm.client.deviceName!! })
      WgCardTextInput({
        inputId: "input2",
        tag: "私钥",
        inputValue: this.vm.client.privateKey!!,
        onInputWillChange: (it) => {
          if (it.content.length > 64) {
            return false;
          } else {
            return true;
          }
        },
        funBtnList: [{
          type: "symbolBtn",
          symbol: $r('sys.symbol.arrow_2_circlepath'),
          action: () => {
            this.vm.makeKeyPair();
          }
        }]
      })
      WgCardTextInput({
        inputId: "input3",
        tag: "公钥",
        inputEnable: false,
        placeholder: "(生成)",
        inputValue: this.vm.client.publicKey!!,
        onNoInputTextClick: () => {
          this.vm.copyPublicKeyToSystem(this.getUIContext());
        }
      })
      Row({ space: '8vp' }) {
        WgCardTextInput({
          inputId: "input4",
          tag: "局域网 IP 地址",
          inputValue: this.vm.client.vpnAddress!!,
          inputFilter: this.vm.inputRegex.ipMark,
        }).layoutWeight(2)
        WgCardTextInput({
          inputId: "input5",
          tag: "监听端口",
          placeholder: "(随机)",
          inputValue: this.vm.client.listenerPort!!,
          inputFilter: this.vm.inputRegex.port,
        })
          .layoutWeight(1)
      }
      .width('100%')

      Row({ space: '8vp' }) {
        WgCardTextInput({
          inputId: "input6",
          tag: "DNS 服务器",
          inputValue: this.vm.client.dnsIps!!,
          inputFilter: this.vm.inputRegex.dns,
        })
          .layoutWeight(2)
        WgCardTextInput({
          inputId: "input7",
          tag: "MTU",
          placeholder: "(自动)",
          inputValue: this.vm.client.mtu!!,
          inputFilter: this.vm.inputRegex.mtu,
        }).layoutWeight(1)
      }
      .width('100%')

      // Text('应用过滤')
      //   .onClick(() => {
      //
      //   })
      //   .textAlign(TextAlign.Center)
      //   .align(Alignment.Center)
      //   .layoutGravity(LocalizedAlignment.CENTER)
      //   .width('100%')
      //   .height('auto')
      //   .padding('16vp')
    }
    .cardBackgroundStyle()
  }
}

/**
 * Peer 编辑卡片
 */
@ComponentV2
struct PeerEditCardView {
  @Param @Require vm: WGEditConfigViewModel
  @Param @Require index: number
  @Param @Require data: PeerEditConfig
  private TAG = "Peer编辑";

  build() {
    Column({ space: "16vp" }) {
      Row() {
        Text(`${this.index + 1}、远程（Peer）`)
        Blank().layoutWeight(1)
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize('24fp')
          .onClick(() => {
            this.vm.removePeer(this.data);
          })
      }

      WgCardTextInput({ inputValue: this.data.publicKey!!, inputId: `publicKey_${this.index}`, tag: "公钥" })
      WgCardTextInput({
        inputValue: this.data.preSharedKey!!,
        inputId: `preShareKey_${this.index}`,
        tag: "预共享密钥",
        placeholder: "（可选）"
      })
      WgCardTextInput({
        inputValue: this.data.keepaliveInterval!!,
        inputId: `active_${this.index}`,
        tag: "连接保活间隔",
        placeholder: "（可选，不建议设置）",
        inputFilter: this.vm.inputRegex.num,
        funBtnList: [{
          type: "tag",
          tag: "秒",
          action: () => {
            this.vm.makeKeyPair();
          }
        }]
      })
      WgCardTextInput({
        inputValue: this.data.address!!,
        inputId: `remotePeer_${this.index}`,
        tag: "对端",
        inputFilter: this.vm.inputRegex.noSpace,
      })

      Row() {
        Text(this.data.addressCheckMessage)
          .fontColor(this.data.addressVerify ? Color.Green : Color.Red)
          .fontSize('12fp')
          .layoutWeight(1)
          .layoutGravity(LocalizedAlignment.START)
        Blank().layoutWeight(0)
      }
      .layoutWeight(0)
      .width("100%")

      // 仅域名时显示解析偏好四选一与解析测试
      if (this.data.isDomain) {
        Column({ space: '8vp' }) {
          Text("DNS解析偏好")
            .fontSize('14fp')
            .width('100%')
            .layoutGravity(LocalizedAlignment.START)
          // 单行横排四个选项卡
          Row({ space: '8vp' }) {
            this.buildDnsModeTab(DnsResolveMode.PREFER_IPV4, "默认IPv4")
            this.buildDnsModeTab(DnsResolveMode.PREFER_IPV6, "优先IPv6")
            this.buildDnsModeTab(DnsResolveMode.FORCE_IPV6, "强制IPv6")
            this.buildDnsModeTab(DnsResolveMode.FORCE_IPV4, "强制IPv4")
          }
          .width('100%')
        }
        .width('100%')

        // 解析测试按钮（随解析偏好一起显示/隐藏）
        Row({ space: '8vp' }) {
          Button("解析测试", { type: ButtonType.Normal })
            .fontSize('14fp')
            .fontColor(Color.White)
            .backgroundColor($r('app.color.wg_new_card_item_select_color'))
            .borderRadius('8vp')
            .height('32vp')
            .padding({ left: '16vp', right: '16vp' })
            .onClick(() => {
              this.data.testDnsResolve(this.getUIContext());
            })
          if (this.data.dnsTestResult.length > 0) {
            Text(this.data.dnsTestResult)
              .fontSize('14fp')
              .layoutWeight(1)
          }
        }
        .width('100%')
      }

      WgCardTextInput({
        inputValue: this.data.allowedIpsInput!!,
        inputId: `ipArea_${this.index}`,
        tag: "路由的IP地址（段）",
        inputFilter: this.vm.inputRegex.noSpace,
      })
      Row() {
        Text($r('app.string.seek_router_value_desc'))
          .fontSize('12fp')
      }
      .alignSelf(ItemAlign.Start)
      .padding({ left: 2 })
    }
    .cardBackgroundStyle()
  }

  @Builder
  buildDnsModeTab(mode: DnsResolveMode, desc: string) {
    Text(desc)
      .fontSize('12fp')
      .fontColor(this.data.dnsMode == mode ? Color.White : Color.Gray)
      .backgroundColor(this.data.dnsMode == mode
        ? $r('app.color.wg_new_card_item_select_color')
        : Color.Transparent)
      .borderRadius('8vp')
      .padding({ top: '6vp', bottom: '6vp', left: '4vp', right: '4vp' })
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .onClick(() => {
        this.data.dnsMode = mode;
      })
  }
}
