export const NATIVE_TOOLS_VERSION: string = '0.1.1';
export {
  LOCAL_DOCUMENT_MAX_BYTES, LocalDocumentError, DocumentRecord, DocumentReceipt, DocumentCatalogSnapshot,
  DocumentCatalogPort, DocumentBlobPort, DocumentWriteRequest, LocalDocumentResult, LocalDocumentOperationStatus
} from './src/main/ets/documents/DocumentContracts';
export { LocalDocumentStore, documentTextBytes } from './src/main/ets/documents/LocalDocumentStore';
export { OhosDocumentBlobStore, RdbDocumentCatalog, SystemNativeDocumentDigest } from './src/main/ets/documents/OhosDocumentStorage';
export { NativeDocumentToolAdapter, NativeDocumentTools, NATIVE_DOCUMENT_CAPABILITY } from './src/main/ets/documents/NativeDocumentTools';
export { createOhosNativeDocumentTools, OhosNativeDocumentToolSet } from './src/main/ets/documents/OhosDocumentComposition';
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
