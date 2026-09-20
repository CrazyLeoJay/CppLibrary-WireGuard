// =====================================================================
// SingleFlightLoop 行为单元测试
//
// ⚠️ 本文件是 wg_tunnel/src/main/ets/keepalive/SingleFlightLoop.ets 的
//    1:1 逻辑移植（去 ArkTS 类型与 LLog，Node 可直接运行）。
//    修改 SingleFlightLoop.ets 的任何调度逻辑后，必须同步更新本移植
//    并重新运行本测试——pre-commit hook 会在变更时强制执行：
//        node tests/single-flight-loop.test.mjs
//
// 覆盖语义（20 断言）：
//   基线：空闲周期触发且计时随轮重启 / stop 静止 / start 幂等
//   干扰：信号即时唤醒与来源透传 / 睡眠期合并 / 执行期丢弃不补跑 /
//         minGap 推迟 / 长轮次不叠加 / defer 窗口丢弃
//   极限：未启动信号风暴单飞行 / stop 后迟到信号保底单轮 / stop→start 重启
// =====================================================================
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const ETS_PATH = join(HERE, '..', 'wg_tunnel', 'src', 'main', 'ets', 'keepalive', 'SingleFlightLoop.ets');

// ---- 漂移哨兵：关键结构令牌缺失 = 移植已与源文件脱节，先同步再测 ----
const CANARY_TOKENS = [
  'class SingleFlightLoop',
  'awaitSignalOrTimeout',
  'settle',
  'pendingSource',
  'bootstrapRunning',
  'lastRoundEnd',
  'minRoundGap',
  'wakeWaiter',
  "this.waiter = { settle: settle }",
];
const etsSource = readFileSync(ETS_PATH, 'utf-8');
const missing = CANARY_TOKENS.filter((t) => !etsSource.includes(t));
if (missing.length > 0) {
  console.error(`[漂移哨兵] SingleFlightLoop.ets 缺少令牌: ${JSON.stringify(missing)}`);
  console.error('[漂移哨兵] 源文件调度逻辑可能已重构，请先同步更新本测试的移植类再运行。');
  process.exit(1);
}

// ---- 移植类（保持与 .ets 逐行等价，仅去类型/LLog） ----
const LLog = { info: () => {}, warn: () => {}, error: () => {} };

class SingleFlightLoop {
  #round; #maxWaitInterval; #minRoundGap;
  #running = false; #started = false;
  #waiter = undefined; #lastRoundEnd = 0;
  #pendingSource = '';
  #bootstrapRunning = false;
  constructor(round, maxWaitInterval = 60000, minRoundGap = 3000) {
    this.#round = round; this.#maxWaitInterval = maxWaitInterval; this.#minRoundGap = minRoundGap;
  }
  start() {
    if (this.#started) return;
    this.#started = true; this.#running = true;
    this.#runLoop();
  }
  stop() {
    if (!this.#started) return;
    this.#started = false; this.#running = false;
    this.#pendingSource = '';
    this.#wakeWaiter('timeout');
  }
  signal(source) {
    if (!this.#started) {
      if (this.#bootstrapRunning) { return; }   // 保底单轮执行中，丢弃
      this.#bootstrapRunning = true;
      this.#runOnce(source).finally(() => { this.#bootstrapRunning = false; });
      return;
    }
    this.#pendingSource = source;
    if (!this.#wakeWaiter('signal')) {
      this.#pendingSource = '';
    }
  }
  async #runLoop() {
    while (this.#running) {
      await this.#awaitSignalOrTimeout(this.#maxWaitInterval);
      if (!this.#running) break;
      const source = this.#pendingSource !== '' ? this.#pendingSource : 'idle';
      this.#pendingSource = '';
      await this.#runOnce(source);
    }
  }
  async #runOnce(source) {
    const sinceLast = Date.now() - this.#lastRoundEnd;
    if (this.#lastRoundEnd > 0 && sinceLast < this.#minRoundGap) {
      await this.#sleep(this.#minRoundGap - sinceLast);
      if (!this.#running) return;
    }
    try { await this.#round(source); }
    catch (e) { /* isolated */ }
    finally { this.#lastRoundEnd = Date.now(); }
  }
  #awaitSignalOrTimeout(timeoutMs) {
    return new Promise((resolve) => {
      let done = false; let timer = 0;
      const settle = (reason) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        this.#waiter = undefined;
        resolve(reason);
      };
      timer = setTimeout(() => settle('timeout'), timeoutMs);
      this.#waiter = { settle };
    });
  }
  #wakeWaiter(reason) {
    const waiter = this.#waiter;
    if (waiter === undefined) return false;
    this.#waiter = undefined;
    waiter.settle(reason);
    return true;
  }
  #sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }
}

// ---- 断言设施 ----
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let passed = 0, failed = 0;
function assert(cond, msg) {
  if (cond) { passed++; console.log(`  PASS ${msg}`); }
  else { failed++; console.log(`  FAIL ${msg}`); }
}

// ============ 基础语义 ============
{
  console.log('T1 定时触发/计时随轮重启（未干扰基线）');
  const rounds = [];
  const loop = new SingleFlightLoop(async (src) => { rounds.push({ src, t: Date.now() }); }, 200, 50);
  loop.start();
  await sleep(700);
  loop.stop();
  assert(rounds.length >= 3 && rounds.length <= 4, `700ms/200ms 周期触发 ${rounds.length} 轮`);
  assert(rounds.every((r) => r.src === 'idle'), '全部轮次 source=idle');
  let ok = true;
  for (let i = 1; i < rounds.length; i++) if (rounds[i].t - rounds[i-1].t < 180) ok = false;
  assert(ok, '相邻轮间隔≥180ms（计时从上一轮结束起算）');
}
{
  console.log('T2 信号即时唤醒与来源透传');
  const rounds = [];
  const loop = new SingleFlightLoop(async (src) => { rounds.push(src); }, 5000, 10);
  loop.start();
  await sleep(50);
  loop.signal('switchOn');
  await sleep(80);
  loop.stop();
  assert(rounds.length === 1 && rounds[0] === 'switchOn', `唤醒一轮且 source 正确（${JSON.stringify(rounds)}）`);
}
{
  console.log('T3 睡眠期信号合并');
  let rounds = 0;
  const loop = new SingleFlightLoop(async () => { rounds++; }, 5000, 10);
  loop.start();
  await sleep(30);
  for (let i = 0; i < 10; i++) loop.signal('s' + i);
  await sleep(100);
  loop.stop();
  assert(rounds === 1, `10 个信号合并为 ${rounds} 轮`);
}
{
  console.log('T4 执行期信号丢弃 + 下一轮时间计算');
  const rounds = [];
  let release;
  const gate = new Promise((r) => { release = r; });
  const loop = new SingleFlightLoop(async (src) => {
    rounds.push(src);
    if (src === 'switchOn') await gate;
  }, 200, 10);
  loop.start();
  await sleep(30);
  loop.signal('switchOn');
  await sleep(60);
  loop.signal('mid');
  await sleep(30);
  assert(rounds.length === 1 && rounds[0] === 'switchOn', '执行期轮只跑一次且 source 正确');
  release();
  await sleep(60);
  assert(rounds.length === 1, '执行期信号被丢弃不补跑');
  await sleep(220);
  assert(rounds.length === 2 && rounds[1] === 'idle', `下一轮=本轮结束+maxWait（${JSON.stringify(rounds)}）`);
  loop.stop();
}
{
  console.log('T5 最小执行间隔推迟');
  const times = [];
  const loop = new SingleFlightLoop(async () => { times.push(Date.now()); }, 5000, 150);
  loop.start();
  await sleep(20);
  loop.signal('a');
  await sleep(60);
  loop.signal('b');
  await sleep(220);
  loop.stop();
  assert(times.length === 2, `共 ${times.length} 轮`);
  if (times.length === 2) assert(times[1] - times[0] >= 140, `两轮间隔 ${times[1] - times[0]}ms ≥ minGap 下限`);
}

// ============ 极限/边界事件 ============
{
  console.log('T10 [极限] 未启动状态信号风暴 → 单飞行');
  let rounds = 0;
  const loop = new SingleFlightLoop(async (src) => {
    await sleep(30);   // 保底轮含 await 空窗，风暴信号在空窗内到达
    rounds++;
  }, 5000, 10);
  for (let i = 0; i < 10; i++) loop.signal('storm' + i);   // 未启动，10 连发
  await sleep(150);
  assert(rounds === 1, `信号风暴仅执行 ${rounds} 轮（并发注册缺陷回归）`);
}
{
  console.log('T11 [极限] stop 后迟到的信号 → 恰好一轮保底且不进周期');
  const rounds = [];
  const loop = new SingleFlightLoop(async (src) => { rounds.push(src); }, 100, 10);
  loop.start();
  await sleep(150);
  loop.stop();
  const before = rounds.length;
  loop.signal('late');
  await sleep(300);
  assert(rounds.length === before + 1 && rounds[rounds.length - 1] === 'late',
    `stop 后迟到信号保底一轮（${JSON.stringify(rounds)}）`);
  assert(rounds.length === before + 1, '保底后不进入周期轮询');
}
{
  console.log('T12 [极限] start 重复调用幂等');
  let rounds = 0;
  const loop = new SingleFlightLoop(async () => { rounds++; }, 100, 10);
  loop.start();
  loop.start();
  loop.start();
  await sleep(450);
  loop.stop();
  assert(rounds >= 3 && rounds <= 5, `三重 start 仍为单循环节奏（${rounds} 轮，翻倍则为幂等失效）`);
}
{
  console.log('T13 [极限] stop → start 重启恢复周期');
  let rounds = 0;
  const loop = new SingleFlightLoop(async () => { rounds++; }, 100, 10);
  loop.start();
  await sleep(150);
  loop.stop();
  const atStop = rounds;
  await sleep(150);
  assert(rounds === atStop, 'stop 后静止');
  loop.start();
  await sleep(350);
  loop.stop();
  assert(rounds >= atStop + 2, `重启后周期恢复（${atStop} → ${rounds}）`);
}
{
  console.log('T14 [极限] 单轮执行时长超过 maxWait → 不叠加轮次');
  const times = [];
  const loop = new SingleFlightLoop(async () => {
    times.push(Date.now());
    await sleep(250);   // 轮时长 250ms > maxWait 100ms
  }, 100, 10);
  loop.start();
  await sleep(800);
  loop.stop();
  assert(times.length === 2, `长轮次不产生叠加（${times.length} 轮，错误实现会 4-5 轮）`);
  if (times.length === 2) assert(times[1] - times[0] >= 340, `下一轮=轮结束+maxWait（间隔 ${times[1] - times[0]}ms）`);
}
{
  console.log('T15 [极限] minGap 推迟睡眠窗口内到达的信号 → 丢弃且推迟轮照常执行');
  const rounds = [];
  const times = [];
  const loop = new SingleFlightLoop(async (src) => {
    rounds.push(src);
    times.push(Date.now());
  }, 5000, 200);
  loop.start();
  await sleep(20);
  loop.signal('a');          // t≈20 轮1
  await sleep(30);           // t≈50：唤醒落账 b，runOnce 进入 defer 睡眠
  loop.signal('b');
  await sleep(50);           // t≈100：defer 睡眠窗口内
  loop.signal('c');          // t≈100：waiter 未挂 → 应丢弃
  await sleep(250);          // t≈350
  loop.stop();
  assert(rounds.length === 2 && rounds[0] === 'a' && rounds[1] === 'b',
    `defer 窗口信号丢弃，推迟轮照常执行且来源正确（${JSON.stringify(rounds)}）`);
  if (rounds.length === 2) assert(times[1] - times[0] >= 190, `推迟轮距上轮 ${times[1] - times[0]}ms ≥ minGap`);
}

console.log(`\n===== ${passed} passed, ${failed} failed =====`);
process.exit(failed > 0 ? 1 : 0);
