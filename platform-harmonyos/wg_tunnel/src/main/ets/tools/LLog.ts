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
import hilog from '@ohos.hilog'

export type ErrorParams = string | { error: any, message?: string } | Error

class LogImpl {
  domain: number = 0xFF0F
  defaultPrefix: string = "app:"

  private p2s(msg: ErrorParams): string {
    try {
      if (typeof msg === 'string') {
        return msg
      } else if (msg instanceof Error || ('name' in msg && 'message' in msg && 'stack' in msg)) {
        return `ERROR:${msg.message}\n${msg.stack}`
      } else if ('error' in msg) {
        const error = msg.error
        if (error === null || error === undefined) {
          return `ERROR(group):${msg.message ?? 'unknown'}\nERROR:null`
        }
        if (error instanceof Error || ('message' in error && 'stack' in error)) {
          const code = 'code' in error ? error.code : 'unknown'
          return `ERROR(group):${msg.message ?? 'unknown'}\nERROR(${code}):${error.message}\n${error.stack}`
        } else if (typeof error === 'object') {
          return `ERROR(group):${msg.message ?? 'unknown'}\nERROR:${JSON.stringify(error)}`
        } else {
          return `ERROR(group):${msg.message ?? 'unknown'}\nERROR:${String(error)}`
        }
      } else if (typeof msg === 'object') {
        return JSON.stringify(msg)
      } else {
        return String(msg)
      }
    } catch (e) {
      return `ERROR(unknown):${String(msg)}`
    }
  }

  info(tag: string, msg: ErrorParams, ...any: any[]) {
    hilog.info(this.domain, `${this.defaultPrefix}${tag}`, this.p2s(msg), ...any)
  }

  debug(tag: string, msg: ErrorParams, ...any: any[]) {
    hilog.debug(this.domain, `${this.defaultPrefix}${tag}`, this.p2s(msg), ...any)
  }

  warn(tag: string, msg: ErrorParams, ...any: any[]) {
    hilog.warn(this.domain, `${this.defaultPrefix}${tag}`, this.p2s(msg), ...any)
  }

  error(tag: string, msg: ErrorParams, ...any: any[]) {
    hilog.error(this.domain, `${this.defaultPrefix}${tag}`, this.p2s(msg), ...any)
  }
}

export const LLog = new LogImpl()