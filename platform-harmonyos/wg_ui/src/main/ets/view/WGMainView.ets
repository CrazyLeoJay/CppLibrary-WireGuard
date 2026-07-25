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
import { WGConf, WireGuard } from 'wg_tunnel';

const TAG = "WG主页";

@Builder
export function NavWGMainPage() {
  WGMainViewNavDest();
}

@Preview
@ComponentV2
struct MainViewPreview {
  @Local vm: WGMainViewModel = new WGMainViewModel();

  aboutToAppear(): void {
    this.vm.preLoadDatas();
  }

  build() {
    WGMainViewNavDest({
      previewVM: this.vm
    })
  }
}

@ComponentV2
export struct WGMainViewNavDest {
  @Param nav: NavPathStack = new NavPathStack();
  @Param previewVM: WGMainViewModel = new WGMainViewModel(this.nav);
  @Local vm: WGMainViewModel = this.previewVM;

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
    .title({
      main: $r('app.string.app_name'),
      sub: $r('app.string.sub_title'),
    })
    .menus([
      {
        value: "刷新",
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.arrow_2_circlepath')),
        action: () => {
          WireGuard.event.publishVpnStatusQuery();
          this.vm.loadConfigs().then(() => {
            try {
              this.getUIContext().getPromptAction().showToast({
                message: `加载了 ${this.vm.wgList.length} 条数据`,
              })
            } catch (error) {
              LLog.error(TAG, error)
            }
          })
        }
      },
      {
        value: "设置",
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.gearshape')),
        action: () => {
          WireGuardNav.navDescToWGSettingPreView(this.nav)
        }
      },
      {
        value: `排序参数:${this.vm.uiConfig.getColumnName()}`,
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.timer')),
        action: () => {
          this.vm.uiConfig.sortColumnToNext()
        }
      },

      {
        value: `排序顺序:${this.vm.uiConfig.listSortAsc ? '正序' : '倒叙'}`,
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.timer')),
        action: () => {
          this.vm.uiConfig.listSortAsc = !this.vm.uiConfig.listSortAsc
        }
      },
      {
        value: `显示信息：${this.vm.uiConfig.listShowSimple ? '简略' : '详细'}`,
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.message')),
        action: () => {
          this.vm.uiConfig.listShowSimple = !this.vm.uiConfig.listShowSimple
        }
      },
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
      value: "选择conf或者zip文件导入配置",
      action: () => {
        // 通过文件系统，读取配置文件，识别后添加到数据列表
        this.vm.readWGConfForSystemFile(this.getUIContext())
          .then((wgConf) => {
            if (wgConf instanceof Array) {
              LLog.info(TAG, `成功导入 ${wgConf.length} 个配置，无需弹窗。`)
              try {
                this.getUIContext().getPromptAction()
                  .showToast({
                    message: `成功导入 ${wgConf.length} 个配置。`
                  })
              } catch (error) {
                LLog.error(TAG, error)
              }
            } else {
              this.newConfigDialog(wgConf);
            }
            this.vm.loadConfigs()
          })
          .catch((e: BusinessError) => {
            LLog.warn(TAG, e)
          })
      }
    },
    {
      value: "扫描二维码添加",
      action: () => {
        this.vm.scanQRCodeAdd(this.getUIContext())
          .then((wgConf) => {
            this.newConfigDialog(wgConf);
          })
          .catch((e: BusinessError) => {
            if (e.code == 1000500002) {
              LLog.info(TAG, "用户去取消了二维码扫描")
              return
            }
            LLog.error(TAG, {
              message: `code=${e.code}`
            , error: e
            })
          })
      }
    },
    {
      value: "手动添加",
      action: () => {
        WireGuardNav.navDescToNewWGConfigView(this.vm.nav, undefined, () => {
          this.vm.loadConfigs();
        });
      }
    },
  ];
  vpnEvent = WireGuard.event.subscribeVpnChange((params) => {
    LLog.info(TAG, `配置读取: ${JSON.stringify(params)}`)
    const status = params.status
    if (status) {
      // 更新UI线程配置
      WireGuard.statusConfig.update(status)
      // 设置开关
      this.vm.setActiveConfigId(status);
    }
  })

  aboutToAppear(): void {
    this.vm.loadConfigs();
    WireGuard.event.publishVpnStatusQuery();
  }

  aboutToDisappear(): void {
    this.vpnEvent.cancel()
  }

  build() {
    Stack() {
      if (this.vm.isEmptyList) {
        this.buildEmptyView()
      } else {
        this.buildConfigListView()
      }
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
    .width('100%')
    .height('100%')
  }

  @LocalBuilder
  buildConfigListView() {
    List() {
      Repeat(this.vm.wgList)
        .each((it) => {
          ListItem() {
            MainItemView({ vm: this.vm, data: it.item, index: it.index })
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

  }

  /**
   * 空白界面时显示
   */
  @LocalBuilder
  buildEmptyView() {
    Text("快来添加一个新配置吧")
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

  newConfigDialog(wgConf: WGConf) {
    const contentNode = new ComponentContent(this.getUIContext(), wrapBuilder(buildDialog),
      { wgConf: wgConf } as QRCodeNewConfig
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
  }
}

@ComponentV2
struct MainItemView {
  @Param @Require vm: WGMainViewModel
  @Param @Require data: MainItemData;
  @Param @Require index: number;

  build() {
    Row() {
      Column() {
        Text(`${this.data.name}`)
          .fontSize('18fp')
        if (!this.vm.uiConfig.listShowSimple) {
          Text(`createAt: ${this.data.data.createdAt}`)
            .fontSize('12fp')
        }
      }
      .alignItems(HorizontalAlign.Start)

      Blank().layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.data.open!! })
        .size({
          width: '50vp',
          height: '28vp',
        })
        .onClick(() => {
          // 关闭其他开关
          this.vm.closeOther(this.data.id)
          this.data.onClick();
        })
        .onChange((isOn: boolean) => {
          this.data.openChange(this.getUIContext(), isOn);
        })
    }
    .padding({ left: '16vp', right: '16vp' })
    .width('100%')
    .height('60vp')
  }
}

