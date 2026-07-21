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
import { ORM } from '@ibestservices/ibest-orm';
import { JSON } from '@kit.ArkTS';
import { WGDBConf } from '../entity/WGConfigEntity';
import WgConfigTable from './table/WgConfigTable';

const TAG = "db"

/**
 * wg 配置数据操作
 * @author leojay`fu
 */
export default class WGDao {
  private orm: ORM

  constructor(orm: ORM) {
    this.orm = orm;
  }

  allConfig(): WgConfigTable[] {
    return this.orm.query(WgConfigTable)
      .orderBy("createdAt", 'desc')
      .find()
  }

  getConfigForId(id: number): WGDBConf | undefined {
    let result = this.orm.query(WgConfigTable)
      .select("config")
      .where({ id: id })
      .first()
    if (!result || !result.config || result.config?.length == 0) {
      return undefined;
    }
    return JSON.parse(result.config) as WGDBConf
  }

  insertNewConfig(config: WGDBConf | WGDBConf[]) {
    if (config instanceof Array) {
      const all = config.map((it) => {
        let cStr = JSON.stringify(it);
        const table = new WgConfigTable();
        table.name = it.name;
        table.config = cStr;
        return table
      })
      this.orm.insert(all);
    } else {
      let cStr = JSON.stringify(config);
      const table = new WgConfigTable();
      table.name = config.name;
      table.config = cStr;
      this.orm.insert(table);
    }
  }

  updateConfig(id: number, config: WGDBConf) {
    let cStr = JSON.stringify(config);
    this.orm.query(WgConfigTable)
      .where({ id: id })
      .update({
        name: config.name,
        config: cStr,
      });
  }

  deleteConfig(id: number) {
    this.orm.deleteById(WgConfigTable, id);
  }

  /**
   * 计数这个名称在配置中出现的次数
   *
   * @param inputName
   */
  getCountForName(inputName: string): number {
    return this.orm.query(WgConfigTable)
      .where({ name: inputName })
      .count()
  }
}
