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

import { UIExtensionContentSession } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { WireGuard } from 'wg_tunnel/src/main/ets/model/WGHelper';
import { LLog } from 'wg_tunnel/src/main/ets/tools/LLog';
import { WGSettingsPrefs } from 'wg_tunnel/src/main/ets/model/WGSettingsPrefs';
import { AppFilterMode, WGDBConf, AppFilterMeta } from 'wg_tunnel';
import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { ShareDebugRecordInfo } from '../ability/WGShareExtAbility';

const TAG = 'ShareConfigViewModel';

/**
 * 分享配置页面 ViewModel
 *
 * 职责：
 * - 从 LocalStorage 读取 Ability 端传递的分享数据（bundleName、appName、appGalleryUrl）
 * - 根据 appGalleryUrl 决定是否从华为应用市场页面抓取应用名称
 * - 加载本地 VPN 配置列表
 * - 执行添加包名到配置的业务逻辑
 * - 管理会话生命周期（关闭分享页面）
 */
@ObservedV2
export default class ShareConfigViewModel {
  @Trace bundleName: string = '';
  @Trace appName: string = '';
  @Trace appGalleryUrl: string = '';
  @Trace hasAppGalleryUrl: boolean = false;
  @Trace configs: WGDBConf[] = [];
  @Trace selectedIndex: number = -1;
  @Trace isLoading: boolean = true;
  @Trace isAdding: boolean = false;
  @Trace messageText: string = '';
  @Trace showMessage: boolean = false;
  @Trace developerMode: boolean = WGSettingsPrefs.getDeveloperMode();
  @Trace debugShareInfos: ShareDebugRecordInfo[] = [];

  private storage: LocalStorage | undefined = undefined;
  private session: UIExtensionContentSession | undefined = undefined;

  /**
   * 异步初始化（@Entry 页面入口调用，传入 SharedLocalStorage）
   * 先渲染界面（isLoading=true），再异步绑定 Storage + 加载配置
   */
  async initAsync(storage: LocalStorage | undefined): Promise<void> {
    if (storage) {
      this.bindStorage(storage);
      this.waitForAsyncData();
    }
    try {
      this.loadConfigs();
    } catch (_e) {
      // 数据库未初始化
      this.isLoading = false;
    }
  }

  /**
   * 异步初始化（Preview 用，注入假数据）
   */
  async initAsyncWithMock(
    bundleName: string, appName: string, appGalleryUrl: string,
    hasAppGalleryUrl: boolean, configs: WGDBConf[],
    debugInfos: ShareDebugRecordInfo[],
  ): Promise<void> {
    this.bundleName = bundleName;
    this.appName = appName;
    this.appGalleryUrl = appGalleryUrl;
    this.hasAppGalleryUrl = hasAppGalleryUrl;
    this.configs = configs;
    this.debugShareInfos = debugInfos;
    if (configs.length === 1) {
      this.selectedIndex = 0;
    }
    this.developerMode = true;
    this.isLoading = false;
  }

  /**
   * 绑定 LocalStorage 和 session（在 View aboutToAppear 中调用）
   */
  bindStorage(storage: LocalStorage): void {
    this.storage = storage;
    this.session = storage.get<UIExtensionContentSession>('session');
  }

  /**
   * 加载本地 VPN 配置列表
   */
  loadConfigs(): void {
    try {
      this.configs = WireGuard.helper.config.allDBConfig();
      LLog.info(TAG, `Loaded ${this.configs.length} configs`);
      if (this.configs.length === 1) {
        this.selectedIndex = 0;
      }
    } catch (e) {
      LLog.error(TAG, { error: e, message: 'Failed to load configs' });
      this.configs = [];
    }
    this.isLoading = false;
  }

  /**
   * 异步等待 Ability 端从分享内容解析的数据
   * 根据 appGalleryUrl 决定是否触发 AppGallery 名称抓取
   */
  waitForAsyncData(): void {
    let attempts = 0;
    const maxAttempts = 30; // 30 × 100ms = 3s
    let bundleNameReady = false;
    let debugReady = !this.developerMode; // 非开发者模式不等 debug 数据
    let nameFetched = false;

    const timer = setInterval(() => {
      attempts++;
      if (!this.storage) {
        clearInterval(timer);
        return;
      }

      if (!bundleNameReady) {
        const name = this.storage.get<string>('bundleName');
        if (name !== undefined && name !== null) {
          bundleNameReady = true;
          if (name.length > 0) {
            this.bundleName = name;
            LLog.info(TAG, `Async: resolved bundleName: ${name}`);
          }
          // bundleName 就绪后立即尝试读取其他字段
          const app = this.storage.get<string>('appName');
          if (app && app.length > 0) {
            this.appName = app;
          }
          const galleryUrl = this.storage.get<string>('appGalleryUrl');
          if (galleryUrl && galleryUrl.length > 0) {
            this.appGalleryUrl = galleryUrl;
          }
          const hasUrl = this.storage.get<boolean>('shouldFetchIcon');
          if (hasUrl !== undefined && hasUrl !== null) {
            this.hasAppGalleryUrl = hasUrl;
          }
        }
      } else {
        // bundleName 已就绪，继续等 appName
        const app = this.storage.get<string>('appName');
        if (app && app.length > 0 && this.appName.length === 0) {
          this.appName = app;
        }
        const galleryUrl = this.storage.get<string>('appGalleryUrl');
        if (galleryUrl && galleryUrl.length > 0 && this.appGalleryUrl.length === 0) {
          this.appGalleryUrl = galleryUrl;
        }

        // 根据 hasAppGalleryUrl 决定是否抓取应用名
        if (!nameFetched && this.bundleName.length > 0 && this.hasAppGalleryUrl &&
          this.appName.length === 0) {
          nameFetched = true;
          this.fetchAppGalleryInfo();
        }
      }

      if (!debugReady) {
        const jsonStr = this.storage.get<string>('shareDebugInfos');
        if (jsonStr !== undefined && jsonStr !== null) {
          debugReady = true;
          if (jsonStr.length > 0) {
            try {
              this.debugShareInfos = JSON.parse(jsonStr) as ShareDebugRecordInfo[];
              LLog.info(TAG, `Debug: loaded ${this.debugShareInfos.length} share record(s)`);
            } catch (e) {
              LLog.warn(TAG, { error: e, message: 'Debug: failed to parse shareDebugInfos' });
            }
          }
        }
      }

      if ((bundleNameReady && debugReady) || attempts >= maxAttempts) {
        clearInterval(timer);
        // 超时后如果还需要抓取名称，尝试一次
        if (!nameFetched && this.bundleName.length > 0 && this.hasAppGalleryUrl &&
          this.appName.length === 0) {
          this.fetchAppGalleryInfo();
        }
        if (this.bundleName.length > 0 && !this.hasAppGalleryUrl) {
          LLog.info(TAG, 'hasAppGalleryUrl=false, skipping AppGallery name fetch (APK share)');
        }
      }
    }, 100);
  }

  /**
   * 从华为应用市场页面抓取应用名称
   * 解析 HTML title 标签获取应用名
   */
  private fetchAppGalleryInfo(): void {
    if (this.bundleName.length === 0) {
      return;
    }

    const fetchUrl = this.appGalleryUrl.length > 0
      ? this.appGalleryUrl
      : `https://appgallery.huawei.com/app/detail?id=${this.bundleName}`;
    LLog.info(TAG, `fetchAppGalleryInfo: ${fetchUrl}`);

    // 将 store:// 协议转为 https://
    const httpsUrl = fetchUrl.replace(/^store:\/\//, 'https://');

    try {
      const httpRequest = http.createHttp();
      httpRequest.request(httpsUrl, {
        method: http.RequestMethod.GET,
        header: {
          'Accept': 'text/html',
          'User-Agent': 'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36',
        },
        connectTimeout: 10000,
        readTimeout: 10000,
      }).then((response) => {
        httpRequest.destroy();
        if (response.responseCode !== 200) {
          LLog.warn(TAG, `fetchAppGalleryInfo: HTTP ${response.responseCode}`);
          return;
        }
        const html = response.result as string;
        if (!html || html.length === 0) {
          LLog.warn(TAG, 'fetchAppGalleryInfo: empty HTML response');
          return;
        }
        // 解析 title 标签获取应用名称
        const appName = this.parseAppNameFromHtml(html);
        if (appName && appName.length > 0 && this.appName.length === 0) {
          this.appName = appName;
          LLog.info(TAG, `fetchAppGalleryInfo: got appName=${appName}`);
        }
      }).catch((e: BusinessError) => {
        LLog.warn(TAG, { error: e, message: 'fetchAppGalleryInfo HTTP request failed' });
      });
    } catch (e) {
      LLog.warn(TAG, { error: e, message: 'fetchAppGalleryInfo failed' });
    }
  }

  /**
   * 从 HTML 的 title 标签解析应用名称
   * 华为应用市场页面 title 格式通常为: "应用名-华为应用市场" 或 "应用名 - AppGallery"
   */
  private parseAppNameFromHtml(html: string): string | undefined {
    const titlePattern = new RegExp('<title[^>]*>([^<]+)</title>', 'i');
    const match = titlePattern.exec(html);
    if (match !== null && match.length > 1 && match[1].length > 0) {
      let title = match[1].trim();
      title = title.replace(/\s*[-|]\s*(华为应用市场|AppGallery|HUAWEI AppGallery).*/i, '').trim();
      if (title.length > 0) {
        return title;
      }
    }
    return undefined;
  }

  /**
   * 获取配置的过滤模式
   */
  getFilterMode(config: WGDBConf): AppFilterMode {
    const included = config.conf.inter.includedApplications;
    const excluded = config.conf.inter.excludedApplications;
    if (included && included.length > 0) {
      return AppFilterMode.INCLUDED;
    }
    if (excluded && excluded.length > 0) {
      return AppFilterMode.EXCLUDED;
    }
    return AppFilterMode.NONE;
  }

  /**
   * 检查包名是否已在配置的过滤列表中
   */
  isDuplicate(config: WGDBConf, name: string): boolean {
    const included = config.conf.inter.includedApplications;
    const excluded = config.conf.inter.excludedApplications;
    if (included && included.includes(name)) {
      return true;
    }
    if (excluded && excluded.includes(name)) {
      return true;
    }
    return false;
  }

  /**
   * 获取默认过滤模式描述文字
   */
  getDefaultFilterModeText(): string {
    return WGSettingsPrefs.getDefaultFilterMode() === AppFilterMode.INCLUDED ? '白名单' : '黑名单';
  }

  /**
   * 确认添加包名到选中的配置
   */
  confirmAdd(): void {
    if (this.selectedIndex < 0 || this.selectedIndex >= this.configs.length) {
      this.showPromptMessage('请先选择一个配置');
      return;
    }
    if (!this.bundleName || this.bundleName.length === 0) {
      this.showPromptMessage('无法从分享内容中解析应用包名');
      return;
    }

    const config = this.configs[this.selectedIndex];
    const bundleName = this.bundleName;

    if (this.isDuplicate(config, bundleName)) {
      this.showPromptMessage(`包名 "${bundleName}" 已存在于配置 "${config.name}" 的过滤列表中`);
      return;
    }

    this.isAdding = true;
    try {
      const mode = this.getFilterMode(config);
      // 构建此条目的元数据
      const meta: AppFilterMeta = {
        appName: this.appName.length > 0 ? this.appName : undefined,
        isShared: true,
      };

      if (mode === AppFilterMode.NONE) {
        // NONE → 使用默认过滤模式
        const defaultMode = WGSettingsPrefs.getDefaultFilterMode();
        if (defaultMode === AppFilterMode.INCLUDED) {
          config.conf.inter.includedApplications = [bundleName];
          LLog.info(TAG, `Auto-enabled whitelist mode for config "${config.name}", added "${bundleName}"`);
        } else {
          config.conf.inter.excludedApplications = [bundleName];
          LLog.info(TAG, `Auto-enabled blacklist mode for config "${config.name}", added "${bundleName}"`);
        }
        const newMeta: Record<string, AppFilterMeta> = {};
        newMeta[bundleName] = meta;
        config.conf.inter.appFilterMeta = newMeta;
      } else if (mode === AppFilterMode.EXCLUDED) {
        const excluded = config.conf.inter.excludedApplications ?? [];
        excluded.push(bundleName);
        config.conf.inter.excludedApplications = excluded;
        // 追加元数据
        const existingMeta = config.conf.inter.appFilterMeta ?? {};
        existingMeta[bundleName] = meta;
        config.conf.inter.appFilterMeta = existingMeta;
      } else if (mode === AppFilterMode.INCLUDED) {
        const included = config.conf.inter.includedApplications ?? [];
        included.push(bundleName);
        config.conf.inter.includedApplications = included;
        // 追加元数据
        const existingMeta = config.conf.inter.appFilterMeta ?? {};
        existingMeta[bundleName] = meta;
        config.conf.inter.appFilterMeta = existingMeta;
      }

      const allConfigs = WireGuard.helper.config.allConfig();
      if (allConfigs.length > this.selectedIndex) {
        const tableId = allConfigs[this.selectedIndex].id;
        if (tableId !== undefined) {
          WireGuard.helper.config.updateConfig(tableId, config);
          LLog.info(TAG, `Config "${config.name}" updated in database`);
        }
      }

      const displayName = this.appName.length > 0 ? `${this.appName} (${bundleName})` : bundleName;
      this.showPromptMessage(`已将 "${displayName}" 添加到配置 "${config.name}"`);

      setTimeout(() => {
        this.closeSession();
      }, 1500);
    } catch (e) {
      LLog.error(TAG, { error: e, message: 'Failed to add bundleName to config' });
      this.showPromptMessage('添加失败，请重试');
    } finally {
      this.isAdding = false;
    }
  }

  /**
   * 关闭分享会话
   */
  closeSession(): void {
    if (this.session) {
      try {
        const resultCode = systemShare.ShareAbilityResultCode.CLOSE;
        this.session.terminateSelfWithResult({ resultCode: resultCode });
      } catch (e) {
        LLog.error(TAG, { error: e, message: 'Failed to terminate session' });
        try {
          this.session.terminateSelf();
        } catch (e2) {
          LLog.error(TAG, { error: e2, message: 'Failed to terminateSelf fallback' });
        }
      }
    }
  }

  /**
   * 显示提示消息（3秒后自动消失）
   */
  showPromptMessage(msg: string): void {
    this.messageText = msg;
    this.showMessage = true;
    setTimeout(() => {
      this.showMessage = false;
    }, 3000);
  }

  /**
   * 取消操作，关闭会话
   */
  cancel(): void {
    this.closeSession();
  }
}
