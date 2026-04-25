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
import { ConnectState, WGConfPeer, WGDBConf, WGDeviceConfig } from 'wg_tunnel';
import { WireGuard } from 'wg_tunnel/src/main/ets/model/WGHelper';
import { LLog } from 'wg_tunnel/src/main/ets/tools/LLog';
import WGConfigPreViewParams from '../entity/WGConfigPreViewParams';
import WGConfigPreViewModel from '../view_model/WGConfigPreViewModel';

const TAG = "配置预览"

@Builder
function WGConfigPreViewBuilder() {
  WGConfigPreViewNavDest();
}

@Preview
@ComponentV2
export struct WGConfigPreViewNavDest {
  @Local vm: WGConfigPreViewModel = new WGConfigPreViewModel();

  aboutToAppear(): void {

  }

  build() {
    NavDestination() {
      WGConfigPreView({ vm: this.vm })
    }
    // .hideTitleBar(true)
    .title("WireGuard")
    .onReady((data) => {
      if (data.pathStack instanceof NavPathStack) {
        this.vm.nav = data.pathStack
      }

      if (data.pathInfo.param) {
        const params = data.pathInfo.param as WGConfigPreViewParams;
        this.vm.params = params;
        this.vm.loadData(params);
      } else {
        LLog.warn(TAG, "未得到参数！")
        this.vm.nav.pop({});
        return;
      }
    })
  }
}

@ComponentV2
export default struct WGConfigPreView {
  @Param @Require vm: WGConfigPreViewModel;

  build() {
    List({ space: '32vp' }) {
      ListItem() {
        InterfaceCardView({ vm: this.vm, data: this.vm.client })
      }

      Repeat(this.vm.peers)
        .each((it) => {
          ListItem() {
            PeerCardView({ vm: this.vm, data: it.item, index: it.index })
          }
        })
    }
    .height('100%')
    .width('100%')
  }
}

@Styles
function cardBackgroundStyle() {
  .backgroundColor($r('app.color.wg_new_card_background_color'))
  .borderRadius('16vp')
  .padding('16vp')
  .margin({ left: '16vp', right: '16vp' })
  .align(Alignment.Start)
}


/**
 * 本地接口编辑卡片
 */
@ComponentV2
struct InterfaceCardView {
  @Param @Require vm: WGConfigPreViewModel
  @Param @Require data: WGDBConf
  @Local state: ConnectState = WireGuard.getRunningServer();
  @Local publicKey: string = ""

  async aboutToAppear(): Promise<void> {
    this.publicKey = await WireGuard.genPublicKey(this.data.conf.inter.privateKey)
  }

  build() {
    Stack() {
      Column({ space: '8vp' }) {
        Text("本地（Interface）")
          .width('100%')
          .layoutGravity(LocalizedAlignment.START)
          .align(Alignment.Start)
        Column() {
          Text('名称').width('100%')
          Text(this.data.name).width('100%')
        }

        Column() {
          Text('公钥').width('100%')
          Text(this.publicKey)
            .width('100%')
            .maxLines(1)
            .ellipsisMode(EllipsisMode.END)
            .wordBreak(WordBreak.BREAK_ALL)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .onClick(() => {
          if (this.publicKey.length > 0) {
            this.vm.copy44KeyToSystem(this.getUIContext(), this.publicKey)
          }
        })

        Column() {
          Text('局域网IP地址').width('100%')
          Text(`${this.data.conf.inter?.ipArea.address}/${this.data.conf.inter.ipArea?.cidr ??
            (this.data.conf.inter.ipArea?.address.isIpv4 ? 32 : 128)}`).width('100%')
        }

        Column() {
          Text('DNS服务器').width('100%')
          Text(`${this.data.conf.inter.dns?.map((it) => it.ip).join(", ") ?? "(未定义)"}`).width('100%')
        }
      }
      .cardBackgroundStyle()

      Toggle({
        type: ToggleType.Switch,
        isOn: this.vm.isVpnOpen!!
        // isOn: (this.vm.params != undefined && this.state.runningConfigId == this.vm.params?.id)
      })
        .layoutGravity(LocalizedAlignment.TOP_END)
        .margin({
          top: '24vp',
          right: '40vp',
        })
        .onChange((isOn) => {
          this.vm.changeVpnConfig(this.getUIContext(), isOn)
        })

    }
  }
}

/**
 * Peer 编辑卡片
 */
@ComponentV2
struct PeerCardView {
  @Param @Require vm: WGConfigPreViewModel
  @Param @Require data: WGConfPeer
  @Param @Require index: number
  private TAG = "";

  build() {
    Column({ space: "8vp" }) {
      Text(`${this.index + 1}、远程（Peer）`).width('100%')
      Column() {
        Text('公钥').width('100%')
        Text(`${this.data.publicKey}`)
          .width('100%')
          .maxLines(1)
          .layoutGravity(LocalizedAlignment.START)
          .align(Alignment.Start)
          .ellipsisMode(EllipsisMode.END)
          .wordBreak(WordBreak.BREAK_ALL)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .onClick(() => {
        this.vm.copy44KeyToSystem(this.getUIContext(), this.data.publicKey)
      })

      Column() {
        Text('路由的IP地址（段）').width('100%')
        Text(`${this.data.allowedIPs.map((it) => `${it.address.ip}/${it.cidr ?? 32}`).join(", ")}`).width('100%')
      }

      Column() {
        Text(`对端`).width('100%')
        Text(`${this.data.endpoint.ipStrOrDomain}:${this.data.endpoint.port}`).width('100%')
      }

      Column() {
        Text(`连接保活时间`).width('100%')
        Text(`每隔 ${this.data.keepaliveInterval ?? 25} 秒`).width('100%')
      }

      // Text(`流量`) // 动态数据

    }
    .cardBackgroundStyle()
  }
}