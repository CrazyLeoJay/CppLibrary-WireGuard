# BRANCHING — 分支模型与改动分类纪律

> **铁律：每次新增/修改功能，动手前先分类；不确定必须询问；开源与闭源永不同提交混合。**

## 三分支角色

| 分支 | 角色 | 远端 |
|---|---|---|
| `harmony-app/open-core` | **开源核心**：无悬浮球/桌面卡片。核心功能与 UI 的唯一开发线 | `github`（公开发布，只推此分支） |
| `harmony-app/master-custom` | **闭源开发主线**：open-core 全部内容 + `wg_custom`（悬浮球/卡片）+ entry 薄壳接线 | `origin` GitLab（私有） |
| `harmony-app/master-hw-agc-publish` | **AGC 发布分支**：签名信息所在地，不开源；发布时从 master-custom 合入 | `origin` GitLab（私有） |

历史锚点：`master-harmonyos` 保留不删（= 拆分前含悬浮球的旧主线）。

## 定制域清单（只有这些路径 = 定制改动）

- `platform-harmonyos/wg_custom/**`
- `entry/src/main/ets/pages/FloatBallPage.ets`
- `entry/src/main/ets/form/**`、`entry/src/main/ets/formability/**`
- `entry/src/main/module.json5` 的 form 扩展声明段与 `SYSTEM_FLOAT_WINDOW`/`PREPARE_APP_TERMINATE` 权限段
- `entry/src/main/resources/base/profile/form_config.json`、`main_pages.json` 的 FloatBallPage 条目
- entry 内指向 `wg_custom` 的 import 语句

**核心域** = 其余一切（wg_tunnel、wg_ui 核心页面与逻辑、entry 核心、构建配置等）。

## 判定规则

1. 只碰定制域 → 只提交到 `master-custom`
2. 只碰核心域 → 先提交到 `open-core`，再 merge 进 `master-custom`（闭源始终包含全部核心）
3. 一次改动同时碰两个域 → **必须拆成两个独立提交**（核心提交 / 定制提交），禁止混合提交
4. 归属不确定 → **停下来询问，不得自行假定**

## 修复流向

```
核心修复/UI调整：  open-core 提交 ──merge──▶ master-custom
定制修复(球/卡片)：master-custom 提交（限定制域，永不回流 open-core）
发版：            master-custom ──merge──▶ master-hw-agc-publish ──▶ AGC 签名构建
开源发布：        open-core ──push──▶ github
```

## 依赖方向（不可违反）

```
entry ──▶ wg_ui ──▶ wg_tunnel
entry ──▶ wg_custom ──▶ wg_ui + wg_tunnel
```

- wg_ui / wg_tunnel **禁止** import `wg_custom`（开源版无此模块）
- 核心需要暴露给定制的能力，走 wg_ui 的门面接口（见 `wg_ui/src/main/ets/custom/WGCustomGate.ets`：
  闭源在模块加载时 `registerFloatBallGate` 注册实现；开源未注册，入口自动隐藏）
- wg_ui/Index.ets 中为定制提供消费的核心导出（VpnToggleService / WGImmersiveMaterial / WGCustomGate）
  属于核心文件，两分支均保留
