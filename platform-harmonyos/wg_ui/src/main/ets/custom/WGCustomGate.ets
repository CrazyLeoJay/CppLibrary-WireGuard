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
import { UIContext } from '@ohos.arkui.UIContext';

/**
 * 定制功能门面（依赖倒置）：核心 wg_ui 不依赖闭源 wg_custom 模块，
 * 由 wg_custom 在模块加载时调用 registerFloatBallGate 注册实现——
 * - 开源构建：未注册，悬浮球入口不渲染、开关恒关，核心独立编译运行
 * - 闭源构建：已注册，设置页悬浮球开关恢复完整功能（含权限申请/挂起补开）
 */
export interface FloatBallGate {
  /** 悬浮球当前是否开启（持久化配置） */
  isEnabled(): boolean;

  /**
   * 切换悬浮球：交互全部内聚在实现侧（关闭 toast / 权限申请挂起 /
   * 引导系统设置 / 异常提示），settled 回调最终落定状态供调用方同步显示
   */
  toggle(context: UIContext, settled: (enabled: boolean) => void): void;

  /** 【debug】绕过开关直接拉起悬浮窗（无权限时 toast 回报） */
  debugShow(context: UIContext): void;
}

let floatBallGate: FloatBallGate | undefined = undefined;

/** 注册定制实现（wg_custom 模块加载时调用；重复注册以后者为准） */
export function registerFloatBallGate(gate: FloatBallGate): void {
  floatBallGate = gate;
}

/** 获取已注册实现；未注册（开源构建）返回 undefined */
export function getFloatBallGate(): FloatBallGate | undefined {
  return floatBallGate;
}
