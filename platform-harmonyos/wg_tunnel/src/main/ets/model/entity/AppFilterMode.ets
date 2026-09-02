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
 *
 */

/**
 * 应用过滤模式枚举
 * - NONE: 无过滤（默认）
 * - EXCLUDED: 黑名单，对应 VpnConfig.blockedApplications
 * - INCLUDED: 白名单，对应 VpnConfig.trustedApplications
 */
export enum AppFilterMode {
  NONE = 0,
  EXCLUDED = 1,
  INCLUDED = 2,
}
