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
import { describe, it, expect } from '@ohos/hypium';
import { SingleFlightLoop } from '../main/ets/keepalive/SingleFlightLoop';

/**
 * SingleFlightLoop（单飞行信号循环）行为单元测试
 *
 * 被测对象为真实源文件 ../main/ets/keepalive/SingleFlightLoop.ets
 * （@ohos.hilog 依赖经 src/mock/mock-config.json5 在测试构建期替换为空实现）。
 *
 * 覆盖语义：
 *   基线：空闲周期触发且计时随轮重启 / stop 静止 / start 幂等 / stop→start 重启
 *   干扰：信号即时唤醒与来源透传 / 睡眠期合并 / 执行期丢弃不补跑 /
 *         minGap 推迟 / 长轮次不叠加 / defer 窗口丢弃
 *   极限：未启动信号风暴单飞行 / stop 后迟到信号保底单轮
 */
function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: (v: void) => void) => setTimeout(resolve, ms));
}

export default function singleFlightLoopTest(): void {
  describe('SingleFlightLoopTest', () => {
    it('T1_idle_periodic_timing_restarts_after_round', 0, async () => {
      const sources: Array<string> = [];
      const times: Array<number> = [];
      const loop = new SingleFlightLoop(async (src: string): Promise<void> => {
        sources.push(src);
        times.push(Date.now());
      }, 200, 50);
      await sleep(300);   // 预热：本地引擎冷启动首个定时器可能显著延迟
      loop.start();
      await sleep(700);
      loop.stop();
      // 本地引擎定时器精度低于 Node（同样700ms窗口Node出3轮、本地可能2轮），
      // 断言语义而非具体轮数：周期持续触发即可，间隔断言承担"随轮重启"校验
      expect(sources.length).assertLargerOrEqual(2);
      const badSources: Array<string> = sources.filter((s: string): boolean => s !== 'idle');
      expect(badSources.length).assertEqual(0);
      expect(sources.every((s: string): boolean => s === 'idle')).assertTrue();
      let gapsOk: boolean = true;
      for (let i = 1; i < times.length; i++) {
        if (times[i] - times[i - 1] < 180) {
          gapsOk = false;
        }
      }
      expect(gapsOk).assertTrue();
    });

    it('T2_signal_wakes_immediately_with_source', 0, async () => {
      const sources: Array<string> = [];
      const loop = new SingleFlightLoop(async (src: string): Promise<void> => {
        sources.push(src);
      }, 5000, 10);
      loop.start();
      await sleep(50);
      loop.signal('switchOn');
      await sleep(80);
      loop.stop();
      expect(sources.length).assertEqual(1);
      expect(sources[0]).assertEqual('switchOn');
    });

    it('T3_signals_during_sleep_coalesce_into_one_round', 0, async () => {
      let rounds: number = 0;
      const loop = new SingleFlightLoop(async (): Promise<void> => {
        rounds++;
      }, 5000, 10);
      loop.start();
      await sleep(30);
      for (let i = 0; i < 10; i++) {
        loop.signal('s' + i);
      }
      await sleep(100);
      loop.stop();
      expect(rounds).assertEqual(1);
    });

    it('T4_signals_during_round_dropped_next_run_after_maxWait', 0, async () => {
      const sources: Array<string> = [];
      let release: () => void = (): void => {};
      const gate: Promise<void> = new Promise<void>((resolve) => {
        release = resolve;
      });
      const loop = new SingleFlightLoop(async (src: string): Promise<void> => {
        sources.push(src);
        if (src === 'switchOn') {
          await gate;
        }
      }, 200, 10);
      loop.start();
      await sleep(30);
      loop.signal('switchOn');
      await sleep(60);
      loop.signal('mid');
      await sleep(30);
      expect(sources.length).assertEqual(1);
      expect(sources[0]).assertEqual('switchOn');
      release();
      await sleep(60);
      expect(sources.length).assertEqual(1);
      await sleep(220);
      expect(sources.length).assertEqual(2);
      expect(sources[1]).assertEqual('idle');
      loop.stop();
    });

    it('T5_wake_before_minGap_deferred_to_full_gap', 0, async () => {
      const times: Array<number> = [];
      const loop = new SingleFlightLoop(async (): Promise<void> => {
        times.push(Date.now());
      }, 5000, 150);
      loop.start();
      await sleep(20);
      loop.signal('a');
      await sleep(60);
      loop.signal('b');
      await sleep(220);
      loop.stop();
      expect(times.length).assertEqual(2);
      if (times.length === 2) {
        expect(times[1] - times[0] >= 140).assertTrue();
      }
    });

    it('T10_not_started_signal_storm_runs_single_round', 0, async () => {
      let rounds: number = 0;
      const loop = new SingleFlightLoop(async (src: string): Promise<void> => {
        await sleep(30);   // 保底轮含 await 空窗，风暴信号在空窗内到达
        rounds++;
      }, 5000, 10);
      for (let i = 0; i < 10; i++) {
        loop.signal('storm' + i);   // 未启动，10 连发
      }
      await sleep(150);
      expect(rounds).assertEqual(1);
    });

    it('T11_signal_after_stop_bootstrap_once_no_period', 0, async () => {
      const sources: Array<string> = [];
      const loop = new SingleFlightLoop(async (src: string): Promise<void> => {
        sources.push(src);
      }, 100, 10);
      loop.start();
      await sleep(150);
      loop.stop();
      const before: number = sources.length;
      loop.signal('late');
      await sleep(300);
      expect(sources.length).assertEqual(before + 1);
      expect(sources[sources.length - 1]).assertEqual('late');
    });

    it('T12_start_is_idempotent', 0, async () => {
      let rounds: number = 0;
      const loop = new SingleFlightLoop(async (): Promise<void> => {
        rounds++;
      }, 100, 10);
      loop.start();
      loop.start();
      loop.start();
      await sleep(450);
      loop.stop();
      expect(rounds >= 3 && rounds <= 5).assertTrue();
    });

    it('T13_stop_then_start_resumes_period', 0, async () => {
      let rounds: number = 0;
      const loop = new SingleFlightLoop(async (): Promise<void> => {
        rounds++;
      }, 100, 10);
      loop.start();
      await sleep(150);
      loop.stop();
      const atStop: number = rounds;
      await sleep(150);
      expect(rounds).assertEqual(atStop);
      loop.start();
      await sleep(350);
      loop.stop();
      expect(rounds >= atStop + 2).assertTrue();
    });

    it('T14_round_longer_than_maxWait_no_overlap', 0, async () => {
      const times: Array<number> = [];
      const loop = new SingleFlightLoop(async (): Promise<void> => {
        times.push(Date.now());
        await sleep(250);   // 轮时长 250ms > maxWait 100ms
      }, 100, 10);
      loop.start();
      await sleep(800);
      loop.stop();
      expect(times.length).assertEqual(2);
      if (times.length === 2) {
        expect(times[1] - times[0] >= 340).assertTrue();
      }
    });

    it('T15_signal_in_defer_window_dropped_deferred_round_runs', 0, async () => {
      const sources: Array<string> = [];
      const times: Array<number> = [];
      const loop = new SingleFlightLoop(async (src: string): Promise<void> => {
        sources.push(src);
        times.push(Date.now());
      }, 5000, 200);
      loop.start();
      await sleep(20);
      loop.signal('a');          // t≈20 轮1
      await sleep(30);           // t≈50：唤醒落账 b，进入 defer 睡眠
      loop.signal('b');
      await sleep(50);           // t≈100：defer 睡眠窗口内
      loop.signal('c');          // waiter 未挂 → 应丢弃
      await sleep(250);          // t≈350
      loop.stop();
      expect(sources.length).assertEqual(2);
      expect(sources[0]).assertEqual('a');
      expect(sources[1]).assertEqual('b');
      expect(times[1] - times[0] >= 190).assertTrue();
    });
  });
}
