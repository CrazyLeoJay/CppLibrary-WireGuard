import { setDebugMode } from './src/main/ets/EnvConfig';
import { DEBUG } from './BuildProfile';

setDebugMode(DEBUG);

export { DEBUG, BUILD_MODE_NAME, HAR_VERSION, TARGET_NAME } from './BuildProfile';
export * from './src/main/ets/EnvConfig';
export * from './src/main/ets/model/WireGuardNav';
export * from './src/main/ets/view/WGMainView';
export * from './src/main/ets/view_model/WGMainViewModel';
export * from './src/main/ets/view/WGEditConfigView';
export * from './src/main/ets/view/WGSettingView';
export * from './src/main/ets/view/ShareConfigView';

