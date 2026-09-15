/*
 * 【本地补齐的最小 stub —— 请勿当成改动集的一部分】
 *
 * 上游 master 与本改动集都没有 EnvConfig.ets，但改动后的
 * wg_ui/src/main/ets/view/ShareConfigView.ets 会 `import { IS_DEBUG } from '../EnvConfig'`，
 * 缺它整个 wg_ui 模块无法编译（Rollup Error 00305015 / ArkTS 10505001）。
 *
 * IS_DEBUG 在改动集里只有一处使用：
 *   if (IS_DEBUG && this.vm.developerMode && this.vm.debugShareInfos.length > 0) { … }
 * 即仅用于开关"调试分享信息"区块，且该区块另有 developerMode 条件。
 * 因此这里取 false（关闭调试区块）是行为安全的选择。
 *
 * 若拿到原文件，请直接覆盖本文件。
 */
export const IS_DEBUG: boolean = false;
