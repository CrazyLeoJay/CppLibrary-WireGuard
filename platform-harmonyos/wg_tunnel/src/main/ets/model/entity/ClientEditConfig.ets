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
export default class ClientEditConfig {
  @Trace deviceName?: string; // 设备名称，或者配置名
  @Trace privateKey?: string; // 本地私钥
  @Trace publicKey?: string; // 本地公钥
  @Trace listenerPort?: number; //本地监听端口(0或者空表示使用默认值 51820)
  @Trace vpnAddress?: string; // vpn网络IP地址，也称VPN 局域网ip地址
  @Trace bindAddress?: string; // 绑定本地ip，一般是null，如果有多网卡情况，可以指定ip监听。
  @Trace dnsIps?: string; // 绑定本地ip，一般是null，如果有多网卡情况，可以指定ip监听。
  /**
   * IPv4 最小 MTU：576 字节
   * （RFC 791 规定主机必须能处理至少 576 字节的 IP 数据报）
   * IPv6 最小 MTU：1280 字节
   * （RFC 2460 强制要求链路层支持至少 1280 字节）
   * ⚠️ 实际 MTU 不能低于这些最小值，否则无法兼容标准 IP 通信。
   *
   *  常见网络类型默认 MTU
   * 网络类型	默认 MTU（字节）
   * 以太网（Ethernet）	    1500
   * PPPoE（如家庭宽带拨号）	1492 或 1480
   * IEEE 802.3 / 802.2	  1492
   * X.25	                576
   * FDDI	                4352
   * 令牌环网（16 Mbps）	  17914
   *
   * ✅ 推荐实践
   * 普通以太网：保持 1500
   * 使用 PPPoE / VPN / 隧道：尝试 1492、1480、1450、1400，通过 ping -f -l size 测试最佳值
   * 数据中心内部高速网络（支持 Jumbo Frame）：设为 9000
   */
  @Trace mtu?: number; // 配置MTU
}
