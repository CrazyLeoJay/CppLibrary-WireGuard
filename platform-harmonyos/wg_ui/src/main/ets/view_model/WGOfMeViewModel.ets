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
import { bundleManager, common } from '@kit.AbilityKit';
import { UIContext } from '@ohos.arkui.UIContext';
import pasteboard from '@ohos.pasteboard';
import { LLog } from 'wg_tunnel';

const TAG = "设置界面"
const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
const wireguardSite = "https://www.wireguard.com/"
const wireguardPapersSite = "https://www.wireguard.com/papers/wireguard.pdf"
const myGitHubProjectSite = "https://github.com/CrazyLeoJay/CppLibrary-WireGuard/tree/master-harmonyos"
const myGitHubSite = "https://github.com/CrazyLeoJay"
const email = "crazyleojay@163.com"

/**
 * 设置界面数据配置
 *
 * Created on 2026/4/21.
 * @author leojay`fu
 */
@ObservedV2
export default class WGSettingViewModel {
  nav: NavPathStack;
  @Trace icon?: Resource;
  @Trace appName: string = ""
  @Trace appVersion: string = ""
  email: string = email

  constructor(nav: NavPathStack) {
    this.nav = nav;
  }

  async loadData(context: UIContext) {
    const msg = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
    this.icon = $r(`app.media.${msg.appInfo.icon.split(":")[1]}`)
    this.appName = msg.appInfo.name
    this.appVersion = msg.versionName
  }

  clickToWireGuardWebSite(context: UIContext) {
    (context.getHostContext() as common.UIAbilityContext).startAbility({
      action: 'ohos.want.action.viewData', // 固定操作类型
      entities: ['entity.system.browsable'], // 标识可浏览实体
      uri: wireguardSite      // 目标链接
    })
      .then(() => console.info('浏览器拉起成功'))
      .catch((err: BusinessError) => {
        console.error(`失败代码: ${err.code}, 错误信息: ${err.message}`);
      });
  }

  clickToPapersWebSite(context: UIContext) {
    (context.getHostContext() as common.UIAbilityContext).startAbility({
      action: 'ohos.want.action.viewData', // 固定操作类型
      entities: ['entity.system.browsable'], // 标识可浏览实体
      uri: wireguardPapersSite      // 目标链接
    })
      .then(() => console.info('浏览器拉起成功'))
      .catch((err: BusinessError) => {
        console.error(`失败代码: ${err.code}, 错误信息: ${err.message}`);
      });
  }

  clickToMyGitHubWebSite(context: UIContext) {
    (context.getHostContext() as common.UIAbilityContext).startAbility({
      action: 'ohos.want.action.viewData', // 固定操作类型
      entities: ['entity.system.browsable'], // 标识可浏览实体
      uri: myGitHubSite      // 目标链接
    })
      .then(() => console.info('浏览器拉起成功'))
      .catch((err: BusinessError) => {
        console.error(`失败代码: ${err.code}, 错误信息: ${err.message}`);
      });
  }
  clickToMyGitHubProjectWebSite(context: UIContext) {
    (context.getHostContext() as common.UIAbilityContext).startAbility({
      action: 'ohos.want.action.viewData', // 固定操作类型
      entities: ['entity.system.browsable'], // 标识可浏览实体
      uri: myGitHubProjectSite      // 目标链接
    })
      .then(() => console.info('浏览器拉起成功'))
      .catch((err: BusinessError) => {
        console.error(`失败代码: ${err.code}, 错误信息: ${err.message}`);
      });
  }

  async copyEmail(context: UIContext) {
    let pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, email);
    try {
      await systemPasteboard.setData(pasteData);
      LLog.info(TAG, "将邮箱复制进入系统剪贴板")
      context.getPromptAction().showToast({
        message: "已复制邮箱地址",
      })
    } catch (error) {
      LLog.info(TAG, `将邮箱复制进入系统剪贴板 异常！！！！：${error}`)
    }
  }
}
