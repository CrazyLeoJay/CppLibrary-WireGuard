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
import WgConfigTable from 'wg_tunnel/src/main/ets/model/db/table/WgConfigTable';
import { WireGuard } from 'wg_tunnel/src/main/ets/model/WGHelper';
import { LLog } from 'wg_tunnel/src/main/ets/tools/LLog';
import { UIContext } from '@ohos.arkui.UIContext';
import { generateBarcode, scanBarcode, scanCore } from '@kit.ScanKit';
import { image } from '@kit.ImageKit';
import { SortColumnName, WGConf, WGDBConf } from 'wg_tunnel';
import { vpnToggleService } from './VpnToggleService';
import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import WGAppException from 'wg_tunnel/src/main/ets/error/WGAppException';
import { AppErrorCode } from 'wg_tunnel/src/main/ets/error/AppErrorCode';
import { PersistenceV2, UIUtils } from '@kit.ArkUI';

const TAG = "主页"

/**
 * 主页数据持有
 */
@ObservedV2
export default class WGMainViewModel {
  nav: NavPathStack = new NavPathStack();
  @Trace wgList: MainItemData[] = [];
  @Trace qrCodePixelMap?: image.PixelMap;
  @Trace uiConfig: MainUiConfig

  constructor(nav?: NavPathStack) {
    this.uiConfig = PersistenceV2.globalConnect({
      // 定义持久化的数据类型
      type: MainUiConfig,
      // 定义默认构造器，返回时需要调用makeObserved，才能实现自动持久化
      defaultCreator: () => UIUtils.makeObserved(new MainUiConfig())
    })!;
    if (nav) {
      this.nav = nav;
    }
  }

  get isEmptyList(): boolean {
    return this.wgList.length == 0;
  }

  /**
   * 加载配置数据
   */
  async loadConfigs() {
    try {
      await this.loadMainDataForDB()
    } catch (e) {
      if ("数据库连接未建立" == (e as Error).message) {
        // 等待一段时间秒，一般是初始化好了
        setTimeout(async () => {
          try {
            // 不自调，防止死锁，最多重试一次
            await this.loadConfigs()
          } catch (err) {
            LLog.error(TAG, err)
          }
        }, 100)
        return
      }
      LLog.error(TAG, e)
    }
  }

  /**
   * 从数据库加载数据
   */
  private async loadMainDataForDB() {
    LLog.info(TAG, `去加载数据`)
    this.wgList = WireGuard.helper.config.allConfig({
      sortAsc: this.uiConfig.listSortAsc,
      sortColumn: this.uiConfig.sortColumn,
    }).map((it) => {
      return new MainItemData(this, it);
    })
    LLog.info(TAG, `加载 ${this.wgList.length} 条数据`)
  }

  async deleteConfig(index: number, item: MainItemData) {
    // 数据库删除
    WireGuard.helper.config.deleteConfig(item.id);
    // 移除数据
    this.wgList.splice(index, 1)
  }

  scanQRCodeAdd(context: UIContext): Promise<WGConf> {
    return scanBarcode.startScanForResult(context.getHostContext(), {
      scanTypes: [scanCore.ScanType.QR_CODE],
      enableMultiMode: true,
      enableAlbum: true
    })
      .then((data: scanBarcode.ScanResult) => {
        LLog.info(TAG, `扫描结果：${data.originalValue}`)
        return WireGuard.readWgConf(data.originalValue)
      })
  }

  makeQRCode(content: string, showListener: (clearCache: () => void) => void) {
    generateBarcode.createBarcode(content, {
      scanType: scanCore.ScanType.QR_CODE,
      height: 400,
      width: 400
    }).then((data: image.PixelMap) => {
      this.qrCodePixelMap = data;
      showListener(() => {
        // 结束后释放内存
        this.qrCodePixelMap = undefined;
      });
    })
      .catch((e: BusinessError) => {
        LLog.error(TAG, { error: e, message: "生成二维码异常" })
      })
  }

  /**
   * @throws 解析异常
   */
  async readWGConfForSystemFile(uiContext: UIContext): Promise<WGConf | WGConf[]> {
    const documentSelectOptions = new picker.DocumentSelectOptions();
    documentSelectOptions.maxSelectNumber = 1; // 最多选择n个文件
    // // 指定选择的文件或者目录的URI（可选）
    // documentSelectOptions.defaultFilePathUri = "file://docs/storage/Users/currentUser/test";
    // 选择文件的后缀类型过滤（可选），例如只显示.txt和.pdf
    // documentSelectOptions.fileSuffixChoices = ['文档|.conf'];
    documentSelectOptions.fileSuffixFilters = ['WireGuard配置|.conf', 'WireGuard导出的压缩包|.zip'];

    let context = uiContext.getHostContext() as common.UIAbilityContext;
    const documentViewPicker = new picker.DocumentViewPicker(context);
    const uris: Array<string> = await documentViewPicker.select(documentSelectOptions)
    if (uris.length != 1) {
      throw new WGAppException({
        type: 'CodeError',
        code: AppErrorCode.SYSTEM_SELECT_FILE_COUNT_ZERO,
        message: "未选择到指定文件"
      })
    }
    const resUrl = uris[0];
    LLog.info(TAG, `选择导入的资源：${resUrl}`)

    return await WireGuard.tools.loadFileToConfigsToDb(uiContext.getHostContext()!, resUrl)
  }

  /**
   * 根据VPN状态广播刷新每行开关显示
   *
   * 行开关跟随"用户意图"(isSwitchOpen+switchConfigId)：
   * - 点击开启后意图立即置true → 行开关立即为开，不受VPN启动过程中的中间广播(running=false)影响
   * - 只有明确启动异常/VPN进程关闭/用户主动关闭(intent回false) → 行开关才为关
   * @param dto VPN状态DTO（sync已完成，此处以本地意图为准刷新行显示）
   */
  /**
   * 按本地意图刷新所有行开关显示（纯显示写入，不产生任务）
   *
   * 行开关唯一状态源 = StatusConfig 的 isSwitchOpen + switchConfigId：
   * 点击（switchOn/OffIntent）、异常回滚（状态机 switchOffIntent）后调用本方法同步显示。
   */
  refreshRowStates() {
    const state = WireGuard.config.status.getConfig();
    const openId = state.isSwitchOpen ? state.switchConfigId : undefined;
    for (let item of this.wgList) {
      item.open = openId != undefined && item.id == openId;
    }
    LLog.info(TAG, `刷新行开关: switchIntent=${state.isSwitchOpen}/${state.switchConfigId}`);
  }

  closeOther(id: number) {
    for (let item of this.wgList) {
      if (item.id != id) {
        item.open = false;
      }
    }
  }

  /**
   * 改变Vpn配置（已废弃独立实现，逻辑统一到 VpnToggleService.requestVpnToggle，
   * 由 MainItemData.openChange 的点击守卫路径调用）
   */

  preLoadDatas() {
    this.wgList = [];
    for (let index = 0; index < 10; index++) {
      this.wgList.push(new MainItemData(this, {
        name: `test-${index}`,
        createdAt: new Date(Date.now()),
        updatedAt: new Date(Date.now()),
      }))
    }
  }

  @Monitor("uiConfig.listSortAsc", "uiConfig.listShowSimple", "uiConfig.sortColumn",)
  async change() {
    this.loadConfigs()
  }
}

/**
 * 主页每行数据
 */
@ObservedV2
export class MainItemData {
  private vm: WGMainViewModel
  name: string;
  @Trace open: boolean = false;
  @Trace toggleEnable: boolean = true;
  data: WgConfigTable
  private isClick = false

  constructor(vm: WGMainViewModel, data: WgConfigTable) {
    this.vm = vm;
    this.data = data;
    this.name = data.name!;
    // 行开关初始跟随用户意图：开关开且意图配置ID匹配
    const state = WireGuard.config.status.getConfig();
    this.open = state.isSwitchOpen && state.switchConfigId == this.id;
  }

  get id(): number {
    return this.data.id!;
  }

  onClick() {
    this.isClick = true
  }

  /**
   * 行开关点击处理（第一道闸门：isClick 手势守卫——仅真实点击进入，
   * 程序性赋值引发的 onChange 因标记 false 空跑返回）
   */
  openChange(context: UIContext, isOn: boolean) {
    if (this.isClick) {
      this.isClick = false
      this.toggleEnable = false;
      // 解析配置并交统一执行器：意图先行 → 联动刷新(纯显示) → id校验后执行
      const config = JSON.parse(this.data.config!) as WGDBConf;
      vpnToggleService.requestVpnToggle(context, this.id, isOn, config,
        () => {
          this.vm.refreshRowStates();
        },
        () => {
          this.toggleEnable = true;
        });
    }
  }
}


@ObservedV2
class MainUiConfig {
  @Trace listSortAsc: boolean = false;
  @Trace listShowSimple: boolean = true;
  @Trace sortColumn: SortColumnName = SortColumnName.create_time

  getColumnName(): string {
    switch (this.sortColumn) {
      case SortColumnName.config_name:
        return "配置名称"
      case SortColumnName.update_time:
        return "更新时间"
      case SortColumnName.create_time:
      default:
        return "创建时间"
    }
  }

  sortColumnToNext() {
    switch (this.sortColumn) {
      case SortColumnName.config_name:
        this.sortColumn = SortColumnName.update_time
        break
      case SortColumnName.update_time:
        this.sortColumn = SortColumnName.create_time
        break
      case SortColumnName.create_time:
      default:
        this.sortColumn = SortColumnName.config_name
    }
    LLog.info(TAG, `this.sortColumn=${this.sortColumn}`)
  }
}