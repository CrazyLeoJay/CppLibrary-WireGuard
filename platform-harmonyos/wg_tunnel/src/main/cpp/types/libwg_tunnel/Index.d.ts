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
import { ClientRegisterConfig, KeyPair, WGConf } from './entity';

export const makeKeyPair: () => Promise<KeyPair>;

export const genPrivateKey: () => Promise<string>;

export function genPublicKey(privateKey: string): Promise<string>;

export function readWGConf(conf: string): Promise<WGConf>;

export function readWGConfToJson(conf: string): Promise<string>;

export function isIpv4(ip: string): Promise<boolean>;

export function isIpv6(ip: string): Promise<boolean>;

/**
 * 是否为IP地址，ipv4或者ipv6
 * @param ip
 * @returns
 */
export function isIpAddress(ip: string): Promise<boolean>;

/**
 * 是否为域名
 * @param domain
 * @returns
 */
export function isValidDomain(domain: string): Promise<boolean>;

/**
 * 是否为base64位的Key
 * @param key
 * @returns
 */
export function isValidBase64Key(key: string): Promise<boolean>;


/**
 * @author leojay`fu
 */
export class WireGuardDevice {
  /**
   * 创建链接，并且获取 socket的描述符
   *
   * @param config 链接配置
   * @param listener socket fd 切换通知
   * @returns socket 连接符
   */
  // @ts-ignore
  async initVpn(config: ClientRegisterConfig, listener: (fd: number) => void): Promise<number>;

  // @ts-ignore
  async start(tunFd: number): Promise<void>;

  // @ts-ignore
  async close(): Promise<void>;
}

export { KeyPair };
