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
import { WGDeviceConfig } from '../entity/WGClientConfig';
import WgConfigTable from './table/WgConfigTable';

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

  getConfigForId(id: number): WGDeviceConfig | undefined {
    let result = this.orm.query(WgConfigTable)
      .select("config")
      .where({ id: id })
      .first()
    if (!result || !result.config || result.config?.length == 0) {
      return undefined;
    }
    return JSON.parse(result.config) as WGDeviceConfig
  }

  insertNewConfig(config: WGDeviceConfig) {
    let cStr = JSON.stringify(config);
    const table = new WgConfigTable();
    table.name = config.device.deviceName;
    table.config = cStr;
    this.orm.insert(table);
  }

  updateConfig(id: number, config: WGDeviceConfig) {
    let cStr = JSON.stringify(config);
    this.orm.query(WgConfigTable)
      .where({ id: id })
      .update({
        name: config.device.deviceName,
        config: cStr,
      });
  }

  deleteConfig(id: number) {
    this.orm.deleteById(WgConfigTable, id);
  }
}
