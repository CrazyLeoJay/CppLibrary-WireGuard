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
      if (!cidr) {
        throw new WGAppException("cidr 转换失败")
      }
      return {
        ip: ip,
        cidr: cidr,
      };
    }
    return {
      ip: content,
      cidr: -1,
    };
  }

  static getIpPort(content: string): IpPortSplit {
    if (content.includes(":")) {
      const result = content.split(":")
      const ip = result[0]
      const str = result[1]
      const port = Number.parseInt(str);
      if (!port) {
        throw new WGAppException("port 转换失败")
      }
      return {
        ip: ip,
        port: port,
      };
    }
    return {
      ip: content,
      port: 80,
    };
  }

}

interface IpCidrSplit {
  ip: string,
  cidr: number;
}

interface IpPortSplit {
  ip: string,
  port: number;
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
    /(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:(:[0-9a-fA-F]{1,4}){1,6}|:(:[0-9a-fA-F]{1,4}){1,7}|::|(?:[0-9a-fA-F]{1,4}:){1,4}:(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?))/
  static ipv6 = RegExp(`^${Regex.IPV6_PATTERN}$`)
  static ipv6Mark = RegExp(`^${Regex.IPV6_PATTERN}\/([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8])$`)
  static ipv6OrMark = RegExp(`^${Regex.IPV6_PATTERN}(\/([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))?$`)
  static ipv6Port = RegExp(`^${Regex.IPV6_PATTERN}:(${Regex.PORT_PATTERN})$`)
  static ipv6OrPort = RegExp(`^${Regex.IPV6_PATTERN}(:(${Regex.PORT_PATTERN}))?$`)
}
