import batteryInfo from '@ohos.batteryInfo';
import {
  AgentErrorClass,
  ContractValidator,
  DataBoundary,
  IdempotencyMode,
  RiskLevel,
  SideEffect,
  ToolDescriptor,
  ToolInvocation,
  ToolOutcome,
  ToolOutcomeStatus,
  ToolSourceType
} from '@harmony_agent/agent-contracts';
import { ToolRegistryEntry } from '@harmony_agent/agent-runtime';
import {
  BatteryStatusPort,
  BatteryStatusSnapshot,
  NativeCancellationSignalPort,
  NativeCapabilityProbePort,
  NativeClockPort,
  NativeDigestPort,
  NativeExecutionEnvironmentPort,
  NativeGrantVerifierPort,
  NativePermissionState,
  NativeToolAdapter,
  NativeToolError,
  NativeToolErrorCode
} from './NativeToolContracts';
import {
  copyNativeToolEntry,
  nativeCanonicalJson,
  parseNativeArguments
} from './NativeToolSupport';

export const BATTERY_STATUS_TOOL_ID: string = 'native://device/power.status.read';
export const BATTERY_STATUS_CAPABILITY: string = 'SystemCapability.PowerManager.BatteryManager.Core';
export const BATTERY_STATUS_VERSION: string = '1.0.0';

class BatteryStatusResultJson {
  batterySOC: number = 0;
  chargingStatus: string = '';
  pluggedType: string = '';
  capacityLevel: string = '';
  isBatteryPresent: boolean = false;
}

function chargingStatusText(value: batteryInfo.BatteryChargeState): string {
  switch (value) {
    case batteryInfo.BatteryChargeState.ENABLE: return 'charging';
    case batteryInfo.BatteryChargeState.DISABLE: return 'notCharging';
    case batteryInfo.BatteryChargeState.FULL: return 'full';
    default: return 'unknown';
  }
}

function pluggedTypeText(value: batteryInfo.BatteryPluggedType): string {
  switch (value) {
    case batteryInfo.BatteryPluggedType.AC: return 'ac';
    case batteryInfo.BatteryPluggedType.USB: return 'usb';
    case batteryInfo.BatteryPluggedType.WIRELESS: return 'wireless';
    default: return 'none';
  }
}

function capacityLevelText(value: batteryInfo.BatteryCapacityLevel): string {
  switch (value) {
    case batteryInfo.BatteryCapacityLevel.LEVEL_FULL: return 'full';
    case batteryInfo.BatteryCapacityLevel.LEVEL_HIGH: return 'high';
    case batteryInfo.BatteryCapacityLevel.LEVEL_NORMAL: return 'normal';
    case batteryInfo.BatteryCapacityLevel.LEVEL_LOW: return 'low';
    case batteryInfo.BatteryCapacityLevel.LEVEL_WARNING: return 'warning';
    case batteryInfo.BatteryCapacityLevel.LEVEL_CRITICAL: return 'critical';
    case batteryInfo.BatteryCapacityLevel.LEVEL_SHUTDOWN: return 'shutdown';
    default: return 'unknown';
  }
}

export class SystemBatteryStatusPort implements BatteryStatusPort {
  read(): BatteryStatusSnapshot {
    const result: BatteryStatusSnapshot = new BatteryStatusSnapshot();
    result.batterySOC = batteryInfo.batterySOC;
    result.chargingStatus = chargingStatusText(batteryInfo.chargingStatus);
    result.pluggedType = pluggedTypeText(batteryInfo.pluggedType);
    result.capacityLevel = capacityLevelText(batteryInfo.batteryCapacityLevel);
    result.isBatteryPresent = batteryInfo.isBatteryPresent;
    return result;
  }
}

export class BatteryStatusToolAdapter implements NativeToolAdapter {
  private readonly digest: NativeDigestPort;
  private readonly clock: NativeClockPort;
  private readonly capability: NativeCapabilityProbePort;
  private readonly environment: NativeExecutionEnvironmentPort;
  private readonly grants: NativeGrantVerifierPort;
  private readonly battery: BatteryStatusPort;
  private readonly entryValue: ToolRegistryEntry;

  constructor(digest: NativeDigestPort, clock: NativeClockPort, capability: NativeCapabilityProbePort,
    environment: NativeExecutionEnvironmentPort, grants: NativeGrantVerifierPort, battery: BatteryStatusPort) {
    this.digest = digest;
    this.clock = clock;
    this.capability = capability;
    this.environment = environment;
    this.grants = grants;
    this.battery = battery;
    this.entryValue = this.createEntry();
  }

  registryEntry(): ToolRegistryEntry {
    const result: ToolRegistryEntry = copyNativeToolEntry(this.entryValue);
    try {
      result.descriptor.availability = this.capability.isAvailable(BATTERY_STATUS_CAPABILITY) ?
        'available' : 'unavailable';
      result.enabled = result.descriptor.availability === 'available';
    } catch (error) {
      result.descriptor.availability = 'unknown';
      result.enabled = false;
    }
    return result;
  }

  async invoke(invocation: ToolInvocation, cancellation: NativeCancellationSignalPort): Promise<ToolOutcome> {
    const startedAt: string = this.safeNow(invocation.createdAt);
    const descriptor: ToolDescriptor = this.entryValue.descriptor;
    if (!ContractValidator.validateToolInvocation(invocation).valid || invocation.toolId !== descriptor.toolId) {
      return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.FAILED,
        AgentErrorClass.INVALID_INPUT, NativeToolErrorCode.INVALID_INVOCATION, 'Native tool invocation is invalid');
    }
    if (invocation.toolIdentityVersion !== descriptor.toolIdentityVersion ||
      invocation.schemaDigest !== descriptor.schemaDigest) {
      return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED,
        AgentErrorClass.POLICY_DENIED, NativeToolErrorCode.IDENTITY_STALE, 'Native tool identity changed');
    }
    try {
      const argumentsValue: Object = parseNativeArguments(invocation.argumentsJson);
      if (Object.keys(argumentsValue).length !== 0 ||
        this.digest.digest(nativeCanonicalJson(argumentsValue)) !== invocation.argumentsDigest) {
        return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED,
          AgentErrorClass.POLICY_DENIED, NativeToolErrorCode.ARGUMENTS_DIGEST_MISMATCH,
          'Native tool arguments changed after authorization');
      }
      if (!this.grants.verify(invocation, descriptor)) {
        return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED,
          AgentErrorClass.POLICY_DENIED, NativeToolErrorCode.GRANT_REJECTED, 'Runtime grant was rejected');
      }
      if (!this.capability.isAvailable(BATTERY_STATUS_CAPABILITY)) {
        return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.FAILED,
          AgentErrorClass.CONFIGURATION, NativeToolErrorCode.CAPABILITY_UNAVAILABLE,
          'Battery system capability is unavailable');
      }
      for (let index: number = 0; index < descriptor.permissionRequirements.length; index++) {
        if (this.environment.permissionState(descriptor.permissionRequirements[index]) !==
          NativePermissionState.GRANTED) {
          return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED,
            AgentErrorClass.PERMISSION_DENIED, NativeToolErrorCode.SYSTEM_PERMISSION_REQUIRED,
            'Required system permission is not granted');
        }
      }
      if (!this.environment.isBackgroundExecutionAllowed(descriptor.toolId)) {
        return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.FAILED,
          AgentErrorClass.PERMISSION_DENIED, NativeToolErrorCode.BACKGROUND_RESTRICTED,
          'Background execution is restricted');
      }
    } catch (error) {
      return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED,
        AgentErrorClass.POLICY_DENIED, NativeToolErrorCode.POLICY_CHECK_FAILED,
        'Native tool policy or environment check failed closed');
    }
    if (cancellation.isCancellationRequested()) {
      return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.CANCELLED,
        AgentErrorClass.CANCELLED, NativeToolErrorCode.CANCELLED, 'Native tool invocation was cancelled');
    }
    try {
      const snapshot: BatteryStatusSnapshot = this.battery.read();
      if (cancellation.isCancellationRequested()) {
        return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.CANCELLED,
          AgentErrorClass.CANCELLED, NativeToolErrorCode.CANCELLED, 'Native tool invocation was cancelled');
      }
      if (!Number.isSafeInteger(snapshot.batterySOC) || snapshot.batterySOC < 0 || snapshot.batterySOC > 100 ||
        snapshot.chargingStatus.trim().length === 0 || snapshot.pluggedType.trim().length === 0 ||
        snapshot.capacityLevel.trim().length === 0) {
        return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.FAILED,
          AgentErrorClass.PROVIDER, NativeToolErrorCode.INVALID_PLATFORM_RESULT,
          'Battery platform result is invalid');
      }
      const payload: BatteryStatusResultJson = new BatteryStatusResultJson();
      payload.batterySOC = snapshot.batterySOC;
      payload.chargingStatus = snapshot.chargingStatus;
      payload.pluggedType = snapshot.pluggedType;
      payload.capacityLevel = snapshot.capacityLevel;
      payload.isBatteryPresent = snapshot.isBatteryPresent;
      const resultJson: string = nativeCanonicalJson(payload as Object);
      const outcome: ToolOutcome = new ToolOutcome();
      outcome.invocationId = invocation.invocationId;
      outcome.status = ToolOutcomeStatus.SUCCEEDED;
      outcome.resultJson = resultJson;
      outcome.resultDigest = this.digest.digest(resultJson);
      outcome.startedAt = startedAt;
      outcome.finishedAt = this.safeNow(startedAt);
      return outcome;
    } catch (error) {
      if (error instanceof NativeToolError) {
        return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.FAILED,
          error.errorClass, error.code, error.message);
      }
      return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.FAILED,
        AgentErrorClass.PROVIDER, NativeToolErrorCode.PLATFORM_FAILURE, 'Battery platform call failed');
    }
  }

  private createEntry(): ToolRegistryEntry {
    const descriptor: ToolDescriptor = new ToolDescriptor();
    descriptor.toolId = BATTERY_STATUS_TOOL_ID;
    descriptor.sourceType = ToolSourceType.NATIVE;
    descriptor.providerId = 'openharmony';
    descriptor.capabilityName = 'device.power.status.read';
    descriptor.capabilityVersion = BATTERY_STATUS_VERSION;
    descriptor.displayName = 'Read device power status';
    descriptor.description = 'Reads current battery level and charging state for runtime scheduling.';
    descriptor.inputSchemaJson = '{"additionalProperties":false,"type":"object"}';
    descriptor.outputSchemaJson = '{"additionalProperties":false,"properties":{' +
      '"batterySOC":{"maximum":100,"minimum":0,"type":"integer"},' +
      '"capacityLevel":{"type":"string"},"chargingStatus":{"type":"string"},' +
      '"isBatteryPresent":{"type":"boolean"},"pluggedType":{"type":"string"}},' +
      '"required":["batterySOC","chargingStatus","pluggedType","capacityLevel",' +
      '"isBatteryPresent"],"type":"object"}';
    descriptor.schemaDigest = this.digest.digest('native-tool-schema-v1|' + descriptor.inputSchemaJson + '|' +
      descriptor.outputSchemaJson);
    descriptor.toolIdentityVersion = this.digest.digest('native-tool-identity-v1|' + descriptor.toolId + '|' +
      descriptor.capabilityVersion + '|' + descriptor.schemaDigest + '|' + BATTERY_STATUS_CAPABILITY);
    descriptor.capabilityTags = ['device-state', 'battery', 'power', 'read-only'];
    descriptor.riskLevel = RiskLevel.LOW;
    descriptor.sideEffect = SideEffect.NONE;
    descriptor.permissionRequirements = [];
    descriptor.dataBoundary = DataBoundary.DEVICE_ONLY;
    descriptor.availability = 'unknown';
    descriptor.latencyClass = 'local-sync';
    descriptor.costClass = 'zero';
    descriptor.idempotencyMode = IdempotencyMode.NONE;
    descriptor.adapterRef = 'native:battery-status';
    const result: ToolRegistryEntry = new ToolRegistryEntry();
    result.descriptor = descriptor;
    result.registryVersion = descriptor.toolIdentityVersion;
    result.descriptionDigest = this.digest.digest(descriptor.description);
    result.registryDigest = this.digest.digest('native-tool-registry-v1|' + descriptor.toolIdentityVersion + '|' +
      result.descriptionDigest);
    result.retrievalRelationVersion = descriptor.toolIdentityVersion;
    result.estimatedCostMicros = 0;
    result.requiresNetwork = false;
    result.enabled = false;
    return result;
  }

  private failure(invocationId: string, startedAt: string, status: ToolOutcomeStatus,
    errorClass: AgentErrorClass, code: string, message: string): ToolOutcome {
    const outcome: ToolOutcome = new ToolOutcome();
    outcome.invocationId = invocationId;
    outcome.status = status;
    outcome.errorClass = errorClass;
    outcome.errorCode = code;
    outcome.errorMessage = message;
    outcome.startedAt = startedAt;
    outcome.finishedAt = this.safeNow(startedAt);
    return outcome;
  }

  private safeNow(fallback: string): string {
    try {
      return this.clock.nowIso();
    } catch (error) {
      return fallback.trim().length > 0 ? fallback : '1970-01-01T00:00:00.000Z';
    }
  }
}
