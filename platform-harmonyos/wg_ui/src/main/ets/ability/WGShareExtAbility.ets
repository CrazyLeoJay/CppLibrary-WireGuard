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

import { ShareExtensionAbility, UIExtensionContentSession, Want } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { LLog } from 'wg_tunnel/src/main/ets/tools/LLog';
import { WireGuard } from 'wg_tunnel/src/main/ets/model/WGHelper';
import { WGSettingsPrefs } from 'wg_tunnel/src/main/ets/model/WGSettingsPrefs';
import { ShareParserFactory, ShareParseResult } from 'wg_tunnel/src/main/ets/model/ShareRecordParser';
import { BusinessError } from '@kit.BasicServicesKit';
import '../view/ShareConfigView'; // 导入命名路由页面，确保 @Entry({ routeName }) 注册生效

const TAG = 'WGShareExtAbility';

/**
 * 分享扩展Ability
 *
 * 接收其他应用通过系统分享面板分享到本应用的内容，
 * 通过 ShareParserFactory 工厂模式按 UTD 类型路由到对应解析器，
 * 从分享内容中解析目标应用包名、名称、AppGallery URL 等信息，
 * 加载配置选择页面 ShareConfigView。
 *
 * 支持的分享格式:
 * - com.android.apk (APK文件分享) — 从文件路径提取包名，不抓取图标
 * - general.hyperlink (应用市场链接分享) — 从URL id参数提取包名，抓取图标
 * - 其他UTD类型 — 回退到通用解析器
 *
 * ShareExtensionAbility 运行在独立的 UIExtension 进程中，
 * 与主应用的 UIAbility 进程隔离。
 */
export default class WGShareExtAbility extends ShareExtensionAbility {
  override onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    LLog.info(TAG, 'onSessionCreate — ShareExtensionAbility runs in independent UIExtension process');

    // 记录进程信息
    try {
      const context = this.context;
      LLog.info(TAG, `ShareExtension process context: cacheDir=${context.cacheDir}`);
    } catch (e) {
      LLog.warn(TAG, { error: e, message: 'Failed to log process context info' });
    }

    // 初始化数据库
    try {
      WireGuard.db.init(this.context);
      LLog.info(TAG, 'Database initialized in ShareExtension process');
    } catch (e) {
      LLog.error(TAG, { error: e, message: 'Failed to initialize database in ShareExtension process' });
    }

    // 初始化设置偏好
    WGSettingsPrefs.init(this.context).catch((e: BusinessError) => {
      LLog.warn(TAG, { error: e, message: 'Failed to init WGSettingsPrefs in ShareExtension process' });
    });

    // 打印 Want 全部参数（调试用）
    LLog.info(TAG, `Want: deviceId=${want.deviceId ?? ''}, bundleName=${want.bundleName ?? ''}, abilityName=${want.abilityName ?? ''}, uri=${want.uri ?? ''}, type=${want.type ?? ''}, action=${want.action ?? ''}, flags=${want.flags ?? 0}`);
    if (want.entities && want.entities.length > 0) {
      LLog.info(TAG, `Want.entities: ${want.entities.join(',')}`);
    }
    if (want.parameters) {
      LLog.info(TAG, `Want.parameters: ${JSON.stringify(want.parameters)}`);
    } else {
      LLog.info(TAG, 'Want.parameters: null');
    }

    // 通过 LocalStorage 传递数据到 ShareConfigView
    const storage: LocalStorage = new LocalStorage();
    storage.setOrCreate('bundleName', '');
    storage.setOrCreate('appName', '');
    storage.setOrCreate('appGalleryUrl', '');
    storage.setOrCreate('shouldFetchIcon', false);
    storage.setOrCreate('session', session);

    // 从分享内容中解析包名（使用工厂模式按UTD类型路由）
    systemShare.getSharedData(want).then((data: systemShare.SharedData) => {
      const records = data.getRecords();
      LLog.info(TAG, `getSharedData: ${records.length} record(s)`);

      const debugInfos: ShareDebugRecordInfo[] = [];
      let bestResult: ShareParseResult | undefined = undefined;

      for (const record of records) {
        const info: ShareDebugRecordInfo = {
          utd: record.utd ?? '',
          title: record.title ?? '',
          content: record.content ?? '',
          uri: record.uri ?? '',
          description: record.description ?? '',
          label: record.label ?? '',
        };
        debugInfos.push(info);
        LLog.info(TAG, `ShareRecord: utd=${info.utd}, content=${info.content}, uri=${info.uri}`);

        // 使用工厂模式解析：按UTD类型自动路由到对应解析器
        if (bestResult === undefined) {
          const result = ShareParserFactory.parse(info.utd, info.content, info.uri, info.title, info.label);
          if (result !== undefined) {
            bestResult = result;
            LLog.info(TAG, `Factory parsed: bundleName=${result.bundleName}, appName=${result.appName}, shouldFetchIcon=${result.shouldFetchIcon}`);
          }
        }
      }

      // 将解析结果写入 LocalStorage
      if (bestResult !== undefined) {
        storage.setOrCreate('bundleName', bestResult.bundleName);
        storage.setOrCreate('appName', bestResult.appName);
        storage.setOrCreate('appGalleryUrl', bestResult.appGalleryUrl);
        storage.setOrCreate('shouldFetchIcon', bestResult.shouldFetchIcon);
        LLog.info(TAG, `Parsed result stored: bundleName=${bestResult.bundleName}, shouldFetchIcon=${bestResult.shouldFetchIcon}`);
      } else {
        LLog.info(TAG, 'Failed to parse any share record');
      }

      storage.setOrCreate('shareDebugInfos', JSON.stringify(debugInfos));
    }).catch((e: BusinessError) => {
      LLog.warn(TAG, { error: e, message: 'Failed to getSharedData' });
      storage.setOrCreate('shareDebugInfos', '');
    });

    // 通过命名路由加载配置选择页面
    try {
      session.loadContentByName('ShareConfigView', storage);
      LLog.info(TAG, 'ShareConfigView loaded via loadContentByName');
    } catch (e) {
      LLog.error(TAG, { error: e, message: 'Failed to load ShareConfigView via loadContentByName' });
    }

    LLog.info(TAG, 'onSessionCreate exit');
  }

  override onSessionDestroy(session: UIExtensionContentSession): void {
    LLog.info(TAG, 'onSessionDestroy');
  }

  override onForeground(): void {
    LLog.info(TAG, 'onForeground');
  }

  override onBackground(): void {
    LLog.info(TAG, 'onBackground');
  }
}

/**
 * 分享记录调试信息 - 用于开发者模式在分享页面显示原始分享数据
 */
export interface ShareDebugRecordInfo {
  utd: string;
  title: string;
  content: string;
  uri: string;
  description: string;
  label: string;
}
