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
import WGAppException from '../error/WGAppException';
import { LLog } from './LLog';
import { WebSitePoint, SiteUrlType, IPAddressArea } from '../model/entity/napi_entity';
import { WireGuard } from '../model/WGHelper';

export default class Tools {
  static isBlank(content?: string): boolean {
    return !content || content.trim().length == 0
  }


  /**
   * 是否为 44 位 Key
   * @param content
   * @returns
   */
  static is44Key(content?: string): boolean {
    return !Tools.isBlank(content) && content?.length == 44;
  }

  static isIpv4OrPort(content?: string) {
    LLog.info("stest", `^${Regex.IPV4_PATTERN}(:(${Regex.PORT_PATTERN}))?$`)
    return !Tools.isBlank(content) && Regex.ipv4OrPort.test(content!);
  }

  static isIpv4Mark(content?: string) {
    return !Tools.isBlank(content) && Regex.ipv4Mark.test(content!);
  }

  static isIpv4OrMark(content?: string) {
    return !Tools.isBlank(content) && Regex.ipv4OrMark.test(content!);
  }

  static isIpv6OrPort(content?: string) {
    return !Tools.isBlank(content) && Regex.ipv6OrPort.test(content!);
  }

  static isIpv6Mark(content?: string) {
    return !Tools.isBlank(content) && Regex.ipv6Mark.test(content!);
  }

  static isIpv6OrMark(content?: string) {
    return !Tools.isBlank(content) && Regex.ipv6OrMark.test(content!);
  }

  /**
   * 获取掩码长度
   * 必须是合格的IP地址
   */
  static getIpCidr(content: string): IpCidrSplit {
    if (content.includes("/")) {
      const result = content.split("/")
      const ip = result[0]
      const str = result[1]
      const cidr = Number.parseInt(str);
      if (cidr < 0) {
        throw new WGAppException(`cidr 转换失败：${cidr}`)
      }
      return {
        ip: Tools.stripBrackets(ip),
        cidr: cidr,
      };
    }
    return {
      ip: Tools.stripBrackets(content),
      cidr: -1,
    };
  }

  /**
   * 移除 IPv6 地址外的中括号
   * 如 [::1] -> ::1
   */
  private static stripBrackets(ip: string): string {
    if (ip.startsWith("[") && ip.endsWith("]")) {
      return ip.substring(1, ip.length - 1);
    }
    return ip;
  }

  /**
   * 读取IP地址段
   * 解析IP和掩码，使用 native 库验证IP类型
   * 未提供掩码时自动补全默认值（IPv4=32, IPv6=128）
   * @param content IP地址或地址段，如 192.168.1.0/24 或 ::1/128
   * @returns IPAddressArea
   */
  static async readIpArea(content: string): Promise<IPAddressArea> {
    const ipCidr = Tools.getIpCidr(content);
    const ip = ipCidr.ip;
    const cidr = ipCidr.cidr;

    let isIpv4: boolean;
    let maxCidr: number;

    if (await WireGuard.Tools.isIpv4(ip)) {
      isIpv4 = true;
      maxCidr = 32;
    } else if (await WireGuard.Tools.isIpv6(ip)) {
      isIpv4 = false;
      maxCidr = 128;
    } else {
      throw new WGAppException(`(${content})不合法。必须是合法的IPv4或IPv6地址`)
    }

    if (cidr !== -1 && (cidr < 0 || cidr > maxCidr)) {
      throw new WGAppException(`${content} ${isIpv4 ? 'ipv4' : 'ipv6'} 掩码取值范围为0-${maxCidr}`)
    }

    return {
      address: { ip: ip, isIpv4: isIpv4 },
      cidr: cidr === -1 ? maxCidr : cidr,
    };
  }

  static async readEndpointAddress(content: string): Promise<WebSitePoint> {
    let ipStr: string;
    let port: number;

    if (content.startsWith("[")) {
      const endBracket = content.indexOf("]");
      if (endBracket === -1) {
        throw new WGAppException("IPv6 地址格式错误")
      }
      ipStr = content.substring(1, endBracket);
      if (endBracket + 1 < content.length && content.charAt(endBracket + 1) === ":") {
        const portStr = content.substring(endBracket + 2);
        port = Number.parseInt(portStr);
        if (isNaN(port)) {
          throw new WGAppException("port 转换失败")
        }
      } else {
        port = 80;
      }
    } else if (content.includes(":")) {
      const colonCount = content.split(":").length - 1;
      if (colonCount > 1) {
        ipStr = content;
        port = 80;
      } else {
        const result = content.split(":")
        ipStr = result[0]
        const str = result[1]
        port = Number.parseInt(str);
        if (isNaN(port)) {
          throw new WGAppException("port 转换失败")
        }
      }
    } else {
      ipStr = content;
      port = 80;
    }

    let type: SiteUrlType;
    if (await WireGuard.Tools.isIpv4(ipStr)) {
      type = SiteUrlType.IPv4;
    } else if (await WireGuard.Tools.isIpv6(ipStr)) {
      type = SiteUrlType.IPv6;
    } else if (await WireGuard.Tools.isValidDomain(ipStr)) {
      type = SiteUrlType.Domain;
    } else {
      type = SiteUrlType.ERROR;
    }

    return {
      ipStrOrDomain: ipStr,
      port: port,
      type: type,
    };
  }
}

interface IpCidrSplit {
  ip: string,
  cidr: number;
}

class Regex {
  static IPV4_PATTERN = `((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)`
  static PORT_PATTERN = `[0-9]|[1-9][0-9]{1,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-3][0-5]`
  static ipv4 = RegExp(`^${Regex.IPV4_PATTERN}$`)
  static ipv4Mark = RegExp(`^${Regex.IPV4_PATTERN}\/([0-9]|[1-2][0-9]|3[0-2])$`)
  static ipv4OrMark = RegExp(`^${Regex.IPV4_PATTERN}(\/([0-9]|[1-2][0-9]|3[0-2]))?$`)
  static ipv4Port = RegExp(`^${Regex.IPV4_PATTERN}:(${Regex.PORT_PATTERN})$`)
  static ipv4OrPort = RegExp(`^${Regex.IPV4_PATTERN}(:(${Regex.PORT_PATTERN}))?$`)
  /**
   * ^(
   * ([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|
   * ([0-9a-fA-F]{1,4}:){1,7}:|
   * ([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|
   * ([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|
   * ([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|
   * ([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|
   * ([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|
   * [0-9a-fA-F]{1,4}:(:[0-9a-fA-F]{1,4}){1,6}|
   * :(:[0-9a-fA-F]{1,4}){1,7}|
   * ::|
   * (?:[0-9a-fA-F]{1,4}:){1,4}:(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)
   * )$
   */
  private static IPV6_PATTERN =
    `(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:(:[0-9a-fA-F]{1,4}){1,6}|:(:[0-9a-fA-F]{1,4}){1,7}|::|(?:[0-9a-fA-F]{1,4}:){1,4}:(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?))`
  static ipv6 = RegExp(`^${Regex.IPV6_PATTERN}$`)
  static ipv6Mark = RegExp(`^${Regex.IPV6_PATTERN}\/([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8])$`)
  static ipv6OrMark = RegExp(`^${Regex.IPV6_PATTERN}(\/([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))?$`)
  static ipv6Port = RegExp(`^${Regex.IPV6_PATTERN}:(${Regex.PORT_PATTERN})$`)
  static ipv6OrPort = RegExp(`^${Regex.IPV6_PATTERN}(:(${Regex.PORT_PATTERN}))?$`)
}
