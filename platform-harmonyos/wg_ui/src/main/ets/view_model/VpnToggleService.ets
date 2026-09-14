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

/**
 * VPN开关统一执行器（主界面行开关 / 预览页开关共用）
 *
 * 【两道闸门，只有目标任务执行】
 * 第一道（UI层，各页面Toggle内）：点击标记（isClick/isSwitchClick）——onClick 设 true、
 * onChange 消费。ArkUI Toggle 的 onChange 在程序赋值时同样会触发，联动按钮的
 * 程序性状态变化引发的 onChange 因标记为 false 直接空跑返回，不产生任务。
 * 第二道（本服务）：任务执行前校验 StatusConfig.switchConfigId 与目标id一致
 * （按开关位区分），不一致=意图已被后到操作覆盖，作废为空操作。
 *
 * 【单飞行槽】currentOp Promise链：新任务接在前一任务落定之后执行，同一时间
 * 只有一个native操作在飞。对已完成Promise接then立即微任务执行，不会重放底层操作。
 *
 * @author leojay`fu
 */
import { UIContext } from '@kit.ArkUI';
import { LLog, vpnKeepAliveManager, WireGuard, WGDBConf } from 'wg_tunnel';

const TAG = 'VpnToggle'

class VpnToggleServiceImpl {
  private currentOp?: Promise<void>;

  /**
   * 统一开关入口（仅由真实点击路径调用：主界面行openChange / 预览页onSwitchChange，
   * 均已过点击标记守卫）
   *
   * 执行序：意图先行（switchConfigId=目标id）→ 刷新按钮显示（联动=纯显示写入，
   * 不产生任务）→ 接入单飞行槽，执行前校验id，只有目标任务执行。
   *
   * @param context UIContext（Toast用）
   * @param targetId 点击的目标配置id
   * @param isOn true=开 false=关
   * @param dbConf 目标配置数据
   * @param onDisplayRefresh 按钮显示刷新回调（读意图重算各行/预览开关显示）
   * @param onSettled 任务落定回调（恢复开关可点状态），成功失败均回调
   */
  requestVpnToggle(context: UIContext, targetId: number, isOn: boolean, dbConf: WGDBConf,
    onDisplayRefresh: () => void, onSettled?: () => void): Promise<void> {
    // 1. 意图先行：本地状态立即置为目标态，UI开关由意图驱动
    if (isOn) {
      WireGuard.config.status.switchOnIntent(targetId);
    } else {
      WireGuard.config.status.switchOffIntent();
    }
    onDisplayRefresh();

    // 2. 接入单飞行槽
    const task = (this.currentOp ?? Promise.resolve()).catch(() => {
    }).then(async () => {
      await this.executeWhenIdMatches(context, targetId, isOn, dbConf);
    });
    this.currentOp = task;
    if (onSettled != undefined) {
      task.finally(() => {
        onSettled();
      });
    }
    return task;
  }

  /**
   * 保存配置后的自动热切换（预览页updateData路径，非点击触发）
   *
   * 意图不变；仅当运行意图仍是本配置（开关开且id一致）时发SWITCH，
   * 把编辑后的配置应用到运行中的隧道。接入同一单飞行槽与其他操作串行。
   */
  requestConfigReloadSwitch(targetId: number, dbConf: WGDBConf): Promise<void> {
    const task = (this.currentOp ?? Promise.resolve()).catch(() => {
    }).then(async () => {
      const s = WireGuard.config.status.getConfig();
      if (!(s.isSwitchOpen && s.switchConfigId === targetId)) {
        LLog.info(TAG, `热切换跳过：运行意图非本配置(target=${targetId}, current=${s.isSwitchOpen}/${s.switchConfigId})`);
        return;
      }
      try {
        await WireGuard.switchVpnConfig(targetId, dbConf);
      } catch (e) {
        LLog.error(TAG, `热切换失败: ${JSON.stringify(e)}`);
      }
    });
    this.currentOp = task;
    return task;
  }

  /**
   * 第二道闸门：id校验 + 执行 + 失败回滚
   *
   * 无论开关，只有 switchConfigId 与目标id一致（且开关位匹配）才执行；
   * 不匹配说明意图已被后到操作覆盖，本次作废为空操作。
   */
  private async executeWhenIdMatches(context: UIContext, targetId: number, isOn: boolean,
    dbConf: WGDBConf): Promise<void> {
    const s = WireGuard.config.status.getConfig();
    const matches = isOn
      ? (s.isSwitchOpen && s.switchConfigId === targetId)
      : (!s.isSwitchOpen && s.switchConfigId === targetId);
    if (!matches) {
      LLog.info(TAG,
        `任务作废(意图已更新): target=${targetId}/${isOn ? '开' : '关'}, current=${s.isSwitchOpen}/${s.switchConfigId}`);
      return;
    }
    try {
      await WireGuard.runWGConfig(targetId, dbConf, isOn);
      if (isOn) {
        vpnKeepAliveManager.onSwitchOn();
      } else {
        vpnKeepAliveManager.onSwitchOff();
      }
    } catch (e) {
      // 回滚：仅当意图仍属本次（被后到意图覆盖时不回滚、不提示）
      const cur = WireGuard.config.status.getConfig();
      const stillMine = isOn
        ? (cur.isSwitchOpen && cur.switchConfigId === targetId)
        : (!cur.isSwitchOpen && cur.switchConfigId === targetId);
      if (stillMine) {
        WireGuard.config.status.switchOffIntent();
        vpnKeepAliveManager.onSwitchOff();
        WireGuard.event.publishVpnNoOpen();
        // 开启失败展示Toast，关闭失败不展示（用户主动关闭不应提示错误）
        if (isOn) {
          const reason = e != undefined ? String(e) : '';
          context.getPromptAction().showToast({
            message: reason.length > 0 ? 'VPN启动失败：' + reason : 'VPN启动失败'
          });
        }
      }
      LLog.error(TAG, { error: e, message: `${isOn ? "开启" : "关闭"}VPN异常` });
    }
  }
}

export const vpnToggleService = new VpnToggleServiceImpl();
