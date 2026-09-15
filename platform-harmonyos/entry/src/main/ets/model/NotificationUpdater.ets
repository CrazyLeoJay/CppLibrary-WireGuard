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
import { LLog } from 'wg_tunnel';

const TAG: string = 'NotifUpdater';

/** 默认保活超时时间：3秒（deadline到期后用最新数据发布，满足系统对进度更新的要求） */
const DEFAULT_TIMEOUT_MS: number = 3 * 1000;

/**
 * 最小发布间隔（毫秒）：同一条通知在窗口内重复发布会被系统限流
 * （1600009 The notification sending frequency reaches the upper limit）。
 * 隧道数据包的到达频率远高于此值，因此数据驱动的发布必须节流；
 * 被节流的更新不丢失——deadline 到期时会用最新数据统一发布。
 */
const MIN_PUBLISH_INTERVAL_MS: number = 3 * 1000;

/**
 * 通知内容提供者回调类型
 *
 * 由调用方实现，负责构建并发布通知内容。
 * Updater在数据到来或保活超时时调用此回调。
 */
export type NotificationProvider = () => void;

/**
 * 通知更新器 - 单deadline倒计时 + 最小发布间隔节流
 *
 * 【核心问题】
 * 1. HarmonyOS DATA_TRANSFER 模式的后台长时任务，要求在10分钟内必须有进度更新，
 *    否则系统会回收后台任务导致VPN连接中断。
 * 2. 通知发布频率不能等于隧道数据包频率：同一条通知高频发布会被系统限流
 *    （1600009），数据驱动的发布必须节流到不超过 1 次/最小间隔。
 *
 * 【设计思路：单deadline倒计时 + 节流窗口】
 * 始终只有一个 setTimeout 在运行，不存在多个定时器各管各的问题：
 *
 *   ┌──────────────────────────────────────────────────────────────┐
 *   │  数据到来 ──→ 距上次发布 ≥ 最小间隔？                          │
 *   │                ├─ 是 ──→ 立即发布 ──→ 清除旧deadline → 重新计时 │
 *   │                └─ 否 ──→ 本次跳过（不发布），deadline到期时刷出  │
 *   │                                                              │
 *   │  无数据 ──→ deadline到期 ──→ 用最新数据发布 → 重新计时          │
 *   └──────────────────────────────────────────────────────────────┘
 *
 * 保证：
 * - 发布间隔下界：MIN_PUBLISH_INTERVAL_MS（节流，避免系统限流1600009）
 * - 发布间隔上界：timeoutMs（deadline兜底，满足系统的进度更新要求）
 * - 内容新鲜度：被节流的更新不丢数据，deadline 发布的是最新数据
 *
 * 【为什么只有一个setTimeout】
 * 每次发布后递归调度新的 setTimeout，不存在两个计时器同时运行的问题。
 * update() 受节流控制：只有真正发布时才重置deadline，被节流时不重置，
 * 从而由已排队的deadline在 timeoutMs 内用最新数据刷出。
 *
 * 【生命周期】
 * - start()：长时任务启动时调用，重置节流窗口并启动deadline倒计时
 * - stop()：长时任务停止时调用，清理计时器
 * - update()：VPN数据到来时调用，受节流控制地发布通知并重置deadline
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
  /** 上次实际发布时间（毫秒时间戳），0表示尚未发布（首次更新立即发布） */
  private lastPublishAt: number = 0;
  /** 自上次发布以来被节流跳过的更新次数，仅用于日志观测 */
  private skippedCount: number = 0;

  /**
   * 构造通知更新器
   *
   * @param provider 通知内容提供者回调，Updater在需要发布通知时调用
   * @param timeoutMs 保活超时时间（毫秒），默认3秒。
   *                  保证从上次发布到下次发布的间隔不超过此值，
   *                  超时则用最新数据发布，防止后台任务被系统回收。
   */
  constructor(provider: NotificationProvider, timeoutMs: number = DEFAULT_TIMEOUT_MS) {
    this.provider = provider;
    this.timeoutMs = timeoutMs;
  }

  /**
   * 启动更新器
   *
   * 长时任务启动时调用，重置节流窗口并启动deadline倒计时。
   * 首次发布由调用方在start()后自行触发，或等待deadline到期后自动发布。
   */
  start(): void {
    this.stop();
    // 重置节流窗口，保证长时任务启动后的首次数据更新能立即发布
    this.lastPublishAt = 0;
    this.skippedCount = 0;
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
   * 距上次发布已超过最小间隔则立即发布并重置deadline倒计时；
   * 否则本次跳过（隧道数据包频率远高于通知配额），不重置deadline，
   * 由已排队的deadline在 timeoutMs 内用最新数据统一发布。
   */
  update(): void {
    const elapsed: number = Date.now() - this.lastPublishAt;
    if (elapsed < MIN_PUBLISH_INTERVAL_MS) {
      this.skippedCount++;
      return;
    }
    this.cancelDeadline();
    this.publish();
    this.scheduleDeadline();
  }

  /**
   * 实际发布通知并记录发布时刻
   *
   * 发布时统一打印被节流合并的更新次数，便于在日志中观测节流效果。
   */
  private publish(): void {
    if (this.skippedCount > 0) {
      LLog.info(TAG, `发布节流：已合并 ${this.skippedCount} 次高频更新`);
      this.skippedCount = 0;
    }
    this.provider();
    this.lastPublishAt = Date.now();
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
   * 使用 setTimeout 递归调度（非setInterval），到期后用最新数据发布并重新调度。
   * 保证：每次发布后从零开始倒计时，始终只有一个计时器在运行。
   */
  private scheduleDeadline(): void {
    this.deadlineTimer = setTimeout(() => {
      this.deadlineTimer = undefined;
      LLog.info(TAG, 'deadline到期：无新数据，重发旧通知保活');
      this.publish();
      this.scheduleDeadline();
    }, this.timeoutMs);
  }
}
