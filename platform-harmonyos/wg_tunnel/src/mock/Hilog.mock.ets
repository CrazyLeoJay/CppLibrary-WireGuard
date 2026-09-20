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

/**
 * @ohos.hilog 的本地单测 Mock 实现
 *
 * Local Test 运行在本地 JS 引擎，不支持系统 API；
 * SingleFlightLoop → LLog → @ohos.hilog 的依赖链经 mock-config.json5
 * 在测试构建期替换为本空实现，使被测代码可原样导入。
 */
class MockHilog {
  debug(domain: number, tag: string, msg: string, ...args: Object[]): void {
  }

  info(domain: number, tag: string, msg: string, ...args: Object[]): void {
  }

  warn(domain: number, tag: string, msg: string, ...args: Object[]): void {
  }

  error(domain: number, tag: string, msg: string, ...args: Object[]): void {
  }

  isLoggable(domain: number, tag: string, level: number): boolean {
    return false;
  }
}

export default new MockHilog();
