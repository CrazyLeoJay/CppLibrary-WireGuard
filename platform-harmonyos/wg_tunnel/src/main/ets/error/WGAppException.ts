import { AppErrorCode } from './AppErrorCode'

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
export default class WGAppException extends Error {
  params?: AppErrorParams

  constructor(params: AppErrorParams) {
    super(toMessage(params))
    this.params = this.params
  }

  get code(): AppErrorCode | undefined {
    if (typeof this.params !== 'string') {
      if ('type' in this.params && this.params.type == `CodeError`) {
        return this.params.code
      }
    }
    return undefined
  }
}

function toMessage(params?: AppErrorParams): string | undefined {
  if (typeof params === 'string') {
    return params
  } else if ('type' in params && params.type == 'CodeError') {
    if (params.e) {
      if (params.e instanceof Error) {
        return `code=${params.code} msg=${params.message ?? params.e.message} \n${params.e.stack}`
      } else {
        return `code=${params.code} msg=${params.message} error: ${params.e}}`
      }
    } else {
      return `code=${params.code} msg=${params.message} error: no message`
    }
  } else {
    if (params.e instanceof Error) {
      return `${params.message ?? params.e.message} \n${params.e.stack}`
    } else {
      return `${params.message} error: ${params.e}}`
    }
  }
}

export type AppErrorParams = string | {
  message?: string,
  e: Error
} | {
  type: 'CodeError',
  code: AppErrorCode,
  e?: Error,
  message?: string,
}
