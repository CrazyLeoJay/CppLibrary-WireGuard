# ArkTS 本地单元测试（Hypium LocalUnit）

## single-flight-loop：SingleFlightLoop 行为测试

被测对象为**真实源文件** `wg_tunnel/src/main/ets/keepalive/SingleFlightLoop.ets`
（保活检查与通知发布的共用调度器，单飞行信号循环）。

- 测试用例：`wg_tunnel/src/test/SingleFlightLoop.test.ets`（注册于同目录 `List.test.ets`）
- 依赖处理：`@ohos.hilog`（LLog 的底层）在本地测试环境不可用，经
  `wg_tunnel/src/mock/mock-config.json5` 在测试构建期替换为 `src/mock/Hilog.mock.ets` 空实现
- 无需设备/模拟器，本地直接运行（LocalUnit）

## 运行

```bash
sh platform-harmonyos/tests/run-local-unit-test.sh
```

或直接使用 hvigor 命令（工程根 = `platform-harmonyos/`，需 `DEVECO_SDK_HOME`）：

```bash
hvigorw test -p module=wg_tunnel -p coverage=false
```

⚠️ hvigor 在用例失败时退出码仍可能为 0，**以结果文件为准**：
`wg_tunnel/.test/default/intermediates/test/coverage_data/test_result.txt`（`Tests run: ..., Failure: 0` 才算通过）。

## 覆盖语义（11 用例 / 20+ 断言）

| 分组 | 用例 | 语义 |
|---|---|---|
| 基线（未干扰） | T1 | 空闲周期触发，计时从每轮结束重新起算，来源恒为 idle |
| | T11/T12/T13 | stop 后迟到信号保底单轮 / start 幂等 / stop→start 重启 |
| 干扰 | T2 | 信号即时唤醒，source 透传到执行轮 |
| | T3 | 睡眠期 N 个信号合并为 1 轮 |
| | T4 | 执行期信号丢弃不补跑，下一轮 = 本轮结束 + maxWait |
| | T5 | 距上轮结束不足 minGap 的唤醒推迟到满间隔 |
| | T14 | 轮时长 > maxWait 不叠加轮次 |
| | T15 | minGap 推迟睡眠窗口内的信号丢弃，推迟轮照常执行 |
| 极限 | T10 | 未启动状态信号风暴仍单飞行（bootstrap 互斥回归） |

本地引擎定时器精度低于 Node，T1 断言"轮数 ≥ 2"而非具体轮数；间隔断言（≥ maxWait/minGap 下限）承担"计时随轮重启"的精确校验。

## 输出结构（每个用例自解释）

`run-local-unit-test.sh` 在测试结束后从 runner 日志（`coverage.log`）提取行为明细：

```
[T4] ===== 干扰-执行期信号：丢弃不补跑，下一轮=本轮结束+maxWait =====   ← 测什么
[T4] 参数: maxWait=200ms, minGap=10ms                                  ← 参数
[T4] 流程: start → 30ms后signal(switchOn，轮内人为挂起) → …            ← 步骤
[T4] 实测(执行中): 来源=["switchOn"]（switchOn轮挂起中）               ← 阶段性实测值
[T4] 实测(计时后): 来源=["switchOn","idle"]（下一轮应为idle，…）
[T4] ✓ 通过: 执行期丢弃 + 下一轮从本轮结束重新计时                     ← 行为级通过标记
```

断言全部失败即用例失败，`Assert.message()` 携带具体原因（期望/实际/语义），
结果文件失败块格式：`message: <原因>, Error in <用例>, expect X equals Y` + 堆栈；
脚本失败时单独打印"失败原因"块并以非零码退出。

## 强制保障（pre-commit hook）

`pre-commit` 检测到暂存区包含 `SingleFlightLoop.ets`、`wg_tunnel/src/test/` 或本目录变更时，
自动调用 `run-local-unit-test.sh`，失败则阻止提交。hook 安装在本仓库 git 公共目录
（两个 worktree 共享），重新克隆后需重新安装：

```bash
cp platform-harmonyos/tests/pre-commit "$(git rev-parse --git-common-dir)/hooks/pre-commit"
chmod +x "$(git rev-parse --git-common-dir)/hooks/pre-commit"
```

临时跳过（不建议）：`git commit --no-verify`。

## 约定

**修改 `SingleFlightLoop.ets` 的任何调度逻辑，必须先跑本测试且全绿后才能提交。**
扩展调度行为时同步新增用例。文档检索可用 `devecocli docs search "单元测试"` /
`devecocli docs read <documentId>`（Local Test、Mock 能力等官方文档已本地化）。

## ohosTest（设备侧测试）

`wg_tunnel/src/ohosTest` 与 `entry/src/ohosTest` 为设备/模拟器上的 Instrument Test
目录（需连接设备，`hvigorw onDeviceUnitTest` 或 DevEco Studio 运行）。本调度器的
纯逻辑语义由 LocalUnit 覆盖；涉及系统能力（backgroundTaskManager 回收、通知锚点等）
的平台行为验证仍走真机回归清单。
