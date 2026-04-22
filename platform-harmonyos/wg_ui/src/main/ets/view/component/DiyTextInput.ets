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
type inputValue = string | number | undefined;

@ComponentV2
export struct DiyTextInput {
  @Param @Require tag: string
  @Param @Require inputId: string
  @Param bgColor: ResourceColor = $r('app.color.wg_new_card_background_color');
  @Param bgSelectColor: ResourceColor = $r('app.color.wg_new_card_item_select_color');
  @Param inputEnable: boolean = true;
  @Param placeholder: string = ""
  @Param funBtnList: Array<FunMenu> = [];
  @Param inputValue: inputValue = ""
  @Event $inputValue: (value: inputValue) => void;
  @Local isFocused: boolean = false
  // 当当前为不可输入时，对显示的文本添加点击事件
  @Param onNoInputTextClick?: () => void = undefined;
  @Param onInputWillChange?: Callback<EditableTextChangeValue, boolean> = undefined;
  @Param inputFilter?: string = undefined;

  @Styles
  inputStyle(){
    .backgroundColor(Color.Transparent)
    .borderWidth(0)
    .layoutWeight(1)
  }

  get isSmailTag(): boolean {
    return this.isFocused || this.placeholder.length > 0 || this.isInput;
  }

  get isInput(): boolean {
    if (!this.inputValue) {
      return false;
    } else if (typeof this.inputValue === 'string') {
      return this.inputValue.length > 0;
    } else if (typeof this.inputValue === 'number') {
      return this.inputValue > 0;
    } else {
      return true
    }
  }

  build() {
    Stack({
      alignContent: Alignment.Center
    }) {
      Row() {
        if (this.inputEnable) {
          TextInput({
            text: this.isInput ? `${this.inputValue}` : undefined,
            placeholder: !this.isSmailTag ? null : this.placeholder
          })
            .id(this.inputId)
            .inputStyle()
            .onWillChange((it) => this.onInputWillChange?.(it) ?? true)
            .inputFilter(this.inputFilter)
            .onFocus(() => {
              animateToImmediately({ duration: 200 }, () => {
                this.isFocused = true
              })
            })
            .onBlur(() => {
              animateToImmediately({ duration: 200 }, () => {
                this.isFocused = false
              })
            })
            .onChange(value => {
              if (typeof this.inputValue == "number") {
                return this.$inputValue(Number.parseInt(value));
              } else {
                return this.$inputValue(value)
              }
            })
        } else {
          Text(this.isInput ? `${this.inputValue}` : this.placeholder)
            .height('40vp')
            .width('100%')
            .align(Alignment.Start)
            .padding({ left: "16vp", right: "16vp" })
            .inputStyle()
            .maxLines(1)
            // .ellipsisMode(EllipsisMode.END)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .wordBreak(WordBreak.BREAK_ALL)
            .onClick(() => {
              this.onNoInputTextClick?.();
            })
        }


        if (this.funBtnList.length > 0) {
          Row({ space: '8vp' }) {
            ForEach(this.funBtnList, (item: FunMenu, _) => {
              if (item.type == "symbolBtn" && item.symbol) {
                SymbolGlyph(item.symbol)
                  .fontSize('20fp')
                  .padding('2vp')
                  .onClick(() => {
                    item.action();
                  })
              } else if (item.type == "tag" && item.tag) {
                Text(item.tag)
                  // .fontSize('20fp')
                  // .width('40vp')
                  // .height('40vp')
                  .padding('2vp')
              }
            })
          }
          .layoutWeight(0)
          .align(Alignment.End)
          .layoutGravity(LocalizedAlignment.END)
          .margin({ right: '16vp' })
        }

      }
      .width('100%')
      .border({
        width: '1vp',
        color: (this.inputEnable && this.isFocused) ? this.bgSelectColor : Color.Black,
        radius: 6
      })
      .backgroundColor(this.bgColor)

      Text(this.tag)
        .fontSize(this.isSmailTag ? '10fp' : '16fp')
        // .align(Alignment.TopStart)
        .position({
          x: this.isSmailTag ? '10vp' : '10vp',
          y: this.isSmailTag ? -6 : 12, // 动态位置
        })
        .backgroundColor(this.bgColor)
        .focusable(false)
        .padding({ left: 5, right: 5 })
        .onClick(() => {
          if (this.inputEnable) {
            animateToImmediately({ duration: 200 }, () => {
              focusControl.requestFocus(this.inputId)
            })
          }
        })
    }
  }
}

export interface FunMenu {
  type: 'symbolBtn' | 'tag'; // 默认是系统按钮 symbolBtn
  symbol?: Resource;
  tag?: string,
  action: () => void;
}