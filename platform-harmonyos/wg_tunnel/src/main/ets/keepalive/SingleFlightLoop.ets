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
import { LLog } from '../tools/LLog';

const TAG: string = 'SingleFlightLoop';

/** 睡眠返回：被信号唤醒 或 空闲超时 */
enum WakeReason {
  SIGNAL = 'signal',
  TIMEOUT = 'timeout',
}

/** 默认空闲最长等待：60秒（每轮执行完成后重新计时） */
const DEFAULT_MAX_WAIT_INTERVAL: number = 60 * 1000;
/** 默认最小执行间隔：3秒（距上一轮结束不足间隔的信号唤醒，推迟到满间隔执行） */
const DEFAULT_MIN_ROUND_GAP: number = 3 * 1000;

/** 单槽等待者：settle 是唤醒主循环协程的句柄 */
interface Waiter {
  settle: (reason: WakeReason) => void;
}

/**
 * 单飞行信号循环 —— 单线程事件循环上的 wait(信号|超时) 调度器
 *
 * 形态（等价 C++ 阻塞循环，epoll_wait(超时) 的单线程仿真）：
 *   while (运行中) {
 *     await wait(信号 | 空闲超时);   // 睡眠：信号随时唤醒，超时兜底
 *     await round();                 // 执行：期间到达的信号无槽可占=丢弃
 *   }
 *
 * 三条硬保证：
 * 1. 每轮执行完成后才重新计时（等待在 round 返回后才启动，超时/信号触发轮一视同仁）；
 * 2. 执行期"阻塞"：单协程串行，执行期 signal() 无等待者即丢弃（视为已触发），
 *    并发第二轮在结构上不存在，杜绝"短时间执行多次"的补跑行为；
 * 3. 最小执行间隔：距上一轮结束不足 minGap 的信号唤醒推迟到满间隔执行。
 * 睡眠期间 N 个信号合并为一次唤醒（单等待者槽位）。
 *
 * 睡眠与唤醒原理：
 * - 睡眠 = await 一个保持 PENDING 的 Promise：协程挂起，线程归还事件循环，零轮询；
 * - 唤醒 = 事件源同步调用 settle 句柄 resolve 该 Promise，协程续体作为微任务
 *   在当前回调栈退栈后立即执行（亚毫秒，不经过任何定时器）；
 * - 超时 setTimeout 只是另一个平等的唤醒源，done 闸门保证先到者生效、后到者空操作。
 *
 * Created on 2026/9/19.
 * @author leojay`fu
 */
export class SingleFlightLoop {
  /** 一轮执行（策略注入：由调用方决定每轮做什么） */
  private readonly round: (source: string) => Promise<void>;
  /** 空闲最长等待：超过则超时唤醒执行一轮 */
  private readonly maxWaitInterval: number;
  /** 最小执行间隔：两轮之间的硬性下限 */
  private readonly minRoundGap: number;

  /** 循环存活标志（stop 后在途一轮跑完自然退出） */
  private running: boolean = false;
  /** 防重入：保证循环体只有一个 */
  private started: boolean = false;
  /** 当前睡眠的等待者（单槽：有=睡眠中可被唤醒；无=执行中或未启动） */
  private waiter?: Waiter;
  /** 上一轮结束时间戳（最小执行间隔的计算基准） */
  private lastRoundEnd: number = 0;
  /** 待执行轮次的信号来源：唤醒成功时落账，轮次开始时消费（超时唤醒为空='idle'） */
  private pendingSource: string = '';
  /** 未启动保底单轮的互斥标志：与主循环同等单飞行语义，防信号风暴并发多轮 */
  private bootstrapRunning: boolean = false;

  constructor(round: (source: string) => Promise<void>,
    maxWaitInterval: number = DEFAULT_MAX_WAIT_INTERVAL,
    minRoundGap: number = DEFAULT_MIN_ROUND_GAP) {
    this.round = round;
    this.maxWaitInterval = maxWaitInterval;
    this.minRoundGap = minRoundGap;
  }

  /** 启动循环（幂等） */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.running = true;
    LLog.info(TAG,
      `循环启动: 最长等待=${this.maxWaitInterval / 1000}s, 最小间隔=${this.minRoundGap / 1000}s`);
    this.runLoop();
  }

  /** 停止循环：置停并唤醒挂起的睡眠，在途一轮跑完自然退出 */
  stop(): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.running = false;
    this.pendingSource = '';
    this.wakeWaiter(WakeReason.TIMEOUT);
    LLog.info(TAG, '循环已停止');
  }

  /**
   * 信号唤醒（全部触发源的唯一入口）
   *
   * - 睡眠中：立即唤醒执行一轮（同一时刻多个信号合并为这一次）；
   * - 执行中：无等待者 → 丢弃（视为已触发，本轮/下轮全量执行会覆盖其后果）；
   * - 未启动：保底执行单轮（循环未启动时到达的关键信号仍能得到处理）。
   *
   * @param source 触发来源（日志定位用）
   */
  signal(source: string): void {
    if (!this.started) {
      // 保底单轮同样单飞行：执行中到达的信号丢弃（runOnce 内部消化异常，finally 必然复位）
      if (this.bootstrapRunning) {
        LLog.info(TAG, `信号(${source})：保底单轮执行中，视为已触发，丢弃`);
        return;
      }
      this.bootstrapRunning = true;
      this.runOnce(source).finally(() => {
        this.bootstrapRunning = false;
      });
      return;
    }
    // 先落账再唤醒：微任务时序保证 runLoop 消费前 source 已就位；
    // 无等待者（执行中）则清除，防止泄漏到下一个空闲轮导致退避误判
    this.pendingSource = source;
    if (!this.wakeWaiter(WakeReason.SIGNAL)) {
      this.pendingSource = '';
      LLog.info(TAG, `信号(${source})：执行中，视为已触发，丢弃`);
    }
  }

  // ===================== 主循环 =====================

  private async runLoop(): Promise<void> {
    while (this.running) {
      // 睡眠：从上一轮结束起算；信号随时唤醒，空闲超时兜底
      await this.awaitSignalOrTimeout(this.maxWaitInterval);
      if (!this.running) {
        break;
      }
      // 执行：单协程串行——执行期 slot 为空，signal() 自动丢弃。
      // 来源：信号唤醒轮用落账的 source，超时唤醒轮为 'idle'
      const source: string = this.pendingSource != '' ? this.pendingSource : 'idle';
      this.pendingSource = '';
      await this.runOnce(source);
    }
  }

  /** 执行一轮（含最小执行间隔推迟与异常隔离：一轮失败不能中断循环） */
  private async runOnce(source: string): Promise<void> {
    const sinceLast: number = Date.now() - this.lastRoundEnd;
    if (this.lastRoundEnd > 0 && sinceLast < this.minRoundGap) {
      LLog.info(TAG, `信号(${source})距上一轮结束仅${sinceLast}ms，推迟${this.minRoundGap - sinceLast}ms`);
      await this.sleep(this.minRoundGap - sinceLast);
      if (!this.running) {
        return;
      }
    }
    try {
      await this.round(source);
    } catch (e) {
      LLog.error(TAG, `轮次执行异常(${source}): ${(e as Error).message}`);
    } finally {
      this.lastRoundEnd = Date.now();
    }
  }

  // ===================== 睡眠与唤醒原语 =====================

  /**
   * 睡眠等待：信号或超时，谁先到算谁
   *
   * await 保持 PENDING 的 Promise 使协程挂起（线程归还事件循环，零轮询）；
   * settle 句柄挂上单槽后，signal() 在信号产生的那一行同步 resolve——
   * 协程续体作为微任务在当前栈退栈后立即执行；setTimeout 到点是超时兜底。
   * done 闸门：先到者生效并撤销另一方，后到者第一行即返回（仅在两个事件点检查）。
   */
  private awaitSignalOrTimeout(timeoutMs: number): Promise<WakeReason> {
    return new Promise<WakeReason>((resolve: (reason: WakeReason) => void) => {
      let done: boolean = false;
      let timer: number = 0;
      const settle: (reason: WakeReason) => void = (reason: WakeReason): void => {
        if (done) {
          return;
        }
        done = true;
        clearTimeout(timer);
        this.waiter = undefined;   // 摘槽：之后的 signal 落入"执行中丢弃"
        resolve(reason);
      };
      timer = setTimeout((): void => {
        settle(WakeReason.TIMEOUT);
      }, timeoutMs);
      this.waiter = { settle: settle };
    });
  }

  /** 唤醒当前等待者；@returns 是否有等待者被唤醒（false=执行中，信号被丢弃） */
  private wakeWaiter(reason: WakeReason): boolean {
    const waiter = this.waiter;
    if (waiter == undefined) {
      return false;
    }
    this.waiter = undefined;
    waiter.settle(reason);
    return true;
  }

  /** 普通睡眠（最小执行间隔推迟用；不可被 stop 打断，至多延迟 minGap 退出） */
  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout((): void => {
        resolve();
      }, ms);
    });
  }
}
