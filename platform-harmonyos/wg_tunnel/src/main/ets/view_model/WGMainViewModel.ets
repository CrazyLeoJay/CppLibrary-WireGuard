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
import WgConfigTable from '../model/db/table/WgConfigTable';
import { WireGuard } from '../model/WGHelper';
import { LLog } from '../tools/LLog';

const TAG = "主页"

/**
 * 主页数据持有
 */
@ObservedV2
export default class WGMainViewModel {
  nav: NavPathStack = new NavPathStack();
  @Trace wgList: MainItemData[] = [];

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