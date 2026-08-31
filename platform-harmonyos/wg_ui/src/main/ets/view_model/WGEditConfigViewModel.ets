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
import { AppIconCache } from 'wg_tunnel/src/main/ets/model/AppIconCache';
import { ClipboardParser } from 'wg_tunnel/src/main/ets/model/ClipboardParser';
import { pasteboard } from '@kit.BasicServicesKit';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import PeerEditConfig from 'wg_tunnel/src/main/ets/model/entity/PeerEditConfig';
import ClientEditConfig from 'wg_tunnel/src/main/ets/model/entity/ClientEditConfig';
import Tools from 'wg_tunnel/src/main/ets/tools/tools';
import WGAppException from 'wg_tunnel/src/main/ets/error/WGAppException';
import { IPAddress, IPAddressArea, SiteUrlType, WGConfPeer, WGDBConf, getDnsMode, AppFilterMode } from 'wg_tunnel';
import WGEditConfigParams from '../entity/WGEditConfigParams';

const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();

const TAG = "创建VPN"

/**
 * 剪贴板状态枚举
 */
export enum ClipboardStatus {
  HAS_VALUE,     // 剪贴板有内容且可解析出包名
  NO_VALUE,      // 剪贴板为空或内容无法解析出包名
  NO_PERMISSION  // 没有剪贴板读取权限
}

/**
 * 主页数据持有
 */
@ObservedV2
export default class WGNewConfigViewModel {
  nav: NavPathStack = new NavPathStack();
  @Trace client: ClientEditConfig = new ClientEditConfig(); // 客户端配置
  @Trace peers: PeerEditConfig[] = []; // 对等端配置列表
  @Trace clipboardStatus: ClipboardStatus = ClipboardStatus.NO_VALUE; // 剪贴板状态
  @Trace clipboardBundleName: string | undefined = undefined; // 剪贴板解析出的包名
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

    // 加载应用过滤配置
    const excludedApps = config.conf.inter.excludedApplications;
    const includedApps = config.conf.inter.includedApplications;
    if (includedApps && includedApps.length > 0) {
      this.client.filterMode = AppFilterMode.INCLUDED;
      this.client.filterApps = includedApps.slice();
    } else if (excludedApps && excludedApps.length > 0) {
      this.client.filterMode = AppFilterMode.EXCLUDED;
      this.client.filterApps = excludedApps.slice();
    } else {
      this.client.filterMode = AppFilterMode.NONE;
      this.client.filterApps = [];
    }

    this.peers = config.conf.peers.map((it) => {
      const config = new PeerEditConfig();
      config.publicKey = it.publicKey;
      config.preSharedKey = it.preSharedKey;
      config.setAddress(it.endpoint);
      config.dnsMode = getDnsMode(it.endpoint);
      config.allowedIpsInput = it.allowedIPs.map((it) => `${it.address.ip}/${it.cidr}`).join(",");
      config.keepaliveInterval = `${it.keepaliveInterval}`;
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

  /**
   * 监听 filterApps 变化，当有新包名添加时触发图标缓存
   */
  @Monitor("client.filterApps")
  onFilterAppsChange(): void {
    const apps = this.client.filterApps;
    for (const appName of apps) {
      if (appName && appName.length > 0) {
        // 异步触发图标获取，不阻塞主流程
        AppIconCache.getAppIcon(appName).catch((e: BusinessError) => {
          LLog.warn(TAG, { error: e, message: `Failed to fetch icon for ${appName}` });
        });
      }
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
   * 请求剪贴板读取权限
   * @returns true 如果权限已授予，false 如果权限被拒绝
   */
  private async requestClipboardPermission(context: Context): Promise<boolean> {
    const atManager = abilityAccessCtrl.createAtManager();
    try {
      const grantStatus = await atManager.checkAccessToken(
        context.applicationInfo.accessTokenId,
        'ohos.permission.READ_PASTEBOARD' as Permissions
      );
      if (grantStatus === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return true;
      }
    } catch (e) {
      LLog.warn(TAG, `checkAccessToken error: ${JSON.stringify(e)}`);
    }
    // 权限未授予，发起运行时请求
    try {
      const result = await atManager.requestPermissionsFromUser(context, ['ohos.permission.READ_PASTEBOARD'] as Permissions[]);
      if (result.authResults.length > 0 && result.authResults[0] === 0) {
        LLog.info(TAG, 'requestClipboardPermission: granted');
        return true;
      }
      LLog.warn(TAG, 'requestClipboardPermission: denied');
      return false;
    } catch (e) {
      LLog.warn(TAG, `requestPermissionsFromUser error: ${JSON.stringify(e)}`);
      return false;
    }
  }

  /**
   * 检查剪贴板状态，更新 clipboardStatus 和 clipboardBundleName
   */
  async checkClipboard(context?: Context): Promise<void> {
    LLog.info(TAG, 'checkClipboard: checking clipboard status');
    // 如果提供了 context，先请求权限
    if (context) {
      const hasPermission = await this.requestClipboardPermission(context);
      if (!hasPermission) {
        this.clipboardStatus = ClipboardStatus.NO_PERMISSION;
        this.clipboardBundleName = undefined;
        return;
      }
    }
    try {
      const hasData = await systemPasteboard.hasData();
      if (!hasData) {
        LLog.info(TAG, 'checkClipboard: no data in clipboard');
        this.clipboardStatus = ClipboardStatus.NO_VALUE;
        this.clipboardBundleName = undefined;
        return;
      }
      const pasteData = await systemPasteboard.getData();
      const text = pasteData.getPrimaryText();
      if (!text || text.length === 0) {
        LLog.info(TAG, 'checkClipboard: clipboard data has no text');
        this.clipboardStatus = ClipboardStatus.NO_VALUE;
        this.clipboardBundleName = undefined;
        return;
      }
      const bundleName = ClipboardParser.parseBundleName(text);
      if (bundleName !== undefined && bundleName.length > 0) {
        LLog.info(TAG, `checkClipboard: parsed bundleName=${bundleName}, status=HAS_VALUE`);
        this.clipboardStatus = ClipboardStatus.HAS_VALUE;
        this.clipboardBundleName = bundleName;
      } else {
        LLog.info(TAG, 'checkClipboard: text found but no bundleName parsed, status=NO_VALUE');
        this.clipboardStatus = ClipboardStatus.NO_VALUE;
        this.clipboardBundleName = undefined;
      }
    } catch (error) {
      LLog.warn(TAG, `checkClipboard error: ${JSON.stringify(error)}`);
      this.clipboardStatus = ClipboardStatus.NO_PERMISSION;
      this.clipboardBundleName = undefined;
    }
  }

  /**
   * 从剪贴板读取内容并解析包名，添加到过滤列表
   */
  async addFromClipboard(context?: Context): Promise<void> {
    LLog.info(TAG, 'addFromClipboard: reading clipboard and adding to filter');
    // 先请求权限
    if (context) {
      const hasPermission = await this.requestClipboardPermission(context);
      if (!hasPermission) {
        this.clipboardStatus = ClipboardStatus.NO_PERMISSION;
        this.clipboardBundleName = undefined;
        return;
      }
    }
    try {
      const hasData = await systemPasteboard.hasData();
      if (!hasData) {
        LLog.info(TAG, 'addFromClipboard: no data in clipboard');
        this.clipboardStatus = ClipboardStatus.NO_VALUE;
        this.clipboardBundleName = undefined;
        return;
      }
      const pasteData = await systemPasteboard.getData();
      const text = pasteData.getPrimaryText();
      if (!text || text.length === 0) {
        LLog.info(TAG, 'addFromClipboard: clipboard data has no text');
        this.clipboardStatus = ClipboardStatus.NO_VALUE;
        this.clipboardBundleName = undefined;
        return;
      }
      const bundleName = ClipboardParser.parseBundleName(text);
      if (bundleName !== undefined && bundleName.length > 0) {
        this.client.filterApps.push(bundleName);
        LLog.info(TAG, `addFromClipboard: added bundleName=${bundleName} to filterApps`);
        this.clipboardStatus = ClipboardStatus.HAS_VALUE;
        this.clipboardBundleName = bundleName;
      } else {
        LLog.info(TAG, 'addFromClipboard: text found but no bundleName parsed');
        this.clipboardStatus = ClipboardStatus.NO_VALUE;
        this.clipboardBundleName = undefined;
      }
    } catch (error) {
      LLog.warn(TAG, `addFromClipboard error: ${JSON.stringify(error)}`);
      this.clipboardStatus = ClipboardStatus.NO_PERMISSION;
      this.clipboardBundleName = undefined;
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
    ipAddress = await Tools.readIpArea(this.client.vpnAddress!)

    let dns: IPAddress[] = []
    if (this.client.dnsIps?.length ?? 0 > 0) {
      const dnsIps = this.client.dnsIps!;
      if (dnsIps.includes(",")) {
        dns = await Promise.all(dnsIps.split(",").map(async (it) => {
          return {
            ip: it.trim(),
            isIpv4: await WireGuard.Tools.isIpv4(it.trim())
          } as IPAddress
        })
        )
      } else {
        dns.push({
          ip: dnsIps.trim(),
          isIpv4: await WireGuard.Tools.isIpv4(dnsIps.trim())
        })
      }
    }

    if (this.peers.length == 0) {
      throw new WGAppException("至少包含一个 Peer")
    }
    const dbPeers = await Promise.all(this.peers.map((it) => this.checkForPeer(it)));

    // 根据 filterMode 构建过滤字段，确保互斥
    let excludedApplications: string[] | undefined = undefined;
    let includedApplications: string[] | undefined = undefined;
    if (this.client.filterMode === AppFilterMode.EXCLUDED) {
      const apps = this.client.filterApps
        .map((it) => it.trim())
        .filter((it) => it.length > 0);
      if (apps.length > 0) {
        excludedApplications = apps;
      }
    } else if (this.client.filterMode === AppFilterMode.INCLUDED) {
      const apps = this.client.filterApps
        .map((it) => it.trim())
        .filter((it) => it.length > 0);
      if (apps.length > 0) {
        includedApplications = apps;
      }
    }

    return {
      name: this.client.deviceName,
      conf: {
        inter: {
          privateKey: this.client.privateKey,
          ipArea: ipAddress,
          listenerPort: this.client.listenerPort,
          mtu: this.client.mtu,
          dns: dns,
          excludedApplications: excludedApplications,
          includedApplications: includedApplications,
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
    const endpoint = await Tools.readEndpointAddress(config.address!)
    if (endpoint.type === SiteUrlType.ERROR) {
      throw new WGAppException(`地址格式异常，必须是合法的IP+端口或者域名+端口，value=${config.address}`)
    }
    endpoint.dnsMode = config.dnsMode;
    endpoint.forceIpv6 = undefined;
    if (endpoint.port < 0 || endpoint.port > 65535) {
      throw new WGAppException("端口取值范围为：0-65535")
    }

    if (config.allowedIps.length == 0) {
      throw new WGAppException("至少得有一个路由ip段")
    }

    // 路由
    const allowedIps: IPAddressArea[] = []
    for (const it of config.allowedIps!) {
      allowedIps.push(await Tools.readIpArea(it));
    }

    return {
      publicKey: config.publicKey!,
      endpoint: endpoint,
      allowedIPs: allowedIps,
      preSharedKey: config.preSharedKey,
      keepaliveInterval: Number.parseInt(config.keepaliveInterval),
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
  dns = `^[\\w.:/,\\-\\[\\]]*$`
  noSpace = `^[\w.:/,\\-\[\]]*$` // 仅允许英文字符、域名、IP、IPv6、端口允许的字符（字母数字、.、:、/、,、-）
  domainArea = `^[0-9.:/,\\-]*$` // 域名段（包含掩码），使用英文逗号进行多条输入，仅检测输入字符是否合法
}
