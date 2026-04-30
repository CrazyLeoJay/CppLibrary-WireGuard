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
import WGConfigPreViewParams from '../entity/WGConfigPreViewParams';
import WGEditConfigParams from '../entity/WGEditConfigParams';

/**
 * UI界面导航
 *
 * Created on 2026/4/22.
 * @author leojay`fu
 */

export namespace WireGuardNav {

  /**
   * 跳转到 Wireguard 主页
   */
  export function navDescToWGMainPage(nav: NavPathStack) {
    nav.pushPath({
      name: "WGMainViewNavDest",
    })
  }

  /**
   * 跳转到添加配置页面
   * @param nav
   * @param onPop
   */
  export function navDescToNewWGConfigView(nav: NavPathStack, params?: WGEditConfigParams, onPop?: () => void) {
    nav.pushPath({
      name: "WGNewConfigView",
      param: params,
      onPop: () => {
        onPop?.();
      }
    })
  }

  /**
   * 添加到预览界面
   * @param nav
   * @param params
   * @param onPop
   */
  export function navDescToWGConfigPreView(nav: NavPathStack, params: WGConfigPreViewParams, onPop?: () => void) {
    nav.pushPath({
      name: "WGConfigPreView",
      param: params,
      onPop: () => {
        onPop?.();
      }
    })
  }

  /**
   * 关于我的界面
   *
   * @param nav
   * @param params
   * @param onPop
   */
  export function navDescToWGSettingPreView(nav: NavPathStack, onPop?: () => void) {
    nav.pushPath({
      name: "WGSettingView",
      onPop: () => {
        onPop?.();
      }
    })
  }

}