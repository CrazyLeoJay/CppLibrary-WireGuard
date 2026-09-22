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
import { deviceInfo } from '@kit.BasicServicesKit';
import { uiMaterial } from '@kit.ArkUI';

/**
 * 沉浸光感材质助手（HarmonyOS 7 / API 26 新能力）
 *
 * 运行时按 sdkApiVersion 门控：API 26 以下的系统返回 undefined——
 * systemMaterial 属性签名为 (material: Material | undefined)，传 undefined
 * 时旧框架直接忽略该属性，原背景色保持不变，不产生视觉回退；
 * 同时短路保证旧系统不会触碰 uiMaterial 命名空间（避免 new 缺失类崩溃）。
 *
 * 【接入必读（官方FAQ）】沉浸材质的视觉层级位于 backgroundColor 之下：
 * 启用材质的组件必须把背景色设为透明/移除，纯色背景会盖在材质层之上
 * 导致材质不可见。薄材质（ULTRA_THIN/THIN）有折射边框特性，内容型
 * 容器建议 REGULAR 及以上保证可读性。
 */

/** 当前运行时是否支持沉浸光感（API 26+） */
export function supportsImmersiveMaterial(): boolean {
  return deviceInfo.sdkApiVersion >= 26;
}

/**
 * 弹窗/面板常规材质：REGULAR 常规厚度，通用场景默认档，
 * 自带背景层次且降低薄材质的折射边框，对文字可读性最稳。
 */
export function panelMaterial(): uiMaterial.Material | undefined {
  if (!supportsImmersiveMaterial()) {
    return undefined;
  }
  return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.REGULAR });
}

/**
 * 弹窗材质：ULTRA_THICK 超厚档（官方弹窗推荐档），模糊最强，内容可读性最高。
 * 注意：材质视觉在 backgroundColor 之下，启用方须把背景设为透明；
 * applyShadow=false 保留调用方自定义 shadow（材质自带阴影会覆盖通用 shadow）。
 */
export function dialogMaterial(): uiMaterial.Material | undefined {
  if (!supportsImmersiveMaterial()) {
    return undefined;
  }
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THICK,
    applyShadow: false,
  });
}

/** 菜单材质：THICK 厚档（官方菜单推荐档），bindMenu 等弹出菜单用 */
export function menuMaterial(): uiMaterial.Material | undefined {
  if (!supportsImmersiveMaterial()) {
    return undefined;
  }
  return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THICK });
}

/**
 * 卡片材质：REGULAR 常规档 + 可选交互形变/光感流光。
 * 列表卡片、设置分组等静态内容面用默认；可点按的入口卡片开 interactive。
 */
export function cardMaterial(interactive: boolean = false, lightEffect: boolean = false)
  : uiMaterial.Material | undefined {
  if (!supportsImmersiveMaterial()) {
    return undefined;
  }
  if (lightEffect) {
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.REGULAR,
      interactive: true,
      lightEffect: { color: undefined },
    });
  }
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.REGULAR,
    interactive: interactive,
  });
}

/**
 * 浮动控件材质：ULTRA_THIN 超薄档（官方浮动工具推荐档）+ 按压弹性形变 +
 * 光感流光。FAB、悬浮工具条等小面积浮动件用；薄材质折射边框明显，
 * 内容型容器勿用（可读性用 cardMaterial）。
 */
export function floatingMaterial(lightEffect: boolean = true): uiMaterial.Material | undefined {
  if (!supportsImmersiveMaterial()) {
    return undefined;
  }
  if (lightEffect) {
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      interactive: true,
      lightEffect: { color: undefined },
    });
  }
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    interactive: true,
  });
}

/**
 * 悬浮球材质：ULTRA_THIN 玻璃感 + 半透明深色赋色（materialColor 需带透明度，
 * 纯不透明会盖死材质）保证白色图标在浅色背景上的对比度 + 按压形变 + 光感流光。
 * 低算力设备 materialColor 自动转为背景色（≈深色圆盘），观感平滑降级。
 */
export function ballMaterial(): uiMaterial.Material | undefined {
  if (!supportsImmersiveMaterial()) {
    return undefined;
  }
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    materialColor: '#B3303034',
    interactive: true,
    lightEffect: { color: undefined },
  });
}
