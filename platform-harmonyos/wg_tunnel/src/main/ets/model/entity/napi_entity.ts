export interface KeyPair {
  privateKey: string;
  publicKey: string;
}

/**
 * @author leojay`fu
 */
export interface DeviceRegisterConfig {
  device: DeviceConfig; // 客户端配置
  peers: PeerConfig[]; // 对等端配置列表
}

/**
 * @author leojay`fu
 */
export interface DeviceConfig {
  privateKey: string; // 本地私钥
  listenerPort?: number; //本地监听端口(0或者空表示使用默认值 51820)
  bindAddress?: IPAddress; // 绑定本地ip，一般是null，如果有多网卡情况，可以指定ip监听。
}

/**
 * @author leojay`fu
 */
export interface PeerConfig {
  publicKey: string; // 对等节点的PublicKey 必有
  endpoint: Endpoint; // 远端IP、端口 必有
  allowedIps: IPAddressArea[]; // 允许访问的IP规则 必须有，通过这个去选择流量
  preSharedKey?: string; // 预共享密钥。可选
  keepaliveInterval?: number; // 保活时间间隔 s
}

/**
 * @author leojay`fu
 */
export interface IPAddress {
  ip: string;
  isIpv4: boolean; // true表示为ipv4， 否则为 ipv6
}


/**
 * ip端点
 * ip地址和端口
 * @author leojay`fu
 */
export interface Endpoint {
  address: IPAddress;
  port: number;
}

/**
 * 地址区域，有掩码
 */
export interface IPAddressArea {
  address: IPAddress;
  cidr: number; // -1表示没有掩码
}


export interface WGConf {
  inter: WGConfInterface;
  peers: WGConfPeer[]
}

export interface WGConfInterface {
  privateKey: string;
  ipArea: IPAddressArea;
  listenerPort?: number,
  dns: IPAddress[];
  mtu?:number;
}

export interface WGConfPeer {
  publicKey: string;
  endpoint: WebSitePoint; // 要建立链接的站点地址
  allowedIPs: IPAddressArea[]; // 需要路由的ip地址域
  keepaliveInterval: number; // 保活间隔
  preSharedKey?: string; // 共享密钥，可能为null
}

/**
 * 站点：域名或者ip地址 和 端口
 * 域名和ip地址都可
 */
export interface WebSitePoint {
  ipStrOrDomain: string; // ip地址或者域名
  port: number; // 远程端口，没有默认80
}
