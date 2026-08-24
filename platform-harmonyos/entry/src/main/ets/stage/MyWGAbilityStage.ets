import { AbilityStage } from '@kit.AbilityKit';
import { LLog, WireGuard } from 'wg_tunnel';

const TAG = "AbilityStage"

/**
 * 应用级AbilityStage - 应用进程启动的最早入口
 *
 * @author leojay`fu
 */
export default class MyWGAbilityStage extends AbilityStage {
  onCreate(): void {
    // 初始化数据库（必须在所有数据库操作之前完成）
    WireGuard.init(this.context)

    // ===== 应用进程启动时：同步VPN进程状态 + 检测自动重连 =====
    // 覆盖场景：应用进程被系统完全杀死后重新启动（此时onForeground不会触发，需要在这里检测）
    //
    // 步骤1：发送查询广播，如果VPN Extension在运行，VPN进程会回复最新状态
    // 主应用进程的 subscribeVpnChange → syncFromVpnProcess 会自动同步
    WireGuard.event.publishVpnStatusQuery();

    // 步骤2：检测是否需要自动重连
    // shouldAutoReconnect 内部会先检测VPN Extension是否在运行
    WireGuard.shouldAutoReconnect().then((shouldReconnect: boolean) => {
      if (shouldReconnect) {
        LLog.info(TAG, '应用启动时检测到VPN需要自动重连，开始重连...');
        WireGuard.tryReconnectVpn().then((success: boolean) => {
          if (success) {
            LLog.info(TAG, '应用启动时VPN自动重连成功');
          } else {
            LLog.error(TAG, '应用启动时VPN自动重连失败');
          }
        }).catch((e: BusinessError) => {
          LLog.error(TAG, `应用启动时VPN自动重连异常: ${e.message}`);
        });
      }
    }).catch((e: BusinessError) => {
      LLog.error(TAG, `应用启动时VPN自动重连检测异常: ${e.message}`);
    });
  }

  onDestroy(): void {
    WireGuard.destroy(this.context)
  }
}