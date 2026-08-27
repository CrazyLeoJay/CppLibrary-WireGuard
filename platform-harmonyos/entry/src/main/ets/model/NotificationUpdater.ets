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
import { LLog } from 'wg_tunnel';

const TAG: string = 'NotifUpdater';

/** 默认保活超时时间：10秒 */
const DEFAULT_TIMEOUT_MS: number = 3 * 1000;

/**
 * 通知内容提供者回调类型
 *
 * 由调用方实现，负责构建并发布通知内容。
 * Updater在数据到来或保活超时时调用此回调。
 */
export type NotificationProvider = () => void;

/**
 * 通知更新器 - 单deadline倒计时，保证最长N秒内至少一次通知发布
 *
 * 【核心问题】
 * HarmonyOS DATA_TRANSFER 模式的后台长时任务，要求在10分钟内必须有进度更新，
 * 否则系统会回收后台任务导致VPN连接中断。
 *
 * 【设计思路：单deadline倒计时】
 * 始终只有一个 setTimeout 在运行，不存在多个定时器各管各的问题：
 *
 *   ┌─────────────────────────────────────────────────────┐
 *   │  数据到来 ──→ 同步发布 ──→ 清除旧deadline → 重新计时  │
 *   │                                                     │
 *   │  无数据 ──→ deadline到期 ──→ 重发旧数据 → 重新计时     │
 *   └─────────────────────────────────────────────────────┘
 *
 * 保证：从上次发布到下次发布，间隔不超过 timeoutMs。
 * - 有数据：数据到来后立即同步发布，deadline重新开始倒计时
 * - 无数据：deadline到期后重发旧数据（内容不变），满足系统的进度更新要求
 *
 * 【为什么只有一个setTimeout】
 * 每次发布后递归调度新的 setTimeout，不存在两个计时器同时运行的问题。
 * update() 同步调用 provider() 后重置deadline，无需额外的即时更新定时器。
 *
 * 【生命周期】
 * - start()：长时任务启动时调用，启动deadline倒计时
 * - stop()：长时任务停止时调用，清理计时器
 * - update()：VPN数据到来时调用，同步发布通知并重置deadline
 *
 * Created on 2026/8/27.
 * @author leojay`fu
 */
export class NotificationUpdater {
  /** 保活超时时间（毫秒），最长多久必须有一次通知发布 */
  private timeoutMs: number;
  /** 通知内容提供者，负责实际的构建和发布通知 */
  private provider: NotificationProvider;
  /** deadline倒计时器ID（setTimeout），到期后重发旧数据并重新调度 */
  private deadlineTimer?: number;

  /**
   * 构造通知更新器
   *
   * @param provider 通知内容提供者回调，Updater在需要发布通知时调用
   * @param timeoutMs 保活超时时间（毫秒），默认10秒。
   *                  保证从上次发布到下次发布的间隔不超过此值，
   *                  超时则重发旧数据，防止后台任务被系统回收。
   */
  constructor(provider: NotificationProvider, timeoutMs: number = DEFAULT_TIMEOUT_MS) {
    this.provider = provider;
    this.timeoutMs = timeoutMs;
  }

  /**
   * 启动更新器
   *
   * 长时任务启动时调用，启动deadline倒计时。
   * 首次发布由调用方在start()后自行触发，或等待deadline到期后自动发布。
   */
  start(): void {
    this.stop();
    this.scheduleDeadline();
    LLog.info(TAG, `更新器已启动, 保活超时=${this.timeoutMs / 1000}s`);
  }

  /**
   * 停止更新器
   *
   * 长时任务停止时调用，清理deadline计时器。
   */
  stop(): void {
    this.cancelDeadline();
    LLog.info(TAG, '更新器已停止');
  }

  /**
   * 通知数据更新 - VPN数据到来时调用
   *
   * 同步调用provider发布通知，然后重置deadline倒计时。
   * 保证从本次发布到下次发布（无论是有数据还是deadline到期）间隔不超过 timeoutMs。
   */
  update(): void {
    this.cancelDeadline();
    this.provider();
    this.scheduleDeadline();
  }

  /**
   * 取消deadline倒计时
   */
  private cancelDeadline(): void {
    if (this.deadlineTimer != undefined) {
      clearTimeout(this.deadlineTimer);
      this.deadlineTimer = undefined;
    }
  }

  /**
   * 调度deadline倒计时
   *
   * 使用 setTimeout 递归调度（非setInterval），到期后重发旧数据并重新调度。
   * 保证：每次发布后从零开始倒计时，始终只有一个计时器在运行。
   */
  private scheduleDeadline(): void {
    this.deadlineTimer = setTimeout(() => {
      this.deadlineTimer = undefined;
      LLog.info(TAG, 'deadline到期：无新数据，重发旧通知保活');
      this.provider();
      this.scheduleDeadline();
    }, this.timeoutMs);
  }
}
