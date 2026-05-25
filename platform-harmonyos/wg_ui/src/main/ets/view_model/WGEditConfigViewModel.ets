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
import { WireGuard } from 'wg_tunnel/src/main/ets/model/WGHelper';
import { LLog } from 'wg_tunnel/src/main/ets/tools/LLog';
import { pasteboard } from '@kit.BasicServicesKit';
import PeerEditConfig from 'wg_tunnel/src/main/ets/model/entity/PeerEditConfig';
import ClientEditConfig from 'wg_tunnel/src/main/ets/model/entity/ClientEditConfig';
import Tools from 'wg_tunnel/src/main/ets/tools/tools';
import WGAppException from 'wg_tunnel/src/main/ets/error/WGAppException';
import { IPAddress, IPAddressArea, WGConfPeer, WGDBConf, } from 'wg_tunnel';
import WGEditConfigParams from '../entity/WGEditConfigParams';

const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();

const TAG = "创建VPN"

/**
 * 主页数据持有
 */
@ObservedV2
export default class WGNewConfigViewModel {
  nav: NavPathStack = new NavPathStack();
  @Trace client: ClientEditConfig = new ClientEditConfig(); // 客户端配置
  @Trace peers: PeerEditConfig[] = []; // 对等端配置列表
  inputRegex = new InputRegex();
  dbId?: number;
  /**
   * 记录下每次随机生成时的私钥
   * 用于检测私钥变化时，是否生成公钥进行计算
   */
  private lastPrivateKey?: string;

  constructor(nav?: NavPathStack) {
    if (nav) {
      this.nav = nav;
    }
  }

  async initEditData(params: WGEditConfigParams) {
    LLog.info(TAG, "预填充数据")
    const config = params.config;
    this.dbId = params.id;

    this.client.deviceName = config.name
    this.client.privateKey = config.conf.inter.privateKey
    this.client.publicKey = await WireGuard.genPublicKey(config.conf.inter.privateKey);
    this.client.listenerPort = config.conf.inter.listenerPort
    this.client.vpnAddress = `${config.conf.inter.ipArea.address.ip}/${config.conf.inter.ipArea.cidr}`
    this.client.dnsIps = config.conf.inter.dns?.map((it) => it.ip)
      .join(",")
    this.client.mtu = config.conf.inter.mtu
    this.peers = config.conf.peers.map((it) => {
      const config = new PeerEditConfig();
      config.publicKey = it.publicKey;
      config.preSharedKey = it.preSharedKey;
      config.address = `${it.endpoint.ipStrOrDomain}:${it.endpoint.port}`;
      config.allowedIpsInput = it.allowedIPs.map((it) => `${it.address.ip}/${it.cidr}`).join(",");
      config.keepaliveInterval = it.keepaliveInterval;
      return config;
    })
  }

  async makeKeyPair() {
    try {
      let kp = await WireGuard.makeKeyPair();
      this.client.publicKey = kp.publicKey;
      this.client.privateKey = kp.privateKey;
      this.lastPrivateKey = kp.privateKey;
      LLog.info(TAG, `生成KeyPair：\nPrivateKey:${this.client.privateKey}\nPublicKey :${this.client.publicKey}`)
    } catch (e) {
      LLog.warn(TAG, e)
    }
  }

  @Monitor("client.privateKey")
  async listenerPrivateKey() {
    // LLog.info(TAG, `${this.client.privateKey}`)
    if (this.client.privateKey) {
      try {
        if (!Tools.isBlank(this.client.privateKey) && this.client.privateKey == this.lastPrivateKey) {
          return;
        }
        if (Tools.is44Key(this.client.privateKey)) {
          let pubKey = await WireGuard.genPublicKey(this.client.privateKey);
          this.client.publicKey = pubKey;
        } else {
          this.client.publicKey = undefined;
        }
      } catch (e) {
        LLog.warn(TAG, "计算失败")
      }
    } else {
      this.client.publicKey = undefined;
    }
  }

  async copyPublicKeyToSystem(context: UIContext) {
    if (!Tools.is44Key(this.client.publicKey)) {
      return;
    }
    let pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.client.publicKey);
    try {
      await systemPasteboard.setData(pasteData);
      LLog.info(TAG, "将公钥复制进入系统剪贴板")
      context.getPromptAction().showToast({
        message: "已复制",
      })
    } catch (error) {
      LLog.info(TAG, `将公钥复制进入系统剪贴板 异常！！！！：${error}`)
    }
  }

  /**
   * 测试用
   * PrivateKey:CKvZGm8S0HoQUwvUIsZ8wd39Bqt/5Z5vaJNuKX4LHGI=
   * PublicKey :gN9lnPxypH67F7KystwjDdpwNsT007AV8s/MOOc0QGM=
   */
  async save(context: UIContext) {
    // LLog.info(TAG, `config: ${json.stringify(this.client)}`)
    // LLog.info(TAG, `peer: ${json.stringify(this.peers)}`)

    try {
      let db = await this.checkAndMakeDBConfig();
      LLog.info(TAG, `db Config : ${JSON.stringify(db)}`)
      if (this.dbId) {
        WireGuard.helper.config.updateConfig(this.dbId, db);
      } else {
        WireGuard.helper.config.insertNewConfig(db);
      }
      this.nav.pop({});
    } catch (e) {
      LLog.warn(TAG, e);
      if (e instanceof WGAppException) {
        try {
          context.getPromptAction()
            .showToast({
              message: e.message
            })
        } catch (e) {
          LLog.error(TAG, e)
        }
      }
    }
  }

  addNewPeer() {
    try {
      this.peers.push(new PeerEditConfig())
    } catch (error) {
      LLog.error(TAG, `添加空配置异常：${error}}`)
    }
  }

  removePeer(peer: PeerEditConfig) {
    try {
      this.peers.splice(this.peers.indexOf(peer), 1);
    } catch (error) {
      LLog.error(TAG, `移除配置异常：${error}}`)
    }
  }


  /**
   * 检查参数并且构建保存实体
   * @returns
   */
  private async checkAndMakeDBConfig(): Promise<WGDBConf> {
    if (Tools.isBlank(this.client.deviceName)) {
      throw new WGAppException("设备名称不能为空")
    }
    if (!Tools.is44Key(this.client.privateKey)) {
      throw new WGAppException("本地私钥格式异常")
    }

    // 公钥虽然是自动生成，但这里检查一下
    if (!Tools.is44Key(this.client.publicKey)) {
      throw new WGAppException("本地公钥格式异常")
    }

    let ipAddress: IPAddressArea
    if (Tools.isIpv4OrMark(this.client.vpnAddress)) {
      const ic = Tools.getIpCidr(this.client.vpnAddress!)
      if (ic.cidr < -1 || ic.cidr > 32) {
        throw new WGAppException("ipv4 掩码取值范围为0-32")
      }
      ipAddress = { address: { ip: ic.ip, isIpv4: true, }, cidr: ic.cidr }
    } else if (Tools.isIpv6OrMark(this.client.vpnAddress)) {
      const ic = Tools.getIpCidr(this.client.vpnAddress!)
      if (ic.cidr < -1 || ic.cidr > 128) {
        throw new WGAppException("ipv6 掩码取值范围为0-128")
      }
      ipAddress = { address: { ip: ic.ip, isIpv4: false }, cidr: ic.cidr }
    } else {
      throw new WGAppException(`局域网Ip地址（${this.client.vpnAddress}）不合法`)
    }

    let dns: IPAddress[] = []
    if (this.client.dnsIps?.length ?? 0 > 0) {
      const dnsIps = this.client.dnsIps!;
      if (dnsIps.includes(",")) {
        dns = await Promise.all(dnsIps.split(",").map(async (it) => {
          return {
            ip: dnsIps,
            isIpv4: await WireGuard.Tools.isIpv4(dnsIps)
          } as IPAddress
        })
        )
      } else {
        dns.push({
          ip: dnsIps,
          isIpv4: await WireGuard.Tools.isIpv4(dnsIps)
        })
      }
    }

    if (this.peers.length == 0) {
      throw new WGAppException("至少包含一个 Peer")
    }
    const dbPeers = await Promise.all(this.peers.map((it) => this.checkForPeer(it)));
    return {
      name: this.client.deviceName,
      conf: {
        inter: {
          privateKey: this.client.privateKey,
          ipArea: ipAddress,
          listenerPort: this.client.listenerPort,
          mtu: this.client.mtu,
          dns: dns
        },
        peers: dbPeers,
      }
    } as WGDBConf;
  }

  private async checkForPeer(config: PeerEditConfig): Promise<WGConfPeer> {
    if (!Tools.is44Key(config.publicKey)) {
      throw new WGAppException("Peer 公钥格式异常")
    }
    if (!config.address) {
      throw new WGAppException("Peer 目标地址为空")
    }
    // 远程端点
    const ipPort = Tools.getIpPort(config.address!)
    const ip = ipPort.ipOrDomain;
    if (await WireGuard.Tools.isIpAddress(ip) || await WireGuard.Tools.isValidDomain(ip)) {
      // 是ip或者域名
    } else {
      throw new WGAppException(`地址格式异常，必须是合法的IP+端口或者域名+端口，value=${config.address}`)
    }
    if (ipPort.port < 0 || ipPort.port > 65535) {
      throw new WGAppException("端口取值范围为：0-65535")
    }

    if (config.allowedIps.length == 0) {
      throw new WGAppException("至少得有一个路由ip段")
    }

    // 路由
    const allowedIps = config.allowedIps!.map((it) => {
      let ip: IPAddressArea;
      if (Tools.isIpv4Mark(it)) {
        const ic = Tools.getIpCidr(it)
        if (ic.cidr < -1 || ic.cidr > 32) {
          throw new WGAppException(`${it} ipv4 掩码取值范围为0-32`)
        }
        ip = { address: { ip: ic.ip, isIpv4: true }, cidr: ic.cidr }
      } else if (Tools.isIpv4OrMark(it)) {
        throw new WGAppException(`${it} 需要配置掩码`)
      } else if (Tools.isIpv6Mark(it)) {
        const ic = Tools.getIpCidr(it)
        if (ic.cidr < -1 || ic.cidr > 128) {
          throw new WGAppException(`${it} ipv6 掩码取值范围为0-128`)
        }
        ip = { address: { ip: ic.ip, isIpv4: false }, cidr: ic.cidr }
      } else if (Tools.isIpv6OrMark(it)) {
        throw new WGAppException(`${it} 需要配置掩码`)
      } else {
        throw new WGAppException(`(${it})不合法。必须是带有掩码的IP地址段`)
      }
      return ip;
    })

    return {
      publicKey: config.publicKey!,
      endpoint: {
        ipStrOrDomain: ipPort.ipOrDomain,
        port: ipPort.port
      },
      allowedIPs: allowedIps,
      preSharedKey: config.preSharedKey,
      keepaliveInterval: config.keepaliveInterval,
    } as WGConfPeer;
  }
}

class InputRegex {
  num = `^\\d*$` // 纯数字
  port = `^\\d{0,5}$` // 端口，最多5位数
  mtu = `^\\d{0,6}$`; // mtu 最多六位数
  ip = `^\\d{0,3}([.]\\d{0,3}){0,3}$` // 纯IP
  ipMark = `^\\d{0,3}([.]\\d{0,3}){0,3}(/\\d{0,3})?$` // 包含掩码的Ip
  ipPort = `^\\d{0,3}([.]\\d{0,3}){0,3}(:\\d{0,5})?$` // 报端端口的Ip
  ipArea = `^\\d{0,3}([.]\\d{0,3}){0,3}(/\\d{0,3})?(,\\d{0,3}([.]\\d{0,3}){0,3}(/\\d{0,3})?)?$` // 包含掩码的Ip使用，分割
  dns = `^\\d{0,3}([.]\\d{0,3}){0,3}(,\\d{0,3}([.]\\d{0,3}){0,3})*$` // 纯ip 组 使用，分割
}
