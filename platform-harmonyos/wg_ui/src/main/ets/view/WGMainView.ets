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
import { vpnToggleState } from '../view_model/VpnToggleService';
import { ComponentContent, ComposeTitleBar, promptAction, SymbolGlyphModifier } from '@kit.ArkUI';
import { LLog } from 'wg_tunnel/src/main/ets/tools/LLog';
import { WireGuardNav } from '../model/WireGuardNav';
import { QRCodeNewConfig, QRCodeNewConfig as QRCodeNewParams, QRCodeNewWGConfDialog } from './QRCodeNewWGConfDialog';
import { WGConf, WireGuard, vpnRunStatusState } from 'wg_tunnel';

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
  @Local isSwipeActionDelete: boolean = false;
  @Local nowTick: number = Date.now();
  listScroller: ListScroller = new ListScroller();
  private tickTimer?: number;
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
            try {
              this.getUIContext().getPromptAction().showToast({
                message: e.message
              })
            } catch (error) {
            }
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
    // 【仅显示同步，不控制开关】行开关唯一状态源是本地意图(StatusConfig)。
    // 仅在VPN进程要关闭（异常/进程关闭，本地意图已被状态机置关）时同步一次显示
    if (params.vpnThreadRunning === false) {
      this.vm.refreshRowStates();
    }
  })

  aboutToAppear(): void {
    this.vm.loadConfigs();
    WireGuard.event.publishVpnStatusQuery();
    // 运行状态条"心跳Xs前"滚动刷新（仅页面可见期间计时）
    this.tickTimer = setInterval(() => {
      this.nowTick = Date.now();
    }, 1000);
  }

  aboutToDisappear(): void {
    this.vpnEvent.cancel()
    if (this.tickTimer != undefined) {
      clearInterval(this.tickTimer);
      this.tickTimer = undefined;
    }
  }

  /** 运行配置名（按运行id从列表解析；列表未含时兜底显示配置#id） */
  private resolveRunningConfigName(): string {
    const id = vpnRunStatusState.runningConfigId;
    if (id < 0) {
      return '';
    }
    const item = this.vm.wgList.find(it => it.id === id);
    return item != undefined ? item.name : `配置#${id}`;
  }

  /** 状态条文案（nowTick驱动"心跳Xs前"响应式滚动） */
  get runStatusText(): string {
    return vpnRunStatusState.buildStatusText(this.nowTick, this.resolveRunningConfigName());
  }

  /** 状态条颜色：绿=已连接且心跳新鲜；橙=连接中/心跳久远；红=Socket异常 */
  get runStatusColor(): string {
    const s = vpnRunStatusState;
    const socketErrorFresh = s.socketError !== '' && (this.nowTick - s.socketErrorTime) < 30 * 1000;
    if (socketErrorFresh) {
      return '#D83931';
    }
    const heartbeatStale = s.lastHeartbeatTime === 0 || (this.nowTick - s.lastHeartbeatTime) > 180 * 1000;
    if (!s.handshakeOk || heartbeatStale) {
      return '#B25F00';
    }
    return '#2A5F1E';
  }

  /**
   * 运行状态条：标题与配置列表之间的固定单行窗体
   * 展示当前VPN连接情况——连接是否成功/上次心跳时间/Socket异常提示
   */
  @LocalBuilder
  buildRunStatusBanner() {
    if (vpnRunStatusState.running) {
      Row({ space: 8 }) {
        Circle({ width: 8, height: 8 })
          .fill(this.runStatusColor)
        Text(this.runStatusText)
          .fontSize(13)
          .fontColor(this.runStatusColor)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 7, bottom: 7 })
      .backgroundColor('#14000000')
    }
  }

  build() {
    Stack() {
      if (this.vm.isEmptyList) {
        this.buildEmptyView()
      } else {
        Column() {
          this.buildRunStatusBanner()
          this.buildConfigListView()
        }
        .width('100%')
        .height('100%')
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
    List({ scroller: this.listScroller }) {
      Repeat(this.vm.wgList)
        .each((it) => {
          ListItem() {
            MainItemView({ vm: this.vm, data: it.item, index: it.index })
              .onClick(() => {
                WireGuardNav.navDescToWGConfigPreView(this.vm.nav, { id: it.item.id }, () => {
                  LLog.info(TAG, "onPop 从预览页返回，刷新列表")
                  this.vm.loadConfigs();
                });
              })
          }
          .swipeAction({
            end: {
              builder: () => {
                this.itemEndFunsView(it);
              },
              onAction: () => {
                this.listScroller.closeAllSwipeActions();
                this.vm.deleteConfig(it.index, it.item);
              },
              onEnterActionArea: () => {
                this.isSwipeActionDelete = true;
              },
              onExitActionArea: () => {
                this.isSwipeActionDelete = false
              }
            },
            start: undefined,
          })
        })
        .virtualScroll({})
    }
    .width('100%')
    .layoutWeight(1)
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

  @Styles
  deleteStyle(){
    .width('120vp')
    .height('100%')

  }

  @LocalBuilder
  itemEndFunsView(it: RepeatItem<MainItemData>) {
    Row() {
      if (this.isSwipeActionDelete) {
        Text("松开删除")
          .textAlign(TextAlign.Center)
          .fontColor($r('app.color.swipe_delete_text_color'))
          .deleteStyle()
      } else {
        Text("删除")
          .textAlign(TextAlign.Center)
          .fontColor($r('app.color.swipe_delete_text_color'))
          .deleteStyle()
          .onClick(() => {
            this.listScroller.closeAllSwipeActions();
            this.vm.deleteConfig(it.index, it.item);
          })
      }
    }.backgroundColor($r('app.color.swipe_delete_bg_color'))
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
      if (this.data.busyLabel != undefined) {
        Text(this.data.busyLabel)
          .fontSize('12fp')
          .fontColor('#666666')
          .margin({ right: '8vp' })
      }
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
        .enabled(this.data.toggleEnable && vpnToggleState.phase === 'idle')
        .onChange((isOn: boolean) => {
          this.data.openChange(this.getUIContext(), isOn);
        })
    }
    .padding({ left: '16vp', right: '16vp' })
    .width('100%')
    .height('60vp')
  }
}

