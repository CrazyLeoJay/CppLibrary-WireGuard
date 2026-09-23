/*
 * Copyright [2026] @github-crazyleojay (crazyleojay@163.com/gmail.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import { common } from '@kit.AbilityKit';
import { WGSettingsPrefs } from 'wg_tunnel';
import BuildProfile from '../../../../BuildProfile';

/**
 * 定制功能装配注册表（依赖倒置，付费隔离点）：
 *
 * 核心（entry/wg_ui/wg_tunnel）不 import 任何具体定制模块，只认识这里的
 * 两个通用注册表。定制模块（wg_custom）在自身模块加载时向注册表装配实现：
 * - 开源/免费构建：不含定制模块 → 注册表为空 → 定制区块不渲染、生命周期
 *   分发为空操作，核心独立编译运行；
 * - 付费构建：定制模块随 entry 一行 `import 'wg_custom'` 装配生效。
 * 后续新增定制能力只扩展注册表契约，核心业务代码不再感知具体功能。
 */

// ==================== 付费功能总开关（多渠道target + debug调试设置） ====================

/** 渠道付费开关（EntryAbility.onCreate 从 target 资源覆盖读出后注入） */
let channelPaidEnabled: boolean | undefined = undefined;

/** 注入渠道付费开关（free target 资源覆盖=false；default/未注入 视为启用） */
export function setChannelPaidEnabled(enabled: boolean): void {
  channelPaidEnabled = enabled;
}

/**
 * 付费（定制）功能是否启用：
 * release 恒启用；debug 构建下 = 非 free 渠道 且
 * debug 调试设置「启用付费功能」未关闭。
 */
export function isCustomFeaturesEnabled(): boolean {
  if (!BuildProfile.DEBUG) {
    return true;
  }
  if (channelPaidEnabled === false) {
    return false;
  }
  return WGSettingsPrefs.getCustomFeaturesEnabled();
}

/** 设置调试期付费功能开关（持久化；仅 debug 构建可关） */
export function setCustomFeaturesEnabled(enabled: boolean): void {
  WGSettingsPrefs.setCustomFeaturesEnabled(enabled);
}

// ==================== 应用生命周期钩子 ====================

/**
 * 定制模块的生命周期钩子（全部可选，定制侧只实现需要的）。
 * 由 entry 的 UIAbility 在对应时机分发；分发逐个隔离异常，单个钩子失败不影响其它。
 */
export interface AppLifecycleHooks {
  /** UIAbility.onCreate：绑定上下文、初始化定制模块（幂等） */
  onAppCreate?(ctx: common.UIAbilityContext): void;
  /** 主窗口 loadContent 完成且 uiContext 就绪：按需上屏悬浮球等窗口类功能 */
  onMainWindowReady?(): void;
  /** 应用回到前台 */
  onAppForeground?(): void;
  /** 应用退后台 */
  onAppBackground?(): void;
  /** UIAbility.onWindowStageDestroy */
  onAppDestroy?(): void;
  /** 付费功能开关变化（仅debug构建会触发false）：定制侧即时停用/恢复自身功能 */
  onFeaturesEnabledChanged?(enabled: boolean): void;
}

const lifecycleHooks: AppLifecycleHooks[] = [];
/** onCreate分发的上下文（关闭状态下跳过分发也要存着，重开后补分发实现即时生效） */
let storedCreateCtx: common.UIAbilityContext | undefined = undefined;
let createDispatched: boolean = false;

/** 注册生命周期钩子（定制模块加载时调用；重复注册以追加处理，定制侧自行保证幂等） */
export function registerAppLifecycleHooks(hooks: AppLifecycleHooks): void {
  lifecycleHooks.push(hooks);
}

function dispatchSafely(invoker: (hooks: AppLifecycleHooks) => void): void {
  if (!isCustomFeaturesEnabled()) {
    return;
  }
  lifecycleHooks.forEach((hooks) => {
    try {
      invoker(hooks);
    } catch (e) {
      // 单个定制钩子异常不阻断主应用与其余钩子
    }
  });
}

/** 分发 onCreate（EntryAbility.onCreate 调用） */
export function dispatchAppCreate(ctx: common.UIAbilityContext): void {
  storedCreateCtx = ctx;
  if (!isCustomFeaturesEnabled()) {
    // 关闭状态冷启动：不分发（等同免费构建），重开时由onFeaturesEnabledChanged补发
    return;
  }
  createDispatched = true;
  dispatchSafely((h) => h.onAppCreate?.(ctx));
}

/** 分发主窗口就绪（loadContent 成功回调内调用） */
export function dispatchMainWindowReady(): void {
  dispatchSafely((h) => h.onMainWindowReady?.());
}

/** 分发回前台（EntryAbility.onForeground 调用） */
export function dispatchAppForeground(): void {
  dispatchSafely((h) => h.onAppForeground?.());
}

/** 分发退后台（EntryAbility.onBackground 调用） */
export function dispatchAppBackground(): void {
  dispatchSafely((h) => h.onAppBackground?.());
}

/** 分发销毁（EntryAbility.onWindowStageDestroy 调用） */
export function dispatchAppDestroy(): void {
  dispatchSafely((h) => h.onAppDestroy?.());
}

/**
 * 分发付费功能开关变化（调试设置切换时调用；不受开关门控——它就是开关通知本身）。
 * 重开为启用时，若本会话尚未分发过onCreate（冷启动时处于关闭态），先补发onCreate
 * 让定制模块完成attach，使恢复无需重启应用。
 */
export function dispatchFeaturesEnabledChanged(enabled: boolean): void {
  if (enabled && !createDispatched && storedCreateCtx != undefined) {
    createDispatched = true;
    const ctx = storedCreateCtx;
    lifecycleHooks.forEach((hooks) => {
      try {
        hooks.onAppCreate?.(ctx);
      } catch (e) {
        // 同dispatchSafely，逐个隔离
      }
    });
  }
  lifecycleHooks.forEach((hooks) => {
    try {
      hooks.onFeaturesEnabledChanged?.(enabled);
    } catch (e) {
      // 逐个隔离
    }
  });
}

// ==================== 定制窗口内容注册表 ====================

/**
 * 悬浮窗等定制窗口的内容注册：main_pages 是 HAP 级页面表无法按包合并，
 * entry 仅保留通用宿主页（pages/WindowHost），定制模块注册内容 builder，
 * 宿主页渲染之——main_pages 不出现任何定制页面名。
 */

/** 窗口内容 builder 入参（预留扩展位；内容组件目前自包含） */
export interface CustomWindowContentArg {
}

let windowContentBuilder: WrappedBuilder<[CustomWindowContentArg]> | undefined = undefined;

/** 注册定制窗口内容（定制模块加载时调用；后注册覆盖前者） */
export function registerWindowContent(builder: WrappedBuilder<[CustomWindowContentArg]>): void {
  windowContentBuilder = builder;
}

/** 读取窗口内容（免费构建/未注册返回undefined，宿主页渲染为空） */
export function getWindowContentBuilder(): WrappedBuilder<[CustomWindowContentArg]> | undefined {
  return windowContentBuilder;
}

// ==================== 设置页自定义区块 ====================

/** 区块 builder 入参（预留扩展位；区块组件目前自包含，无需外部状态） */
export interface CustomSectionArg {
}

/**
 * 设置页自定义区块：定制模块向设置页贡献一组 ListItem/ListItemGroup。
 * builder 必须是全局 @Builder（wrapBuilder 包装），内容自渲染含卡片样式。
 */
export interface CustomSettingsSection {
  /** 去重/渲染 key */
  id: string;
  /** 排序权重，小者在前 */
  order: number;
  /** 是否渲染（每次页面构建时求值，可做 debug 构建判断等） */
  visible(): boolean;
  builder: WrappedBuilder<[CustomSectionArg]>;
  /** 设置页重新可见（含从系统设置授权返回）：同步区块内部状态用 */
  onShown?(): void;
}

const settingsSections: CustomSettingsSection[] = [];

/** 注册设置页区块（定制模块加载时调用；同 id 重复注册以最后者为准） */
export function registerCustomSettingsSection(section: CustomSettingsSection): void {
  const idx = settingsSections.findIndex((it) => it.id === section.id);
  if (idx >= 0) {
    settingsSections[idx] = section;
  } else {
    settingsSections.push(section);
  }
}

/** 读取已注册区块（按 order 升序的副本；未注册定制或付费开关关闭时为空数组） */
export function getCustomSettingsSections(): CustomSettingsSection[] {
  if (!isCustomFeaturesEnabled()) {
    return [];
  }
  return [...settingsSections].sort((a, b) => a.order - b.order);
}
