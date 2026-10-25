import { describe, expect, it } from '@ohos/hypium';
import {
  AgentErrorClass,
  TaskEnvelope,
  ToolDescriptor,
  ToolInvocation,
  ToolOutcome,
  ToolOutcomeStatus,
  ToolSourceType,
  WorkflowStep
} from '@harmony_agent/agent-contracts';
import { StepDispatchRequest } from '@harmony_agent/agent-runtime';
import {
  BATTERY_STATUS_CAPABILITY,
  BATTERY_STATUS_TOOL_ID,
  BatteryStatusPort,
  BatteryStatusSnapshot,
  BatteryStatusToolAdapter,
  NativeCancellationSignalPort,
  NativeCancellationResolverPort,
  NativeCapabilityProbePort,
  NativeClockPort,
  NativeDigestPort,
  NativeExecutionEnvironmentPort,
  NativeGrantVerifierPort,
  NativePermissionState,
  NativeStepDispatchAdapter,
  NativeToolOutcomeSinkPort,
  NativeToolErrorCode
} from '../../Index';

class FixtureDigest implements NativeDigestPort {
  digest(value: string): string {
    return 'digest:' + value;
  }
}

class FixtureClock implements NativeClockPort {
  private tick: number = 0;

  nowIso(): string {
    this.tick++;
    return this.tick === 1 ? '2026-10-07T10:00:00.000Z' : '2026-10-07T10:00:00.001Z';
  }
}

class FixtureCapability implements NativeCapabilityProbePort {
  available: boolean = true;
  fail: boolean = false;
  calls: number = 0;
  requested: string = '';

  isAvailable(systemCapability: string): boolean {
    this.calls++;
    this.requested = systemCapability;
    if (this.fail) throw new Error('capability service unavailable');
    return this.available;
  }
}

class FixtureEnvironment implements NativeExecutionEnvironmentPort {
  permission: NativePermissionState = NativePermissionState.GRANTED;
  backgroundAllowed: boolean = true;
  fail: boolean = false;
  permissionCalls: number = 0;
  backgroundCalls: number = 0;

  permissionState(_permission: string): NativePermissionState {
    this.permissionCalls++;
    if (this.fail) throw new Error('permission service unavailable');
    return this.permission;
  }

  isBackgroundExecutionAllowed(_toolId: string): boolean {
    this.backgroundCalls++;
    if (this.fail) throw new Error('lifecycle service unavailable');
    return this.backgroundAllowed;
  }
}

class FixtureGrantVerifier implements NativeGrantVerifierPort {
  allowed: boolean = true;
  fail: boolean = false;
  calls: number = 0;

  verify(_invocation: ToolInvocation, _descriptor: ToolDescriptor): boolean {
    this.calls++;
    if (this.fail) throw new Error('grant store unavailable');
    return this.allowed;
  }
}

class FixtureCancellation implements NativeCancellationSignalPort {
  cancelOnCall: number = 0;
  calls: number = 0;

  isCancellationRequested(): boolean {
    this.calls++;
    return this.cancelOnCall > 0 && this.calls >= this.cancelOnCall;
  }
}

class FixtureCancellationResolver implements NativeCancellationResolverPort {
  readonly signal: FixtureCancellation = new FixtureCancellation();
  taskId: string = '';
  stepId: string = '';
  dispatchId: string = '';
  invocationId: string = '';

  resolve(taskId: string, stepId: string, dispatchId: string,
    invocationId: string): NativeCancellationSignalPort {
    this.taskId = taskId;
    this.stepId = stepId;
    this.dispatchId = dispatchId;
    this.invocationId = invocationId;
    return this.signal;
  }
}

class FixtureOutcomeSink implements NativeToolOutcomeSinkPort {
  outcomeStatus?: ToolOutcomeStatus;
  taskId: string = '';
  stepId: string = '';
  dispatchId: string = '';
  private resolveWait?: () => void;
  readonly completed: Promise<void>;

  constructor() {
    this.completed = new Promise<void>((resolve: () => void): void => {
      this.resolveWait = resolve;
    });
  }

  complete(taskId: string, stepId: string, dispatchId: string, outcome: ToolOutcome): void {
    this.taskId = taskId;
    this.stepId = stepId;
    this.dispatchId = dispatchId;
    this.outcomeStatus = outcome.status;
    const resolve: (() => void) | undefined = this.resolveWait;
    if (resolve !== undefined) resolve();
  }
}

class FixtureBattery implements BatteryStatusPort {
  calls: number = 0;
  fail: boolean = false;
  snapshot: BatteryStatusSnapshot = validSnapshot();

  read(): BatteryStatusSnapshot {
    this.calls++;
    if (this.fail) throw new Error('battery service unavailable');
    return this.snapshot;
  }
}

function validSnapshot(): BatteryStatusSnapshot {
  const result: BatteryStatusSnapshot = new BatteryStatusSnapshot();
  result.batterySOC = 73;
  result.chargingStatus = 'charging';
  result.pluggedType = 'usb';
  result.capacityLevel = 'high';
  result.isBatteryPresent = true;
  return result;
}

class FixtureAssembly {
  readonly digest: FixtureDigest = new FixtureDigest();
  readonly capability: FixtureCapability = new FixtureCapability();
  readonly environment: FixtureEnvironment = new FixtureEnvironment();
  readonly grants: FixtureGrantVerifier = new FixtureGrantVerifier();
  readonly battery: FixtureBattery = new FixtureBattery();
  readonly adapter: BatteryStatusToolAdapter = new BatteryStatusToolAdapter(this.digest, new FixtureClock(),
    this.capability, this.environment, this.grants, this.battery);
}

function invocation(fixture: FixtureAssembly): ToolInvocation {
  const descriptor: ToolDescriptor = fixture.adapter.registryEntry().descriptor;
  const result: ToolInvocation = new ToolInvocation();
  result.invocationId = 'native-battery-invocation-1';
  result.taskId = 'task-power-1';
  result.stepId = 'read-battery';
  result.operationId = 'operation-power-1';
  result.attemptId = 'attempt-power-1';
  result.toolId = descriptor.toolId;
  result.toolIdentityVersion = descriptor.toolIdentityVersion;
  result.schemaDigest = descriptor.schemaDigest;
  result.argumentsJson = '{}';
  result.argumentsDigest = fixture.digest.digest('{}');
  result.authorizationGrantId = 'grant-power-1';
  result.timeoutMs = 1000;
  result.createdAt = '2026-10-07T09:59:59.000Z';
  return result;
}

export default function batteryStatusToolTest(): void {
  describe('BatteryStatusTool', () => {
    it('publishesReadOnlyDeviceDescriptorAndIsolatedAvailabilitySnapshot', 0, () => {
      const fixture: FixtureAssembly = new FixtureAssembly();
      const first = fixture.adapter.registryEntry();

      expect(first.descriptor.toolId).assertEqual(BATTERY_STATUS_TOOL_ID);
      expect(first.descriptor.sourceType).assertEqual(ToolSourceType.NATIVE);
      expect(first.descriptor.sideEffect).assertEqual('none');
      expect(first.descriptor.dataBoundary).assertEqual('deviceOnly');
      expect(first.descriptor.permissionRequirements.length).assertEqual(0);
      expect(first.requiresNetwork).assertFalse();
      expect(first.enabled).assertTrue();
      expect(fixture.capability.requested).assertEqual(BATTERY_STATUS_CAPABILITY);
      first.descriptor.displayName = 'mutated';
      expect(fixture.adapter.registryEntry().descriptor.displayName).assertEqual('Read device power status');
    });

    it('marksUnavailableOrUnknownCapabilityWithoutEnablingTool', 0, () => {
      const fixture: FixtureAssembly = new FixtureAssembly();
      fixture.capability.available = false;
      expect(fixture.adapter.registryEntry().descriptor.availability).assertEqual('unavailable');
      expect(fixture.adapter.registryEntry().enabled).assertFalse();
      fixture.capability.fail = true;
      expect(fixture.adapter.registryEntry().descriptor.availability).assertEqual('unknown');
      expect(fixture.adapter.registryEntry().enabled).assertFalse();
    });

    it('normalizesBatterySuccessAfterGrantAndEnvironmentChecks', 0, async () => {
      const fixture: FixtureAssembly = new FixtureAssembly();
      const outcome = await fixture.adapter.invoke(invocation(fixture), new FixtureCancellation());

      expect(outcome.status).assertEqual(ToolOutcomeStatus.SUCCEEDED);
      expect(outcome.resultJson).assertEqual('{"batterySOC":73,"capacityLevel":"high",' +
        '"chargingStatus":"charging","isBatteryPresent":true,"pluggedType":"usb"}');
      expect(outcome.resultDigest).assertEqual('digest:' + outcome.resultJson);
      expect(fixture.grants.calls).assertEqual(1);
      expect(fixture.environment.permissionCalls).assertEqual(0);
      expect(fixture.environment.backgroundCalls).assertEqual(1);
      expect(fixture.battery.calls).assertEqual(1);
    });

    it('rejectsChangedArgumentsBeforeGrantOrPlatformRead', 0, async () => {
      const fixture: FixtureAssembly = new FixtureAssembly();
      const request: ToolInvocation = invocation(fixture);
      request.argumentsJson = '{"unexpected":true}';

      const outcome = await fixture.adapter.invoke(request, new FixtureCancellation());

      expect(outcome.status).assertEqual(ToolOutcomeStatus.DENIED);
      expect(outcome.errorCode).assertEqual(NativeToolErrorCode.ARGUMENTS_DIGEST_MISMATCH);
      expect(fixture.grants.calls).assertEqual(0);
      expect(fixture.battery.calls).assertEqual(0);
    });

    it('rejectsStaleIdentityBeforeGrantOrPlatformRead', 0, async () => {
      const fixture: FixtureAssembly = new FixtureAssembly();
      const request: ToolInvocation = invocation(fixture);
      request.toolIdentityVersion = 'stale-native-identity';

      const outcome = await fixture.adapter.invoke(request, new FixtureCancellation());

      expect(outcome.errorCode).assertEqual(NativeToolErrorCode.IDENTITY_STALE);
      expect(fixture.grants.calls).assertEqual(0);
      expect(fixture.battery.calls).assertEqual(0);
    });

    it('failsClosedForRejectedOrUnavailableGrantVerification', 0, async () => {
      const rejected: FixtureAssembly = new FixtureAssembly();
      rejected.grants.allowed = false;
      const denied = await rejected.adapter.invoke(invocation(rejected), new FixtureCancellation());
      expect(denied.errorCode).assertEqual(NativeToolErrorCode.GRANT_REJECTED);
      expect(rejected.battery.calls).assertEqual(0);

      const unavailable: FixtureAssembly = new FixtureAssembly();
      unavailable.grants.fail = true;
      const failed = await unavailable.adapter.invoke(invocation(unavailable), new FixtureCancellation());
      expect(failed.errorCode).assertEqual(NativeToolErrorCode.POLICY_CHECK_FAILED);
      expect(failed.errorClass).assertEqual(AgentErrorClass.POLICY_DENIED);
      expect(unavailable.battery.calls).assertEqual(0);
    });

    it('failsClosedWhenCapabilityIsUnavailable', 0, async () => {
      const fixture: FixtureAssembly = new FixtureAssembly();
      const request: ToolInvocation = invocation(fixture);
      fixture.capability.available = false;

      const outcome = await fixture.adapter.invoke(request, new FixtureCancellation());

      expect(outcome.errorCode).assertEqual(NativeToolErrorCode.CAPABILITY_UNAVAILABLE);
      expect(outcome.errorClass).assertEqual(AgentErrorClass.CONFIGURATION);
      expect(fixture.battery.calls).assertEqual(0);
    });

    it('reportsBackgroundRestrictionBeforePlatformRead', 0, async () => {
      const fixture: FixtureAssembly = new FixtureAssembly();
      const request: ToolInvocation = invocation(fixture);
      fixture.environment.backgroundAllowed = false;

      const outcome = await fixture.adapter.invoke(request, new FixtureCancellation());

      expect(outcome.errorCode).assertEqual(NativeToolErrorCode.BACKGROUND_RESTRICTED);
      expect(fixture.battery.calls).assertEqual(0);
    });

    it('honorsCancellationBeforeAndAfterSynchronousPlatformRead', 0, async () => {
      const before: FixtureAssembly = new FixtureAssembly();
      const beforeSignal: FixtureCancellation = new FixtureCancellation();
      beforeSignal.cancelOnCall = 1;
      const beforeOutcome = await before.adapter.invoke(invocation(before), beforeSignal);
      expect(beforeOutcome.status).assertEqual(ToolOutcomeStatus.CANCELLED);
      expect(before.battery.calls).assertEqual(0);

      const after: FixtureAssembly = new FixtureAssembly();
      const afterSignal: FixtureCancellation = new FixtureCancellation();
      afterSignal.cancelOnCall = 2;
      const afterOutcome = await after.adapter.invoke(invocation(after), afterSignal);
      expect(afterOutcome.status).assertEqual(ToolOutcomeStatus.CANCELLED);
      expect(after.battery.calls).assertEqual(1);
    });

    it('mapsPlatformFailureWithoutRetry', 0, async () => {
      const fixture: FixtureAssembly = new FixtureAssembly();
      const request: ToolInvocation = invocation(fixture);
      fixture.battery.fail = true;

      const outcome = await fixture.adapter.invoke(request, new FixtureCancellation());

      expect(outcome.errorCode).assertEqual(NativeToolErrorCode.PLATFORM_FAILURE);
      expect(outcome.errorClass).assertEqual(AgentErrorClass.PROVIDER);
      expect(fixture.battery.calls).assertEqual(1);
    });

    it('rejectsInvalidPlatformSnapshot', 0, async () => {
      const fixture: FixtureAssembly = new FixtureAssembly();
      const request: ToolInvocation = invocation(fixture);
      fixture.battery.snapshot.batterySOC = 101;

      const outcome = await fixture.adapter.invoke(request, new FixtureCancellation());

      expect(outcome.errorCode).assertEqual(NativeToolErrorCode.INVALID_PLATFORM_RESULT);
      expect(outcome.status).assertEqual(ToolOutcomeStatus.FAILED);
      expect(fixture.battery.calls).assertEqual(1);
    });

    it('adaptsRuntimeDispatchWithoutExposingTaskControl', 0, async () => {
      const fixture: FixtureAssembly = new FixtureAssembly();
      const cancellations: FixtureCancellationResolver = new FixtureCancellationResolver();
      const sink: FixtureOutcomeSink = new FixtureOutcomeSink();
      const dispatcher: NativeStepDispatchAdapter = new NativeStepDispatchAdapter(
        fixture.adapter, cancellations, sink);
      const request: StepDispatchRequest = new StepDispatchRequest();
      request.task = new TaskEnvelope();
      request.task.taskId = 'task-power-1';
      request.step = new WorkflowStep();
      request.step.stepId = 'read-battery';
      request.dispatchId = 'dispatch-power-1';
      request.toolInvocation = invocation(fixture);

      const receipt = dispatcher.dispatch(request);
      await sink.completed;

      expect(receipt.accepted).assertTrue();
      expect(cancellations.taskId).assertEqual('task-power-1');
      expect(cancellations.stepId).assertEqual('read-battery');
      expect(cancellations.dispatchId).assertEqual('dispatch-power-1');
      expect(cancellations.invocationId).assertEqual('native-battery-invocation-1');
      expect(sink.taskId).assertEqual('task-power-1');
      expect(sink.stepId).assertEqual('read-battery');
      expect(sink.dispatchId).assertEqual('dispatch-power-1');
      expect(sink.outcomeStatus).assertEqual(ToolOutcomeStatus.SUCCEEDED);
    });
  });
}
