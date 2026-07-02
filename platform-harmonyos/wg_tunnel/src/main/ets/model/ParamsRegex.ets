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
 * 参数正则表达式
 *
 * Created on 2026/7/2.
 * @author leojay`fu
 */
export default class ParamsRegex {
  /**
   * 先检测地址类型，再校验端口合法性
   */
  peerAddressCheck(address?: string): AddressTypeResult {
    if (!address || address.length === 0) {
      return {
        addressType: AddressType.NONE,
        verify: false,
        message: '地址不能为空'
      };
    }

    const parsed = parseHostAndPort(address);

    const addressType = detectAddressType(parsed.host);

    let verify = true;
    const messages: string[] = [];

    if (addressType === AddressType.NONE) {
      verify = false;
      messages.push('地址类型未知');
      messages.push('不支持的地址格式，仅支持 IPv4、IPv6 或合法域名');
    } else {
      messages.push(`当前输入为${getAddressTypeName(addressType)}类型`);
    }

    if (parsed.portRaw !== undefined) {
      if (!/^\d+$/.test(parsed.portRaw)) {
        verify = false;
        messages.push('端口格式不合法，端口必须为数字');
      } else {
        const portNum = parseInt(parsed.portRaw, 10);
        if (!isValidPort(portNum)) {
          verify = false;
          messages.push(`端口 ${portNum} 不合法，端口范围应为 1-65535`);
        } else {
          messages.push(`端口 ${portNum} 合法`);
        }
      }
    }

    return {
      addressType,
      verify,
      message: messages.join('；')
    };
  }
}

interface ParseResult {
  host: string;
  portRaw: string | undefined;
}

function parseHostAndPort(address: string): ParseResult {
  const lastColonIndex = address.lastIndexOf(':');
  const lastBracketIndex = address.lastIndexOf(']');

  if (address.startsWith('[') && lastBracketIndex > 0) {
    const portPart = address.substring(lastBracketIndex + 1);
    const host = address.substring(1, lastBracketIndex);
    if (portPart.length === 0) {
      return { host, portRaw: undefined };
    }
    if (portPart.startsWith(':')) {
      return { host, portRaw: portPart.substring(1) };
    }
    return { host, portRaw: portPart };
  }

  if (lastColonIndex >= 0) {
    const colonCount = (address.match(/:/g) || []).length;
    if (colonCount === 1) {
      const host = address.substring(0, lastColonIndex);
      const portRaw = address.substring(lastColonIndex + 1);
      return { host, portRaw };
    }
  }

  return { host: address, portRaw: undefined };
}

function detectAddressType(host: string): AddressType {
  if (REGEX_IPV4.test(host)) {
    return AddressType.IPV4;
  }
  if (REGEX_IPV6.test(host)) {
    return AddressType.IPV6;
  }
  if (REGEX_DOMAIN.test(host)) {
    return AddressType.DOMAIN;
  }
  return AddressType.NONE;
}

function isValidPort(port: number): boolean {
  return !isNaN(port) && port >= 1 && port <= 65535;
}

function getAddressTypeName(type: AddressType): string {
  switch (type) {
    case AddressType.IPV4:
      return 'IPv4';
    case AddressType.IPV6:
      return 'IPv6';
    case AddressType.DOMAIN:
      return '域名';
    default:
      return '未知';
  }
}

const REGEX_IPV4 =
  /^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$/

const REGEX_IPV6 =
  /^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))$/

const REGEX_DOMAIN =
  /^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$/

export enum AddressType {
  NONE, // 未知
  IPV4, // ipv4
  IPV6, // ipv6
  DOMAIN, // 域名
}

export interface AddressTypeResult {
  addressType: AddressType
  verify: boolean
  message: string
}