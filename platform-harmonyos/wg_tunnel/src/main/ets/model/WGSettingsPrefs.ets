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

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LLog } from '../tools/LLog';

const TAG = 'WGSettingsPrefs';
const PREFS_NAME = 'wg_settings';

/** 持久化键定义 */
export interface SettingsKeys {
  developerMode: boolean;
  defaultFilterMode: number; // AppFilterMode 值：0=NONE, 1=EXCLUDED(黑名单), 2=INCLUDED(白名单)
}

const KEYS: Record<string, preferences.ValueType> = {
  'developer_mode': false as preferences.ValueType,
  'default_filter_mode': 1 as preferences.ValueType, // 默认黑名单
};

/**
 * 应用设置持久化工具（单例）
 *
 * 使用 @ohos.data.preferences 持久化轻量级设置项：
 * - developerMode: 开发者模式开关
 * - defaultFilterMode: 默认过滤模式（黑名单/白名单）
 */
class WGSettingsPrefsImpl {
  private prefs: preferences.Preferences | undefined = undefined;
  private initialized: boolean = false;

  /**
   * 初始化（在 Ability onCreate 中调用）
   */
  async init(context: common.Context): Promise<void> {
    if (this.initialized) {
      return;
    }
    try {
      this.prefs = await preferences.getPreferences(context, PREFS_NAME);
      this.initialized = true;
      LLog.info(TAG, 'WGSettingsPrefs initialized');
    } catch (e) {
      LLog.error(TAG, { error: e, message: 'Failed to init WGSettingsPrefs' });
    }
  }

  /**
   * 获取开发者模式开关
   */
  getDeveloperMode(): boolean {
    if (!this.prefs) {
      return false;
    }
    return this.prefs.getSync('developer_mode', false) as boolean;
  }

  /**
   * 设置开发者模式开关
   */
  setDeveloperMode(value: boolean): void {
    if (!this.prefs) {
      return;
    }
    this.prefs.putSync('developer_mode', value);
    this.prefs.flushSync();
    LLog.info(TAG, `developerMode set to ${value}`);
  }

  /**
   * 获取默认过滤模式
   * @returns AppFilterMode 值（0=NONE, 1=EXCLUDED, 2=INCLUDED）
   */
  getDefaultFilterMode(): number {
    if (!this.prefs) {
      return 1; // 默认黑名单
    }
    return this.prefs.getSync('default_filter_mode', 1) as number;
  }

  /**
   * 设置默认过滤模式
   */
  setDefaultFilterMode(value: number): void {
    if (!this.prefs) {
      return;
    }
    this.prefs.putSync('default_filter_mode', value);
    this.prefs.flushSync();
    LLog.info(TAG, `defaultFilterMode set to ${value}`);
  }
}

export const WGSettingsPrefs = new WGSettingsPrefsImpl();
