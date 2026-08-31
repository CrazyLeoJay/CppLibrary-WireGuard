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

import { UIExtensionContentSession } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { WireGuard } from 'wg_tunnel/src/main/ets/model/WGHelper';
import { LLog } from 'wg_tunnel/src/main/ets/tools/LLog';
import { AppIconCache } from 'wg_tunnel/src/main/ets/model/AppIconCache';
import { WGSettingsPrefs } from 'wg_tunnel/src/main/ets/model/WGSettingsPrefs';
import { AppFilterMode, WGDBConf } from 'wg_tunnel';
import { BusinessError } from '@kit.BasicServicesKit';
import { ShareDebugRecordInfo } from '../ability/WGShareExtAbility';

const TAG = 'ShareConfigView';
/** 编译时决定，release 构建时此常量为 false，开发者选项不显示 */
const IS_DEBUG = true;

@Entry({ routeName: 'ShareConfigView', useSharedStorage: true })
@Component
struct ShareConfigViewPage {
  @State bundleName: string = '';
  @State appName: string = '';
  @State configs: WGDBConf[] = [];
  @State selectedIndex: number = -1;
  @State isLoading: boolean = true;
  @State isAdding: boolean = false;
  @State messageText: string = '';
  @State showMessage: boolean = false;
  @State developerMode: boolean = false;
  @State debugShareInfos: ShareDebugRecordInfo[] = [];
  private storage: LocalStorage | undefined = undefined;
  private session: UIExtensionContentSession | undefined = undefined;

  aboutToAppear(): void {
    LLog.info(TAG, 'ShareConfigView aboutToAppear');

    // 读取开发者模式设置
    this.developerMode = WGSettingsPrefs.getDeveloperMode();

    this.storage = this.getUIContext().getSharedLocalStorage();
    if (this.storage) {
      this.session = this.storage.get<UIExtensionContentSession>('session');
      this.waitForAsyncData();
    }

    this.loadConfigs();
  }

  private loadConfigs(): void {
    try {
      this.configs = WireGuard.helper.config.allDBConfig();
      LLog.info(TAG, `Loaded ${this.configs.length} configs`);
      if (this.configs.length === 1) {
        this.selectedIndex = 0;
      }
    } catch (e) {
      LLog.error(TAG, { error: e, message: 'Failed to load configs' });
      this.configs = [];
    }
    this.isLoading = false;
  }

  /**
   * 异步等待 Ability 端从分享内容解析的 bundleName、appName 和 debug 数据
   */
  private waitForAsyncData(): void {
    let attempts = 0;
    const maxAttempts = 30; // 30 × 100ms = 3s
    let bundleNameReady = false;
    let debugReady = !this.developerMode; // 非开发者模式不等 debug 数据

    const timer = setInterval(() => {
      attempts++;
      if (!this.storage) {
        clearInterval(timer);
        return;
      }

      if (!bundleNameReady) {
        const name = this.storage.get<string>('bundleName');
        if (name !== undefined && name !== null) {
          bundleNameReady = true;
          if (name.length > 0) {
            this.bundleName = name;
            LLog.info(TAG, `Async: resolved bundleName: ${name}`);
          }
          // bundleName 就绪后立即尝试读取 appName
          const app = this.storage.get<string>('appName');
          if (app && app.length > 0) {
            this.appName = app;
          }
        }
      } else {
        // bundleName 已就绪，继续等 appName
        const app = this.storage.get<string>('appName');
        if (app && app.length > 0 && this.appName.length === 0) {
          this.appName = app;
        }
      }

      if (!debugReady) {
        const jsonStr = this.storage.get<string>('shareDebugInfos');
        if (jsonStr !== undefined && jsonStr !== null) {
          debugReady = true;
          if (jsonStr.length > 0) {
            try {
              this.debugShareInfos = JSON.parse(jsonStr) as ShareDebugRecordInfo[];
              LLog.info(TAG, `Debug: loaded ${this.debugShareInfos.length} share record(s)`);
            } catch (e) {
              LLog.warn(TAG, { error: e, message: 'Debug: failed to parse shareDebugInfos' });
            }
          }
        }
      }

      if ((bundleNameReady && debugReady) || attempts >= maxAttempts) {
        clearInterval(timer);
      }
    }, 100);
  }

  private getFilterMode(config: WGDBConf): AppFilterMode {
    const included = config.conf.inter.includedApplications;
    const excluded = config.conf.inter.excludedApplications;
    if (included && included.length > 0) {
      return AppFilterMode.INCLUDED;
    }
    if (excluded && excluded.length > 0) {
      return AppFilterMode.EXCLUDED;
    }
    return AppFilterMode.NONE;
  }

  private isDuplicate(config: WGDBConf, name: string): boolean {
    const included = config.conf.inter.includedApplications;
    const excluded = config.conf.inter.excludedApplications;
    if (included && included.includes(name)) {
      return true;
    }
    if (excluded && excluded.includes(name)) {
      return true;
    }
    return false;
  }

  private confirmAdd(): void {
    if (this.selectedIndex < 0 || this.selectedIndex >= this.configs.length) {
      this.showPromptMessage('请先选择一个配置');
      return;
    }
    if (!this.bundleName || this.bundleName.length === 0) {
      this.showPromptMessage('无法从分享内容中解析应用包名');
      return;
    }

    const config = this.configs[this.selectedIndex];
    const bundleName = this.bundleName;

    if (this.isDuplicate(config, bundleName)) {
      this.showPromptMessage(`包名 "${bundleName}" 已存在于配置 "${config.name}" 的过滤列表中`);
      return;
    }

    this.isAdding = true;
    try {
      const mode = this.getFilterMode(config);
      if (mode === AppFilterMode.NONE) {
        // NONE → 使用默认过滤模式
        const defaultMode = WGSettingsPrefs.getDefaultFilterMode();
        if (defaultMode === AppFilterMode.INCLUDED) {
          config.conf.inter.includedApplications = [bundleName];
          LLog.info(TAG, `Auto-enabled whitelist mode for config "${config.name}", added "${bundleName}"`);
        } else {
          config.conf.inter.excludedApplications = [bundleName];
          LLog.info(TAG, `Auto-enabled blacklist mode for config "${config.name}", added "${bundleName}"`);
        }
      } else if (mode === AppFilterMode.EXCLUDED) {
        const excluded = config.conf.inter.excludedApplications ?? [];
        excluded.push(bundleName);
        config.conf.inter.excludedApplications = excluded;
      } else if (mode === AppFilterMode.INCLUDED) {
        const included = config.conf.inter.includedApplications ?? [];
        included.push(bundleName);
        config.conf.inter.includedApplications = included;
      }

      const allConfigs = WireGuard.helper.config.allConfig();
      if (allConfigs.length > this.selectedIndex) {
        const tableId = allConfigs[this.selectedIndex].id;
        if (tableId !== undefined) {
          WireGuard.helper.config.updateConfig(tableId, config);
          LLog.info(TAG, `Config "${config.name}" updated in database`);
        }
      }

      const displayName = this.appName.length > 0 ? `${this.appName} (${bundleName})` : bundleName;
      this.showPromptMessage(`已将 "${displayName}" 添加到配置 "${config.name}"`);

      AppIconCache.getAppIcon(bundleName).catch((e: BusinessError) => {
        LLog.warn(TAG, { error: e, message: `Failed to cache icon for ${bundleName}` });
      });

      setTimeout(() => {
        this.closeSession();
      }, 1500);
    } catch (e) {
      LLog.error(TAG, { error: e, message: 'Failed to add bundleName to config' });
      this.showPromptMessage('添加失败，请重试');
    } finally {
      this.isAdding = false;
    }
  }

  private closeSession(): void {
    if (this.session) {
      try {
        const resultCode = systemShare.ShareAbilityResultCode.CLOSE;
        this.session.terminateSelfWithResult({ resultCode: resultCode });
      } catch (e) {
        LLog.error(TAG, { error: e, message: 'Failed to terminate session' });
        try {
          this.session.terminateSelf();
        } catch (e2) {
          LLog.error(TAG, { error: e2, message: 'Failed to terminateSelf fallback' });
        }
      }
    }
  }

  private showPromptMessage(msg: string): void {
    this.messageText = msg;
    this.showMessage = true;
    setTimeout(() => {
      this.showMessage = false;
    }, 3000);
  }

  private cancel(): void {
    this.closeSession();
  }

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
      if (IS_DEBUG && this.developerMode && this.debugShareInfos.length > 0) {
        Column({ space: '8vp' }) {
          Text('DEBUG 分享数据')
            .fontSize('12fp')
            .fontColor('#FF6600')
            .fontWeight(FontWeight.Bold)
            .width('100%')

          ForEach(this.debugShareInfos, (record: ShareDebugRecordInfo, index: number) => {
            Column({ space: '4vp' }) {
              Row({ space: '6vp' }) {
                Text(`#${index + 1}`)
                  .fontSize('10fp')
                  .fontColor('#999999')
                Text(record.utd)
                  .fontSize('10fp')
                  .fontColor(Color.White)
                  .backgroundColor('#FF6600')
                  .borderRadius('4vp')
                  .padding({ left: '6vp', right: '6vp', top: '2vp', bottom: '2vp' })
                if (record.label && record.label.length > 0) {
                  Text(record.label)
                    .fontSize('10fp')
                    .fontColor('#FF6600')
                    .border({ width: 1, color: '#FF6600', radius: 4 })
                    .padding({ left: '4vp', right: '4vp', top: '1vp', bottom: '1vp' })
                }
              }

              if (record.content && record.content.length > 0) {
                Text(record.content)
                  .fontSize('10fp')
                  .fontColor('#333333')
                  .width('100%')
                  .maxLines(5)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .padding('4vp')
                  .backgroundColor('#F5F5F5')
                  .borderRadius('4vp')
                  .copyOption(CopyOptions.LocalDevice)
              }

              if (record.uri && record.uri.length > 0) {
                Text(`uri: ${record.uri}`)
                  .fontSize('9fp')
                  .fontColor('#666666')
                  .width('100%')
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }

              if (record.title && record.title.length > 0) {
                Text(`title: ${record.title}`)
                  .fontSize('9fp')
                  .fontColor('#666666')
                  .width('100%')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .width('100%')
            .padding('6vp')
            .border({ width: 1, color: '#FFD4A8', radius: 8, style: BorderStyle.Dashed })
          }, (record: ShareDebugRecordInfo, index: number) => `${index}_${record.utd}`)
        }
        .width('100%')
        .padding('16vp')
        .backgroundColor($r('app.color.wg_new_card_background_color'))
        .borderRadius('16vp')
        .margin({ left: '16vp', right: '16vp' })
      }

      // 顶部数据框：应用名称 + 包名
      if (this.bundleName && this.bundleName.length > 0) {
        Row({ space: '12vp' }) {
          // 应用图标
          Image(AppIconCache.getAppIconSync(this.bundleName))
            .width('40vp')
            .height('40vp')
            .borderRadius('8vp')
            .objectFit(ImageFit.Cover)
            .alt($r('app.media.wg_icon'))

          Column({ space: '4vp' }) {
            Text(this.appName.length > 0 ? this.appName : this.bundleName)
              .fontSize('16fp')
              .fontWeight(FontWeight.Medium)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.appName.length > 0) {
              Text(this.bundleName)
                .fontSize('12fp')
            .fontColor('#99000000')
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
      } else {
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
            .fontColor('#99000000')
            .width('100%')
            .textAlign(TextAlign.Center)
          Button('关闭')
            .type(ButtonType.Normal)
            .backgroundColor('#FFE84026')
            .fontColor(Color.White)
            .borderRadius('20vp')
            .width('120vp')
            .height('40vp')
            .onClick(() => {
              this.cancel();
            })
        }
        .width('100%')
        .padding('16vp')
        .alignItems(HorizontalAlign.Center)
      }

      // 配置列表
      if (this.bundleName && this.bundleName.length > 0) {
        if (this.isLoading) {
          LoadingProgress()
            .width('40vp')
            .height('40vp')
            .color($r('app.color.wg_new_card_item_select_color'))
        } else if (this.configs.length === 0) {
          Column({ space: '12vp' }) {
            Text('无可用配置')
              .fontSize('16fp')
              .fontColor('#99000000')
              .width('100%')
              .textAlign(TextAlign.Center)
            Text('请先在 WireGuard 中创建至少一个配置')
              .fontSize('14fp')
              .fontColor('#99000000')
              .width('100%')
              .textAlign(TextAlign.Center)
            Button('关闭')
              .type(ButtonType.Normal)
              .backgroundColor('#FFE84026')
              .fontColor(Color.White)
              .borderRadius('20vp')
              .width('120vp')
              .height('40vp')
              .onClick(() => {
                this.cancel();
              })
          }
          .width('100%')
          .padding('16vp')
          .alignItems(HorizontalAlign.Center)
        } else {
          Column({ space: '8vp' }) {
            Text(this.configs.length === 1 ? '将添加到以下配置' : '请选择要添加到的配置')
              .fontSize('14fp')
              .fontColor('#99000000')
              .width('100%')
              .padding({ left: '16vp', right: '16vp' })

            List({ space: '8vp' }) {
              ForEach(this.configs, (config: WGDBConf, index: number) => {
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
                .backgroundColor('#0D000000')
                .fontColor('#E6000000')
                .borderRadius('20vp')
                .height('40vp')
                .layoutWeight(1)
                .onClick(() => {
                  this.cancel();
                })
              Button('确认添加')
                .type(ButtonType.Normal)
                .backgroundColor($r('app.color.wg_new_card_item_select_color'))
                .fontColor(Color.White)
                .borderRadius('20vp')
                .height('40vp')
                .layoutWeight(1)
                .enabled(!this.isAdding && this.selectedIndex >= 0)
                .onClick(() => {
                  this.confirmAdd();
                })
            }
            .width('100%')
            .padding({ left: '16vp', right: '16vp', bottom: '16vp' })
          }
          .width('100%')
          .layoutWeight(1)
        }
      }

      if (this.showMessage) {
        Text(this.messageText)
          .fontSize('14fp')
          .fontColor(Color.White)
          .backgroundColor($r('app.color.wg_new_card_item_select_color'))
          .borderRadius('20vp')
          .padding({ left: '16vp', right: '16vp', top: '8vp', bottom: '8vp' })
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

  @Builder
  buildConfigItem(config: WGDBConf, index: number) {
    Row({ space: '12vp' }) {
      if (this.selectedIndex === index) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize('24fp')
          .fontColor([$r('app.color.wg_new_card_item_select_color')])
      } else {
        SymbolGlyph($r('sys.symbol.circle'))
          .fontSize('24fp')
          .fontColor([Color.Gray])
      }

      Column({ space: '4vp' }) {
        Text(config.name)
          .fontSize('16fp')
          .fontWeight(FontWeight.Medium)
        if (this.getFilterMode(config) !== AppFilterMode.NONE) {
          Text(this.getFilterMode(config) === AppFilterMode.EXCLUDED ? '黑名单模式' : '白名单模式')
            .fontSize('12fp')
            .fontColor(Color.Gray)
        } else {
          Text(`未启用过滤（将自动开启${WGSettingsPrefs.getDefaultFilterMode() === AppFilterMode.INCLUDED ? '白名单' : '黑名单'}模式）`)
            .fontSize('12fp')
            .fontColor(Color.Orange)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding('12vp')
    .backgroundColor(this.selectedIndex === index
      ? $r('app.color.wg_new_card_background_color')
      : Color.Transparent)
    .borderRadius('8vp')
    .border({
      width: this.selectedIndex === index ? 2 : 1,
      color: this.selectedIndex === index
        ? $r('app.color.wg_new_card_item_select_color')
        : Color.Gray,
      radius: 8,
      style: BorderStyle.Solid,
    })
    .onClick(() => {
      this.selectedIndex = index;
    })
  }
}
