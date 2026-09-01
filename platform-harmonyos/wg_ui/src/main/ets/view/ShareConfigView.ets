/*
 * Copyright [2026] @github-crazyleojay (crazyleojay@163.com/gmail.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AppFilterMode, WGDBConf, WGConf, WGConfInterface, IPAddress, IPAddressArea } from 'wg_tunnel';
import { ShareDebugRecordInfo } from '../ability/WGShareExtAbility';
import ShareConfigViewModel from '../view_model/ShareConfigViewModel';

const TAG = 'ShareConfigView';
/** 编译时决定，release 构建时此常量为 false，开发者选项不显示 */
const IS_DEBUG = true;

// ===== 可复用的分享配置内容组件 =====

@ComponentV2
struct ShareConfigContent {
  @Param vm: ShareConfigViewModel = new ShareConfigViewModel();

  build() {
    Column({ space: '16vp' }) {
      // 标题
      Text('分享到 WireGuard')
        .fontSize('20fp')
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: '8vp', bottom: '8vp' })

      // 开发者模式：显示分享数据原文和文件类型标签
      if (IS_DEBUG && this.vm.developerMode && this.vm.debugShareInfos.length > 0) {
        this.buildDebugSection();
      }

      // 顶部数据框：应用名称 + 包名
      if (this.vm.bundleName && this.vm.bundleName.length > 0) {
        this.buildAppInfoCard();
      } else {
        this.buildEmptyBundleCard();
      }

      // 配置列表
      if (this.vm.bundleName && this.vm.bundleName.length > 0) {
        this.buildConfigListSection();
      }

      // 提示消息
      if (this.vm.showMessage) {
        Text(this.vm.messageText)
          .fontSize('14fp')
          .fontColor($r('app.color.share_primary_text'))
          .backgroundColor($r('app.color.wg_new_card_item_select_color'))
          .borderRadius('20vp')
          .padding({
            left: '16vp',
            right: '16vp',
            top: '8vp',
            bottom: '8vp'
          })
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ left: '16vp', right: '16vp' })
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: '16vp' })
  }

  // ===== DEBUG 分享数据区 =====

  @Builder
  buildDebugSection() {
    Column({ space: '8vp' }) {
      Text('DEBUG 分享数据')
        .fontSize('12fp')
        .fontColor($r('app.color.share_debug_accent'))
        .fontWeight(FontWeight.Bold)
        .width('100%')

      ForEach(this.vm.debugShareInfos, (record: ShareDebugRecordInfo, index: number) => {
        Column({ space: '4vp' }) {
          Row({ space: '6vp' }) {
            Text(`#${index + 1}`)
              .fontSize('10fp')
              .fontColor($r('app.color.share_placeholder_text'))
            Text(record.utd)
              .fontSize('10fp')
              .fontColor($r('app.color.share_primary_text'))
              .backgroundColor($r('app.color.share_debug_accent'))
              .borderRadius('4vp')
              .padding({
                left: '6vp',
                right: '6vp',
                top: '2vp',
                bottom: '2vp'
              })
            if (record.label && record.label.length > 0) {
              Text(record.label)
                .fontSize('10fp')
                .fontColor($r('app.color.share_debug_accent'))
                .border({ width: 1, color: $r('app.color.share_debug_accent'), radius: 4 })
                .padding({
                  left: '4vp',
                  right: '4vp',
                  top: '1vp',
                  bottom: '1vp'
                })
            }
          }

          if (record.content && record.content.length > 0) {
            Text(record.content)
              .fontSize('10fp')
              .fontColor($r('app.color.share_debug_content_text'))
              .width('100%')
              .maxLines(5)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding('4vp')
              .backgroundColor($r('app.color.share_debug_content_bg'))
              .borderRadius('4vp')
              .copyOption(CopyOptions.LocalDevice)
          }

          if (record.uri && record.uri.length > 0) {
            Text(`uri: ${record.uri}`)
              .fontSize('9fp')
              .fontColor($r('app.color.share_tertiary_text'))
              .width('100%')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }

          if (record.title && record.title.length > 0) {
            Text(`title: ${record.title}`)
              .fontSize('9fp')
              .fontColor($r('app.color.share_tertiary_text'))
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .padding('6vp')
        .border({
          width: 1,
          color: $r('app.color.share_debug_border'),
          radius: 8,
          style: BorderStyle.Dashed
        })
      }, (record: ShareDebugRecordInfo, index: number) => `${index}_${record.utd}`)
    }
    .width('100%')
    .padding('16vp')
    .backgroundColor($r('app.color.wg_new_card_background_color'))
    .borderRadius('16vp')
    .margin({ left: '16vp', right: '16vp' })
  }

  // ===== 应用信息卡片（名称 + 包名） =====

  @Builder
  buildAppInfoCard() {
    Row() {
      Row({ space: '12vp' }) {
        // 上面应用名称，下面包名
        Column({ space: '4vp' }) {
          Text(this.vm.appName.length > 0 ? this.vm.appName : this.vm.bundleName)
            .fontSize('16fp')
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.vm.appName.length > 0) {
            Text(this.vm.bundleName)
              .fontSize('12fp')
              .fontColor($r('app.color.share_secondary_text'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding('16vp')
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.wg_new_card_background_color'))
      .borderRadius('16vp')
      .margin({ left: '16vp', right: '16vp' })
      .layoutWeight(1)
    }
    .width('100%')
  }

  // ===== 无法解析包名提示 =====

  @Builder
  buildEmptyBundleCard() {
    Column({ space: '12vp' }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize('32fp')
        .fontColor([Color.Orange])
      Text('无法解析应用包名')
        .fontSize('16fp')
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .textAlign(TextAlign.Center)
      Text('未能从分享内容中提取应用包名，请确认分享来源包含应用市场链接或包名信息。')
        .fontSize('14fp')
        .fontColor($r('app.color.share_secondary_text'))
        .width('100%')
        .textAlign(TextAlign.Center)
      Button('关闭')
        .type(ButtonType.Normal)
        .backgroundColor($r('app.color.share_btn_warning_bg'))
        .fontColor($r('app.color.share_primary_text'))
        .borderRadius('20vp')
        .width('120vp')
        .height('40vp')
        .onClick(() => {
          this.vm.cancel();
        })
    }
    .width('100%')
    .padding('16vp')
    .alignItems(HorizontalAlign.Center)
  }

  // ===== 配置列表区域 =====

  @Builder
  buildConfigListSection() {
    if (this.vm.isLoading) {
      LoadingProgress()
        .width('40vp')
        .height('40vp')
        .color($r('app.color.wg_new_card_item_select_color'))
    } else if (this.vm.configs.length === 0) {
      Column({ space: '12vp' }) {
        Text('无可用配置')
          .fontSize('16fp')
          .fontColor($r('app.color.share_secondary_text'))
          .width('100%')
          .textAlign(TextAlign.Center)
        Text('请先在 WireGuard 中创建至少一个配置')
          .fontSize('14fp')
          .fontColor($r('app.color.share_secondary_text'))
          .width('100%')
          .textAlign(TextAlign.Center)
        Button('关闭')
          .type(ButtonType.Normal)
          .backgroundColor($r('app.color.share_btn_warning_bg'))
          .fontColor($r('app.color.share_primary_text'))
          .borderRadius('20vp')
          .width('120vp')
          .height('40vp')
          .onClick(() => {
            this.vm.cancel();
          })
      }
      .width('100%')
      .padding('16vp')
      .alignItems(HorizontalAlign.Center)
    } else {
      Column({ space: '8vp' }) {
        Text(this.vm.configs.length === 1 ? '将添加到以下配置' : '请选择要添加到的配置')
          .fontSize('14fp')
          .fontColor($r('app.color.share_secondary_text'))
          .width('100%')
          .padding({ left: '16vp', right: '16vp' })

        List({ space: '8vp' }) {
          ForEach(this.vm.configs, (config: WGDBConf, index: number) => {
            ListItem() {
              this.buildConfigItem(config, index)
            }
          }, (config: WGDBConf, index: number) => `${index}_${config.name}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: '16vp', right: '16vp' })

        // 底部按钮区
        Row({ space: '12vp' }) {
          Button('取消')
            .type(ButtonType.Normal)
            .backgroundColor($r('app.color.share_btn_cancel_bg'))
            .fontColor($r('app.color.share_btn_cancel_text'))
            .borderRadius('20vp')
            .height('40vp')
            .layoutWeight(1)
            .onClick(() => {
              this.vm.cancel();
            })
          Button('确认添加')
            .type(ButtonType.Normal)
            .backgroundColor($r('app.color.wg_new_card_item_select_color'))
            .fontColor($r('app.color.share_primary_text'))
            .borderRadius('20vp')
            .height('40vp')
            .layoutWeight(1)
            .enabled(!this.vm.isAdding && this.vm.selectedIndex >= 0)
            .onClick(() => {
              this.vm.confirmAdd();
            })
        }
        .width('100%')
        .padding({ left: '16vp', right: '16vp', bottom: '16vp' })
      }
      .width('100%')
      .layoutWeight(1)
    }
  }

  // ===== 配置项 =====

  @Builder
  buildConfigItem(config: WGDBConf, index: number) {
    Row({ space: '12vp' }) {
      if (this.vm.selectedIndex === index) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize('24fp')
          .fontColor([$r('app.color.wg_new_card_item_select_color')])
      } else {
        SymbolGlyph($r('sys.symbol.circle'))
          .fontSize('24fp')
          .fontColor([$r('app.color.share_unselected_border')])
      }

      Column({ space: '4vp' }) {
        Text(config.name)
          .fontSize('16fp')
          .fontWeight(FontWeight.Medium)
        if (this.vm.getFilterMode(config) !== AppFilterMode.NONE) {
          Text(this.vm.getFilterMode(config) === AppFilterMode.EXCLUDED ? '黑名单模式' : '白名单模式')
            .fontSize('12fp')
            .fontColor($r('app.color.share_tertiary_text'))
        } else {
          Text(`未启用过滤（将自动开启${this.vm.getDefaultFilterModeText()}模式）`)
            .fontSize('12fp')
            .fontColor(Color.Orange)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding('12vp')
    .backgroundColor(this.vm.selectedIndex === index
      ? $r('app.color.wg_new_card_background_color')
      : Color.Transparent)
    .borderRadius('8vp')
    .border({
      width: this.vm.selectedIndex === index ? 2 : 1,
      color: this.vm.selectedIndex === index
        ? $r('app.color.wg_new_card_item_select_color')
        : $r('app.color.share_unselected_border'),
      radius: 8,
      style: BorderStyle.Solid,
    })
    .onClick(() => {
      this.vm.selectedIndex = index;
    })
  }
}

// ===== @Entry 页面入口 =====

@Entry({ routeName: 'ShareConfigView', useSharedStorage: true })
@ComponentV2
struct ShareConfigViewPage {
  @Local vm: ShareConfigViewModel = new ShareConfigViewModel();

  aboutToAppear(): void {
    this.vm.initAsync(this.getUIContext().getSharedLocalStorage());
  }

  build() {
    Column() {
      ShareConfigContent({ vm: this.vm })
    }
    .width('100%')
    .height('100%')
  }
}

// ===== Preview: 假数据 =====

/** 构造假数据用的辅助函数 */
function createMockWGConf(excluded?: string[], included?: string[]): WGConf {
  const inter: WGConfInterface = {
    deviceName: 'wg0',
    privateKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    ipArea: { address: { ip: '10.0.0.2', isIpv4: true }, cidr: 24 } as IPAddressArea,
    dns: [{ ip: '8.8.8.8', isIpv4: true } as IPAddress],
    excludedApplications: excluded,
    includedApplications: included,
  };
  return { inter: inter, peers: [] };
}

/** 3 个假配置：黑名单 / 无过滤 / 白名单 */
function createMockConfigs(): WGDBConf[] {
  return [
    { name: '公司VPN', conf: createMockWGConf(['com.tencent.mm', 'com.tencent.mobileqq']) } as WGDBConf,
    { name: '家庭网络', conf: createMockWGConf() } as WGDBConf,
    { name: '测试服务器', conf: createMockWGConf(undefined, ['com.alibaba.android.rimet']) } as WGDBConf,
  ];
}

// --- Preview 1: 应用市场链接分享（抓取图标） ---

@Preview
@ComponentV2
struct ShareConfigViewPreviewAppGallery {
  @Local vm: ShareConfigViewModel = new ShareConfigViewModel();

  aboutToAppear(): void {
    this.vm.initAsyncWithMock('com.netease.ohmail', '网易邮箱大师',
      'https://appgallery.huawei.com/app/detail?id=com.netease.ohmail&channelId=LAUNCHERSHARE',
      true, createMockConfigs(),
      [{
        utd: 'general.hyperlink',
        title: '网易邮箱大师',
        content: 'https://appgallery.huawei.com/app/detail?id=com.netease.ohmail&channelId=LAUNCHERSHARE',
        uri: 'store://appgallery.huawei.com/app/detail?id=com.netease.ohmail',
        description: '',
        label: '应用市场',
      } as ShareDebugRecordInfo]);
  }

  build() {
    ShareConfigContent({ vm: this.vm })
  }
}

// --- Preview 2: APK 分享（不抓取图标） ---

@Preview
@ComponentV2
struct ShareConfigViewPreviewApk {
  @Local vm: ShareConfigViewModel = new ShareConfigViewModel();

  aboutToAppear(): void {
    this.vm.initAsyncWithMock('com.wireguard.android', 'WireGuard', '', false, createMockConfigs(),
      [{
        utd: 'com.android.apk',
        title: 'WireGuard',
        content: 'file://docs/storage/ANCO_APP_DATA/com.wireguard.android/base.apk',
        uri: '',
        description: '',
        label: '16.94 MB - base.apk',
      } as ShareDebugRecordInfo]);
  }

  build() {
    ShareConfigContent({ vm: this.vm })
  }
}
