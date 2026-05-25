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
import {
  getORM, IBestORMInit, ORM, setErrorLocale, setTimeFormat
} from '@ibestservices/ibest-orm';
import { LLog } from '../../tools/LLog';
import WgConfigTable from './table/WgConfigTable';

const TAG = "数据库"
// @ibestservices/ibest-orm
// 文档：https://ibest-orm.ibestservices.com/guide/quickstart/
const DATABASE_NAME = 'WireGuardCLJ'
// 支持的格式：'datetime' | 'date' | 'time' | 'timestamp' | 'iso'
setTimeFormat('datetime'); // 默认：2024-01-01 12:00:00
// setTimeFormat('iso');       // ISO 格式：2024-01-01T12:00:00.000Z
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
// setTimeFormat('timestamp'); // 时间戳：1704067200000

// 设置为英文
// setErrorLocale('en');

// 设置为中文（默认）
setErrorLocale('zh');

/**
 * @author leojay`fu
 */
export class DatabaseHelper {
  _orm?: ORM

  async init(
    context: Context,
    success?: () => void
  ) {
    this._orm = await IBestORMInit(context, {
      name: `${DATABASE_NAME}.db`, // 自定义数据库文件名
      debug: true, // 关闭调试日志
    });
    try {
      this._orm.migrate(WgConfigTable)
      success?.()
    } catch (err) {
      LLog.error(TAG, { message: "数据库异常", error: err })
    }
  }

  get orm(): ORM {
    return this._orm ?? getORM()
  }
}
