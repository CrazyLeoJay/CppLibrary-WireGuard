import { AbilityStage } from '@kit.AbilityKit';
import { LLog, WireGuard } from 'wg_tunnel';

const TAG = "AbilityStage"

/**
 * 应用级AbilityStage - 应用进程启动的最早入口
 *
 * 职责：
 * 1. 初始化数据库
 * 2. 销毁时清理资源
 *
 * VPN事件监听和长时任务管理已移至EntryAbility（backgroundTaskManager要求UIAbilityContext）。
 *
 * @author leojay`fu
 */
export default class MyWGAbilityStage extends AbilityStage {

  onCreate(): void {
    // 初始化数据库（必须在所有数据库操作之前完成）
    WireGuard.init(this.context)
    LLog.info(TAG, 'AbilityStage onCreate');
  }

  onDestroy(): void {
    WireGuard.destroy(this.context)
    LLog.info(TAG, 'AbilityStage onDestroy');
  }
}
