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
  Column, ColumnType, CreatedAt, PrimaryKey, Table, UpdatedAt
} from '@ibestservices/ibest-orm';

/**
 * @author leojay`fu
 */
@Table({ name: "WgConfigTable" })
export default class WgConfigTable {
  @PrimaryKey() id?: number
  @Column({ notNull: true }) name?: string;
  @Column({
    notNull: true,
    type: ColumnType.BLOB,
  }) config?: string;
  @CreatedAt() createdAt?: Date;
  @UpdatedAt() updatedAt?: Date;
}

