export let IS_DEBUG: boolean = false;

/**
 * 由 Index.ets 在模块加载时调用，将 Hvigor 生成的 BuildProfile.DEBUG 值注入到此模块内部。
 *
 * 原因：Hvigor 的 Rollup 打包器编译范围仅限 src/main/ets/ 目录，
 * 内部源码无法通过相对路径向上引用模块根目录的 BuildProfile.ets（会报 Could not resolve）。
 * 只有模块入口 Index.ets 具有特殊权限，可以直接引用同级 BuildProfile.ets。
 * 因此通过此桥接函数，由 Index.ets 读取 BuildProfile.DEBUG 并注入到 IS_DEBUG，
 * 供内部源文件使用。
 */
export function setDebugMode(debug: boolean): void {
  IS_DEBUG = debug;
}
