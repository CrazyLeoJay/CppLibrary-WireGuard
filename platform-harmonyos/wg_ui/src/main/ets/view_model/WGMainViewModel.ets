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
import { WGConf } from 'wg_tunnel';
import { fileIo, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import WGAppException from 'wg_tunnel/src/main/ets/error/WGAppException';
import { buffer } from '@kit.ArkTS';

const TAG = "主页"

/**
 * 主页数据持有
 */
@ObservedV2
export default class WGMainViewModel {
  nav: NavPathStack = new NavPathStack();
  @Trace wgList: MainItemData[] = [];
  @Trace qrCodePixelMap?: image.PixelMap;

  constructor(nav?: NavPathStack) {
    if (nav) {
      this.nav = nav;
    }
  }

  async loadConfigs() {
    this.wgList = WireGuard.helper.config.allConfig().map((it) => {
      return new MainItemData(it);
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
  async readWGConfForSystemFile(uiContext: UIContext): Promise<WGConf> {
    const documentSelectOptions = new picker.DocumentSelectOptions();
    documentSelectOptions.maxSelectNumber = 1; // 最多选择5个文件
    // // 指定选择的文件或者目录的URI（可选）
    // documentSelectOptions.defaultFilePathUri = "file://docs/storage/Users/currentUser/test";
    // 选择文件的后缀类型过滤（可选），例如只显示.txt和.pdf
    // documentSelectOptions.fileSuffixChoices = ['文档|.conf'];
    documentSelectOptions.fileSuffixFilters = ['WireGuard配置|.conf'];

    let context = uiContext.getHostContext() as common.UIAbilityContext;
    const documentViewPicker = new picker.DocumentViewPicker(context);
    const uris: Array<string> = await documentViewPicker.select(documentSelectOptions)
    if (uris.length != 1) {
      throw new WGAppException("未选择到指定文件")
    }
    const resUrl = uris[0];
    LLog.info(TAG, `资源：${resUrl}`)
    let file: fileIo.File | undefined
    try {
      file = await fileIo.open(resUrl, fileIo.OpenMode.READ_ONLY)
      // todo 一般情况下 1m 的内存足够配置，后续还是要在c++处构建可以通过流写入的方式
      const buf = new ArrayBuffer(1024 * 1024)
      const readLen = await fileIo.read(file.fd, buf)
      if (readLen <= 0) {
        throw new WGAppException("没有读取到配置")
      }
      const content = buffer.from(buf).toString()
      // const content = await fileIo.read(fd);
      return WireGuard.readWgConf(content)
    } finally {
      if (file) {
        fileIo.close(file);
      }
    }
  }
}

/**
 * 主页每行数据
 */
export class MainItemData {
  name: string;
  open: boolean = false;
  data: WgConfigTable

  constructor(data: WgConfigTable) {
    this.data = data;
    this.name = data.name!;
  }

  get id(): number {
    return this.data.id!;
  }
}