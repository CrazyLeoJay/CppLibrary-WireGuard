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
import WGMainViewModel, { MainItemData } from '../view_model/WGMainViewModel';
import { ComponentContent, ComposeTitleBar, promptAction, SymbolGlyphModifier } from '@kit.ArkUI';
import { LLog } from 'wg_tunnel/src/main/ets/tools/LLog';
import { WireGuardNav } from '../model/WireGuardNav';
import { QRCodeNewConfig, QRCodeNewConfig as QRCodeNewParams, QRCodeNewWGConfDialog } from './QRCodeNewWGConfDialog';

const TAG = "WG主页";

@Builder
export function NavWGMainPage() {
  WGMainViewNavDest();
}

@Preview
@ComponentV2
export struct WGMainViewNavDest {
  @Param nav: NavPathStack = new NavPathStack();
  @Local vm: WGMainViewModel = new WGMainViewModel(this.nav);

  build() {
    NavDestination() {
      WGMainView({ vm: this.vm });
    }
    .onReady((info) => {
      if (info.pathInfo instanceof NavPathStack) {
        this.vm.nav = info.pathStack
      }
    })
    // .hideTitleBar(true)
    // .title(this.titleView())
    .title("WireGuard.CLJ_Fu")
    .menus([
      {
        value: "刷新",
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.arrow_2_circlepath')),
        action: () => {
          this.vm.loadConfigs()
        }
      },
      // {
      //   value: "新建VPN",
      //   symbolIcon: new SymbolGlyphModifier($r('sys.symbol.plus_circle')),
      //   action: () => {
      //     WireGuard.navDescToNewWGConfigView(this.vm.nav, () => {
      //       this.vm.loadConfigs();
      //     });
      //   }
      // },
      {
        value: "设置",
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.dot_grid_1x2')),
        action: () => {
          WireGuardNav.navDescToWGSettingPreView(this.nav)
        }
      }
    ])
  }

  @LocalBuilder
  titleView() {
    ComposeTitleBar()
  }
}

@Builder
function buildDialog(params: QRCodeNewParams) {
  QRCodeNewWGConfDialog({
    wgConf: params.wgConf,
  })
}


/**
 * WG主界面
 */
@ComponentV2
export struct WGMainView {
  @Param vm: WGMainViewModel = new WGMainViewModel();
  @Local isShow: boolean = true;

  funcBtn: MenuElement[] = [
    {
      value: "导入配置",
      action: () => {
        // todo 通过文件系统，读取配置文件，识别后添加到数据列表
      }
    },
    {
      value: "扫描二维码添加",
      action: () => {
        this.vm.scanQRCodeAdd(this.getUIContext())
          .then((wgConf) => {
            const contentNode = new ComponentContent(this.getUIContext(), wrapBuilder(buildDialog),
              {
                wgConf: wgConf
              } as QRCodeNewConfig
            );
            this.getUIContext()
              .getPromptAction()
              .openCustomDialogWithController(contentNode, new promptAction.DialogController(), {
                onDidDisappear: () => {
                  // 重新加载数据
                  this.vm.loadConfigs();
                }
              })
              .then(() => {
                LLog.info(TAG, "open 弹窗")
                contentNode.dispose()
              })
              .catch((e: BusinessError) => {
                LLog.info(TAG, e);
              })
          })
      }
    },
    {
      value: "手动添加",
      action: () => {
        WireGuardNav.navDescToNewWGConfigView(this.vm.nav, () => {
          this.vm.loadConfigs();
        });
      }
    },
  ];

  aboutToAppear(): void {
    this.vm.loadConfigs();
  }

  build() {
    Stack() {
      List() {
        Repeat(this.vm.wgList)
          .each((it) => {
            ListItem() {
              MainItemView({ data: it.item, index: it.index })
                .onClick(() => {
                  WireGuardNav.navDescToWGConfigPreView(this.vm.nav, { id: it.item.id });
                })
            }
            .swipeAction({
              end: {
                builder: () => {
                  this.itemEndFunsView(it);
                },
                onAction: () => {
                  LLog.info(TAG, "item row to end");
                }
              },
              start: undefined,
            })
          })
          .virtualScroll({})
      }
      .width('100%')
      .height('100%')
      .divider({
        strokeWidth: '1vp',
      })

      Button() {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontColor([$r('app.color.wg_float_button_svg_color')])
      }
      .width('45vp')
      .aspectRatio(1)
      .backgroundColor($r(`app.color.wg_float_button_backgroud_color`))
      .borderRadius($r('sys.float.corner_radius_level5'))
      .layoutGravity(LocalizedAlignment.BOTTOM_END)
      .margin({ bottom: '32vp', right: "32vp" })
      // .position({ x: '80%', y: '85%' }) // 右下角位置
      .hitTestBehavior(HitTestMode.Transparent) // 穿透触摸事件
      .hitTestBehavior(HitTestMode.Block) // 阻塞父组件事件
      .onClick((event: ClickEvent) => {
        animateToImmediately({ duration: 100 }, () => {
          this.isShow = true;
        })
      })
      .bindMenu(this.isShow!!, this.funcBtn, {
        placement: Placement.Top,
      })
    }
  }

  @LocalBuilder
  itemEndFunsView(it: RepeatItem<MainItemData>) {
    Row() {
      Text("删除")
        .textAlign(TextAlign.Center)
        .fontColor(Color.White)
        .width('150vp')
        .height('100%')
        .backgroundColor(Color.Red)
        .onClick(() => {
          this.vm.deleteConfig(it.index, it.item);
        })
    }
  }
}

@ComponentV2
struct MainItemView {
  @Param @Require data: MainItemData;
  @Param @Require index: number;

  build() {
    Row() {
      Column() {
        Text(`(${this.index + 1}) ${this.data.name}`)
        Text(`createAt: ${this.data.data.createdAt}`)
      }
      .alignItems(HorizontalAlign.Start)

      Blank().layoutWeight(1)
      // Toggle({ type: ToggleType.Switch, isOn: this.data.open!! })
      //   .onChange((isOn) => {
      //
      //   })
    }
    .padding({ left: '16vp', right: '16vp' })
    .width('100%')
    .height('60vp')
  }
}

