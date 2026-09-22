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
import { ComponentContent, promptAction, SymbolGlyphModifier } from '@kit.ArkUI';
import { LLog } from 'wg_tunnel/src/main/ets/tools/LLog';
import { WireGuardNav } from '../model/WireGuardNav';
import { QRCodeNewConfig, QRCodeNewConfig as QRCodeNewParams, QRCodeNewWGConfDialog } from './QRCodeNewWGConfDialog';
import { WGConf, WireGuard, vpnRunStatusState, StreamLogMessage, VpnEventTag } from 'wg_tunnel';
import { floatingMaterial, supportsImmersiveMaterial } from '../ui/WGImmersiveMaterial';

const TAG = "WG主页";

/** 鸿蒙7内嵌卡片行：系统卡片底色（深浅色自适应）+ 系统圆角档 + 行间距 */
@Extend(ListItem)
function mainRowCardStyle() {
  .backgroundColor($r('sys.color.comp_background_primary'))
  .borderRadius($r('sys.float.corner_radius_level4'))
  .margin({ bottom: '8vp' })
}

/** 删除粒子消散覆盖层的定位（vp，相对主页根Stack） */
interface WgDeleteFx {
  left: number;
  top: number;
  width: number;
  height: number;
}

/**
 * 删除消散粒子：一次性爆发——count为总量、高emitRate在约0.2s内全部射出，
 * lifetime 500±200ms 自然消亡；颜色在删除红与中性灰间随机插值，深浅色均可读
 */
function buildDeleteDissolveParticle(): ParticleOptions<ParticleType, ParticleUpdater,
  ParticleUpdater, ParticleUpdater, ParticleUpdater, ParticleUpdater, ParticleUpdater>[] {
  return [{
    emitter: {
      particle: {
        type: ParticleType.POINT,
        config: { radius: 4 },
        count: 72,
        lifetime: 500,
        lifetimeRange: 200
      },
      emitRate: 360,
      shape: ParticleEmitterShape.RECTANGLE,
      position: ['50%', '50%'],
      size: ['100%', '100%']
    },
    velocity: { speed: [40, 140], angle: [-180, 180] },
    color: { range: ['#FFE84026', '#FFBBBBBB'] },
    opacity: { range: [0.5, 1.0] },
    scale: { range: [0.5, 1.2] }
  }];
}

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
    // 鸿蒙7内嵌卡片：页面二级灰底衬托卡片行（深浅色自适应）
    .backgroundColor($r('sys.color.background_secondary'))
    // 菜单文案用静态标签：NavDestination.menus 的动态文案在V2下不随状态刷新，
    // 当前值改为点击后toast反馈（排序字段/方向/显示信息）
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
        value: "排序字段",
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.timer')),
        action: () => {
          this.vm.uiConfig.sortColumnToNext()
          this.getUIContext().getPromptAction().showToast({
            message: `已按${this.vm.uiConfig.getColumnName()}排序`,
          })
        }
      },
      {
        value: "排序方向",
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.timer')),
        action: () => {
          this.vm.uiConfig.listSortAsc = !this.vm.uiConfig.listSortAsc
          this.getUIContext().getPromptAction().showToast({
            message: `已切换为${this.vm.uiConfig.listSortAsc ? '正序' : '倒序'}`,
          })
        }
      },
      {
        value: "显示信息",
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.message')),
        action: () => {
          this.vm.uiConfig.listShowSimple = !this.vm.uiConfig.listShowSimple
          this.getUIContext().getPromptAction().showToast({
            message: `已切换为${this.vm.uiConfig.listShowSimple ? '简略' : '详细'}`,
          })
        }
      },
    ])
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
  @Local deleteFx: WgDeleteFx | undefined = undefined;
  listScroller: ListScroller = new ListScroller();
  private tickTimer?: number;
  private deleteFxTimer?: number;
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
      this.vm.resetRunTraffic();
    }
    // 新会话开启（含热切换到新配置）：清空上一会话的累计流量展示
    if ((params.tag as VpnEventTag) === VpnEventTag.START_VPN) {
      this.vm.resetRunTraffic();
    }
  })
  // 运行行流量展示的数据管道：只更新vm缓存，文本由每秒tick节流刷新
  streamEvent = WireGuard.event.subscribeVpnStreamLogs((log: StreamLogMessage) => {
    this.vm.updateRunTraffic(log);
  })

  aboutToAppear(): void {
    this.vm.loadConfigs();
    WireGuard.event.publishVpnStatusQuery();
    // 运行状态条"收/发X前"滚动刷新 + 运行行流量文本节流刷新（仅页面可见期间计时）
    this.tickTimer = setInterval(() => {
      this.nowTick = Date.now();
      this.vm.refreshRunTrafficText();
    }, 1000);
  }

  aboutToDisappear(): void {
    this.vpnEvent.cancel()
    this.streamEvent.cancel()
    if (this.tickTimer != undefined) {
      clearInterval(this.tickTimer);
      this.tickTimer = undefined;
    }
    if (this.deleteFxTimer != undefined) {
      clearTimeout(this.deleteFxTimer);
      this.deleteFxTimer = undefined;
    }
  }

  /**
   * 删除配置并播放粒子消散动效：
   * 取被删行相对主页根Stack的坐标，在原位播放一次粒子爆发（约0.9s），
   * 数据在粒子起飞后延迟120ms移除并伴随列表收拢动画；
   * 坐标取不到（页面瞬时重建等）时退化为直接删除。
   */
  private deleteWithFx(item: MainItemData): void {
    const ui = this.getUIContext();
    try {
      const row = ui.getComponentUtils().getRectangleById(`wg_cfg_row_${item.id}`);
      const root = ui.getComponentUtils().getRectangleById('wg_main_root');
      this.deleteFx = {
        left: ui.px2vp(row.windowOffset.x - root.windowOffset.x),
        top: ui.px2vp(row.windowOffset.y - root.windowOffset.y),
        width: ui.px2vp(row.size.width),
        height: ui.px2vp(row.size.height),
      };
    } catch (e) {
      LLog.warn(TAG, `删除动效取行坐标失败，直接删除: ${e}`);
    }
    if (this.deleteFxTimer != undefined) {
      clearTimeout(this.deleteFxTimer);
    }
    this.deleteFxTimer = setTimeout(() => {
      this.deleteFx = undefined;
      this.deleteFxTimer = undefined;
    }, 900);
    const idx = this.vm.wgList.findIndex(it => it.id === item.id);
    if (idx < 0) {
      return;
    }
    ui.animateTo({ duration: 260, curve: Curve.EaseOut, delay: 120 }, () => {
      this.vm.deleteConfig(idx, item);
    });
  }

  /** 状态条文案（nowTick驱动"收/发X前"响应式滚动） */
  get runStatusText(): string {
    return vpnRunStatusState.buildStatusText(this.nowTick);
  }

  /** 状态条颜色（深浅色资源自适应）：绿=已连接且心跳新鲜；橙=连接中/心跳久远；红=Socket异常 */
  get runStatusColor(): ResourceStr {
    const s = vpnRunStatusState;
    const socketErrorFresh = s.socketError !== '' && (this.nowTick - s.socketErrorTime) < 30 * 1000;
    if (socketErrorFresh) {
      return $r('app.color.wg_run_status_error');
    }
    const heartbeatStale = s.lastHeartbeatTime === 0 || (this.nowTick - s.lastHeartbeatTime) > 180 * 1000;
    if (!s.handshakeOk || heartbeatStale) {
      return $r('app.color.wg_run_status_warn');
    }
    return $r('app.color.wg_run_status_ok');
  }

  /**
   * 运行状态条：标题与配置列表之间的固定单行窗体
   * 展示当前VPN连接情况——连接是否成功/上次收发数据时间/Socket异常提示
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
      .backgroundColor($r('app.color.wg_run_status_banner_bg'))
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
      // 删除粒子消散覆盖层（定位到被删行原位置，粒子播完自动移除）
      if (this.deleteFx != undefined) {
        Particle({ particles: buildDeleteDissolveParticle() })
          .width(this.deleteFx.width)
          .height(this.deleteFx.height)
          .position({ x: this.deleteFx.left, y: this.deleteFx.top })
          .hitTestBehavior(HitTestMode.None)
      }
      Button() {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontColor([$r('app.color.wg_float_button_svg_color')])
      }
      .width('45vp')
      .aspectRatio(1)
      // 鸿蒙7沉浸光感：API26+改ULTRA_THIN浮动件材质+半透明赋色背景。
      // 注意两点：①纯色页面上无赋色的超薄材质无内容可折射会完全隐形；
      // ②materialColor传$r资源实测不被材质滤镜解析，改用普通backgroundColor
      // 叠半透明色（FAQ：只有不透明背景会盖死材质，半透明=色调叠加，
      // 且$r深浅色自适应必然生效）；旧系统回落原浅青纯色
      .backgroundColor(supportsImmersiveMaterial()
        ? $r('app.color.wg_float_button_glass_tint') : $r(`app.color.wg_float_button_backgroud_color`))
      .borderRadius($r('sys.float.corner_radius_level5'))
      .systemMaterial(floatingMaterial())
      .layoutGravity(LocalizedAlignment.BOTTOM_END)
      .margin({ bottom: '32vp', right: "32vp" })
      // .position({ x: '80%', y: '85%' }) // 右下角位置
      .hitTestBehavior(HitTestMode.Block) // 阻塞父组件事件（原Transparent被此处覆盖，属无效代码已去重）
      .onClick((event: ClickEvent) => {
        animateToImmediately({ duration: 100 }, () => {
          this.isShow = true;
        })
      })
      .bindMenu(this.isShow!!, this.funcBtn, {
        placement: Placement.Top,
      })
    }
    .id('wg_main_root')
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
              .id(`wg_cfg_row_${it.item.id}`)
              .onClick(() => {
                WireGuardNav.navDescToWGConfigPreView(this.vm.nav, { id: it.item.id }, () => {
                  LLog.info(TAG, "onPop 从预览页返回，刷新列表")
                  this.vm.loadConfigs();
                });
              })
          }
          .mainRowCardStyle()
          .swipeAction({
            end: {
              builder: () => {
                this.itemEndFunsView(it);
              },
              onAction: () => {
                this.listScroller.closeAllSwipeActions();
                this.deleteWithFx(it.item);
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
    // 鸿蒙7内嵌卡片行：行自带卡片底/圆角，分割线由行间距替代
    .padding({ left: '12vp', right: '12vp', top: '4vp' })
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
            this.deleteWithFx(it.item);
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
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (!this.vm.uiConfig.listShowSimple) {
          Text(`createAt: ${this.data.data.createdAt}`)
            .fontSize('12fp')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (this.data.busyLabel != undefined) {
        Text(this.data.busyLabel)
          .fontSize('12fp')
          .fontColor($r('sys.color.font_tertiary'))
          .margin({ right: '8vp' })
      }
      // 运行中配置：开关左侧展示本会话累计下载/上传（vm每秒节流刷新）
      if (this.data.open) {
        Text(`↓${this.vm.runRxText} ↑${this.vm.runTxText}`)
          .fontSize('12fp')
          .fontColor($r('app.color.share_secondary_text'))
          .margin({ right: '8vp' })
      }
      Toggle({ type: ToggleType.Switch, isOn: this.data.open!! })
        .selectedColor($r('app.color.wg_theme_primary'))
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
    .constraintSize({ minHeight: '60vp' })
  }
}

