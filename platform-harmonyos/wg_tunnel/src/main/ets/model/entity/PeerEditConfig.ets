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
import { LLog, SiteUrlType, WebSitePoint, WireGuard } from '../../../../../Index';

const TAG = "Peer编辑配置"

/**
 * @author leojay`fu
 */
@ObservedV2
export default class PeerEditConfig {
  @Trace publicKey?: string; // 对等节点的PublicKey
  @Trace preSharedKey?: string; // 预共享密钥。可选
  @Trace address?: string;
  @Trace allowedIpsInput: string = "0.0.0.0/0"; // 允许访问的IP规则 必须是IP段
  @Trace keepaliveInterval: string = ""; // 保活时间间隔 s

  @Trace addressCheckMessage: string = "";
  @Trace addressVerify: boolean = true;

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

  setAddress(sitePoint: WebSitePoint) {
    if (sitePoint.type == SiteUrlType.IPv6) {
      this.address = `[${sitePoint.ipStrOrDomain}]:${sitePoint.port}`
    } else if (sitePoint.type == SiteUrlType.IPv4) {
      this.address = `${sitePoint.ipStrOrDomain}:${sitePoint.port}`
    } else if (sitePoint.type == SiteUrlType.Domain) {
      this.address = `${sitePoint.ipStrOrDomain}:${sitePoint.port}`
    } else {
      LLog.info(TAG, `异常地址类型：${sitePoint.type} value=${sitePoint.ipStrOrDomain}}`)
    }
  }

  @Monitor("address")
  listenerAddressChange() {
    const type = WireGuard.regex.peerAddressCheck(this.address)
    this.addressCheckMessage = type.message
    this.addressVerify = type.verify

  }
}


