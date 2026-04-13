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
export const add: (a: number, b: number) => number;

export const makeKeyPair: () => KeyPair;

export const genPrivateKey: () => string;

export function genPublicKey(privateKey: string): string;

export interface KeyPair {
  privateKey: string;
  publicKey: string;
}

/**
 * @author leojay`fu
 */
export interface ClientRegisterConfig {
  client: ClientConfig; // 客户端配置
  peers: PeerConfig[]; // 对等端配置列表
}

/**
 * @author leojay`fu
 */
export interface ClientConfig {
  deviceName: string; // 设备名称，或者配置名
  privateKey: string; // 本地私钥
  publicKey: string; // 本地公钥
  listenerPort?: number; //本地监听端口(0或者空表示使用默认值 51820)
  bindAddress?: IPAddress; // 绑定本地ip，一般是null，如果有多网卡情况，可以指定ip监听。
}

/**
 * @author leojay`fu
 */
export interface PeerConfig {
  publicKey: string; // 对等节点的PublicKey 必有
  endpoint: Endpoint; // 远端IP、端口 必有
  allowedIps: IPAddress[]; // 允许访问的IP规则 必须有，通过这个去选择流量
  preSharedKey?: string; // 预共享密钥。可选
  keepaliveInterval?: number; // 保活时间间隔 s
}

/**
 * @author leojay`fu
 */
export interface Endpoint {
  address: IPAddress;
  port: number;
}

/**
 * @author leojay`fu
 */
export interface IPAddress {
  ip: string;
  isIpv4: boolean; // true表示为ipv4， 否则为 ipv6
  cidr?: number;
}

// 当前Socket发生变化时回调，并且第一次初始化时，也要回调
export interface SocketFdListener {
  listener: (fd: number) => void;
}

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
