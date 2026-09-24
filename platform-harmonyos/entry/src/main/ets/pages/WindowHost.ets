/*
 * Copyright [2026] @github-crazyleojay (crazyleojay@163.com/gmail.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LLog } from 'wg_tunnel';
import { CustomWindowContentArg, getWindowContentBuilder } from 'wg_ui';

const TAG = 'WindowHost';

/**
 * 定制窗口内容宿主页（核心通用件，无任何定制引用）
 *
 * main_pages 是 HAP 级页面表无法按包合并，定制窗口（悬浮球等）的内容经
 * wg_ui 注册表注入本页渲染——main_pages 不出现定制页面名，摘除定制模块
 * 后本页保留但渲染为空（且不会有窗口加载它）。
 * 透明背景：官方FAQ方案二，setWindowBackgroundColor须在loadContent生效后
 * 调用（API明文约束，否则1300002），页面就绪后经getLastWindow设置最稳；
 * 失败由Manager侧post-show设置兜底。
 */
@Entry
@Component
struct WindowHost {
  aboutToAppear(): void {
    window.getLastWindow(getContext(this) as common.UIAbilityContext).then((win: window.Window) => {
      win.setWindowBackgroundColor('#00000000');
    }).catch((e: BusinessError) => {
      LLog.warn(TAG, { error: e, message: '页面侧设置透明背景失败' });
    });
  }

  build() {
    Column() {
      if (getWindowContentBuilder() != undefined) {
        getWindowContentBuilder()!.builder({} as CustomWindowContentArg)
      }
    }
    .width('100%')
    .height('100%')
  }
}
