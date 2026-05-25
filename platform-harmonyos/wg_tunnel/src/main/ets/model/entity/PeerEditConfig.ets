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
 * @author leojay`fu
 */
@ObservedV2
export default class PeerEditConfig {
  @Trace publicKey?: string; // 对等节点的PublicKey
  @Trace preSharedKey?: string; // 预共享密钥。可选
  @Trace address?: string;
  @Trace allowedIpsInput?: string; // 允许访问的IP规则 必须是IP段
  @Trace keepaliveInterval?: number; // 保活时间间隔 s


  // 允许访问的IP规则
  get allowedIps(): string[] {
    if (!this.allowedIpsInput) {
      return [];
    }
    if (this.allowedIpsInput.includes(",")) {
      return this.allowedIpsInput.split(',')
    } else {
      return [this.allowedIpsInput]
    }
  }
}


