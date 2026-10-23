import deviceSmokeTest from './McpDeviceSmoke.test';
import storageDeviceRecoveryTest from './StorageDeviceRecovery.test';
import memoryDeviceRecoveryTest from './MemoryDeviceRecovery.test';
import batteryStatusDeviceTest from './BatteryStatusDevice.test';
import runtimeRdbDeviceRecoveryTest from './RuntimeRdbDeviceRecovery.test';
import localAIGatewayDeviceTest from './LocalAIGatewayDevice.test';
import mcpFacadeDeviceTest from './McpFacadeDevice.test';
import localAIGatewayFacadeDeviceTest from './LocalAIGatewayFacadeDevice.test';
import shuviWebSearchDeviceTest from './ShuviWebSearchDevice.test';
import securityStorageDeviceTest from './SecurityStorageDevice.test';

export default function testsuite(): void {
  deviceSmokeTest();
  storageDeviceRecoveryTest();
  memoryDeviceRecoveryTest();
  batteryStatusDeviceTest();
  runtimeRdbDeviceRecoveryTest();
  localAIGatewayDeviceTest();
  mcpFacadeDeviceTest();
  localAIGatewayFacadeDeviceTest();
  shuviWebSearchDeviceTest();
  securityStorageDeviceTest();
}

