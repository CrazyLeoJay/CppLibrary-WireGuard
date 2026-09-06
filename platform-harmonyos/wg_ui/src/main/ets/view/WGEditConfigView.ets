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
import { ClipboardStatus } from '../view_model/WGEditConfigViewModel';
import { SymbolGlyphModifier } from '@ohos.arkui.modifier';
import { DiyTextInput as WgCardTextInput } from './component/DiyTextInput';
import PeerEditConfig from 'wg_tunnel/src/main/ets/model/entity/PeerEditConfig';
import WGEditConfigParams from '../entity/WGEditConfigParams';
import { LLog, DnsResolveMode, AppFilterMode, WGSettingsPrefs, AppFilterItem } from 'wg_tunnel';
import { pasteboard } from '@kit.BasicServicesKit';

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

      // 应用过滤模块
      AppFilterEditModule({ vm: this.vm })
    }
    .cardBackgroundStyle()
  }
}

/**
 * 应用过滤编辑模块
 */
@ComponentV2
struct AppFilterEditModule {
  @Param @Require vm: WGEditConfigViewModel

  get isFilterOn(): boolean {
    return this.vm.client.filterMode !== AppFilterMode.NONE;
  }

  get modeHintText(): string {
    if (this.vm.client.filterMode === AppFilterMode.EXCLUDED) {
      return '黑名单：列出的应用不经过VPN隧道，其他应用走VPN';
    }
    if (this.vm.client.filterMode === AppFilterMode.INCLUDED) {
      return '白名单：仅列出的应用经过VPN隧道，其他应用不走VPN';
    }
    return '';
  }

  get clipboardButtonText(): string {
    if (this.vm.clipboardStatus === ClipboardStatus.HAS_VALUE) {
      return `从剪贴板获取（${this.vm.clipboardBundleName ?? ''}）`;
    }
    if (this.vm.clipboardStatus === ClipboardStatus.NO_PERMISSION) {
      return '从剪贴板获取（无权限）';
    }
    return '从剪贴板获取（无值）';
  }

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as Context;
    this.vm.checkClipboard(context).catch((e: BusinessError) => {
      LLog.warn(TAG, `checkClipboard failed: ${JSON.stringify(e)}`);
    });
    // 监听剪贴板内容变化，自动更新按钮状态
    try {
      const pasteboard_ = pasteboard.getSystemPasteboard();
      pasteboard_.on('update', () => {
        LLog.info(TAG, 'Clipboard content changed, re-checking');
        this.vm.checkClipboard(context).catch((e: BusinessError) => {
          LLog.warn(TAG, `checkClipboard on update failed: ${JSON.stringify(e)}`);
        });
      });
    } catch (e) {
      LLog.warn(TAG, `Failed to register clipboard listener: ${JSON.stringify(e)}`);
    }
  }

  aboutToDisappear(): void {
    try {
      const pasteboard_ = pasteboard.getSystemPasteboard();
      pasteboard_.off('update');
    } catch (e) {
      // ignore
    }
  }

  build() {
    Column({ space: '12vp' }) {
      // 标题行 + Switch
      Row() {
        Text('应用过滤')
          .fontSize('16fp')
          .fontWeight(FontWeight.Medium)
        Blank().layoutWeight(1)
        Toggle({
          type: ToggleType.Switch,
          isOn: this.isFilterOn,
        })
          .onChange((isOn: boolean) => {
            if (isOn) {
              const defaultMode = WGSettingsPrefs.getDefaultFilterMode();
              this.vm.client.filterMode =
                (defaultMode === AppFilterMode.INCLUDED) ? AppFilterMode.INCLUDED : AppFilterMode.EXCLUDED;
            } else {
              this.vm.client.filterMode = AppFilterMode.NONE;
              this.vm.client.filterApps = [];
            }
          })
      }
      .width('100%')

      // Switch 打开后显示内容
      if (this.isFilterOn) {
        // 模式切换标签行
        Row({ space: '8vp' }) {
          this.buildModeTab(AppFilterMode.EXCLUDED, '黑名单')
          this.buildModeTab(AppFilterMode.INCLUDED, '白名单')
        }
        .width('100%')

        // 提示文字
        Text(this.modeHintText)
          .fontSize('12fp')
          .fontColor(Color.Gray)
          .width('100%')

        // 包名输入行列表
        Repeat(this.vm.client.filterApps)
          .each((it) => {
            Row({ space: '8vp' }) {
              // 图标：分享条目用 share.svg，手动条目用占位符号
              if (it.item.isShared) {
                Image($r('app.media.share'))
                  .width('24vp')
                  .height('24vp')
                  .fillColor($r('app.color.share_debug_accent'))
              } else {
                SymbolGlyph($r('sys.symbol.square_grid_2x2'))
                  .fontSize('24fp')
                  .fontColor([Color.Gray])
              }

              if (it.item.isShared) {
                // 分享条目：只读显示，不可编辑包名
                Column({ space: '2vp' }) {
                  if (it.item.appName && it.item.appName.length > 0) {
                    Text(it.item.appName)
                      .fontSize('14fp')
                      .fontWeight(FontWeight.Medium)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  Text(it.item.bundleName)
                    .fontSize('12fp')
                    .fontColor($r('app.color.share_secondary_text'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              } else {
                // 手动条目：可编辑 TextInput
                TextInput({ text: it.item.bundleName, placeholder: '输入应用包名' })
                  .layoutWeight(1)
                  .fontSize('14fp')
                  .borderRadius('6vp')
                  .onChange((value: string) => {
                    this.vm.client.filterApps[it.index] = {
                      bundleName: value,
                      appName: it.item.appName,
                      isShared: it.item.isShared,
                    };
                  })
              }

              SymbolGlyph($r('sys.symbol.minus_circle'))
                .fontSize('24fp')
                .fontColor([$r('app.color.wg_new_card_item_select_color')])
                .onClick(() => {
                  this.vm.client.filterApps.splice(it.index, 1);
                })
            }
            .width('100%')
          })

        // 虚线框添加按钮
        Row() {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize('16fp')
            .fontColor([Color.Gray])
          Text('添加应用')
            .fontSize('14fp')
            .fontColor(Color.Gray)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding('12vp')
        .border({
          width: 1,
          color: Color.Gray,
          radius: 6,
          style: BorderStyle.Dashed,
        })
        .onClick(() => {
          this.vm.client.filterApps.push({ bundleName: '', isShared: false });
        })

        // // 从剪贴板获取按钮
        // // 不许删除此段注释代码。 由于华为官方权限申请问题，隐私协议和权限对不上，导致无法发布，先注释这个功能，等修复成功后再开放。
        // Row() {
        //   Text(this.clipboardButtonText)
        //     .fontSize('14fp')
        //     .fontColor(Color.Gray)
        //     .maxLines(2)
        //     .textOverflow({ overflow: TextOverflow.Ellipsis })
        // }
        // .width('100%')
        // .justifyContent(FlexAlign.Center)
        // .padding('12vp')
        // .border({
        //   width: 1,
        //   color: Color.Gray,
        //   radius: 6,
        //   style: BorderStyle.Solid,
        // })
        // .onClick(() => {
        //   const context = this.getUIContext().getHostContext() as Context;
        //   this.vm.addFromClipboard(context).catch((e: BusinessError) => {
        //     LLog.warn(TAG, `addFromClipboard failed: ${JSON.stringify(e)}`);
        //   });
        // })

        // 说明文字
        Text('因系统限制，无法获取已安装应用列表，需手动输入应用包名')
          .fontSize('12fp')
          .fontColor(Color.Gray)
          .width('100%')
      }
    }
    .width('100%')
  }

  @Builder
  buildModeTab(mode: AppFilterMode, desc: string) {
    Text(desc)
      .fontSize('12fp')
      .fontColor(this.vm.client.filterMode === mode ? Color.White : Color.Gray)
      .backgroundColor(this.vm.client.filterMode === mode
        ? $r('app.color.wg_new_card_item_select_color')
        : Color.Transparent)
      .borderRadius('8vp')
      .padding({
        top: '6vp',
        bottom: '6vp',
        left: '8vp',
        right: '8vp'
      })
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .onClick(() => {
        if (this.vm.client.filterMode !== mode) {
          this.vm.client.filterMode = mode;
          this.vm.client.filterApps = [];
        }
      })
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
      .padding({
        top: '6vp',
        bottom: '6vp',
        left: '4vp',
        right: '4vp'
      })
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .onClick(() => {
        this.data.dnsMode = mode;
      })
  }
}


