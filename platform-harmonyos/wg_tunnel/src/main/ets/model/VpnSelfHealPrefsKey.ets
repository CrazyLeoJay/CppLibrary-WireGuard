/*
 * Copyright [2026] @github-crazyleojay (crazyleojay@163.com/gmail.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LLog } from '../tools/LLog';

const TAG = 'VpnSelfHealPrefsKey';

/**
 * 自愈持久化文件名与key定义（下沉到wg_tunnel供跨模块共用）
 *
 * entry模块的VpnSelfHealPrefsImpl（冷启动自愈读写方）与本模块
 * clearSelfHealRecord（用户主动关闭时的同步清除方）共用同一份存储，
 * 常量必须单点定义，避免魔法字符串双端漂移导致清除落空。
 */
export const VPN_SELF_HEAL_PREFS_NAME = 'vpn_self_heal';

/** 自愈持久化key：最后处于运行状态的VPN配置ID（-1=无记录，不自愈） */
export const VPN_SELF_HEAL_KEY_LAST_OPEN_CONFIG_ID = 'last_open_config_id';

/**
 * 用户主动关闭后的"状态广播抑制窗口"（毫秒）
 *
 * 关闭指令下发前已同步清除记录，但VEA的running=true状态广播是异步IPC，
 * 清除之后仍可能到达并据此重新写回configId（正是要修的竞态）。
 * 窗口内忽略running=true的写入；用户若立刻重新开启，runWGConfig(true)会立即解除抑制。
 */
const USER_STOP_SUPPRESS_WINDOW_MS = 3000;

let lastUserStopAtMs = 0;

/** 标记用户主动关闭（进入抑制窗口） */
export function markUserStopSuppression(): void {
  lastUserStopAtMs = Date.now();
}

/** 用户重新开启VPN：立即解除抑制，避免影响正常的记录写入 */
export function clearUserStopSuppression(): void {
  lastUserStopAtMs = 0;
}

/** 是否处于用户关闭后的抑制窗口内（供entry模块recordStatus判断） */
export function isUserStopSuppressionActive(): boolean {
  return lastUserStopAtMs > 0 && Date.now() - lastUserStopAtMs < USER_STOP_SUPPRESS_WINDOW_MS;
}

/**
 * 同步清除自愈持久化记录（用户主动关闭VPN时本地立即调用）
 *
 * 为什么必须本地同步清除而不能等VEA的STOP回执广播：
 * 回执是跨进程异步链路（发STOP → VEA销毁VPN → 回发广播 → 主进程落盘），
 * 用户关开关后立即杀app会落在此窗口内，记录残留将导致下次冷启动
 * 自愈误判"VPN本应在运行"而自动重连（实测竞态场景）。
 *
 * 同应用内getPreferencesSync(name)对同一文件返回同一缓存实例，
 * 此处写入与entry模块VpnSelfHealPrefsImpl的后续读取即时一致。
 */
export function clearSelfHealRecord(context?: common.Context): void {
  if (!context) {
    LLog.warn(TAG, '清除自愈记录时上下文未初始化，跳过（init尚未执行）');
    return;
  }
  try {
    const prefs = preferences.getPreferencesSync(context, { name: VPN_SELF_HEAL_PREFS_NAME });
    prefs.putSync(VPN_SELF_HEAL_KEY_LAST_OPEN_CONFIG_ID, -1);
    prefs.flushSync();
    // 进入抑制窗口：STOP指令下发后VEA仍可能补投running=true广播，
    // 若不抑制会把刚写入的-1覆盖回configId，残留记录依旧导致冷启动误自愈
    markUserStopSuppression();
    LLog.info(TAG, '已同步清除自愈持久化记录');
  } catch (e) {
    LLog.error(TAG, { error: e, message: '同步清除自愈持久化记录失败' });
  }
}
