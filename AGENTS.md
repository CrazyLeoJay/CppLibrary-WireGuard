# wg-harmonyos 分支与修改流程规则

每次进入本项目做任何修改前，必须先按本规则路由分支。规则经用户确认（2026-09-24），变更需用户明确同意。

## 分支拓扑

| 分支 | 角色 | 是否可直接修改 |
|------|------|----------------|
| `master-cpp` | C/C++ 跨平台核心（native 源码、libwg_tunnel 等） | ✅ C 代码唯一修改点 |
| `harmony-app/open-core` | 鸿蒙开源核心 App（默认功能：entry、wg_ui、wg_tunnel、docs 等） | ✅ 默认 app 改动的唯一修改点 |
| `harmony-app/master-custom` | 定制/付费版壳（entry_custom、wg_custom 等） | ✅ 仅定制/付费功能，且须先合并 open-core |
| `master` | 开源发布分支 | ❌ 只接受合并，不直接修改 |

## 修改路由（先判断改什么，再选分支）

1. **App 默认功能**（鸿蒙 ArkTS / UI / HAR / 资源 / 构建脚本 / 文档）：
   在 `harmony-app/open-core` 修改并提交。
2. **定制-付费功能**：
   先把 `harmony-app/open-core` 合并入 `harmony-app/master-custom`（保证基线最新），
   然后在 `harmony-app/master-custom` 上修改提交。
3. **C/C++ 代码**：
   必须在 `master-cpp` 修改提交，然后**依次合并**：
   `master-cpp` → `harmony-app/open-core` → `harmony-app/master-custom`。
4. **开源发布**：
   `master` 接受 `master-cpp` 与 `harmony-app/open-core` 的合并并进行开源
   （github 远端为开源发布目标；origin 为开发主远端）。

合并方向永远自下而上（cpp → open-core → custom；master 只收 cpp/open-core）。
禁止把 custom 的定制内容反向带入 open-core / master-cpp / master。

## 操作要点

- 跨分支搬运改动前，先 `git diff <分支A> <分支B> -- <目标路径>` 确认目标文件在两分支无差异，
  再用 stash/apply 或补丁方式搬运，避免冲突。
- `wg_tunnel` 的 LocalUnit 单测由 pre-commit 钩子强制运行（`platform-harmonyos/tests/run-local-unit-test.sh`），
  提交前自动验证，失败不落库。
- 本文件属于全仓规则：修改后按「App 默认功能」路由，从 `harmony-app/open-core` 提交再合并至 `master-custom`。

## 未来平台扩展

后续若有其他平台开源（如 Android），沿用同一拓扑与流程，仅更换命名空间
（例如 `android-app/open-core`、`android-app/master-custom`；C 核心仍收敛在 `master-cpp`）。
