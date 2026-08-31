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

import { LLog } from '../tools/LLog';

const TAG = 'ClipboardParser';

/**
 * 剪贴板内容解析器
 * 从文本/链接中提取应用包名
 */
export class ClipboardParser {
  /**
   * 从文本中解析包名
   * 优先匹配应用市场链接 id 参数，其次匹配 com.xxx.xxx 格式
   *
   * @param text 剪贴板文本内容
   * @returns 解析出的包名，无法解析返回 undefined
   */
  static parseBundleName(text: string): string | undefined {
    if (!text || text.length === 0) {
      LLog.debug(TAG, 'parseBundleName: text is empty');
      return undefined;
    }

    LLog.info(TAG, `parseBundleName: attempting to parse text (length=${text.length})`);

    // 1. 尝试从应用市场链接中提取 id 参数
    const appGalleryId = ClipboardParser.extractIdFromAppGalleryLink(text);
    if (appGalleryId !== undefined && appGalleryId.length > 0) {
      LLog.info(TAG, `parseBundleName: extracted from app gallery link: ${appGalleryId}`);
      return appGalleryId;
    }

    // 2. 尝试匹配 com.xxx.xxx 格式的包名
    const bundleNamePattern = new RegExp('com\\.[a-zA-Z0-9_]+\\.[a-zA-Z0-9_.]+');
    const match = bundleNamePattern.exec(text);
    if (match !== null && match.length > 0) {
      LLog.info(TAG, `parseBundleName: matched com.xxx.xxx format: ${match[0]}`);
      return match[0];
    }

    LLog.info(TAG, 'parseBundleName: unable to parse bundle name from text');
    return undefined;
  }

  /**
   * 从应用市场链接中提取 id 参数值
   * 支持格式: store://appgallery.huawei.com/app/detail?id=<bundleName>
   *
   * @param url 文本内容（可能包含应用市场链接）
   * @returns 提取的 id 参数值，未匹配返回 undefined
   */
  static extractIdFromAppGalleryLink(url: string): string | undefined {
    if (!url || url.length === 0) {
      return undefined;
    }

    // 匹配 store://appgallery.huawei.com/app/detail?id=xxx
    const pattern = new RegExp('store://appgallery\\.huawei\\.com/app/detail\\?id=([a-zA-Z0-9_.]+)');
    const match = pattern.exec(url);
    if (match !== null && match.length > 1 && match[1].length > 0) {
      LLog.info(TAG, `extractIdFromAppGalleryLink: extracted id=${match[1]}`);
      return match[1];
    }

    return undefined;
  }
}
