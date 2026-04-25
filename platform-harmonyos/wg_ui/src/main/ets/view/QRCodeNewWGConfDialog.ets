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
 */
import { LLog, WGConf, WireGuard } from 'wg_tunnel';
import { DiyTextInput } from './component/DiyTextInput';

const TAG = "QRCodeDialog"

/**
 * QrCodeDialog参数
 */
export interface QRCodeNewConfig {
  wgConf: WGConf
}

/**
 * 二维码扫描添加配置弹窗
 *
 * Created on 2026/4/25.
 * @author leojay`fu
 */
@ComponentV2
export struct QRCodeNewWGConfDialog {
  @Param @Require wgConf: WGConf
  @Local inputName: string = "";

  aboutToAppear(): void {
    if (!this.wgConf) {
      // 没有参数
      LLog.warn(TAG, "没有配置参数")
      this.getDialogController()?.close();
    }
  }

  build() {
    Column({ space: ' 16vp' }) {
      Text("通过二维码添加配置")

      DiyTextInput({
        tag: "隧道名称",
        inputId: "qrcode_new_config_name",
        inputValue: this.inputName!!,
      })

      Row({ space: '16vp' }) {
        Button("取消")
          .layoutWeight(1)
          .onClick(() => {
            if (this.getDialogController()) {
              this.getDialogController()?.close();
            }
          })
        Button("确认")
          .layoutWeight(1)
          .onClick(() => {
            if (!this.wgConf) {
              this.getUIContext().getPromptAction().showToast({
                message: "配置没有读取到！！"
              })
              return
            }
            if (this.inputName.length <= 0) {
              LLog.warn(TAG, "名称太短")
              this.getUIContext().getPromptAction().showToast({
                message: "名称太短!!"
              })
              return;
            }
            WireGuard.helper.config.insertNewConfig({
              name: this.inputName,
              conf: this.wgConf,
            })
            if (this.getDialogController()) {
              this.getDialogController()?.close();
            }
          })
      }
    }
    .width('80%')
    .backgroundColor($r('app.color.wg_dialog_background_color'))
    .padding('16vp')
    .borderRadius('8vp')
    .justifyContent(FlexAlign.Center)
  }
}