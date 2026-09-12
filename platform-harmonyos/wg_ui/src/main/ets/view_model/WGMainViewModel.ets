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
import { SortColumnName, StatusConfigDTO, WGConf, WGDBConf, vpnKeepAliveManager } from 'wg_tunnel';
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
  setActiveConfigId(dto: StatusConfigDTO) {
    const state = WireGuard.config.status.getConfig();
    const openId = state.isSwitchOpen ? state.switchConfigId : undefined;
    for (let item of this.wgList) {
      item.open = (openId != undefined && item.id == openId);
    }
    LLog.info(TAG,
      `刷新行开关: switchIntent=${state.isSwitchOpen}/${state.switchConfigId}, dto.running=${dto.running}/${dto.runningConfigId}`);
  }

  closeOther(id: number) {
    for (let item of this.wgList) {
      if (item.id != id) {
        // if (item.id == this.lastOpenConfigId) {
        item.open = false;
      }
    }
  }

  lastOpenConfigId: number = +1;

  /**
   * 改变Vpn配置，启动或停止
   *
   * 意图驱动流程：
   * - 开启：立即 switchOnIntent(本地状态置开) → UI行开关即刻为开 → 启动VPN进程
   *          → 只要成功发起启动即启动长时任务(vpnKeepAliveManager.onSwitchOn)
   * - 关闭：立即 switchOffIntent → UI行开关即刻为关 → 停止长时任务 → 关闭VPN进程
   * 失败(启动异常/授权拒绝) → 回滚意图与UI，并停止长时任务。
   */
  async changeVpnConfig(context: UIContext, item: MainItemData, isOn: boolean) {
    const status = WireGuard.config.status.getConfig();
    // 防重复：该配置已是用户意图开启状态
    if (isOn && status.isSwitchOpen && status.switchConfigId == item.id) {
      return;
    }
    if (isOn) {
      // 1. 立即将本地状态置为开启（意图先行，UI即刻显示开）
      this.lastOpenConfigId = item.id;
      WireGuard.config.status.switchOnIntent(item.id);
      item.open = true;
    } else {
      this.lastOpenConfigId = -1;
      WireGuard.config.status.switchOffIntent();
      item.open = false;
    }
    try {
      const config = JSON.parse(item.data.config!) as WGDBConf
      // 2. 启动/关闭VPN进程
      await WireGuard.runWGConfig(item.id, config, isOn)
      // 3. 开启：成功发起启动后直接启动长时任务（不再等待VPN服务状态事件）
      //    关闭：直接停止长时任务
      if (isOn) {
        vpnKeepAliveManager.onSwitchOn();
      } else {
        vpnKeepAliveManager.onSwitchOff();
      }
    } catch (e) {
      // 启动/关闭异常 → 回滚意图：开关为关、停止长时任务
      WireGuard.config.status.switchOffIntent();
      item.open = false;
      vpnKeepAliveManager.onSwitchOff();
      WireGuard.event.publishVpnNoOpen()
      // 开启失败展示Toast，关闭失败不展示（用户主动关闭不应提示错误）
      if (isOn) {
        const reason = e != undefined ? String(e) : '';
        context.getPromptAction().showToast({ message: reason.length > 0 ? 'VPN启动失败：' + reason : 'VPN启动失败' })
      }
      LLog.error(TAG, { error: e, message: `${isOn ? "开启" : "关闭"}VPN异常` });
    }
  }


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
    // 同步VM层记录的最后打开ID
    if (this.open) {
      vm.lastOpenConfigId = this.id;
    }
  }

  get id(): number {
    return this.data.id!;
  }

  onClick() {
    this.isClick = true
  }

  openChange(context: UIContext, isOn: boolean) {
    if (this.isClick) {
      this.toggleEnable = false;
      // 等启停流程（含异常回滚）完成后再恢复开关可点，防止快速连点造成操作交错
      const task = isOn ? this.vm.changeVpnConfig(context, this, true)
        : this.vm.changeVpnConfig(context, this, false);
      task.finally(() => {
        this.toggleEnable = true;
      });
      this.isClick = false
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