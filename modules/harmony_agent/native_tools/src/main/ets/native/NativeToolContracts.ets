import {
  AgentErrorClass,
  ToolDescriptor,
  ToolInvocation,
  ToolOutcome
} from '@harmony_agent/agent-contracts';
import { ToolRegistryEntry } from '@harmony_agent/agent-runtime';

export enum NativePermissionState {
  GRANTED = 'granted',
  DENIED = 'denied',
  NOT_DECLARED = 'notDeclared'
}

export enum NativeToolErrorCode {
  INVALID_INVOCATION = 'NATIVE_INVALID_INVOCATION',
  IDENTITY_STALE = 'NATIVE_TOOL_IDENTITY_STALE',
  ARGUMENTS_DIGEST_MISMATCH = 'NATIVE_ARGUMENTS_DIGEST_MISMATCH',
  GRANT_REJECTED = 'NATIVE_GRANT_REJECTED',
  POLICY_CHECK_FAILED = 'NATIVE_POLICY_CHECK_FAILED',
  CAPABILITY_UNAVAILABLE = 'NATIVE_CAPABILITY_UNAVAILABLE',
  SYSTEM_PERMISSION_REQUIRED = 'SYSTEM_PERMISSION_REQUIRED',
  BACKGROUND_RESTRICTED = 'BACKGROUND_EXECUTION_RESTRICTED',
  CANCELLED = 'NATIVE_CANCELLED',
  PLATFORM_FAILURE = 'NATIVE_PLATFORM_FAILURE',
  INVALID_PLATFORM_RESULT = 'NATIVE_INVALID_PLATFORM_RESULT'
}

export class NativeToolError extends Error {
  readonly code: NativeToolErrorCode;
  readonly errorClass: AgentErrorClass;

  constructor(code: NativeToolErrorCode, errorClass: AgentErrorClass, message: string) {
    super(message);
    this.name = 'NativeToolError';
    this.code = code;
    this.errorClass = errorClass;
  }
}

export interface NativeDigestPort {
  digest(value: string): string;
}

export interface NativeClockPort {
  nowIso(): string;
}

export interface NativeCapabilityProbePort {
  isAvailable(systemCapability: string): boolean;
}

export interface NativeExecutionEnvironmentPort {
  permissionState(permission: string): NativePermissionState;
  isBackgroundExecutionAllowed(toolId: string): boolean;
}

export interface NativeGrantVerifierPort {
  verify(invocation: ToolInvocation, descriptor: ToolDescriptor): boolean;
}

export interface NativeCancellationSignalPort {
  isCancellationRequested(): boolean;
}

export interface NativeCancellationResolverPort {
  resolve(taskId: string, stepId: string, dispatchId: string,
    invocationId: string): NativeCancellationSignalPort;
}

export interface NativeToolOutcomeSinkPort {
  complete(taskId: string, stepId: string, dispatchId: string, outcome: ToolOutcome): void;
}

export interface NativeToolAdapter {
  registryEntry(): ToolRegistryEntry;
  invoke(invocation: ToolInvocation, cancellation: NativeCancellationSignalPort): Promise<ToolOutcome>;
}

export class BatteryStatusSnapshot {
  batterySOC: number = 0;
  chargingStatus: string = '';
  pluggedType: string = '';
  capacityLevel: string = '';
  isBatteryPresent: boolean = false;
}

export interface BatteryStatusPort {
  read(): BatteryStatusSnapshot;
}
