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
import { LLog, errToString } from './LLog';

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
 * IPv4 走 C++ native（dnsToIpWithType）+ 系统 connection API 双路回退
 * IPv6 走 HarmonyOS connection API
 * 原因：HarmonyOS C++ 层 getaddrinfo(AF_INET6) 返回 EAI_SYSTEM (System error)，
 * 系统 connection API 能正确解析 IPv6。
 *
 * 双路回退的必要性（真机实证）：承载切换的数百毫秒内，native 的 getaddrinfo 会
 * 拿到 EAI_AGAIN（"Try again"）——出网路径此刻本来就不可用。而系统
 * connection.getAddressesByName 走 netd，同一时刻往往当场就能拿到结果。
 * 原实现只回退到另一族（IPv4 失败→IPv6），两族都不可达时直接失败，
 * 上层据此判"DNS 不可用"并升级为整隧道重启——这是切换后长时间断网的关键放大器。
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
    switch (mode) {
      case DnsResolveMode.FORCE_IPV6:
        result = await systemDnsResolve(domain, true);
        break;
      case DnsResolveMode.FORCE_IPV4:
        result = await native.dnsToIpWithType(domain, 4);
        break;
      case DnsResolveMode.PREFER_IPV6:
        try {
          result = await systemDnsResolve(domain, true);
        } catch (e) {
          LLog.warn(TAG, `IPv6解析失败，回退系统IPv4: domain=${domain}, error=${errToString(e)}`)
          try {
            result = await systemDnsResolve(domain, false);
          } catch (e2) {
            LLog.warn(TAG, `系统IPv4解析亦失败，回退native IPv4: domain=${domain}, error=${errToString(e2)}`)
            result = await native.dnsToIpWithType(domain, 4);
          }
        }
        break;
      case DnsResolveMode.PREFER_IPV4:
      default:
        try {
          result = await native.dnsToIpWithType(domain, 4);
        } catch (e) {
          LLog.warn(TAG, `IPv4解析失败（native），回退系统IPv4: domain=${domain}, error=${errToString(e)}`)
          try {
            // 系统解析走 netd，网络切换瞬间比 native getaddrinfo 更可靠（真机实测当场可成）
            result = await systemDnsResolve(domain, false);
          } catch (e2) {
            // 两路 IPv4 均失败即认定失败，不再回退 IPv6：域名通常只有 A 记录，
            // 回退 IPv6 必然抛"无IPv6地址"，既白耗一次 2 秒超时，又让上层把
            // "IPv4 解析失败"误读为"DNS 不可用"（真机实证：该误判是切换后长时间断网的放大器）
            LLog.warn(TAG, `系统IPv4解析亦失败，放弃本次（IPv4优先，不再回退IPv6）: domain=${domain}, error=${errToString(e2)}`)
            throw new Error(`IPv4解析失败: ${domain}, native=${errToString(e)}`)
          }
        }
        break;
    }
    LLog.info(TAG, `dnsResolveByMode: domain=${domain}, resolved=${result}`)
    return result;
  } catch (e) {
    const errMsg = errToString(e);
    // 传对象而非拼字符串：LLog 的 p2s 能展开 error.message/stack，
    // 拼进模板串反而会把普通对象变成 "[object Object]"（真机实证的丢根因方式）
    LLog.error(TAG, { error: e, message: `dnsResolveByMode failed: domain=${domain}, mode=${mode}` })
    throw new Error(`dnsResolveByMode failed: domain=${domain}, mode=${mode}, error=${errMsg}`);
  }
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
