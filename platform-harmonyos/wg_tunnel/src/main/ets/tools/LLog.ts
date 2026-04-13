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
    if (typeof msg === 'string') {
      return msg
    } else if ('error' in msg && 'message' in msg) {
      if (msg.message) {
        if (msg.error instanceof Error) {
          return `ERROR(group):${msg.message}\nERROR:${msg.error.message}\n${msg.error.stack}`
        } else {
          return `ERROR(group):${msg.message}\nERROR:${msg.error}}`
        }
      } else {
        if (msg.error instanceof Error) {
          return `ERROR(group):${msg.error.message}\n${msg.error.stack}`
        } else {
          return `ERROR(group):${msg.error}}`
        }
      }
    } else if (msg instanceof Error || ('name' in msg && 'message' in msg && 'stack' in msg)) {
      if (msg instanceof Error) {
        return `ERROR:${msg.message}\n${msg.stack}`
      } else {
        return `ERROR:${msg.error}}`
      }
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