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
import { ComposeTitleBar, SymbolGlyphModifier } from '@kit.ArkUI';
import { WireGuard } from '../model/WGHelper';
import { LLog } from '../tools/LLog';

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
      {
        value: "新建VPN",
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.plus_circle')),
        action: () => {
          WireGuard.navDescToNewWGConfigView(this.vm.nav, () => {
            this.vm.loadConfigs();
          });
        }
      }
    ])
  }

  @LocalBuilder
  titleView() {
    ComposeTitleBar()
  }
}

/**
 * WG主界面
 */
@ComponentV2
export struct WGMainView {
  @Param vm: WGMainViewModel = new WGMainViewModel();

  aboutToAppear(): void {
    this.vm.loadConfigs();
  }

  build() {
    List() {
      Repeat(this.vm.wgList)
        .each((it) => {
          ListItem() {
            MainItemView({ data: it.item, index: it.index })
              .onClick(() => {
                WireGuard.navDescToWGConfigPreView(this.vm.nav, { id: it.item.id });
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

  @LocalBuilder
  itemEndFunsView(it:RepeatItem<MainItemData>) {
    Row() {
      Text("删除")
        .textAlign(TextAlign.Center)
        .fontColor(Color.White)
        .width('150vp')
        .height('100%')
        .backgroundColor(Color.Red)
        .onClick(()=>{
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

