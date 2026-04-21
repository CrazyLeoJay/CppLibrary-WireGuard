import { AbilityStage } from '@kit.AbilityKit';
import { WireGuard } from 'wg_tunnel';

/**
 * @author leojay`fu
 */
export default class MyWGAbilityStage extends AbilityStage {
  onCreate(): void {
    WireGuard.init(this.context)
  }

  onDestroy(): void {
    WireGuard.destroy(this.context)
  }
}