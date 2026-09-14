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

import native from 'libwg_tunnel.so';
import { connection } from '@kit.NetworkKit';
import { DnsResolveMode, WebSitePoint } from '../model/entity/napi_entity';
import { LLog } from './LLog';

const TAG = "DNS解析"

/**
 * 使用 HarmonyOS 系统 connection.getAddressesByName 解析域名
 * 返回所有IP地址，通过 NetAddress.family 手动过滤：1=IPv4, 2=IPv6
 * 注：getAddressesByName 从 API 8+ 支持，NetAddress.family 同样是旧API
 *
 * @param domain 域名
 * @param wantIpv6 是否需要IPv6地址
 * @returns 解析后的IP字符串（纯IP，不带方括号）
 * @throws 解析失败抛出异常
 */
async function systemDnsResolve(domain: string, wantIpv6: boolean): Promise<string> {
  const allAddresses = await connection.getAddressesByName(domain);
  LLog.info(TAG, `systemDnsResolve: domain=${domain}, wantIpv6=${wantIpv6}, allResults=${JSON.stringify(allAddresses)}`)
  // 按 family 过滤：1=IPv4, 2=IPv6
  const filtered = allAddresses.filter(it => wantIpv6 ? it.family === 2 : it.family === 1);
  if (!filtered || filtered.length === 0) {
    throw new Error(`域名解析失败: ${domain} 无${wantIpv6 ? 'IPv6' : 'IPv4'}地址`);
  }
  return filtered[0].address;
}

/**
 * 按解析偏好解析域名
 * IPv4 使用 C++ native（dnsToIp），IPv6 使用 HarmonyOS connection API
 * 原因：HarmonyOS C++ 层 getaddrinfo(AF_INET6) 返回 EAI_SYSTEM (System error)，
 * 系统 connection API 能正确解析 IPv6
 *
 * @param domain 域名
 * @param mode 解析偏好
 * @returns 解析后的IP字符串
 * @throws 解析失败抛出异常
 */
export async function dnsResolveByMode(domain: string, mode: DnsResolveMode): Promise<string> {
  LLog.info(TAG, `dnsResolveByMode: domain=${domain}, mode=${mode}`)
  try {
    let result: string;
    let isIpv6Result = false;
    switch (mode) {
      case DnsResolveMode.FORCE_IPV6:
        result = await systemDnsResolve(domain, true);
        isIpv6Result = true;
        break;
      case DnsResolveMode.FORCE_IPV4:
        result = await native.dnsToIpWithType(domain, 4);
        break;
      case DnsResolveMode.PREFER_IPV6:
        try {
          result = await systemDnsResolve(domain, true);
          isIpv6Result = true;
        } catch (e) {
          LLog.warn(TAG, `IPv6解析失败，回退IPv4: domain=${domain}, error=${e}`)
          result = await native.dnsToIpWithType(domain, 4);
        }
        break;
      case DnsResolveMode.PREFER_IPV4:
      default:
        try {
          result = await native.dnsToIpWithType(domain, 4);
        } catch (e) {
          LLog.warn(TAG, `IPv4解析失败，回退IPv6: domain=${domain}, error=${e}`)
          result = await systemDnsResolve(domain, true);
        }
        break;
    }
    // IPv4结果若为私网地址，走公网DNS直查兜底（详见 resolvePrivateViaPublicDns）
    if (!isIpv6Result) {
      result = await resolvePrivateViaPublicDns(domain, result);
    }
    LLog.info(TAG, `dnsResolveByMode: domain=${domain}, resolved=${result}`)
    return result;
  } catch (e) {
    const errMsg = e instanceof Error ? e.message : String(e);
    LLog.error(TAG, `dnsResolveByMode failed: domain=${domain}, mode=${mode}, error=${errMsg}`)
    throw new Error(`dnsResolveByMode failed: domain=${domain}, mode=${mode}, error=${errMsg}`);
  }
}

/** 私网IPv4判断：10/8、127/8、169.254/16、192.168/16、172.16-31 */
function isPrivateIpv4(ip: string): boolean {
  const m = /^(\d{1,3})\.(\d{1,3})\./.exec(ip);
  if (!m) {
    return false;
  }
  const a = Number(m[1]);
  const b = Number(m[2]);
  return a === 10 || a === 127 || (a === 169 && b === 254) || (a === 192 && b === 168) ||
    (a === 172 && b >= 16 && b <= 31);
}

/**
 * 私网解析结果公网DNS兜底
 *
 * 部分路由器DNS会对自家DDNS域名返回NAT硬回流的内网IP（实测华为路由器返回
 * leojay.synology.me → 10.3.3.6），若该内网地址恰无服务端会导致隧道永远无法建立。
 * 策略：系统解析结果为私网IPv4时，向公网DNS（阿里/腾讯）直查公网A记录；
 * 公网DNS失败（纯内网域名场景）则保留系统结果，行为向后兼容。
 */
async function resolvePrivateViaPublicDns(domain: string, ip: string): Promise<string> {
  if (!isPrivateIpv4(ip)) {
    return ip;
  }
  LLog.warn(TAG, `解析结果为私网地址(${ip})，尝试公网DNS直查: domain=${domain}`)
  const servers = ['223.5.5.5', '119.29.29.29'];
  for (const server of servers) {
    try {
      const pub = await native.dnsToIpFromServer(domain, 4, server);
      if (pub) {
        LLog.info(TAG, `公网DNS(${server})解析成功: domain=${domain}, resolved=${pub}`)
        return pub;
      }
    } catch (e) {
      LLog.warn(TAG, `公网DNS(${server})解析失败: domain=${domain}, error=${e}`)
    }
  }
  LLog.warn(TAG, `公网DNS均失败，保留系统解析结果: ${ip}`)
  return ip;
}

/**
 * 将 native 抛出的英文/混合错误转换为中文可读信息
 * @param e 错误对象或错误信息字符串
 * @returns 中文错误信息
 */
export function formatDnsError(e: Error | string): string {
  const raw = typeof e === 'string' ? e : e.message;
  if (raw.includes('No address associated') || raw.includes('无IPv4') || raw.includes('无IPv6')) {
    return '该域名没有对应类型的IP地址';
  }
  if (raw.includes('Temporary failure')) {
    return 'DNS服务器暂时不可用，请检查网络';
  }
  if (raw.includes('Network is unreachable') || raw.includes('网络不可达')) {
    return '网络不可达，请检查网络连接';
  }
  if (raw.includes('Name or service not known') || raw.includes('域名无法识别')) {
    return '域名无法识别，请检查域名拼写';
  }
  if (raw.includes('地址族')) {
    return '该域名没有对应类型的IP地址';
  }
  if (raw.includes('2100002') || raw.includes('2101007')) {
    return '网络不可用，请检查网络连接';
  }
  if (raw.includes('2102001') || raw.includes('2102002')) {
    return '域名解析失败，请检查域名拼写或网络';
  }
  return `解析失败：${raw}`;
}

/**
 * 从 WebSitePoint 读取有效 dnsMode（兼容旧数据）
 * 旧数据只有 forceIpv6 字段时：forceIpv6===true 映射为 FORCE_IPV6，否则 PREFER_IPV4
 * @param sitePoint 站点点
 * @returns 解析偏好
 */
export function getDnsMode(sitePoint: WebSitePoint): DnsResolveMode {
  if (sitePoint.dnsMode !== undefined) {
    return sitePoint.dnsMode;
  }
  return sitePoint.forceIpv6 ? DnsResolveMode.FORCE_IPV6 : DnsResolveMode.PREFER_IPV4;
}

/**
 * 解析偏好中文名称（用于预览界面只读展示）
 * @param mode 解析偏好
 * @returns 中文描述
 */
export function dnsModeDesc(mode: DnsResolveMode): string {
  switch (mode) {
    case DnsResolveMode.PREFER_IPV6:
      return '优先IPv6';
    case DnsResolveMode.FORCE_IPV6:
      return '强制IPv6';
    case DnsResolveMode.FORCE_IPV4:
      return '强制IPv4';
    case DnsResolveMode.PREFER_IPV4:
    default:
      return '默认优先IPv4';
  }
}
