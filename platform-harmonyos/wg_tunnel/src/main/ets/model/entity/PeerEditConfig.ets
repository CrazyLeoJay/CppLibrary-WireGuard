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
import { LLog, DnsResolveMode, SiteUrlType, WebSitePoint, WireGuard } from '../../../../../Index';
import { dnsResolveByMode, formatDnsError, getDnsMode } from '../../tools/DnsResolve';
import { AddressType } from '../ParamsRegex';
import { UIContext } from '@kit.ArkUI';

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

  @Trace dnsMode: DnsResolveMode = DnsResolveMode.PREFER_IPV4; // 解析偏好（四选一）
  @Trace dnsTestResult: string = ""; // DNS解析测试结果

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

  /**
   * 当前对端地址是否为域名（同步判断，供UI控制显示）
   */
  get isDomain(): boolean {
    if (!this.address || this.address.length === 0) {
      return false;
    }
    return WireGuard.regex.peerAddressCheck(this.address).addressType == AddressType.DOMAIN;
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
    this.dnsMode = getDnsMode(sitePoint);
  }

  @Monitor("address")
  listenerAddressChange() {
    const type = WireGuard.regex.peerAddressCheck(this.address)
    this.addressCheckMessage = type.message
    this.addressVerify = type.verify
  }

  /**
   * 从 address 字符串中提取 host 部分
   * 支持 IPv4:port、[IPv6]:port、domain:port 格式
   * @returns host 字符串，解析失败返回空字符串
   */
  extractHostFromAddress(): string {
    if (!this.address || this.address.length === 0) {
      return "";
    }
    const addr = this.address;
    if (addr.startsWith("[")) {
      const endBracket = addr.indexOf("]");
      if (endBracket === -1) {
        return "";
      }
      return addr.substring(1, endBracket);
    }
    const lastColonIndex = addr.lastIndexOf(":");
    if (lastColonIndex >= 0) {
      const colonCount = (addr.match(/:/g) || []).length;
      if (colonCount === 1) {
        return addr.substring(0, lastColonIndex);
      }
    }
    return addr;
  }

  /**
   * 测试DNS解析：解析当前对端地址的域名
   * 如果不是域名则 Toast 提示，返回 false
   * @param context UIContext，用于 Toast 提示
   * @returns 是否为域名且成功发起解析
   */
  async testDnsResolve(context: UIContext): Promise<boolean> {
    this.dnsTestResult = "";
    const host = this.extractHostFromAddress();
    if (!host) {
      context.getPromptAction().showToast({ message: "对端地址为空" });
      return false;
    }
    const isIp = await WireGuard.Tools.isIpAddress(host);
    if (isIp) {
      context.getPromptAction().showToast({ message: "对端地址不是域名，无需DNS解析" });
      return false;
    }
    try {
      this.dnsTestResult = await dnsResolveByMode(host, this.dnsMode);
      return true;
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      this.dnsTestResult = formatDnsError(err);
      return false;
    }
  }
}
