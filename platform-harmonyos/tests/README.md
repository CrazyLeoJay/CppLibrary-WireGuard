# ArkTS 行为单元测试（Node 移植仿真）

## single-flight-loop.test.mjs

`wg_tunnel/src/main/ets/keepalive/SingleFlightLoop.ets`（单飞行信号循环，保活检查与通知发布的共用调度器）的行为测试。

**⚠️ 本测试是源文件的 1:1 逻辑移植**（去 ArkTS 类型与 LLog），不是直接 import 源文件——
ArkTS 依赖链（hilog 等）无法在 Node 中加载。因此约定：

1. **修改 `SingleFlightLoop.ets` 的任何调度逻辑，必须同步更新本测试的移植类**；
2. 修改后、提交前必须运行本测试并全部通过（pre-commit hook 会强制执行）；
3. 测试内置"漂移哨兵"：源文件关键结构令牌缺失时直接失败，提示移植已脱节。

## 运行

```bash
node tests/single-flight-loop.test.mjs        # 工作目录：platform-harmonyos/
```

要求：Node ≥ 18（使用了 private fields、top-level await）。

## 覆盖语义（20 断言 / 11 组用例）

| 分组 | 用例 | 语义 |
|---|---|---|
| 基线（未干扰） | T1 | 空闲周期触发，计时从每轮结束重新起算 |
| | T6/T12/T13 | stop 静止 / start 幂等 / stop→start 重启 |
| 干扰 | T2 | 信号即时唤醒，source 透传到执行轮 |
| | T3 | 睡眠期 N 个信号合并为 1 轮 |
| | T4 | 执行期信号丢弃不补跑，下一轮 = 本轮结束 + maxWait |
| | T5 | 距上轮结束不足 minGap 的唤醒推迟到满间隔 |
| | T14 | 轮时长 > maxWait 不叠加轮次 |
| | T15 | minGap 推迟睡眠窗口内的信号丢弃，推迟轮照常执行 |
| 极限 | T10 | 未启动状态信号风暴仍单飞行（bootstrap 互斥回归） |
| | T11 | stop 后迟到信号恰好一轮保底且不进周期 |

## pre-commit hook

`pre-commit` 检测到暂存区包含 `SingleFlightLoop.ets` 或本测试时，自动运行测试，
失败则阻止提交。hook 安装在本仓库的 git 公共目录（两个 worktree 共享），
重新克隆后需重新安装：

```bash
cp platform-harmonyos/tests/pre-commit "$(git rev-parse --git-common-dir)/hooks/pre-commit"
chmod +x "$(git rev-parse --git-common-dir)/hooks/pre-commit"
```

临时跳过（不建议）：`git commit --no-verify`。
