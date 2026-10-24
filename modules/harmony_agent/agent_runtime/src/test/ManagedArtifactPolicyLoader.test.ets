import { describe, expect, it } from '@ohos/hypium';
import { ArtifactKind, ArtifactLifecycleStatus } from '@harmony_agent/agent-contracts';
import {
  ArtifactBaselinePolicyLoaderPort,
  ArtifactCanaryAssignmentPort,
  ArtifactPolicyCancellationSource,
  ArtifactPolicyDecision,
  ArtifactPolicyExecutionMode,
  ArtifactPolicyFallbackCode,
  ArtifactPolicyReleaseConfig,
  ArtifactPolicyReleaseRunner,
  ArtifactPolicyRequest,
  ArtifactPolicyResourceOperationPort,
  ArtifactPolicyRunCode,
  ArtifactPolicyRunResult,
  ArtifactPolicyTimerHandlePort,
  ArtifactPolicyTimerPort,
  ArtifactRegistryEntry,
  ArtifactReleaseRegistryViewPort,
  ArtifactReleasedPolicyLoaderPort,
  ArtifactShadowObservationCode,
  ManagedArtifactBaselinePolicy,
  ManagedArtifactReleasedPolicy
} from '../../Index';

function digest(character: string): string {
  return 'sha256:' + character.repeat(64);
}

function artifact(id: string, character: string,
  status: ArtifactLifecycleStatus): ArtifactRegistryEntry {
  const value: ArtifactRegistryEntry = new ArtifactRegistryEntry();
  value.manifest.artifactId = id;
  value.manifest.artifactKind = ArtifactKind.POLICY;
  value.manifest.artifactDigest = digest(character);
  value.manifest.lifecycleStatus = status;
  value.packageDigest = digest('f');
  return value;
}

function request(): ArtifactPolicyRequest {
  const value: ArtifactPolicyRequest = new ArtifactPolicyRequest();
  value.requestId = 't63-request';
  value.candidateIds = ['baseline', 'candidate'];
  value.inputJson = '{"fixture":"resource-release"}';
  return value;
}

function decision(selectedId: string): ArtifactPolicyDecision {
  const value: ArtifactPolicyDecision = new ArtifactPolicyDecision();
  value.selectedId = selectedId;
  value.evidenceJson = '{"fixture":true}';
  return value;
}

class FixtureOperation implements ArtifactPolicyResourceOperationPort {
  readonly resourceKind: string;
  readonly selectedId: string;
  pending: boolean;
  cancelCalls: number = 0;
  closeCalls: number = 0;
  private lateResolve?: (value: ArtifactPolicyDecision) => void;

  constructor(resourceKind: string, selectedId: string, pending: boolean) {
    this.resourceKind = resourceKind;
    this.selectedId = selectedId;
    this.pending = pending;
  }

  result(): Promise<ArtifactPolicyDecision> {
    if (!this.pending) return Promise.resolve(decision(this.selectedId));
    return new Promise<ArtifactPolicyDecision>((resolve: (value: ArtifactPolicyDecision) => void): void => {
      this.lateResolve = resolve;
    });
  }

  cancel(): void {
    this.cancelCalls++;
  }

  close(): void {
    this.closeCalls++;
  }

  resolveLate(): void {
    const resolve: ((value: ArtifactPolicyDecision) => void) | undefined = this.lateResolve;
    if (resolve !== undefined) resolve(decision(this.selectedId));
  }
}

class FixtureBaselineLoader implements ArtifactBaselinePolicyLoaderPort {
  operation: FixtureOperation;
  constructor(operation: FixtureOperation) { this.operation = operation; }
  load(requestValue: ArtifactPolicyRequest): ArtifactPolicyResourceOperationPort { return this.operation; }
}

class FixtureReleasedLoader implements ArtifactReleasedPolicyLoaderPort {
  operation: FixtureOperation;
  constructor(operation: FixtureOperation) { this.operation = operation; }
  load(artifactValue: ArtifactRegistryEntry,
    requestValue: ArtifactPolicyRequest): ArtifactPolicyResourceOperationPort { return this.operation; }
}

class FixtureRegistry implements ArtifactReleaseRegistryViewPort {
  shadows: ArtifactRegistryEntry[] = [];
  canary?: ArtifactRegistryEntry;
  active?: ArtifactRegistryEntry;
  shadowArtifacts(kind: ArtifactKind): ArtifactRegistryEntry[] { return this.shadows.slice(); }
  canaryArtifact(kind: ArtifactKind): ArtifactRegistryEntry | undefined { return this.canary; }
  activeArtifact(kind: ArtifactKind): ArtifactRegistryEntry | undefined { return this.active; }
}

class FixtureAssignment implements ArtifactCanaryAssignmentPort {
  assignedValue: boolean = false;
  assigned(requestId: string, artifactDigest: string, trafficBasisPoints: number): boolean {
    return this.assignedValue;
  }
}

class FixtureTimerHandle implements ArtifactPolicyTimerHandlePort {
  private readonly action: () => void;
  cancelled: boolean = false;
  constructor(action: () => void) { this.action = action; }
  cancel(): void { this.cancelled = true; }
  fire(): void { if (!this.cancelled) this.action(); }
}

class FixtureTimer implements ArtifactPolicyTimerPort {
  handles: FixtureTimerHandle[] = [];
  schedule(delayMs: number, action: () => void): ArtifactPolicyTimerHandlePort {
    const value: FixtureTimerHandle = new FixtureTimerHandle(action);
    this.handles.push(value);
    return value;
  }
  latest(): FixtureTimerHandle { return this.handles[this.handles.length - 1]; }
}

function releaseConfig(): ArtifactPolicyReleaseConfig {
  const value: ArtifactPolicyReleaseConfig = new ArtifactPolicyReleaseConfig();
  value.canaryTrafficBasisPoints = 10000;
  value.maxShadowEvaluations = 1;
  value.attemptTimeoutMs = 5000;
  return value;
}

async function flushPromises(): Promise<void> {
  for (let index: number = 0; index < 8; index++) await Promise.resolve();
}

function runner(registry: FixtureRegistry, baseline: FixtureOperation, released: FixtureOperation,
  assignment: FixtureAssignment, timer: FixtureTimer): ArtifactPolicyReleaseRunner {
  return new ArtifactPolicyReleaseRunner(registry,
    new ManagedArtifactBaselinePolicy(new FixtureBaselineLoader(baseline)),
    new ManagedArtifactReleasedPolicy(new FixtureReleasedLoader(released)),
    assignment, releaseConfig(), timer);
}

export default function managedArtifactPolicyLoaderTest(): void {
  describe('T63ManagedArtifactPolicyLoader', () => {
    it('releasesProcessFixtureWhenBaselineTimesOut', 0, async () => {
      const process: FixtureOperation = new FixtureOperation('process', 'baseline', true);
      const timer: FixtureTimer = new FixtureTimer();
      const pending: Promise<ArtifactPolicyRunResult> = runner(new FixtureRegistry(), process,
        new FixtureOperation('unused', 'candidate', false), new FixtureAssignment(), timer).run(request());
      timer.latest().fire();
      const result: ArtifactPolicyRunResult = await pending;
      expect(result.code).assertEqual(ArtifactPolicyRunCode.BASELINE_TIMED_OUT);
      expect(process.cancelCalls).assertEqual(1);
      expect(process.closeCalls).assertEqual(1);
    });

    it('releasesWorkerFixtureWhenShadowTimesOut', 0, async () => {
      const registry: FixtureRegistry = new FixtureRegistry();
      registry.shadows = [artifact('shadow-a', 'a', ArtifactLifecycleStatus.SHADOW)];
      const worker: FixtureOperation = new FixtureOperation('worker', 'candidate', true);
      const timer: FixtureTimer = new FixtureTimer();
      const pending: Promise<ArtifactPolicyRunResult> = runner(registry,
        new FixtureOperation('baseline', 'baseline', false), worker,
        new FixtureAssignment(), timer).run(request());
      await flushPromises();
      timer.latest().fire();
      const result: ArtifactPolicyRunResult = await pending;
      expect(result.executionMode).assertEqual(ArtifactPolicyExecutionMode.BASELINE);
      expect(result.shadowObservations[0].code).assertEqual(ArtifactShadowObservationCode.TIMED_OUT);
      expect(worker.cancelCalls).assertEqual(1);
      expect(worker.closeCalls).assertEqual(1);
    });

    it('releasesIpcFixtureWhenCanaryIsCancelled', 0, async () => {
      const registry: FixtureRegistry = new FixtureRegistry();
      registry.canary = artifact('canary-a', 'b', ArtifactLifecycleStatus.CANARY);
      const ipc: FixtureOperation = new FixtureOperation('ipc', 'candidate', true);
      const assignment: FixtureAssignment = new FixtureAssignment();
      assignment.assignedValue = true;
      const cancellation: ArtifactPolicyCancellationSource = new ArtifactPolicyCancellationSource();
      const pending: Promise<ArtifactPolicyRunResult> = runner(registry,
        new FixtureOperation('baseline', 'baseline', false), ipc,
        assignment, new FixtureTimer()).run(request(), cancellation);
      await flushPromises();
      cancellation.cancel();
      const result: ArtifactPolicyRunResult = await pending;
      expect(result.code).assertEqual(ArtifactPolicyRunCode.CANCELLED);
      expect(ipc.cancelCalls).assertEqual(1);
      expect(ipc.closeCalls).assertEqual(1);
    });

    it('releasesNetworkFixtureAndIgnoresLateActiveResult', 0, async () => {
      const registry: FixtureRegistry = new FixtureRegistry();
      registry.active = artifact('active-a', 'c', ArtifactLifecycleStatus.ACTIVE);
      const network: FixtureOperation = new FixtureOperation('network', 'candidate', true);
      const timer: FixtureTimer = new FixtureTimer();
      const pending: Promise<ArtifactPolicyRunResult> = runner(registry,
        new FixtureOperation('baseline', 'baseline', false), network,
        new FixtureAssignment(), timer).run(request());
      await flushPromises();
      timer.latest().fire();
      const result: ArtifactPolicyRunResult = await pending;
      expect(result.executionMode).assertEqual(ArtifactPolicyExecutionMode.BASELINE);
      expect(result.fallbackCode).assertEqual(ArtifactPolicyFallbackCode.ACTIVE_TIMED_OUT);
      expect(network.cancelCalls).assertEqual(1);
      expect(network.closeCalls).assertEqual(1);
      network.resolveLate();
      await flushPromises();
      expect(result.executionMode).assertEqual(ArtifactPolicyExecutionMode.BASELINE);
      expect(network.closeCalls).assertEqual(1);
    });

    it('closesSuccessfulBaselineAndActiveOperationsWithoutCancellingThem', 0, async () => {
      const registry: FixtureRegistry = new FixtureRegistry();
      registry.active = artifact('active-a', 'd', ArtifactLifecycleStatus.ACTIVE);
      const baseline: FixtureOperation = new FixtureOperation('process', 'baseline', false);
      const active: FixtureOperation = new FixtureOperation('network', 'candidate', false);
      const result: ArtifactPolicyRunResult = await runner(registry, baseline, active,
        new FixtureAssignment(), new FixtureTimer()).run(request());
      expect(result.executionMode).assertEqual(ArtifactPolicyExecutionMode.ACTIVE);
      expect(baseline.cancelCalls).assertEqual(0);
      expect(active.cancelCalls).assertEqual(0);
      expect(baseline.closeCalls).assertEqual(1);
      expect(active.closeCalls).assertEqual(1);
    });
  });
}
