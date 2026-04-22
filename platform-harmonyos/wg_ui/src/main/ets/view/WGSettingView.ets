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
import { ComposeTitleBar } from '@kit.ArkUI';

/**
 *
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
  @Param nav:NavPathStack = new NavPathStack();
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

  build() {

  }
}