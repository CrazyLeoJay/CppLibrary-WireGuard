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
import { appManager, common, Context } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';
import { MessageType, WGConf, WireGuard } from '../../../../Index';
import { LLog } from '../tools/LLog';
import { zlib } from '@kit.BasicServicesKit';
import WGAppException from '../error/WGAppException';
import fs from '@ohos.file.fs';
import { WGDBConf } from './entity/WGConfigEntity';
import { fileUri } from '@kit.CoreFileKit';

/**
 * WG 工具包
 *
 * Created on 2026/7/11.
 * @author leojay`fu
 */

const TAG = "WG工具"
const MAX_FILE_SIZE = 10 * 1024 * 1024

class WGToolsImpl {
  // 判断 VpnExtensionAbility 是否正在运行
  // 返回 true 表示正在运行，false 表示未运行
  async isVpnExtensionRunning(): Promise<boolean> {
    try {
      // 获取当前应用所有运行进程的信息
      const processInfos: appManager.ProcessInformation[] = await appManager.getRunningProcessInformation();

      // 遍历进程列表，查找进程名以 :vpn 结尾的进程
      for (const info of processInfos) {
        LLog.debug(TAG, '进程名: %{public}s, PID: %{public}d', info.processName, info.pid);
        if (info.processName.endsWith(':vpn')) {
          LLog.debug(TAG, 'VPN 进程正在运行, 进程名: %{public}s', info.processName);
          return true;
        }
      }
      LLog.debug(TAG, 'VPN 进程未运行');
      return false;
    } catch (err) {
      const error = err as BusinessError;
      LLog.error(TAG, '获取进程信息失败: %{public}s', JSON.stringify(error));
      return false;
    }
  }

  // 在 UIAbility 或页面中通过 context 获取
  async checkVpnByContext(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const processInfos =
        await context.getApplicationContext().getRunningProcessInformation();
      return processInfos.some((info: appManager.ProcessInformation) =>
      info.processName.endsWith(':vpn')
      );
    } catch (err) {
      LLog.error('VpnCheck', '检查失败: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  getMessageTypeDesc(messageType: MessageType): string {
    switch (messageType) {
      case MessageType.HANDSHAKE_INITIATION:
        return "发起握手"
      case MessageType.HANDSHAKE_RESPONSE:
        return "握手响应"
      case MessageType.HANDSHAKE_COOKIE:
        return "Cookie挑战"
      case MessageType.DATA:
        return "数据传输"
      case MessageType.INVALID:
        return "未知"
      default:
        return "未知"
    }
  }

  /**
   * 从文件读取配置（不写入数据库）
   *
   * 需要自己区分是单个配置文件还是压缩包
   *
   * @param context
   * @param resUrl
   * @returns 读取到的配置列表或单个配置
   * @throws WGAppException
   */
  async loadFileToConfigs(context: Context, resUrl: string): Promise<WGConf | WGConf[]> {
    LLog.info(TAG, "判断文件类型")
    const fileUriObj: fileUri.FileUri = new fileUri.FileUri(resUrl);
    const stat = await fs.stat(fileUriObj.path)
    if (!stat.isFile()) {
      throw new WGAppException("不是文件")
    }
    LLog.info(TAG, "开始解压缩分析配置")
    try {
      await this.validateZipFile(resUrl)
      return await this.zipAndReadWGConfig(context, resUrl)
    } catch (err) {
      if (resUrl.toLowerCase().endsWith('.conf')) {
        return await this.confFileReadToConfig(resUrl)
      }
      LLog.info(TAG, err)
      throw new WGAppException("不支持的文件类型，仅支持ZIP压缩包或.conf配置文件")
    }
  }

  /**
   * 从文件读取配置并写入数据库
   *
   * @param context
   * @param resUrl
   * @returns 导入成功的配置数量
   * @throws WGAppException
   */
  async loadFileToConfigsToDb(context: Context, resUrl: string): Promise<WGConf | WGConf[]> {
    const configs = await this.loadFileToConfigs(context, resUrl)

    if (configs instanceof Array) {
      WireGuard.helper.config.insertNewConfig(configs.map((it) => {
        return {
          name: it.inter.deviceName,
          conf: it,
        } as WGDBConf
      }))
      LLog.info(TAG, `配置写入数据库成功: ${configs.length} 个`)
    } else {
      WireGuard.helper.config.insertNewConfig({
        name: configs.inter.deviceName,
        conf: configs,
      } as WGDBConf)
      LLog.info(TAG, `配置写入数据库成功: ${configs.inter.deviceName}`)
    }
    return configs
  }

  /**
   * 从zip文件读取配.置（不写入数据库）
   * @param context 上下文
   * @param resUrl zip文件路径
   * @returns 读取到的配置列表
   * @throws WGAppException
   */
  async zipAndReadWGConfig(context: Context, resUrl: string): Promise<WGConf[]> {
    const cacheDir = WireGuard.Paths.getZipDecodeTmpDir(context)
    const copyFile = `${cacheDir}/wg.confs.zip`
    const decodeDir = `${cacheDir}/wg.confs.decode`

    try {
      await this.checkFileSize(resUrl)
      if (!await fs.access(cacheDir)) {
        LLog.debug(TAG, `创建缓存目录:${cacheDir}`)
        await fs.mkdir(cacheDir, true)
      }

      if (!await fs.access(decodeDir)) {
        LLog.debug(TAG, `创建解压缓存目录:${decodeDir}`)
        await fs.mkdir(decodeDir, true)
      }

      LLog.debug(TAG, `复制文件到指定目录:${copyFile}`)
      const resFd = await fs.open(resUrl, fs.OpenMode.READ_ONLY)
      await fs.copyFile(resFd.fd, copyFile);
      await fs.close(resFd)


      LLog.debug(TAG, `开始解压缩：${copyFile}`)
      await zlib.decompressFile(copyFile, decodeDir, {})
      LLog.debug(TAG, "解压缩结束")

      const confFiles = await this.listConfFiles(decodeDir)
      if (confFiles.length === 0) {
        throw new WGAppException("解压后未找到conf文件")
      }

      LLog.debug(TAG, "读取配置")
      return await this.readAllConfigs(confFiles)
    } finally {
      if (cacheDir) {
        if (await fs.access(cacheDir)) {
          this.deleteDir(cacheDir).catch((e: BusinessError) => {
            LLog.warn(TAG, `清理缓存目录失败: ${cacheDir}, error: ${JSON.stringify(e)}`)
          })
        }
      }
    }
  }

  async validateZipFile(resUrl: string): Promise<void> {
    if (!resUrl || resUrl.length === 0) {
      throw new WGAppException("文件路径为空")
    }

    let file: fs.File | undefined
    try {
      file = await fs.open(resUrl, fs.OpenMode.READ_ONLY)
      const buf = new ArrayBuffer(4)
      const readLen = await fs.read(file.fd, buf)

      if (readLen < 4) {
        throw new WGAppException("文件太小，无法读取文件头")
      }

      const bytes = new Uint8Array(buf)
      if (bytes[0] !== 0x50 || bytes[1] !== 0x4B || bytes[2] !== 0x03 || bytes[3] !== 0x04) {
        throw new WGAppException("不是有效的ZIP文件")
      }
    } catch (e) {
      if (e instanceof WGAppException) {
        throw e
      }
      throw new WGAppException({ message: "验证ZIP文件失败", e: e as Error })
    } finally {
      if (file) {
        fs.close(file).catch(() => {
        })
      }
    }
  }

  async checkFileSize(resUrl: string): Promise<void> {
    try {
      let path = resUrl;
      if (path.startsWith("file://")) {
        const fileUriObj: fileUri.FileUri = new fileUri.FileUri(resUrl);
        path = fileUriObj.path;
      }
      const stat = await fs.stat(path)
      if (stat.size > MAX_FILE_SIZE) {
        throw new WGAppException(`文件大小超过限制(最大10M)，当前大小: ${(stat.size / 1024 / 1024).toFixed(2)}M`)
      }
    } catch (e) {
      throw new WGAppException({ message: "获取文件大小失败", e: e as Error })
    }
  }

  async listConfFiles(dirPath: string): Promise<string[]> {
    LLog.info(TAG, `查找配置：${dirPath}`)
    try {
      const files = await fs.listFile(dirPath, {
        recursion: false, // 不递归
        filter: {
          suffix: [".conf"],
        }
      })
      return files
        .map((file: string) => `${dirPath}/${file}`)
        .filter((file: string) => {
          try {
            const stat = fs.statSync(file)
            return stat.isFile()
          } catch (e) {
            const err: BusinessError = e as BusinessError;
            // console.error(`获取文件信息失败: ${file}, code: ${err.code}, message: ${err.message}`);
            LLog.error(TAG, {
              error: e,
              message: `获取文件信息失败: ${file}, code: ${err.code}, message: ${err.message}`,
            })
            return false;
          }
        })
    } catch (e) {
      throw new WGAppException({ message: "读取解压目录失败", e: e as Error })
    }
  }

  async readSingleConfig(filePath: string): Promise<WGConf | undefined> {
    const fileName = filePath.substring(filePath.lastIndexOf('/') + 1)
    const configName = fileName.substring(0, fileName.lastIndexOf('.'))

    let file: fs.File | undefined
    try {
      file = await fs.open(filePath, fs.OpenMode.READ_ONLY)
      const buf = new ArrayBuffer(1024 * 1024)
      const readLen = await fs.read(file.fd, buf)

      if (readLen <= 0) {
        LLog.warn(TAG, `配置文件为空，跳过: ${fileName}`)
        return undefined
      }

      const content = buffer.from(buf).toString()
      const wgConf = await WireGuard.readWgConf(content)
      wgConf.inter.deviceName = configName;

      LLog.info(TAG, `成功读取配置: ${configName}`)
      return wgConf
    } catch (e) {
      LLog.warn(TAG, `读取配置文件失败，跳过: ${fileName}, error: ${JSON.stringify(e)}`)
      return undefined
    } finally {
      if (file) {
        fs.close(file).catch(() => {
        })
      }
    }
  }

  async readAllConfigs(filePaths: string[]): Promise<WGConf[]> {
    const configs: WGConf[] = []

    for (const filePath of filePaths) {
      const config = await this.readSingleConfig(filePath)
      if (config) {
        configs.push(config)
      }
    }

    if (configs.length === 0) {
      throw new WGAppException("没有成功读取到任何配置")
    }

    return configs
  }

  async deleteDir(dirPath: string): Promise<void> {
    try {
      await fs.rmdir(dirPath)
      LLog.debug(TAG, `缓存目录已删除: ${dirPath}`)
    } catch (e) {
      throw new WGAppException({ message: "删除缓存目录失败", e: e as Error })
    }
  }

  async confFileReadToConfig(resUrl: string): Promise<WGConf> {
    await this.checkFileSize(resUrl)

    const config = await this.readSingleConfig(resUrl)
    if (config) {
      return config;
    } else {
      throw new WGAppException("读取配置文件失败")
    }
  }
}

const WGTools = new WGToolsImpl();

export default WGTools