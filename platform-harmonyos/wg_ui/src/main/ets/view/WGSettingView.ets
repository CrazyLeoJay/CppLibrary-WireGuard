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
import { LLog, AppFilterMode } from 'wg_tunnel';
import WGSettingViewModel from '../view_model/WGOfMeViewModel';

const TAG = "设置界面"
/** 编译时决定，release 构建时此常量为 false，开发者选项不显示 */
const IS_DEBUG = true;

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
    this.vm.loadData(this.getUIContext())
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
      // ===== 应用过滤配置 =====
      this.buildBaseSetting();

      // ===== 开发者模式（仅 debug 构建显示） =====
      if (IS_DEBUG) {
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
                  : '#1A000000')

              // 右侧：白名单背景
              Column()
                .width('50%')
                .height('100%')
                .borderRadius({ topRight: 14, bottomRight: 14 })
                .backgroundColor(this.vm.defaultFilterMode === AppFilterMode.INCLUDED
                  ? $r('app.color.wg_new_card_item_select_color')
                  : '#1A000000')
            }
            .width('100%')
            .height('100%')

            // 上层：文字标签
            Row() {
              Text('黑名单')
                .fontSize('12fp')
                .fontWeight(this.vm.defaultFilterMode === AppFilterMode.EXCLUDED ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.vm.defaultFilterMode === AppFilterMode.EXCLUDED ? Color.White : '#666666')
                .textAlign(TextAlign.Center)
                .layoutWeight(1)

              Text('白名单')
                .fontSize('12fp')
                .fontWeight(this.vm.defaultFilterMode === AppFilterMode.INCLUDED ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.vm.defaultFilterMode === AppFilterMode.INCLUDED ? Color.White : '#666666')
                .textAlign(TextAlign.Center)
                .layoutWeight(1)
            }
            .width('100%')
            .height('100%')
          }
          .width('152vp')
          .height('28vp')
          .borderRadius(14)
          .border({ width: 1, color: '#33999999', radius: 14 })
        }
        .width('100%')

        // 根据选中模式显示不同注释
        if (this.vm.defaultFilterMode === AppFilterMode.EXCLUDED) {
          Text('黑名单模式：列表中的应用不经过VPN通道，其余应用正常走VPN')
            .fontSize('12fp')
            .fontColor('#ff707070')
            .width('100%')
        } else {
          Text('白名单模式：仅列表中的应用经过VPN通道，其余应用不走VPN')
            .fontSize('12fp')
            .fontColor('#ff707070')
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
              .fontColor('#ff707070')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.vm.developerMode })
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
    }
    .listGroupStyle()
  }
}

@Extend(Text)
function tagStyle() {
  .fontSize('12fp')
  .fontColor('#ff707070')
}

/**
 * 默认列表样式
 */
@Extend(List)
function listStyle() {
  .width('100%')
  // .height('100%')
  .divider({
    strokeWidth: '2vp'
  })
}

@Extend(ListItemGroup)
function listGroupStyle() {
  .width('100%')
  // .height('100%')
  .divider({
    strokeWidth: '2vp'
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
