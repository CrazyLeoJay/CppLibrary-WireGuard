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
import WGSettingViewModel from '../view_model/WGOfMeViewModel';

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
            Text('Author: GitHub/CrazyLeojay ')
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

      ListItem() {
        Row() {
          Text('WireGuard 官网')
          Blank().layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
        }
        .itemRowStyle()
        .onClick(() => {
          this.vm.clickToWireGuardWebSite(this.getUIContext());
        })
      }

      ListItem() {
        Row() {
          Text('WireGuard 白皮书')
          Blank().layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
        }
        .itemRowStyle()
        .onClick(() => {
          this.vm.clickToPapersWebSite(this.getUIContext());
        })
      }

      ListItem() {
        Row() {
          Text('关于作者')
          Blank().layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
        }
        .itemRowStyle()
        .onClick(() => {
          this.vm.clickToMyGitHubWebSite(this.getUIContext());
        })
      }

      ListItem() {
        Column() {
          Text(`联系邮箱：${this.vm.email}`)
            .wordBreak(WordBreak.BREAK_WORD)
            .width('100%')
          Text(`可以通过在github或者通过邮箱向我提供意见以及改进建议。`)
            .wordBreak(WordBreak.BREAK_WORD)
            .width('100%')
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
    .divider({
      strokeWidth: '2vp'
    })
  }
}