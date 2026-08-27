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
import { LLog, WireGuard } from 'wg_tunnel';
import fs from '@ohos.file.fs';
import { zlib } from '@kit.BasicServicesKit';
import { fileUri, picker } from '@kit.CoreFileKit';

const TAG = "设置界面"
const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
const wireguardSite = "https://www.wireguard.com/"
const wireguardPapersSite = "https://www.wireguard.com/papers/wireguard.pdf"
const myGitHubProjectSite = "https://github.com/CrazyLeoJay/CppLibrary-WireGuard/tree/master-harmonyos"
const myGitHubSite = "https://github.com/CrazyLeoJay"
const email = "crazyleojay@163.com"
const OPEN_SOURCE_NOTICE = "https://github.com/CrazyLeoJay/CppLibrary-WireGuard/blob/master/NOTICE"

/**
 * 设置界面数据配置
 *
 * Created on 2026/4/21.
 * @author leojay`fu
 */
@ObservedV2
export default class WGSettingViewModel {
  nav: NavPathStack;
  @Trace appName: string = ""
  @Trace appVersion: string = ""
  email: string = email

  constructor(nav: NavPathStack) {
    this.nav = nav;
  }

  async loadData(context: UIContext) {
    const msg = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
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

  /**
   * 开源库声明
   */
  clickToOpenSourceNotice(context: UIContext) {
    (context.getHostContext() as common.UIAbilityContext).startAbility({
      action: 'ohos.want.action.viewData', // 固定操作类型
      entities: ['entity.system.browsable'], // 标识可浏览实体
      uri: OPEN_SOURCE_NOTICE      // 目标链接
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

  /**
   * 保存配置到zip文件
   */
  /**
   * @throws
   */
  async saveConfigToZip(context: UIContext) {

    // if (!canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection')) {
    //   throw new WGAppException("不支持保存到本地")
    // }

    const dir = WireGuard.Paths.getZipEncodeTmpDir(context.getHostContext()!)
    const contentDir = `${dir}/compress_files` // 生成需要压缩的文件
    const zipFilePath = `${dir}/wireguard.zip` // 压缩的目标文件

    try {
      if (!await fs.access(contentDir)) {
        await fs.mkdir(contentDir, true)
      }

      const configs = WireGuard.helper.config.allDBConfig()
      const zipFilePaths: string[] = []
      const nameMap: Map<string, number> = new Map();

      for (let item of configs) {
        const content = await WireGuard.helper.dbConfig2ConfFileContent(item)
        let name = item.name ?? item.conf.inter.deviceName

        const index = nameMap.get(name) ?? 0
        nameMap.set(name, index + 1) // 出现一次加个1
        if (index != 0) {
          name = `${name}_${index + 1}`
        }

        const filePath = `${contentDir}/${name}.conf`
        let file: fs.File | undefined
        try {
          file = await fs.open(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)
          await fs.write(file.fd, content)
          zipFilePaths.push(filePath)
          LLog.info(TAG, `创建配置:${name}`)
        } finally {
          if (file) {
            fs.close(file)
          }
        }
      }

      LLog.info(TAG, "开始压缩")
      await zlib.compressFiles(zipFilePaths, zipFilePath, {})
      LLog.info(TAG, "压缩完成，保存到本地")


      // 创建文件保存选项
      let documentSaveOptions = new picker.DocumentSaveOptions();
      // 设置为 DOWNLOAD 模式，直达下载目录
      // pickerMode设置为DOWNLOAD时，用户配置的参数newFileNames、defaultFilePathUri和fileSuffixChoices将不会生效。
      documentSaveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      let documentViewPicker = new picker.DocumentViewPicker(context.getHostContext()!);
      // 调用 save 方法，系统弹出保存界面，用户确认后返回文件 URI
      let documentSaveResult: Array<string> = await documentViewPicker.save(documentSaveOptions);
      if (documentSaveResult.length != 1) {
        LLog.info(TAG, `返回异常数量保存地址：count=${documentSaveResult.length}`)
        return
      }
      // DOWNLOAD 模式返回的是目录 URI（下载目录/包名）
      const dirUriStr = documentSaveResult[0];
      // 将目录 URI 转换为文件系统路径
      let dirPath: string = new fileUri.FileUri(dirUriStr).path;
      LLog.info(TAG, `地址: ${dirUriStr}\n转为：${dirPath}`)
      const writePath = `${dirPath}/wireguard-export.zip`;
      LLog.info(TAG, `保存: ${zipFilePath}\n到\n本地文件地址：${writePath}`)
      let wf: fs.File | undefined
      let rf: fs.File | undefined
      try {
        rf = await fs.open(zipFilePath, fs.OpenMode.READ_ONLY)
        wf = await fs.open(writePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)
        await fs.copyFile(rf.fd, wf.fd)
      } finally {
        if (rf) {
          await fs.close(rf)
        }
        if (wf) {
          await fs.close(wf)
        }
      }
      LLog.info(TAG, `保存到本地成功，地址=${writePath}`)
      context.getPromptAction().showToast({
        message: "保存成功到下载目录中"
      })
    } finally {
      if (await fs.access(dir)) {
        try {
          await fs.rmdir(dir)
          LLog.info(TAG, `删除缓存目录：${dir}`)
        } catch (err) {
          LLog.error(TAG, err)
        }
      }
    }
  }
}
