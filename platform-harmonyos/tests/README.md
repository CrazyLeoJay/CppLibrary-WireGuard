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

## 用例组织（21 个行为级用例）

**同一场景的多条行为断言拆分为独立 `it`，用例名 = 被验证的行为**——DevEco Studio
测试面板的用例树本身就是"验证了哪些行为"的清单（每个 ✓ 对应一条被验证的行为），
失败时面板直接显示该行为用例的 `Assert.message` 原因（期望/实际/语义）。
同组 it 复用同一场景函数（确定性时序，各 it 独立重跑场景，总耗时约 15s）。

| 分组 | 用例（树中可见） | 验证的行为 |
|---|---|---|
| T1 基线 | a/b/c | 空闲周期持续触发≥2轮 / 来源恒为idle / 相邻轮间隔从上一轮结束重新起算 |
| T2 睡眠期信号 | a/b | 恰执行一轮 / 来源透传switchOn |
| T3 | — | 睡眠期10个信号合并为1轮 |
| T4 执行期信号 | a/b/c | 执行期仅挂起轮在跑 / mid信号丢弃不补跑 / 下一轮idle于轮结束+maxWait触发 |
| T5 不足minGap | a/b | 恰两轮 / 推迟轮间隔≥minGap下限 |
| T10 未启动风暴 | — | 10连发仍单飞行（bootstrap互斥回归） |
| T11 stop后迟到信号 | a/b | 保底恰一轮且来源late / 不进入周期轮询 |
| T12 | — | start三重调用仍单循环节奏 |
| T13 | a/b | stop后完全静止 / 重新start周期恢复 |
| T14 长轮次 | a/b | 轮时长>maxWait不叠加 / 下一轮=轮结束+maxWait |
| T15 defer窗口 | a/b | 窗口内信号丢弃、推迟轮照常执行 / 间隔≥minGap下限 |

本地引擎定时器精度低于 Node，T1 轮数断言写"≥2"；间隔断言（≥ maxWait/minGap 下限）承担"计时随轮重启"的精确校验。

### 输出去向（重要）

- **DevEco Studio 测试面板**：显示用例树（21 项行为 ✓/✗）+ 失败时的 message 原因。
  **用例内的 console 输出不会显示在面板上**——LocalUnit runner 将其重定向至
  coverage.log，属框架行为。
- **阶段性流程输出**（每场景的参数/实测值）：位于
  `wg_tunnel/.test/default/intermediates/test/coverage_data/coverage.log`
  （IDE 中可直接打开该文件），或运行 `run-local-unit-test.sh` 在终端查看提取后的
  行为明细（各用例结果表 + 行为明细 + 汇总，失败时单独打印失败原因块）。

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
