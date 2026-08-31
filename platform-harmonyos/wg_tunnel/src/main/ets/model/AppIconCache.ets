/*
 * Copyright [2026] @github-crazyleojay (crazyleojay@163.com/gmail.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { bundleManager, common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { LLog } from '../tools/LLog';

const TAG = 'AppIconCache';
const ICON_DIR = 'app_icons';

/**
 * 应用图标缓存管理器（单例）
 *
 * 条件性功能：需要 ohos.permission.GET_BUNDLE_INFO_PRIVILEGED 权限。
 * 无权限时降级为占位图标，不影响核心过滤功能。
 */
class AppIconCacheImpl {
  private cacheDir?: string;
  private initialized: boolean = false;

  /**
   * 初始化缓存目录（需要 Context）
   * 在 Ability/ExtensionAbility onCreate 中调用
   */
  init(context: common.Context): void {
    if (this.initialized) {
      LLog.info(TAG, 'AppIconCache already initialized');
      return;
    }
    this.cacheDir = context.cacheDir;
    this.ensureCacheDir();
    this.initialized = true;
    LLog.info(TAG, `AppIconCache initialized, cacheDir: ${this.cacheDir}`);
  }

  /**
   * 确保缓存目录存在
   */
  private ensureCacheDir(): void {
    if (!this.cacheDir) {
      return;
    }
    const iconDirPath = `${this.cacheDir}/${ICON_DIR}`;
    try {
      if (!fileIo.accessSync(iconDirPath)) {
        fileIo.mkdirSync(iconDirPath);
        LLog.info(TAG, `Created icon cache directory: ${iconDirPath}`);
      }
    } catch (e) {
      LLog.error(TAG, { error: e, message: 'Failed to create icon cache directory' });
    }
  }

  /**
   * 获取应用图标路径
   * 有缓存返回缓存路径，无缓存尝试获取
   *
   * @param bundleName 应用包名
   * @returns 图标本地路径，获取失败返回 undefined
   */
  async getAppIcon(bundleName: string): Promise<string | undefined> {
    if (!bundleName || bundleName.length === 0) {
      LLog.warn(TAG, 'getAppIcon: bundleName is empty');
      return undefined;
    }

    const cachedPath = this.getIconCachePath(bundleName);
    if (cachedPath && fileIo.accessSync(cachedPath)) {
      LLog.info(TAG, `Cache hit for ${bundleName}: ${cachedPath}`);
      return cachedPath;
    }

    LLog.info(TAG, `Cache miss for ${bundleName}, attempting fetch`);
    return await this.cacheIcon(bundleName);
  }

  /**
   * 同步获取已缓存的应用图标路径
   * 仅查缓存，不触发网络/文件IO获取，适合UI层同步引用
   *
   * @param bundleName 应用包名
   * @returns 缓存的图标路径，未缓存返回 undefined
   */
  getAppIconSync(bundleName: string): string | undefined {
    if (!bundleName || bundleName.length === 0) {
      return undefined;
    }
    const cachedPath = this.getIconCachePath(bundleName);
    if (cachedPath && fileIo.accessSync(cachedPath)) {
      return cachedPath;
    }
    return undefined;
  }

  /**
   * 从系统获取图标并缓存到本地
   *
   * @param bundleName 应用包名
   * @param iconPath 可选的已有图标路径（用于直接缓存）
   * @returns 缓存后的本地路径，失败返回 undefined
   */
  async cacheIcon(bundleName: string, iconPath?: string): Promise<string | undefined> {
    if (!this.cacheDir) {
      LLog.warn(TAG, 'cacheIcon: cacheDir not initialized');
      return undefined;
    }

    const targetPath = this.getIconCachePath(bundleName);
    if (!targetPath) {
      return undefined;
    }

    // 如果已有缓存，直接返回
    if (fileIo.accessSync(targetPath)) {
      LLog.info(TAG, `Icon already cached at ${targetPath}, returning cached path`);
      return targetPath;
    }

    LLog.info(TAG, `Attempting to fetch icon for ${bundleName} from bundleManager`);

    try {
      // 尝试通过 bundleManager 获取应用信息
      const bundleInfo = await bundleManager.getBundleInfo(
        bundleName,
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
      );

      LLog.info(TAG, `BundleInfo fetched successfully for ${bundleName}`);

      const appInfo = bundleInfo.appInfo;
      if (!appInfo || !appInfo.icon) {
        LLog.warn(TAG, `No icon found for ${bundleName}: appInfo=${appInfo ? 'exists' : 'null'}, icon=${appInfo?.icon ?? 'null'}`);
        return undefined;
      }

      // 复制图标到缓存目录
      const sourceIcon = appInfo.icon;
      LLog.info(TAG, `Icon source path for ${bundleName}: ${sourceIcon}`);
      // appInfo.icon 可能是资源路径（如 $media:app_icon），需要通过 context 获取
      // bundleManager 返回的 icon 路径是沙箱内的绝对路径
      if (sourceIcon.startsWith('/')) {
        fileIo.copyFileSync(sourceIcon, targetPath);
        LLog.info(TAG, `Icon fetch success: copied ${sourceIcon} -> ${targetPath}`);
        return targetPath;
      }

      LLog.warn(TAG, `Icon path format not supported for ${bundleName}: ${sourceIcon} (expected absolute path starting with /)`);
      return undefined;
    } catch (e) {
      LLog.error(TAG, { error: e, message: `Icon fetch failed for ${bundleName} (likely missing GET_BUNDLE_INFO_PRIVILEGED permission)` });
      return undefined;
    }
  }

  /**
   * 计算缓存文件路径
   * 规则：{cacheDir}/app_icons/{bundleName_dot_to_underscore}.png
   *
   * @param bundleName 应用包名
   * @returns 缓存文件路径
   */
  getIconCachePath(bundleName: string): string | undefined {
    if (!this.cacheDir) {
      LLog.warn(TAG, 'getIconCachePath: cacheDir not initialized');
      return undefined;
    }
    const fileName = bundleName.replace(/\./g, '_') + '.png';
    const fullPath = `${this.cacheDir}/${ICON_DIR}/${fileName}`;
    LLog.debug(TAG, `Cache path for ${bundleName}: ${fullPath}`);
    return fullPath;
  }

  /**
   * 获取应用显示名称
   * 通过 bundleManager.getBundleInfo 获取 appInfo.labelRef 资源 ID，
   * 再通过 context.resourceManager 解析为实际显示名称。
   *
   * @param bundleName 应用包名
   * @param context Context（用于资源解析）
   * @returns 应用显示名称，获取失败返回 undefined
   */
  async getAppName(bundleName: string, context: common.Context): Promise<string | undefined> {
    if (!bundleName || bundleName.length === 0) {
      return undefined;
    }
    try {
      const bundleInfo = await bundleManager.getBundleInfo(
        bundleName,
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
      );
      const appInfo = bundleInfo.appInfo;
      if (!appInfo) {
        LLog.warn(TAG, `No appInfo for ${bundleName}`);
        return undefined;
      }
      // appInfo.label 是资源引用（如 $string:app_name），需要通过 resourceManager 解析
      const labelRes = appInfo.label;
      if (labelRes && labelRes.length > 0) {
        // label 可能是直接字符串或资源引用，先尝试作为字符串返回
        if (!labelRes.startsWith('$')) {
          return labelRes;
        }
        // 资源引用格式如 $string:app_name，通过资源名获取
        try {
          const resName = labelRes.replace(/^\$string:/, '');
          const resolved = context.resourceManager.getStringByNameSync(resName);
          return resolved;
        } catch (labelErr) {
          LLog.warn(TAG, { error: labelErr, message: `Failed to resolve label resource for ${bundleName}` });
          // 回退到 appInfo.name
        }
      }
      // 回退：使用 appInfo.name
      if (appInfo.name && appInfo.name.length > 0) {
        return appInfo.name;
      }
      return undefined;
    } catch (e) {
      LLog.warn(TAG, { error: e, message: `Failed to get app name for ${bundleName}` });
      return undefined;
    }
  }

  /**
   * 清空图标缓存
   */
  async clearCache(): Promise<void> {
    if (!this.cacheDir) {
      LLog.warn(TAG, 'clearCache: cacheDir not initialized');
      return;
    }
    const iconDirPath = `${this.cacheDir}/${ICON_DIR}`;
    try {
      if (fileIo.accessSync(iconDirPath)) {
        fileIo.rmdirSync(iconDirPath);
        // 重新创建空目录
        fileIo.mkdirSync(iconDirPath);
        LLog.info(TAG, 'Icon cache cleared');
      } else {
        LLog.info(TAG, 'Icon cache directory does not exist, nothing to clear');
      }
    } catch (e) {
      LLog.error(TAG, { error: e, message: 'Failed to clear icon cache' });
    }
  }
}

export const AppIconCache = new AppIconCacheImpl();
