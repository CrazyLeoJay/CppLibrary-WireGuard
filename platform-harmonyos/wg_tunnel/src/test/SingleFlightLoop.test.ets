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
 * 【用例组织】同一场景的多条行为断言拆分为独立 it（行为名即用例名），
 * DevEco Studio 测试面板的用例树本身就是"验证了哪些行为"的清单；
 * 失败时面板直接显示该行为的 Assert.message 原因（期望/实际/语义）。
 * 同组 it 复用同一场景函数（确定性时序，各 it 独立重跑场景）。
 *
 * 【输出说明】用例内的 console.info 阶段性流程输出（参数/实测值）被 LocalUnit
 * runner 重定向至 wg_tunnel/.test/default/intermediates/test/coverage_data/
 * coverage.log（IDE 面板不显示 console，属框架行为）；可用
 * sh platform-harmonyos/tests/run-local-unit-test.sh 在终端查看提取后的
 * 完整行为明细，或直接打开该日志文件。
 */

// ==================== 观测数据类型 ====================
interface ObservedSourcesTimes {
  sources: Array<string>;
  times: Array<number>;
}

interface ObservedSources {
  sources: Array<string>;
}

interface ObservedTimes {
  times: Array<number>;
}

interface ObservedCount {
  count: number;
}

interface T4Observed {
  duringRun: Array<string>;   // switchOn轮挂起中的来源快照
  afterDropCount: number;     // 放行+观察后的轮数（执行期mid应被丢弃，恰1轮）
  final: Array<string>;       // 下一轮计时到达后的来源快照
}

interface T13Observed {
  atStop: number;         // stop时刻累计轮数
  afterQuiet: number;     // 静止150ms后累计轮数
  afterRestart: number;   // 重启350ms后累计轮数
}

interface T11Observed {
  before: number;          // stop前累计轮数
  afterBootstrap: number;  // 迟到信号保底轮后累计轮数
  afterExtra: number;      // 再观察窗口后累计轮数（验证不进周期）
  lastSource: string;      // 保底轮来源
}

// ==================== 工具 ====================
function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: (v: void) => void) => setTimeout(resolve, ms));
}

function log(caseTag: string, msg: string): void {
  console.info(`[${caseTag}] ${msg}`);
}

function arrStr(arr: Array<string>): string {
  return JSON.stringify(arr);
}

// ==================== 场景函数（同组 it 复用，确定性时序） ====================

/** T1场景：预热后启动，空闲观察700ms（maxWait=200, minGap=50） */
async function scenarioT1(): Promise<ObservedSourcesTimes> {
  const sources: Array<string> = [];
  const times: Array<number> = [];
  const loop = new SingleFlightLoop(async (src: string): Promise<void> => {
    sources.push(src);
    times.push(Date.now());
  }, 200, 50);
  await sleep(300);   // 本地引擎冷启动预热
  loop.start();
  await sleep(700);
  loop.stop();
  log('T1', `参数: maxWait=200ms, minGap=50ms; 实测: ${sources.length}轮, 来源=${arrStr(sources)}, 间隔ms=${JSON.stringify(
    times.map((v: number, i: number): number => i === 0 ? 0 : v - times[i - 1]))}`);
  return { sources: sources, times: times };
}

/** T2场景：启动后睡眠50ms发一个信号，观察80ms（maxWait=5000, minGap=10） */
async function scenarioT2(source: string): Promise<ObservedSources> {
  const sources: Array<string> = [];
  const loop = new SingleFlightLoop(async (src: string): Promise<void> => {
    sources.push(src);
  }, 5000, 10);
  loop.start();
  await sleep(50);
  loop.signal(source);
  await sleep(80);
  loop.stop();
  log('T2', `参数: maxWait=5000ms, minGap=10ms; 实测: 来源=${arrStr(sources)}`);
  return { sources: sources };
}

/** T3场景：启动后睡眠30ms连发10个信号，观察100ms（maxWait=5000, minGap=10） */
async function scenarioT3(): Promise<ObservedCount> {
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
  log('T3', `参数: maxWait=5000ms, minGap=10ms; 实测: 10信号→${rounds}轮`);
  return { count: rounds };
}

/** T4场景：执行期挂起+执行期信号+放行后计时（maxWait=200, minGap=10） */
async function scenarioT4(): Promise<T4Observed> {
  const duringRun: Array<string> = [];
  const final: Array<string> = [];
  let release: () => void = (): void => {};
  const gate: Promise<void> = new Promise<void>((resolve) => {
    release = resolve;
  });
  const loop = new SingleFlightLoop(async (src: string): Promise<void> => {
    if (duringRun.length === 0) {
      duringRun.push(src);   // 首轮（switchOn）进入挂起
      await gate;
    }
    final.push(src);
  }, 200, 10);
  loop.start();
  await sleep(30);
  loop.signal('switchOn');
  await sleep(60);
  loop.signal('mid');        // 执行期信号：switchOn轮挂起中，mid应被丢弃
  await sleep(30);
  release();                 // 放行挂起轮
  await sleep(60);           // 放行后60ms：mid若被补跑此时已可见
  const afterDropCount: number = final.length;   // 应恰1（switchOn）
  await sleep(220);          // 下一轮=轮结束+maxWait
  loop.stop();
  log('T4', `参数: maxWait=200ms, minGap=10ms; 实测: 挂起中=${arrStr(duringRun)}, ` +
    `放行后=${afterDropCount}轮, 计时后=${arrStr(final)}`);
  return { duringRun: duringRun, afterDropCount: afterDropCount, final: final };
}

/** T5场景：两连信号，第二个距上轮结束不足minGap（maxWait=5000, minGap=150） */
async function scenarioT5(): Promise<ObservedTimes> {
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
  log('T5', `参数: maxWait=5000ms, minGap=150ms; 实测: ${times.length}轮, 间隔=${times.length === 2 ? times[1] - times[0] : -1}ms`);
  return { times: times };
}

/** T10场景：未启动状态10连发信号风暴（轮体含30ms await空窗） */
async function scenarioT10(): Promise<ObservedCount> {
  let rounds: number = 0;
  const loop = new SingleFlightLoop(async (src: string): Promise<void> => {
    await sleep(30);
    rounds++;
  }, 5000, 10);
  for (let i = 0; i < 10; i++) {
    loop.signal('storm' + i);
  }
  await sleep(150);
  log('T10', `参数: maxWait=5000ms, minGap=10ms; 实测: 10连发(未启动)→${rounds}轮`);
  return { count: rounds };
}

/** T11场景：start→150ms后stop→迟到信号→双窗口观察（maxWait=100, minGap=10） */
async function scenarioT11(): Promise<T11Observed> {
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
  const afterBootstrap: number = sources.length;
  const lastSource: string = sources.length > 0 ? sources[sources.length - 1] : '';
  await sleep(300);
  log('T11', `参数: maxWait=100ms, minGap=10ms; 实测: stop前${before}轮, ` +
    `保底后${afterBootstrap}轮(末位=${lastSource}), 再300ms后${sources.length}轮`);
  return { before: before, afterBootstrap: afterBootstrap, afterExtra: sources.length, lastSource: lastSource };
}

/** T12场景：三重start，观察450ms（maxWait=100, minGap=10） */
async function scenarioT12(): Promise<ObservedCount> {
  let rounds: number = 0;
  const loop = new SingleFlightLoop(async (): Promise<void> => {
    rounds++;
  }, 100, 10);
  loop.start();
  loop.start();
  loop.start();
  await sleep(450);
  loop.stop();
  log('T12', `参数: maxWait=100ms, minGap=10ms; 实测: 三重start→450ms内${rounds}轮`);
  return { count: rounds };
}

/** T13场景：start→stop→静止→重启（maxWait=100, minGap=10） */
async function scenarioT13(): Promise<T13Observed> {
  let rounds: number = 0;
  const loop = new SingleFlightLoop(async (): Promise<void> => {
    rounds++;
  }, 100, 10);
  loop.start();
  await sleep(150);
  loop.stop();
  const atStop: number = rounds;
  await sleep(150);
  const afterQuiet: number = rounds;
  loop.start();
  await sleep(350);
  loop.stop();
  log('T13', `参数: maxWait=100ms, minGap=10ms; 实测: stop时${atStop}轮, ` +
    `静止150ms后${afterQuiet}轮, 重启350ms后${rounds}轮`);
  return { atStop: atStop, afterQuiet: afterQuiet, afterRestart: rounds };
}

/** T14场景：轮体固定耗时250ms > maxWait=100（minGap=10），观察800ms */
async function scenarioT14(): Promise<ObservedTimes> {
  const times: Array<number> = [];
  const loop = new SingleFlightLoop(async (): Promise<void> => {
    times.push(Date.now());
    await sleep(250);
  }, 100, 10);
  loop.start();
  await sleep(800);
  loop.stop();
  log('T14', `参数: maxWait=100ms, minGap=10ms, 轮耗时250ms; 实测: 800ms内${times.length}轮, ` +
    `间隔=${times.length === 2 ? times[1] - times[0] : -1}ms`);
  return { times: times };
}

/** T15场景：a→b(进入defer睡眠)→c(defer窗口内)（maxWait=5000, minGap=200） */
async function scenarioT15(): Promise<ObservedSourcesTimes> {
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
  log('T15', `参数: maxWait=5000ms, minGap=200ms; 实测: 来源=${arrStr(sources)}, ` +
    `间隔=${times.length === 2 ? times[1] - times[0] : -1}ms`);
  return { sources: sources, times: times };
}

/** T16场景：循环建立后 stop → 同步立即 start（不给旧循环微任务退出的机会，复活竞态） */
async function scenarioT16(): Promise<ObservedCount> {
  let rounds: number = 0;
  const loop = new SingleFlightLoop(async (): Promise<void> => {
    rounds++;
  }, 100, 10);
  loop.start();
  await sleep(150);   // 建立循环并跑出基线轮次
  loop.stop();
  loop.start();       // 同步紧接：旧循环被唤醒检查时running已翻回true
  await sleep(450);
  loop.stop();
  log('T16', `参数: maxWait=100ms, minGap=10ms; 实测: stop→立即start后450ms内${rounds}轮`);
  return { count: rounds };
}

// ==================== 行为级用例（用例名=被验证的行为） ====================
export default function singleFlightLoopTest(): void {
  describe('SingleFlightLoopTest', () => {
    // ---------- T1 未干扰基线：空闲周期 ----------
    it('T1a_未干扰时空闲周期持续触发_700ms内至少2轮', 0, async () => {
      const o = await scenarioT1();
      expect(o.sources.length).message(`T1a: 未干扰700ms应周期触发≥2轮，实际${o.sources.length}轮`)
        .assertLargerOrEqual(2);
    });
    it('T1b_无信号时轮次来源恒为idle', 0, async () => {
      const o = await scenarioT1();
      const bad: Array<string> = o.sources.filter((s: string): boolean => s !== 'idle');
      expect(bad.length).message(`T1b: 无信号时出现非idle来源=${arrStr(bad)}`).assertEqual(0);
    });
    it('T1c_相邻轮间隔从上一轮结束重新起算_均不小于180ms', 0, async () => {
      const o = await scenarioT1();
      let gapsOk: boolean = true;
      for (let i = 1; i < o.times.length; i++) {
        if (o.times[i] - o.times[i - 1] < 180) {
          gapsOk = false;
        }
      }
      expect(gapsOk)
        .message(`T1c: 存在间隔<180ms，计时未从上一轮结束重新起算 ${JSON.stringify(o.times)}`)
        .assertTrue();
    });

    // ---------- T2 干扰-睡眠期信号 ----------
    it('T2a_睡眠期信号立即唤醒_恰执行一轮', 0, async () => {
      const o = await scenarioT2('switchOn');
      expect(o.sources.length).message(`T2a: 信号唤醒后应恰1轮，实际${o.sources.length}轮 ${arrStr(o.sources)}`)
        .assertEqual(1);
    });
    it('T2b_唤醒轮来源透传为switchOn', 0, async () => {
      const o = await scenarioT2('switchOn');
      const first: string = o.sources.length > 0 ? o.sources[0] : '';
      expect(first).message(`T2b: 来源透传失效，实际=${first || '无轮次'}`).assertEqual('switchOn');
    });

    // ---------- T3 干扰-睡眠期信号风暴 ----------
    it('T3_睡眠期10个信号合并为1轮', 0, async () => {
      const o = await scenarioT3();
      expect(o.count).message(`T3: 10个睡眠期信号应合并为1轮（单槽等待者），实际${o.count}轮`)
        .assertEqual(1);
    });

    // ---------- T4 干扰-执行期信号 ----------
    it('T4a_执行期仅挂起轮在跑且来源为switchOn', 0, async () => {
      const o = await scenarioT4();
      expect(o.duringRun.length).message(`T4a: 挂起期应仅1轮，实际${o.duringRun.length}轮`)
        .assertEqual(1);
      expect(o.duringRun[0]).message(`T4a: 执行轮来源应为switchOn，实际=${o.duringRun[0] ?? 'undefined'}`)
        .assertEqual('switchOn');
    });
    it('T4b_执行期信号丢弃_不产生补跑', 0, async () => {
      const o = await scenarioT4();
      expect(o.afterDropCount).message(`T4b: 执行期mid信号应丢弃（出现补跑说明语义破坏），实际${o.afterDropCount}轮`)
        .assertEqual(1);
    });
    it('T4c_下一轮idle于本轮结束加maxWait时触发', 0, async () => {
      const o = await scenarioT4();
      expect(o.final.length).message(`T4c: 轮结束后maxWait应触发下一轮，实际${o.final.length}轮`)
        .assertEqual(2);
      expect(o.final[1]).message(`T4c: 第二轮应为超时触发的idle，实际=${o.final[1] ?? 'undefined'}`)
        .assertEqual('idle');
    });

    // ---------- T5 干扰-不足minGap ----------
    it('T5a_距上轮不足minGap的两连信号恰执行两轮', 0, async () => {
      const o = await scenarioT5();
      expect(o.times.length).message(`T5a: 应恰2轮（a立即+b推迟），实际${o.times.length}轮`)
        .assertEqual(2);
    });
    it('T5b_推迟轮与上轮间隔不小于minGap下限', 0, async () => {
      const o = await scenarioT5();
      const gap: number = o.times.length === 2 ? o.times[1] - o.times[0] : -1;
      expect(gap >= 140).message(`T5b: 两轮间隔${gap}ms应≥140ms，最小间隔推迟失效`).assertTrue();
    });

    // ---------- T10 极限-未启动信号风暴 ----------
    it('T10_未启动状态信号风暴仍单飞行_仅执行一轮', 0, async () => {
      const o = await scenarioT10();
      expect(o.count).message(`T10: 未启动10连发应只执行1轮（bootstrap互斥，并发注册缺陷回归），实际${o.count}轮`)
        .assertEqual(1);
    });

    // ---------- T11 极限-stop后迟到信号 ----------
    it('T11a_stop后迟到信号保底执行一轮', 0, async () => {
      const o = await scenarioT11();
      expect(o.afterBootstrap).message(`T11a: stop后迟到信号应保底1轮（${o.before}→${o.afterBootstrap}）`)
        .assertEqual(o.before + 1);
      expect(o.lastSource).message(`T11a: 保底轮来源应为late，实际=${o.lastSource}`).assertEqual('late');
    });
    it('T11b_保底单轮后不进入周期轮询', 0, async () => {
      const o = await scenarioT11();
      expect(o.afterExtra).message(`T11b: 保底后不进周期（${o.afterBootstrap}→${o.afterExtra}应不变）`)
        .assertEqual(o.afterBootstrap);
    });

    // ---------- T12 极限-start幂等 ----------
    it('T12_start三重调用仍为单循环节奏', 0, async () => {
      const o = await scenarioT12();
      expect(o.count >= 3 && o.count <= 5)
        .message(`T12: 三重start应仍为单循环（实际${o.count}轮，超出[3,5]说明幂等失效产生叠加循环）`)
        .assertTrue();
    });

    // ---------- T13 极限-stop重启 ----------
    it('T13a_stop后循环完全静止', 0, async () => {
      const o = await scenarioT13();
      expect(o.afterQuiet).message(`T13a: stop后应静止（${o.atStop}→${o.afterQuiet}）`)
        .assertEqual(o.atStop);
    });
    it('T13b_重新start后周期恢复', 0, async () => {
      const o = await scenarioT13();
      expect(o.afterRestart >= o.afterQuiet + 2)
        .message(`T13b: 重启后周期应恢复（${o.afterQuiet}→${o.afterRestart}，应≥+2）`)
        .assertTrue();
    });

    // ---------- T16 极限-stop立即start快速重启 ----------
    it('T16_stop后立即start快速重启_不产生双循环', 0, async () => {
      const o = await scenarioT16();
      expect(o.count >= 3 && o.count <= 6)
        .message(`T16: stop→立即start应仍为单循环（实际${o.count}轮，≈8-10轮说明旧循环被running翻转复活成双循环，epoch校验失效）`)
        .assertTrue();
    });

    // ---------- T14 干扰-长轮次 ----------
    it('T14a_轮时长超过maxWait不产生叠加轮次', 0, async () => {
      const o = await scenarioT14();
      expect(o.times.length).message(`T14a: 长轮次不叠加应恰2轮，实际${o.times.length}轮`)
        .assertEqual(2);
    });
    it('T14b_下一轮于轮结束加maxWait时触发', 0, async () => {
      const o = await scenarioT14();
      const gap: number = o.times.length === 2 ? o.times[1] - o.times[0] : -1;
      expect(gap >= 340).message(`T14b: 下一轮应=轮结束+maxWait（间隔≥340ms），实际${gap}ms`).assertTrue();
    });

    // ---------- T15 干扰-defer窗口信号 ----------
    it('T15a_defer窗口内信号被丢弃_推迟轮照常执行', 0, async () => {
      const o = await scenarioT15();
      expect(o.sources.length).message(`T15a: defer窗口信号应丢弃（应恰2轮a,b），实际${o.sources.length}轮 ${arrStr(o.sources)}`)
        .assertEqual(2);
      expect(o.sources[0]).message(`T15a: 轮1来源应为a，实际=${o.sources[0] ?? 'undefined'}`).assertEqual('a');
      expect(o.sources[1]).message(`T15a: 轮2来源应为b，实际=${o.sources[1] ?? 'undefined'}`).assertEqual('b');
    });
    it('T15b_推迟轮与上轮间隔不小于minGap下限', 0, async () => {
      const o = await scenarioT15();
      const gap: number = o.times.length === 2 ? o.times[1] - o.times[0] : -1;
      expect(gap >= 190).message(`T15b: 推迟轮距上轮应≥190ms（minGap=200下限），实际${gap}ms`).assertTrue();
    });
  });
}
