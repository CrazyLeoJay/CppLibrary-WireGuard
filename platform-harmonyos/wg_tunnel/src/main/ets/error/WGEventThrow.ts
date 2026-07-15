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
 * event 异常抛出
 *
 * Created on 2026/7/15.
 * @author leojay`fu
 */

/**
 * 异常说明
 * - none 表示数据为空
 * - normal 常规异常，默认可使用
 * - want_no_get_args 表示在启动时，未从Want中获取到启动参数。
 */
export interface WGEventThrow {
  type: 'none' | 'normal' | `want_no_get_args`
  message: string,
}

export type WGEventThrowParam = string | WGEventThrow

export function WGEventThrowToString(wget: WGEventThrowParam): string {
  if (typeof wget === 'string') {
    return JSON.stringify({
      type: 'normal', message: wget
    } as WGEventThrow)
  } else {
    return JSON.stringify(wget);
  }
}

export function WGEventThrowForString(wget: string): WGEventThrow {
  return JSON.parse(wget) as WGEventThrow
}