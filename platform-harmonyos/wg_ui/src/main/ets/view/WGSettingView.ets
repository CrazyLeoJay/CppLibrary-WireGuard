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
 */
import { LLog, AppFilterMode, networkResidueState } from 'wg_tunnel';
import WGSettingViewModel from '../view_model/WGOfMeViewModel';
import { BusinessError } from '@kit.BasicServicesKit';
import { ComponentContent, promptAction } from '@kit.ArkUI';
import BuildProfile from '../../../../BuildProfile';

const TAG = "设置界面"

/**
 * 设置界面
 *
 * Created on 2026/4/21.
 * @author leojay`fu
 */

@Builder
function WGSettingViewNavDestPage() {
  WGSettingViewNavDest();
}

@Preview
@ComponentV2
struct WGSettingViewNavDest {
  @Param nav: NavPathStack = new NavPathStack();
  @Local vm: WGSettingViewModel = new WGSettingViewModel(this.nav);

  build() {
    NavDestination() {
      WGSettingView({ vm: this.vm })
    }
    .onReady((info) => {
      if (info.pathInfo instanceof NavPathStack) {
        this.vm.nav = info.pathStack
      }
    })
    .title("设置")
  }
}

@ComponentV2
struct WGSettingView {
  @Param @Require vm: WGSettingViewModel;
  @Local showHide: boolean = false;
  @Local showHideClickCount: number = 0;
  maxClick = 10 - 1;

  aboutToAppear(): void {
    this.vm.loadData(this.getUIContext());
    this.vm.refreshNetworkStatus();
    this.vm.startNetworkStatusWatch();
  }

  aboutToDisappear(): void {
    this.vm.stopNetworkStatusWatch();
  }

  /** 「修复网络」小字：当前网络状态实时摘要（当前网络/VPN挂载/残留/是否正常） */
  get networkStatusText(): string {
    const s = networkResidueState;
    if (s.checking) {
      return '正在检测网络状态…';
    }
    if (s.checkedAt === 0) {
      return '尚未检测网络状态';
    }
    if (!s.hasNetwork) {
      return '当前无可用网络，建议检查网络连接';
    }
    // vpnMounted按系统全部网络的BEARER_VPN枚举判定（分流配置下默认网络不切换为VPN，
    // 不能以默认网络bearer为准）；residue=意图已关但VPN网络仍挂载
    if (s.residue) {
      return `当前网络=${s.netType}，VPN网络残留，建议修复`;
    }
    if (s.vpnMounted) {
      return `当前网络=${s.netType}，VPN网络挂载中，网络正常`;
    }
    return `当前网络=${s.netType}，VPN网络未挂载，无残留，网络正常`;
  }

  @Styles
  itemRowStyle(){
    .width('100%')
    .padding({
      top: '8vp',
      bottom: '8vp',
      left: '16vp',
      right: '16vp'
    })
  }

  build() {
    List({ space: '16vp' }) {
      // ===== 应用版本信息 =====
      this.buildAppIconVersionMessage();
      // ===== 应用申明 =====
      this.buildStatement()
      // ===== 导出隧道配置 =====
      this.buildBaseFuns();
      // ===== 悬浮球（闭源定制接入后显示；开源构建未注册门面则隐藏） =====
      if (this.vm.floatBallAvailable) {
        this.buildFloatBall();
      }
      // ===== 悬浮球测试（仅 debug 构建显示，绕过开关直接拉起悬浮窗） =====
      if (BuildProfile.DEBUG && this.vm.floatBallAvailable) {
        this.buildFloatBallDebug();
      }
      // ===== 应用过滤配置 =====
      this.buildBaseSetting();

      // ===== 开发者模式（仅 debug 构建显示） =====
      if (BuildProfile.DEBUG) {
        this.buildDevModel();
      }

      // ===== 关于 =====
      this.buildForMe();

      ListItem() {
        Column() {
          Text(`联系邮箱：${this.vm.email} (点击复制邮箱地址)`)
            .wordBreak(WordBreak.BREAK_WORD)
            .width('100%')
            .tagStyle()
          Text(
            `项目是我根据WireGuard官方白皮书，使用C++14完全由自己编写，项目中用到的开源项目均已在项目中标记。可以通过在github或者通过邮箱向我提供意见以及改进建议。`)
            .wordBreak(WordBreak.BREAK_WORD)
            .width('100%')
            .tagStyle()
        }
        .alignItems(HorizontalAlign.Start)
        .itemRowStyle()
        .onClick(() => {
          this.vm.copyEmail(this.getUIContext());
        })
      }
    }
    .width('100%')
    .height('100%')
    .listStyle()
  }

  /**
   * 应用icon、版本信息
   */
  @LocalBuilder
  buildAppIconVersionMessage() {
    ListItem() {
      Row({ space: '16vp' }) {
        Image($r('app.media.wg_icon'))
          .aspectRatio(1)
          .width('85vp')
        Column({ space: '8vp' }) {
          Text(`WireGuard for HarmonyOs v${this.vm.appVersion}`)
            .fontSize('18fp')
            .wordBreak(WordBreak.BREAK_WORD)
            .maxLines(3)
            .width('100%')
          Text('开源项目\nAuthor: GitHub/CrazyLeojay ')
            .fontSize('12fp')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .alignItems(VerticalAlign.Top)
      .onClick(() => {
        this.vm.clickToMyGitHubProjectWebSite(this.getUIContext());
      })
      .width('100%')
      .padding({
        top: '16vp',
        left: '16vp',
        right: '16vp'
      })
    }

  }

  /**
   * 申明
   */
  @LocalBuilder
  buildStatement() {
    ListItem() {
      Column() {
        Text($r('app.string.review_instructions'))
          .fontSize('14fp')
          .wordBreak(WordBreak.BREAK_WORD)
          .width('100%')
          .onClick(() => {
            if (this.showHide) {
              this.showHide = false;
            } else if (this.showHideClickCount == this.maxClick) {
              this.showHide = true;
              this.showHideClickCount = 0;
            } else {
              this.showHideClickCount++;
            }
          })
          .tagStyle()
        if (this.showHide) {
          Text($r('app.string.review_instructions_hide'))
            .fontSize('14fp')
            .wordBreak(WordBreak.BREAK_WORD)
            .width('100%')
            .onClick(() => {
              this.showHide = false;
            })
        }
      }
      .layoutWeight(1)
      .itemRowStyle()
    }
  }

  /**
   * 应用基础功能
   */
  @LocalBuilder
  buildBaseFuns() {
    ListItem() {
      Column({ space: '4vp' }) {
        Text("导出隧道配置")
          .defaultTagTitleStyle()
        Text("导出配置为zip文件在下载目录中")
          .width('100%')
          .fontSize('12fp')
      }
      .onClick(() => {
        this.vm.saveConfigToZip(this.getUIContext()).catch((e: BusinessError) => {
          LLog.error(TAG, e)
        })
      })
      .layoutWeight(1)
      .itemRowStyle()
    }
    ListItem() {
      Column({ space: '4vp' }) {
        Text("修复网络")
          .defaultTagTitleStyle()
        Text(this.networkStatusText)
          .width('100%')
          .fontSize('12fp')
      }
      .onClick(() => {
        this.vm.repairNetwork(this.getUIContext()).catch((e: BusinessError) => {
          LLog.error(TAG, e)
        })
      })
      .layoutWeight(1)
      .itemRowStyle()
    }
  }

  /**
   * 悬浮球开关（照开发者模式 Toggle 行范式）
   */
  @LocalBuilder
  buildFloatBall() {
    ListItem() {
      Column({ space: '8vp' }) {
        Text('悬浮球')
          .defaultTagTitleStyle()

        Row() {
          Column({ space: '2vp' }) {
            Text('桌面悬浮球')
              .fontSize('16fp')
            Text('在其他应用上层悬浮显示连接状态，支持快捷检查网络与回到应用')
              .fontSize('12fp')
              .fontColor($r('sys.color.font_tertiary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.vm.floatBallEnabled })
            .selectedColor($r('app.color.wg_theme_primary'))
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .itemRowStyle()
      .onClick(() => {
        // 点击整行切换悬浮球
        this.vm.toggleFloatBall(this.getUIContext());
      })
    }
  }

  /**
   * 悬浮球测试入口（仅 debug 构建显示）：绕过开关配置直接拉起悬浮窗，
   * 隔离"悬浮窗能否创建显示"与"悬浮球开关"两个问题；结果用Toast回报
   */
  @LocalBuilder
  buildFloatBallDebug() {
    ListItem() {
      Column({ space: '8vp' }) {
        Text('悬浮球测试')
          .defaultTagTitleStyle()

        Row() {
          Column({ space: '2vp' }) {
            Text('直接拉起悬浮球')
              .fontSize('16fp')
            Text('无论上方悬浮球开关是否开启，点击立即创建并显示悬浮窗')
              .fontSize('12fp')
              .fontColor($r('sys.color.font_tertiary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Blank()
          Button('拉起')
            .buttonStyle(ButtonStyleMode.NORMAL)
            .onClick(() => {
              this.vm.debugOpenFloatBall(this.getUIContext());
            })
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .itemRowStyle()
    }
  }

  /**
   * 应用基础设置
   */
  @LocalBuilder
  buildBaseSetting() {
    ListItem() {
      Column({ space: '8vp' }) {
        Text('应用过滤')
          .defaultTagTitleStyle()

        // 默认过滤模式 — 胶囊分段开关
        Row() {
          Text('默认过滤模式')
            .fontSize('16fp')
            .layoutWeight(1)

          // 胶囊分段开关：左半圆(黑名单) + 矩形 + 右半圆(白名单)
          Stack() {
            // 底层：两个半透明背景块
            Row() {
              // 左侧：黑名单背景
              Column()
                .width('50%')
                .height('100%')
                .borderRadius({ topLeft: 14, bottomLeft: 14 })
                .backgroundColor(this.vm.defaultFilterMode === AppFilterMode.EXCLUDED
                  ? $r('app.color.wg_new_card_item_select_color')
                  : $r('app.color.wg_seg_unselected_bg'))

              // 右侧：白名单背景
              Column()
                .width('50%')
                .height('100%')
                .borderRadius({ topRight: 14, bottomRight: 14 })
                .backgroundColor(this.vm.defaultFilterMode === AppFilterMode.INCLUDED
                  ? $r('app.color.wg_new_card_item_select_color')
                  : $r('app.color.wg_seg_unselected_bg'))
            }
            .width('100%')
            .height('100%')

            // 上层：文字标签
            Row() {
              Text('黑名单')
                .fontSize('12fp')
                .fontWeight(this.vm.defaultFilterMode === AppFilterMode.EXCLUDED ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.vm.defaultFilterMode === AppFilterMode.EXCLUDED ? Color.White : $r('sys.color.font_secondary'))
                .textAlign(TextAlign.Center)
                .layoutWeight(1)

              Text('白名单')
                .fontSize('12fp')
                .fontWeight(this.vm.defaultFilterMode === AppFilterMode.INCLUDED ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.vm.defaultFilterMode === AppFilterMode.INCLUDED ? Color.White : $r('sys.color.font_secondary'))
                .textAlign(TextAlign.Center)
                .layoutWeight(1)
            }
            .width('100%')
            .height('100%')
          }
          .width('152vp')
          .height('28vp')
          .borderRadius(14)
          .border({ width: 1, color: $r('app.color.wg_input_border'), radius: 14 })
        }
        .width('100%')

        // 根据选中模式显示不同注释
        if (this.vm.defaultFilterMode === AppFilterMode.EXCLUDED) {
          Text('黑名单模式：列表中的应用不经过VPN通道，其余应用正常走VPN')
            .fontSize('12fp')
            .fontColor($r('sys.color.font_tertiary'))
            .width('100%')
        } else {
          Text('白名单模式：仅列表中的应用经过VPN通道，其余应用不走VPN')
            .fontSize('12fp')
            .fontColor($r('sys.color.font_tertiary'))
            .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .itemRowStyle()
      .onClick(() => {
        this.vm.toggleDefaultFilterMode();
      })
    }
  }

  /**
   * 开发者模式
   */
  @LocalBuilder
  buildDevModel() {
    ListItem() {
      Column({ space: '8vp' }) {
        Text('开发者选项')
          .defaultTagTitleStyle()

        Row() {
          Column({ space: '2vp' }) {
            Text('开发者模式')
              .fontSize('16fp')
            Text('开启后在分享页面显示调试信息')
              .fontSize('12fp')
              .fontColor($r('sys.color.font_tertiary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.vm.developerMode })
            .selectedColor($r('app.color.wg_theme_primary'))
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .itemRowStyle()
      .onClick(() => {
        // 点击整行切换开发者模式
        this.vm.toggleDeveloperMode();
      })
    }
  }

  @LocalBuilder
  buildForMeTitle() {
    Text("关于")
      .width("100%")
      .defaultTagTitleStyle()
      .padding({
        left:'16vp'
      })
      .height('35vp')
  }

  /**
   * 关于我、项目说明
   */
  @LocalBuilder
  buildForMe() {
    ListItemGroup({
      header: this.buildForMeTitle(),
    }) {
      ListItem() {
        Row() {
          Text('WG-VPN 主页')
            .fontSize('18fp')
          Blank().layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
        }
        .listGroupItemStyle()
        .onClick(() => {
          this.vm.clickToWgVpnHome(this.getUIContext());
        })
      }

      ListItem() {
        Row() {
          Text('使用说明')
            .fontSize('18fp')
          Blank().layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
        }
        .listGroupItemStyle()
        .onClick(() => {
          this.vm.clickToUserGuide(this.getUIContext());
        })
      }

      ListItem() {
        Row() {
          Text('WireGuard 官网')
            .fontSize('18fp')
          Blank().layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
        }
        .listGroupItemStyle()
        .onClick(() => {
          this.vm.clickToWireGuardWebSite(this.getUIContext());
        })
      }

      ListItem() {
        Row() {
          Text('WireGuard 白皮书')
            .fontSize('18fp')
          Blank().layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
        }
        .listGroupItemStyle()
        .onClick(() => {
          this.vm.clickToPapersWebSite(this.getUIContext());
        })
      }

      ListItem() {
        Row() {
          Text('开源库声明')
            .fontSize('18fp')
          Blank().layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
        }
        .listGroupItemStyle()
        .onClick(() => {
          this.vm.clickToOpenSourceNotice(this.getUIContext());
        })
      }

      ListItem() {
        Row() {
          Text('关于作者')
            .fontSize('18fp')
          Blank().layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
        }
        .listGroupItemStyle()
        .onClick(() => {
          this.vm.clickToMyGitHubWebSite(this.getUIContext());
        })
      }

      ListItem() {
        Row() {
          Text('联系我')
            .fontSize('18fp')
          Blank().layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
        }
        .listGroupItemStyle()
        .onClick(() => {
          this.showWechatQRCodeDialog();
        })
      }
    }
    .listGroupStyle()
  }

  showWechatQRCodeDialog() {
    const contentNode = new ComponentContent(this.getUIContext(), wrapBuilder(buildWechatQRCodeDialog),
      {} as WechatQRCodeDialogParams
    );
    this.getUIContext()
      .getPromptAction()
      .openCustomDialogWithController(contentNode, new promptAction.DialogController(), {
        alignment: DialogAlignment.Center,
        autoCancel: true
      })
      .then(() => {
        contentNode.dispose();
      })
      .catch((e: BusinessError) => {
        LLog.info(TAG, e);
      });
  }
}

interface WechatQRCodeDialogParams {}

@Builder
function buildWechatQRCodeDialog(_params: WechatQRCodeDialogParams) {
  WechatQRCodeDialogContent()
}

@ComponentV2
struct WechatQRCodeDialogContent {
  build() {
    Column() {
      Image($r('app.media.wechat_qrcode'))
        .width('260vp')
        .height('260vp')
        .objectFit(ImageFit.Contain)
        .borderRadius('16vp')

      Text('微信扫码联系')
        .fontSize('16fp')
        .fontColor($r('sys.color.font_tertiary'))
        .margin({ top: '16vp' })
    }
    .padding('24vp')
    .alignItems(HorizontalAlign.Center)
  }
}

@Extend(Text)
function tagStyle() {
  .fontSize('12fp')
  .fontColor($r('sys.color.font_tertiary'))
}

/**
 * 默认列表样式
 */
@Extend(List)
function listStyle() {
  .width('100%')
  // .height('100%')
  .divider({
    strokeWidth: '1vp',
    color: $r('app.color.wg_divider_color'),
  })
}

@Extend(ListItemGroup)
function listGroupStyle() {
  .width('100%')
  // .height('100%')
  .divider({
    strokeWidth: '1vp',
    color: $r('app.color.wg_divider_color'),
  })
}

@Extend(Row)
function listGroupItemStyle(){
  .width('100%')
  .padding({
    top: '16vp',
    bottom: '16vp',
    left: '16vp',
    right: '16vp'
  })
}

@Extend(Text)
function defaultTagTitleStyle() {
  .fontSize('18fp')
  .fontWeight(FontWeight.Bold)
  .width('100%')
}
