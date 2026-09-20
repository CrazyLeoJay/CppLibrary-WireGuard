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
 * 每个用例的输出结构（供人工/CI核对测试了什么、怎么测的、结果如何）：
 *   [Tn] ===== 行为标题 =====        —— 本用例验证什么
 *   [Tn] 参数 / 流程                 —— 怎么测
 *   [Tn] 实测: ...                   —— 观察到的真实数据
 *   [Tn] 断言k: ... → 通过           —— 逐条断言（失败时 message 带期望与实际）
 *   [Tn] ✓ 全部断言通过
 */
const TAG: string = 'SFL';

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: (v: void) => void) => setTimeout(resolve, ms));
}

function log(caseTag: string, msg: string): void {
  console.info(`[${caseTag}] ${msg}`);
}

function title(caseTag: string, what: string): void {
  console.info(`[${caseTag}] ===== ${what} =====`);
}

function arrStr(arr: Array<string>): string {
  return JSON.stringify(arr);
}

export default function singleFlightLoopTest(): void {
  describe('SingleFlightLoopTest', () => {
    it('T1_idle_periodic_timing_restarts_after_round', 0, async () => {
      const t: string = 'T1';
      title(t, '未干扰基线：空闲周期触发，计时从每轮结束重新起算，来源恒为idle');
      log(t, '参数: maxWait=200ms, minGap=50ms');
      log(t, '流程: 预热300ms(本地引擎冷启动) → start → 观察700ms → stop');

      const sources: Array<string> = [];
      const times: Array<number> = [];
      const loop = new SingleFlightLoop(async (src: string): Promise<void> => {
        sources.push(src);
        times.push(Date.now());
      }, 200, 50);
      await sleep(300);
      loop.start();
      await sleep(700);
      loop.stop();

      log(t, `实测: 轮次来源=${arrStr(sources)}, 相邻间隔ms=${JSON.stringify(
        times.map((v: number, i: number): number => i === 0 ? 0 : v - times[i - 1]))}`);
      expect(sources.length).message(`${t}: 周期轮次不足2轮（实际${sources.length}轮），空闲周期触发失效`)
        .assertLargerOrEqual(2);
      const badSources: Array<string> = sources.filter((s: string): boolean => s !== 'idle');
      expect(badSources.length).message(`${t}: 存在非idle来源=${arrStr(badSources)}（无信号时应全部为idle）`)
        .assertEqual(0);
      let gapsOk: boolean = true;
      for (let i = 1; i < times.length; i++) {
        if (times[i] - times[i - 1] < 180) {
          gapsOk = false;
        }
      }
      expect(gapsOk)
        .message(`${t}: 相邻轮间隔<180ms=${JSON.stringify(times)}，说明计时未从上一轮结束重新起算`)
        .assertTrue();
      log(t, `✓ 通过: ${sources.length}轮周期触发, 全部idle, 间隔均≥180ms（从上一轮结束起算）`);
    });

    it('T2_signal_wakes_immediately_with_source', 0, async () => {
      const t: string = 'T2';
      title(t, '干扰-睡眠期信号：立即唤醒执行一轮，source透传到执行轮');
      log(t, '参数: maxWait=5000ms, minGap=10ms');
      log(t, '流程: start → 睡眠50ms → signal(switchOn) → 观察80ms → stop');

      const sources: Array<string> = [];
      const loop = new SingleFlightLoop(async (src: string): Promise<void> => {
        sources.push(src);
      }, 5000, 10);
      loop.start();
      await sleep(50);
      loop.signal('switchOn');
      await sleep(80);
      loop.stop();

      log(t, `实测: 轮次来源=${arrStr(sources)}（期望 ["switchOn"]，若为[]说明未唤醒，若含idle说明来源丢失）`);
      expect(sources.length).message(`${t}: 信号唤醒后应只执行1轮，实际${sources.length}轮 ${arrStr(sources)}`)
        .assertEqual(1);
      expect(sources[0]).message(`${t}: 执行轮来源应为switchOn（透传失效），实际=${sources[0] ?? 'undefined'}`)
        .assertEqual('switchOn');
      log(t, `✓ 通过: 信号亚毫秒唤醒，来源透传正确`);
    });

    it('T3_signals_during_sleep_coalesce_into_one_round', 0, async () => {
      const t: string = 'T3';
      title(t, '干扰-睡眠期信号风暴：N个信号合并为1轮');
      log(t, '参数: maxWait=5000ms, minGap=10ms');
      log(t, '流程: start → 睡眠30ms → 连发10个signal → 观察100ms → stop');

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

      log(t, `实测: 10个信号执行了${rounds}轮（期望1，等待者单槽合并）`);
      expect(rounds).message(`${t}: 10个睡眠期信号应合并为1轮，实际${rounds}轮`)
        .assertEqual(1);
      log(t, '✓ 通过: 合并语义正确');
    });

    it('T4_signals_during_round_dropped_next_run_after_maxWait', 0, async () => {
      const t: string = 'T4';
      title(t, '干扰-执行期信号：丢弃不补跑，下一轮=本轮结束+maxWait');
      log(t, '参数: maxWait=200ms, minGap=10ms');
      log(t, '流程: start → 30ms后signal(switchOn，轮内人为挂起) → 执行期signal(mid)应丢弃 → 放行 → 观察220ms');

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

      log(t, `实测(执行中): 来源=${arrStr(sources)}（switchOn轮挂起中）`);
      expect(sources.length).message(`${t}: 执行期只应有1轮在跑，实际${sources.length}轮 ${arrStr(sources)}`)
        .assertEqual(1);
      expect(sources[0]).message(`${t}: 执行轮来源应为switchOn，实际=${sources[0] ?? 'undefined'}`)
        .assertEqual('switchOn');
      release();
      await sleep(60);
      log(t, `实测(放行后): 来源=${arrStr(sources)}（执行期mid应被丢弃，不补跑）`);
      expect(sources.length).message(`${t}: 执行期信号应丢弃，出现补跑说明语义破坏，实际${sources.length}轮`)
        .assertEqual(1);
      await sleep(220);

      log(t, `实测(计时后): 来源=${arrStr(sources)}（下一轮应为idle，且距放行≈maxWait）`);
      expect(sources.length).message(`${t}: 轮结束后maxWait应触发下一轮，实际${sources.length}轮`)
        .assertEqual(2);
      expect(sources[1]).message(`${t}: 第二轮应为超时触发的idle，实际=${sources[1] ?? 'undefined'}`)
        .assertEqual('idle');
      log(t, '✓ 通过: 执行期丢弃 + 下一轮从本轮结束重新计时');
      loop.stop();
    });

    it('T5_wake_before_minGap_deferred_to_full_gap', 0, async () => {
      const t: string = 'T5';
      title(t, '干扰-距上轮结束不足minGap：唤醒推迟到满间隔执行');
      log(t, '参数: maxWait=5000ms, minGap=150ms');
      log(t, '流程: start → 20ms后signal(a) → 再60ms后signal(b)（距a轮结束≈60ms<150ms，应推迟）');

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

      const gap: number = times.length === 2 ? times[1] - times[0] : -1;
      log(t, `实测: 轮数=${times.length}, 两轮间隔=${gap}ms（期望恰2轮且间隔≥140ms）`);
      expect(times.length).message(`${t}: 应恰2轮（a立即+ b推迟），实际${times.length}轮`).assertEqual(2);
      expect(gap >= 140).message(`${t}: 两轮间隔${gap}ms应≥140ms，最小间隔推迟失效`).assertTrue();
      log(t, `✓ 通过: 推迟生效，间隔${gap}ms ≥ minGap下限`);
    });

    it('T10_not_started_signal_storm_runs_single_round', 0, async () => {
      const t: string = 'T10';
      title(t, '极限-未启动信号风暴：保底单轮互斥，仍单飞行');
      log(t, '参数: maxWait=5000ms, minGap=10ms；轮体含30ms await空窗');
      log(t, '流程: 不start → 10连发signal（风暴在保底轮执行窗内到达）→ 观察150ms');

      let rounds: number = 0;
      const loop = new SingleFlightLoop(async (src: string): Promise<void> => {
        await sleep(30);
        rounds++;
      }, 5000, 10);
      for (let i = 0; i < 10; i++) {
        loop.signal('storm' + i);
      }
      await sleep(150);

      log(t, `实测: 10连发执行了${rounds}轮（期望1，bootstrap互斥回归）`);
      expect(rounds).message(`${t}: 未启动信号风暴应只执行1轮（并发注册缺陷回归），实际${rounds}轮`)
        .assertEqual(1);
      log(t, '✓ 通过: 保底单轮单飞行保持');
    });

    it('T11_signal_after_stop_bootstrap_once_no_period', 0, async () => {
      const t: string = 'T11';
      title(t, '极限-stop后迟到信号：恰好一轮保底，且不进入周期');
      log(t, '参数: maxWait=100ms, minGap=10ms');
      log(t, '流程: start → 150ms后stop → 再signal(late) → 观察300ms');

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

      log(t, `实测: stop前${before}轮, stop后信号产生${sources.length - before}轮=${arrStr(sources)}`);
      expect(sources.length).message(`${t}: stop后迟到信号应保底执行1轮，实际执行${sources.length - before}轮`)
        .assertEqual(before + 1);
      expect(sources[sources.length - 1]).message(`${t}: 保底轮来源应为late，实际=${sources[sources.length - 1] ?? 'undefined'}`)
        .assertEqual('late');
      log(t, '✓ 通过: 保底单轮执行且不进入周期轮询');
    });

    it('T12_start_is_idempotent', 0, async () => {
      const t: string = 'T12';
      title(t, '极限-start重复调用：幂等，仍为单循环节奏');
      log(t, '参数: maxWait=100ms, minGap=10ms');
      log(t, '流程: 连续start×3 → 观察450ms → stop');

      let rounds: number = 0;
      const loop = new SingleFlightLoop(async (): Promise<void> => {
        rounds++;
      }, 100, 10);
      loop.start();
      loop.start();
      loop.start();
      await sleep(450);
      loop.stop();

      log(t, `实测: 三重start下450ms执行${rounds}轮（单循环≈3-5轮，双循环叠加会≈6-10轮）`);
      expect(rounds >= 3 && rounds <= 5)
        .message(`${t}: 三重start应仍为单循环（实际${rounds}轮，超出[3,5]说明幂等失效产生叠加循环）`)
        .assertTrue();
      log(t, `✓ 通过: 幂等保持，${rounds}轮`);
    });

    it('T13_stop_then_start_resumes_period', 0, async () => {
      const t: string = 'T13';
      title(t, '极限-stop→start重启：周期恢复');
      log(t, '参数: maxWait=100ms, minGap=10ms');
      log(t, '流程: start → 150ms后stop → 验证静止150ms → start → 观察350ms');

      let rounds: number = 0;
      const loop = new SingleFlightLoop(async (): Promise<void> => {
        rounds++;
      }, 100, 10);
      loop.start();
      await sleep(150);
      loop.stop();
      const atStop: number = rounds;
      await sleep(150);
      log(t, `实测: stop时${atStop}轮, 静止150ms后${rounds}轮`);
      expect(rounds).message(`${t}: stop后应静止（${atStop}→${rounds}）`).assertEqual(atStop);
      loop.start();
      await sleep(350);
      loop.stop();
      log(t, `实测: 重启后350ms共${rounds}轮`);
      expect(rounds >= atStop + 2)
        .message(`${t}: 重启后周期应恢复（${atStop}→${rounds}，应≥+2）`).assertTrue();
      log(t, '✓ 通过: 重启恢复周期');
    });

    it('T14_round_longer_than_maxWait_no_overlap', 0, async () => {
      const t: string = 'T14';
      title(t, '干扰-轮时长超过maxWait：不叠加轮次，下一轮=轮结束+maxWait');
      log(t, '参数: maxWait=100ms, minGap=10ms；轮体固定耗时250ms');
      log(t, '流程: start → 观察800ms（若实现错误会出现4-5轮叠加）→ stop');

      const times: Array<number> = [];
      const loop = new SingleFlightLoop(async (): Promise<void> => {
        times.push(Date.now());
        await sleep(250);
      }, 100, 10);
      loop.start();
      await sleep(800);
      loop.stop();

      const gap: number = times.length === 2 ? times[1] - times[0] : -1;
      log(t, `实测: 800ms内${times.length}轮, 间隔=${gap}ms（期望恰2轮且间隔≥340ms）`);
      expect(times.length).message(`${t}: 长轮次不应叠加（应恰2轮），实际${times.length}轮`).assertEqual(2);
      expect(gap >= 340).message(`${t}: 下一轮应=轮结束+maxWait（间隔≥340ms），实际${gap}ms`).assertTrue();
      log(t, `✓ 通过: 无叠加，间隔${gap}ms`);
    });

    it('T15_signal_in_defer_window_dropped_deferred_round_runs', 0, async () => {
      const t: string = 'T15';
      title(t, '干扰-minGap推迟睡眠窗口内的信号：丢弃，推迟轮照常执行且来源正确');
      log(t, '参数: maxWait=5000ms, minGap=200ms');
      log(t, '流程: 20ms后signal(a) → 30ms后signal(b)（进入defer睡眠） → 50ms后signal(c)（defer窗内应丢弃）');

      const sources: Array<string> = [];
      const times: Array<number> = [];
      const loop = new SingleFlightLoop(async (src: string): Promise<void> => {
        sources.push(src);
        times.push(Date.now());
      }, 5000, 200);
      loop.start();
      await sleep(20);
      loop.signal('a');
      await sleep(30);
      loop.signal('b');
      await sleep(50);
      loop.signal('c');
      await sleep(250);
      loop.stop();

      const gap: number = times.length === 2 ? times[1] - times[0] : -1;
      log(t, `实测: 轮次来源=${arrStr(sources)}, 间隔=${gap}ms（期望恰[a,b]且间隔≥190ms，c被丢弃）`);
      expect(sources.length).message(`${t}: defer窗口信号应丢弃（应恰2轮a,b），实际${sources.length}轮 ${arrStr(sources)}`)
        .assertEqual(2);
      expect(sources[0]).message(`${t}: 轮1来源应为a，实际=${sources[0] ?? 'undefined'}`).assertEqual('a');
      expect(sources[1]).message(`${t}: 轮2来源应为b，实际=${sources[1] ?? 'undefined'}`).assertEqual('b');
      expect(gap >= 190).message(`${t}: 推迟轮距上轮应≥190ms（minGap=200下限），实际${gap}ms`).assertTrue();
      log(t, `✓ 通过: defer窗口丢弃，推迟轮${gap}ms≥minGap`);
    });
  });
}
