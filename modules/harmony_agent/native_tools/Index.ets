export const NATIVE_TOOLS_VERSION: string = '0.1.1';
export {
  NativePermissionState,
  NativeToolErrorCode,
  NativeToolError,
  NativeDigestPort,
  NativeClockPort,
  NativeCapabilityProbePort,
  NativeExecutionEnvironmentPort,
  NativeGrantVerifierPort,
  NativeCancellationSignalPort,
  NativeCancellationResolverPort,
  NativeToolOutcomeSinkPort,
  NativeToolAdapter,
  BatteryStatusSnapshot,
  BatteryStatusPort
} from './src/main/ets/native/NativeToolContracts';
export {
  nativeCanonicalJson,
  parseNativeArguments,
  copyNativeToolEntry,
  SystemNativeCapabilityProbe,
  SystemNativeClock
} from './src/main/ets/native/NativeToolSupport';
export { NativeStepDispatchAdapter } from './src/main/ets/native/NativeStepDispatchAdapter';
export {
  BATTERY_STATUS_TOOL_ID,
  BATTERY_STATUS_CAPABILITY,
  BATTERY_STATUS_VERSION,
  SystemBatteryStatusPort,
  BatteryStatusToolAdapter
} from './src/main/ets/native/BatteryStatusTool';
