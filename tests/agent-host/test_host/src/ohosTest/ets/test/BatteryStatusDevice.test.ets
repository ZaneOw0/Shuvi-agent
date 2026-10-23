import { describe, expect, it } from '@ohos/hypium';
import {
  ToolDescriptor,
  ToolInvocation,
  ToolOutcomeStatus
} from '@harmony_agent/agent-contracts';
import {
  BatteryStatusToolAdapter,
  NativeCancellationSignalPort,
  NativeClockPort,
  NativeDigestPort,
  NativeExecutionEnvironmentPort,
  NativeGrantVerifierPort,
  NativePermissionState,
  SystemBatteryStatusPort,
  SystemNativeCapabilityProbe
} from '@harmony_agent/native-tools';

class DeviceNativeDigest implements NativeDigestPort {
  digest(value: string): string {
    return 'device-native-digest:' + value;
  }
}

class DeviceNativeClock implements NativeClockPort {
  nowIso(): string {
    return new Date().toISOString();
  }
}

class DeviceExecutionEnvironment implements NativeExecutionEnvironmentPort {
  permissionState(_permission: string): NativePermissionState {
    return NativePermissionState.NOT_DECLARED;
  }

  isBackgroundExecutionAllowed(_toolId: string): boolean {
    return true;
  }
}

class DeviceGrantVerifier implements NativeGrantVerifierPort {
  verify(_invocation: ToolInvocation, _descriptor: ToolDescriptor): boolean {
    return true;
  }
}

class DeviceCancellation implements NativeCancellationSignalPort {
  isCancellationRequested(): boolean {
    return false;
  }
}

class BatteryStatusJson {
  batterySOC: number = -1;
  chargingStatus: string = '';
  pluggedType: string = '';
  capacityLevel: string = '';
  isBatteryPresent: boolean = false;
}

function invocation(adapter: BatteryStatusToolAdapter, digest: NativeDigestPort): ToolInvocation {
  const descriptor = adapter.registryEntry().descriptor;
  const result: ToolInvocation = new ToolInvocation();
  result.invocationId = 'device-native-battery-1';
  result.taskId = 'device-native-task-1';
  result.stepId = 'read-battery';
  result.operationId = 'device-native-operation-1';
  result.attemptId = 'device-native-attempt-1';
  result.toolId = descriptor.toolId;
  result.toolIdentityVersion = descriptor.toolIdentityVersion;
  result.schemaDigest = descriptor.schemaDigest;
  result.argumentsJson = '{}';
  result.argumentsDigest = digest.digest('{}');
  result.authorizationGrantId = 'device-native-grant-1';
  result.timeoutMs = 1000;
  result.createdAt = new Date().toISOString();
  return result;
}

export default function batteryStatusDeviceTest(): void {
  describe('BatteryStatusDevice', () => {
    it('readsNormalizedBatteryStatusThroughGuardedNativeAdapter', 0, async () => {
      const digest: DeviceNativeDigest = new DeviceNativeDigest();
      const adapter: BatteryStatusToolAdapter = new BatteryStatusToolAdapter(
        digest,
        new DeviceNativeClock(),
        new SystemNativeCapabilityProbe(),
        new DeviceExecutionEnvironment(),
        new DeviceGrantVerifier(),
        new SystemBatteryStatusPort()
      );

      const entry = adapter.registryEntry();
      expect(entry.enabled).assertTrue();
      expect(entry.descriptor.availability).assertEqual('available');

      const outcome = await adapter.invoke(invocation(adapter, digest), new DeviceCancellation());
      expect(outcome.status).assertEqual(ToolOutcomeStatus.SUCCEEDED);
      const resultJson: string = outcome.resultJson === undefined ? '' : outcome.resultJson;
      expect(resultJson.length > 0).assertTrue();
      const value: BatteryStatusJson = JSON.parse(resultJson) as BatteryStatusJson;
      expect(Number.isSafeInteger(value.batterySOC)).assertTrue();
      expect(value.batterySOC >= 0 && value.batterySOC <= 100).assertTrue();
      expect(value.chargingStatus.length > 0).assertTrue();
      expect(value.pluggedType.length > 0).assertTrue();
      expect(value.capacityLevel.length > 0).assertTrue();
      expect(outcome.resultDigest).assertEqual(digest.digest(resultJson));
    });
  });
}
