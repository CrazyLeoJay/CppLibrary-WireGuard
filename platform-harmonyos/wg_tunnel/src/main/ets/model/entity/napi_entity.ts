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
  deviceName: string; // 设备名称
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
  deviceName: string;
  privateKey: string;
  ipArea: IPAddressArea;
  listenerPort?: number,
  dns: IPAddress[];
  mtu?: number;
  excludedApplications?: string[];
  includedApplications?: string[];
}

export interface WGConfPeer {
  publicKey: string;
  endpoint: WebSitePoint; // 要建立链接的站点地址
  allowedIPs: IPAddressArea[]; // 需要路由的ip地址域
  keepaliveInterval: number; // 保活间隔
  preSharedKey?: string; // 共享密钥，可能为null
}

export enum SiteUrlType {
  ERROR = 0,
  IPv4 = 1, IPv6 = 2, Domain = 3,
}

/**
 * DNS解析偏好（互斥单选）
 */
export enum DnsResolveMode {
  PREFER_IPV4 = 0,  // 默认优先IPv4，解析失败回退IPv6
  PREFER_IPV6 = 1,  // 优先IPv6，解析失败回退IPv4
  FORCE_IPV6 = 2,   // 强制IPv6，只解析IPv6
  FORCE_IPV4 = 3,   // 强制IPv4，只解析IPv4
}

/**
 * 站点：域名或者ip地址 和 端口
 * 域名和ip地址都可
 */
export interface WebSitePoint {
  ipStrOrDomain: string; // ip地址或者域名
  port: number; // 远程端口，没有默认80
  type: SiteUrlType;
  forceIpv6?: boolean; // 兼容旧字段（废弃，但保留读取）
  dnsMode?: DnsResolveMode; // 新的互斥解析偏好
}

/**
 * 数据方向
 */
export enum StreamDirection { RECEIVE = 1, SEND = 2 }

/**
 * 流数据计算
 * 每个Peer单独计算
 */
export interface StreamCalculate {
  length: number; // 当前数据大小
  receiveTotal: number; // 接收总数据量
  sendTotal: number; // 发送总数据量
}

export enum MessageType {
  // 无效消息类型，用于初始化或错误处理
  INVALID = 0,
  HANDSHAKE_INITIATION = 1,
  HANDSHAKE_RESPONSE = 2,
  HANDSHAKE_COOKIE = 3,
  DATA = 4
}

export class Timestamp extends Number {
  constructor(value: number) {
    super(value);
  }

  static from(value: number | Timestamp): Timestamp {
    if (value instanceof Timestamp) {
      return value;
    }
    return new Timestamp(value);
  }

  getFullYear(): number {
    return new Date(this.valueOf()).getFullYear();
  }

  getMonth(): number {
    return new Date(this.valueOf()).getMonth() + 1;
  }

  getDate(): number {
    return new Date(this.valueOf()).getDate();
  }

  getHours(): number {
    return new Date(this.valueOf()).getHours();
  }

  getMinutes(): number {
    return new Date(this.valueOf()).getMinutes();
  }

  getSeconds(): number {
    return new Date(this.valueOf()).getSeconds();
  }

  getMilliseconds(): number {
    return new Date(this.valueOf()).getMilliseconds();
  }

  format(pattern: string = 'yyyy-MM-dd HH:mm:ss:SSS'): string {
    const date = new Date(this.valueOf());
    const year = date.getFullYear().toString();
    const month = this.pad(date.getMonth() + 1);
    const day = this.pad(date.getDate());
    const hours = this.pad(date.getHours());
    const minutes = this.pad(date.getMinutes());
    const seconds = this.pad(date.getSeconds());
    const ms = this.pad(date.getMilliseconds(), 3);

    return pattern
      .replace('yyyy', year)
      .replace('MM', month)
      .replace('dd', day)
      .replace('HH', hours)
      .replace('mm', minutes)
      .replace('ss', seconds)
      .replace('SSS', ms);
  }

  toString(): string {
    return this.format();
  }

  toLocaleString(): string {
    return new Date(this.valueOf()).toLocaleString();
  }

  private pad(num: number, length: number = 2): string {
    return num.toString().padStart(length, '0');
  }
}

export interface StreamLogMessage {
  timestamp: number,
  publicKey: string; // 使用PublicKey作为主键
  peerIndex: number; // 顺序索引
  messageType: MessageType; // 数据类型
  direction: StreamDirection; // 数据方向
  sc: StreamCalculate; // 数据大小
  success: boolean;
  msg: string;
}
