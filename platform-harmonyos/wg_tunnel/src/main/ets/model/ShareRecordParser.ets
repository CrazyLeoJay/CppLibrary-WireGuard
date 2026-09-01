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

import { ClipboardParser } from './ClipboardParser';
import { LLog } from '../tools/LLog';

const TAG = 'ShareRecordParser';

/**
 * 分享记录解析结果
 */
export interface ShareParseResult {
  /** 应用包名 */
  bundleName: string;
  /** 应用显示名称（可能为空） */
  appName: string;
  /** 华为应用市场 URL（APK 分享为空） */
  appGalleryUrl: string;
  /** 是否包含应用市场链接（APK 不包含，应用市场链接包含；决定是否抓取应用名） */
  shouldFetchIcon: boolean;
}

/**
 * 分享记录解析器接口
 * 每种分享格式实现此接口，通过 ShareParserFactory 注册和调度
 */
export interface IShareRecordParser {
  /** 此解析器处理的 UTD 类型列表 */
  utdTypes: string[];
  /** 解析分享记录，无法解析返回 undefined */
  parse(content: string, uri: string, title: string, label: string): ShareParseResult | undefined;
}

/**
 * Android APK 分享解析器
 *
 * UTD 类型: com.android.apk
 *
 * 数据特征:
 * - uri/stream: file://docs/storage/ANCO_APP_DATA/<bundleName>/base.apk
 * - title: 应用名称（如"绳遇"）
 * - label: 大小信息（如"58.43 MB - base.apk"）
 * - 不抓取应用名
 */
export class ApkShareParser implements IShareRecordParser {
  utdTypes: string[] = ['com.android.apk'];

  parse(content: string, uri: string, title: string, label: string): ShareParseResult | undefined {
    let bundleName: string | undefined = undefined;

    // 1. 从文件路径提取: ANCO_APP_DATA/<bundleName>/
    const ancoPattern = new RegExp('ANCO_APP_DATA/([a-zA-Z0-9_.]+)/');
    const contentMatch = ancoPattern.exec(content);
    if (contentMatch !== null && contentMatch.length > 1 && contentMatch[1].length > 0) {
      bundleName = contentMatch[1];
      LLog.info(TAG, `ApkShareParser: extracted from ANCO_APP_DATA in content: ${bundleName}`);
    }
    if (bundleName === undefined) {
      const uriMatch = ancoPattern.exec(uri);
      if (uriMatch !== null && uriMatch.length > 1 && uriMatch[1].length > 0) {
        bundleName = uriMatch[1];
        LLog.info(TAG, `ApkShareParser: extracted from ANCO_APP_DATA in uri: ${bundleName}`);
      }
    }

    // 2. 从通用 file:// 路径中提取 com.xxx.xxx
    if (bundleName === undefined) {
      const filePattern = new RegExp('file://.*/([a-zA-Z0-9_.]+)/[^/]*\\.apk');
      const fileMatch = filePattern.exec(content) ?? filePattern.exec(uri);
      if (fileMatch !== null && fileMatch.length > 1 && fileMatch[1].length > 0) {
        bundleName = fileMatch[1];
        LLog.info(TAG, `ApkShareParser: extracted from file path: ${bundleName}`);
      }
    }

    // 3. 回退: ClipboardParser 通用 com.xxx.xxx 匹配
    if (bundleName === undefined) {
      bundleName = ClipboardParser.parseBundleName(content);
    }
    if (bundleName === undefined) {
      bundleName = ClipboardParser.parseBundleName(uri);
    }

    if (bundleName === undefined || bundleName.length === 0) {
      LLog.warn(TAG, 'ApkShareParser: unable to extract bundleName');
      return undefined;
    }

    return {
      bundleName: bundleName,
      appName: title ?? '',
      appGalleryUrl: '',
      shouldFetchIcon: false,
    };
  }
}

/**
 * 华为应用市场链接分享解析器
 *
 * UTD 类型: general.hyperlink
 *
 * 数据特征:
 * - content: https://appgallery.huawei.com/app/detail?id=<bundleName>&channelId=xxx
 * - uri: store://appgallery.huawei.com/app/detail?id=<bundleName>
 * - title: 应用名称（如"网易邮箱大师"）
 * - label: 来源标识（如"应用市场"）
 * - 需要从应用市场页面抓取应用名
 */
export class AppGalleryShareParser implements IShareRecordParser {
  utdTypes: string[] = ['general.hyperlink'];

  parse(content: string, uri: string, title: string, label: string): ShareParseResult | undefined {
    let bundleName: string | undefined = undefined;
    let appGalleryUrl: string = '';

    // 1. 从 AppGallery URL 提取 bundleName 和完整 URL
    const urlFromContent = ClipboardParser.extractAppGalleryUrl(content);
    const urlFromUri = ClipboardParser.extractAppGalleryUrl(uri);
    const url = urlFromContent ?? urlFromUri;
    if (url !== undefined && url.length > 0) {
      appGalleryUrl = url;
      bundleName = ClipboardParser.extractIdFromAppGalleryLink(url);
      LLog.info(TAG, `AppGalleryShareParser: found URL, bundleName=${bundleName ?? 'null'}`);
    }

    // 2. 回退: ClipboardParser 通用 com.xxx.xxx 匹配
    if (bundleName === undefined || bundleName.length === 0) {
      bundleName = ClipboardParser.parseBundleName(content);
    }
    if (bundleName === undefined || bundleName.length === 0) {
      bundleName = ClipboardParser.parseBundleName(uri);
    }

    if (bundleName === undefined || bundleName.length === 0) {
      LLog.warn(TAG, 'AppGalleryShareParser: unable to extract bundleName');
      return undefined;
    }

    return {
      bundleName: bundleName,
      appName: title ?? '',
      appGalleryUrl: appGalleryUrl,
      shouldFetchIcon: true,
    };
  }
}

/**
 * 默认回退解析器
 *
 * 处理未知 UTD 类型的分享记录，
 * 尝试通用方式提取包名，自动判断是否含 AppGallery 链接
 */
export class DefaultShareParser implements IShareRecordParser {
  utdTypes: string[] = []; // 匹配所有 UTD

  parse(content: string, uri: string, title: string, label: string): ShareParseResult | undefined {
    let bundleName: string | undefined = ClipboardParser.parseBundleName(content);
    if (bundleName === undefined) {
      bundleName = ClipboardParser.parseBundleName(uri);
    }
    if (bundleName === undefined || bundleName.length === 0) {
      return undefined;
    }

    const urlFromContent = ClipboardParser.extractAppGalleryUrl(content);
    const urlFromUri = ClipboardParser.extractAppGalleryUrl(uri);
    const url = urlFromContent ?? urlFromUri;
    const hasGalleryUrl = url !== undefined && url.length > 0;

    return {
      bundleName: bundleName,
      appName: title ?? '',
      appGalleryUrl: url ?? '',
      shouldFetchIcon: hasGalleryUrl,
    };
  }
}

/**
 * 分享记录解析工厂（单例）
 *
 * 职责:
 * - 根据 UTD 类型路由到对应的解析器
 * - 支持动态注册新解析器（register）
 * - 内置 APK 和应用市场两种解析器
 * - 未知类型回退到 DefaultShareParser
 *
 * 扩展方式:
 *   ShareParserFactory.register(new MyCustomParser());
 */
class ShareParserFactoryImpl {
  private parsers: IShareRecordParser[] = [];
  private defaultParser: IShareRecordParser = new DefaultShareParser();

  constructor() {
    this.register(new ApkShareParser());
    this.register(new AppGalleryShareParser());
  }

  /**
   * 注册新解析器
   */
  register(parser: IShareRecordParser): void {
    this.parsers.push(parser);
    LLog.info(TAG, `ShareParserFactory: registered parser for UTD types: [${parser.utdTypes.join(',')}]`);
  }

  /**
   * 根据 UTD 类型解析分享记录
   *
   * @param utd     UTD 类型标识（如 "com.android.apk"、"general.hyperlink"）
   * @param content 分享内容文本
   * @param uri     分享 URI
   * @param title   分享标题（通常为应用名称）
   * @param label   分享标签
   * @returns 解析结果，无法解析返回 undefined
   */
  parse(utd: string, content: string, uri: string, title: string, label: string): ShareParseResult | undefined {
    // 按注册顺序查找匹配的解析器
    for (const parser of this.parsers) {
      for (const type of parser.utdTypes) {
        if (type === utd) {
          const result = parser.parse(content, uri, title, label);
          if (result !== undefined) {
            LLog.info(TAG, `ShareParserFactory: matched UTD=${utd}, bundleName=${result.bundleName}`);
            return result;
          }
        }
      }
    }

    // 回退到默认解析器
    const result = this.defaultParser.parse(content, uri, title, label);
    if (result !== undefined) {
      LLog.info(TAG, `ShareParserFactory: fallback parse for UTD=${utd}, bundleName=${result.bundleName}`);
    } else {
      LLog.warn(TAG, `ShareParserFactory: unable to parse record with UTD=${utd}`);
    }
    return result;
  }
}

export const ShareParserFactory = new ShareParserFactoryImpl();
