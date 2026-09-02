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

/**
 * 编辑态的应用过滤条目
 * ClientEditConfig.filterApps 使用此类型
 * 将 bundleName + meta 合并为扁平结构，方便 UI 渲染
 */
export interface AppFilterItem {
  /** 应用包名（唯一标识） */
  bundleName: string;
  /** 应用名称 */
  appName?: string;
  /** 是否通过分享添加（分享条目只读，不可编辑包名） */
  isShared?: boolean;
}
