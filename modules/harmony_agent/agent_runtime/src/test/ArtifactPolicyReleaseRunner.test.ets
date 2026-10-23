import { describe, expect, it } from '@ohos/hypium';
import {
  ArtifactKind,
  ArtifactLifecycleStatus
} from '@harmony_agent/agent-contracts';
import {
  ArtifactBaselinePolicyPort,
  ArtifactCanaryAssignmentPort,
  ArtifactCanaryBucketPort,
  ArtifactPolicyCancellationSignalPort,
  ArtifactPolicyCancellationSource,
  ArtifactPolicyDecision,
  ArtifactPolicyExecutionMode,
  ArtifactPolicyFallbackCode,
  ArtifactPolicyReleaseConfig,
  ArtifactPolicyReleaseRunner,
  ArtifactPolicyRequest,
  ArtifactPolicyRunCode,
  ArtifactPolicyRunResult,
  ArtifactPolicyTimerHandlePort,
  ArtifactPolicyTimerPort,
  ArtifactRegistryEntry,
  ArtifactReleaseRegistryViewPort,
  ArtifactReleasedPolicyPort,
  ArtifactShadowObservationCode,
  DeterministicArtifactCanaryAssignment
} from '../../Index';

function digest(character: string): string {
  return 'sha256:' + character.repeat(64);
}

function entry(artifactId: string, artifactDigest: string,
  status: ArtifactLifecycleStatus): ArtifactRegistryEntry {
  const value: ArtifactRegistryEntry = new ArtifactRegistryEntry();
  value.manifest.artifactId = artifactId;
  value.manifest.artifactKind = ArtifactKind.POLICY;
  value.manifest.artifactDigest = artifactDigest;
  value.manifest.lifecycleStatus = status;
  value.packageDigest = digest('f');
  value.registeredAtMs = 100;
  return value;
}

class FixtureRegistryView implements ArtifactReleaseRegistryViewPort {
  shadows: ArtifactRegistryEntry[] = [];
  canary?: ArtifactRegistryEntry;
  active?: ArtifactRegistryEntry;
  throwOnRead: boolean = false;

  shadowArtifacts(kind: ArtifactKind): ArtifactRegistryEntry[] {
    if (this.throwOnRead) throw new Error('registry detail must not escape');
    return this.shadows.slice();
  }

  canaryArtifact(kind: ArtifactKind): ArtifactRegistryEntry | undefined {
    if (this.throwOnRead) throw new Error('registry detail must not escape');
    return this.canary;
  }

  activeArtifact(kind: ArtifactKind): ArtifactRegistryEntry | undefined {
    if (this.throwOnRead) throw new Error('registry detail must not escape');
    return this.active;
  }
}

class FixtureBaseline implements ArtifactBaselinePolicyPort {
  calls: number = 0;
  selectedId: string = 'baseline';
  throwOnDecide: boolean = false;
  mutateRequest: boolean = false;
  pending: boolean = false;
  cancellationObserved: boolean = false;

  async decide(request: ArtifactPolicyRequest,
    cancellation?: ArtifactPolicyCancellationSignalPort): Promise<ArtifactPolicyDecision> {
    this.calls++;
    if (this.throwOnDecide) throw new Error('baseline detail must not escape');
    if (this.mutateRequest) request.candidateIds[0] = 'mutated';
    if (this.pending) {
      if (cancellation !== undefined) {
        cancellation.subscribe((): void => {
          this.cancellationObserved = true;
        });
      }
      return new Promise<ArtifactPolicyDecision>((): void => {
      });
    }
    const value: ArtifactPolicyDecision = new ArtifactPolicyDecision();
    value.selectedId = this.selectedId;
    value.evidenceJson = '{"source":"baseline"}';
    return value;
  }
}

class FixtureReleased implements ArtifactReleasedPolicyPort {
  calls: string[] = [];
  selectedByArtifact: Map<string, string> = new Map<string, string>();
  throwingArtifactId: string = '';
  mutateInputs: boolean = false;
  pendingArtifactId: string = '';
  cancellationObserved: boolean = false;

  async decide(artifact: ArtifactRegistryEntry,
    request: ArtifactPolicyRequest,
    cancellation?: ArtifactPolicyCancellationSignalPort): Promise<ArtifactPolicyDecision> {
    this.calls.push(artifact.manifest.artifactId);
    if (artifact.manifest.artifactId === this.throwingArtifactId) {
      throw new Error('candidate detail must not escape');
    }
    if (artifact.manifest.artifactId === this.pendingArtifactId) {
      if (cancellation !== undefined) {
        cancellation.subscribe((): void => {
          this.cancellationObserved = true;
        });
      }
      return new Promise<ArtifactPolicyDecision>((): void => {
      });
    }
    const selected: string | undefined = this.selectedByArtifact.get(artifact.manifest.artifactId);
    const value: ArtifactPolicyDecision = new ArtifactPolicyDecision();
    value.selectedId = selected === undefined ? 'candidate' : selected;
    value.evidenceJson = '{"source":"released"}';
    if (this.mutateInputs) {
      artifact.manifest.artifactId = 'mutated';
      request.candidateIds[0] = 'mutated';
    }
    return value;
  }
}

class FixtureAssignment implements ArtifactCanaryAssignmentPort {
  value: boolean = false;
  throwOnAssign: boolean = false;
  calls: number = 0;

  assigned(requestId: string, artifactDigest: string, trafficBasisPoints: number): boolean {
    this.calls++;
    if (this.throwOnAssign) throw new Error('assignment detail must not escape');
    return this.value;
  }
}

class FixtureBucket implements ArtifactCanaryBucketPort {
  value: number = 0;

  bucket(requestId: string, artifactDigest: string): number {
    return this.value;
  }
}

class FixtureTimerHandle implements ArtifactPolicyTimerHandlePort {
  readonly action: () => void;
  cancelled: boolean = false;

  constructor(action: () => void) {
    this.action = action;
  }

  cancel(): void {
    this.cancelled = true;
  }

  fire(): void {
    if (!this.cancelled) this.action();
  }
}

class FixtureTimer implements ArtifactPolicyTimerPort {
  handles: FixtureTimerHandle[] = [];

  schedule(delayMs: number, action: () => void): ArtifactPolicyTimerHandlePort {
    const handle: FixtureTimerHandle = new FixtureTimerHandle(action);
    this.handles.push(handle);
    return handle;
  }

  latest(): FixtureTimerHandle {
    return this.handles[this.handles.length - 1];
  }
}

async function flushPromises(): Promise<void> {
  for (let index: number = 0; index < 6; index++) await Promise.resolve();
}

function request(): ArtifactPolicyRequest {
  const value: ArtifactPolicyRequest = new ArtifactPolicyRequest();
  value.requestId = 'request-1';
  value.artifactKind = ArtifactKind.POLICY;
  value.candidateIds = ['baseline', 'candidate'];
  value.inputJson = '{"feature":1}';
  return value;
}

function config(maxShadows: number = 2): ArtifactPolicyReleaseConfig {
  const value: ArtifactPolicyReleaseConfig = new ArtifactPolicyReleaseConfig();
  value.canaryTrafficBasisPoints = 1000;
  value.maxShadowEvaluations = maxShadows;
  value.attemptTimeoutMs = 5000;
  return value;
}

export default function artifactPolicyReleaseRunnerTest(): void {
  describe('ArtifactPolicyReleaseRunner', () => {
    it('recordsBoundedShadowDecisionsWithoutChangingBaseline', 0, async () => {
      const registry: FixtureRegistryView = new FixtureRegistryView();
      registry.shadows = [
        entry('shadow-a', digest('a'), ArtifactLifecycleStatus.SHADOW),
        entry('shadow-b', digest('b'), ArtifactLifecycleStatus.SHADOW)
      ];
      const released: FixtureReleased = new FixtureReleased();
      const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        registry, new FixtureBaseline(), released, new FixtureAssignment(), config(1));
      const result = await runner.run(request());
      expect(result.accepted).assertTrue();
      expect(result.executionMode).assertEqual(ArtifactPolicyExecutionMode.BASELINE);
      expect(result.decision?.selectedId).assertEqual('baseline');
      expect(result.fallbackCode).assertEqual(ArtifactPolicyFallbackCode.NO_RELEASE);
      expect(result.shadowObservations.length).assertEqual(1);
      expect(result.shadowObservations[0].code).assertEqual(ArtifactShadowObservationCode.ACCEPTED);
      expect(result.shadowObservations[0].selectedId).assertEqual('candidate');
      expect(released.calls.length).assertEqual(1);
    });

    it('selectsAssignedCanaryAfterBaselineValidation', 0, async () => {
      const registry: FixtureRegistryView = new FixtureRegistryView();
      registry.canary = entry('canary-a', digest('a'), ArtifactLifecycleStatus.CANARY);
      const assignment: FixtureAssignment = new FixtureAssignment();
      assignment.value = true;
      const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        registry, new FixtureBaseline(), new FixtureReleased(), assignment, config());
      const result = await runner.run(request());
      expect(result.executionMode).assertEqual(ArtifactPolicyExecutionMode.CANARY);
      expect(result.decision?.selectedId).assertEqual('candidate');
      expect(result.selectedArtifactDigest).assertEqual(digest('a'));
      expect(result.baselineDecision?.selectedId).assertEqual('baseline');
    });

    it('usesDeterministicBasisPointBucketsAndNeverAssignsZeroTraffic', 0, async () => {
      const bucket: FixtureBucket = new FixtureBucket();
      const assignment: DeterministicArtifactCanaryAssignment =
        new DeterministicArtifactCanaryAssignment(bucket);
      bucket.value = 999;
      expect(assignment.assigned('request-1', digest('a'), 1000)).assertTrue();
      bucket.value = 1000;
      expect(assignment.assigned('request-1', digest('a'), 1000)).assertFalse();
      expect(assignment.assigned('request-1', digest('a'), 0)).assertFalse();
      bucket.value = 9999;
      expect(assignment.assigned('request-1', digest('a'), 10000)).assertTrue();

      const registry: FixtureRegistryView = new FixtureRegistryView();
      registry.canary = entry('canary-a', digest('a'), ArtifactLifecycleStatus.CANARY);
      const fixtureAssignment: FixtureAssignment = new FixtureAssignment();
      const zeroConfig: ArtifactPolicyReleaseConfig = config();
      zeroConfig.canaryTrafficBasisPoints = 0;
      const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        registry, new FixtureBaseline(), new FixtureReleased(), fixtureAssignment, zeroConfig);
      const result = await runner.run(request());
      expect(result.executionMode).assertEqual(ArtifactPolicyExecutionMode.BASELINE);
      expect(fixtureAssignment.calls).assertEqual(0);
    });

    it('usesActiveWhenCanaryIsNotAssigned', 0, async () => {
      const registry: FixtureRegistryView = new FixtureRegistryView();
      registry.canary = entry('canary-a', digest('a'), ArtifactLifecycleStatus.CANARY);
      registry.active = entry('active-a', digest('b'), ArtifactLifecycleStatus.ACTIVE);
      const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        registry, new FixtureBaseline(), new FixtureReleased(), new FixtureAssignment(), config());
      const result = await runner.run(request());
      expect(result.executionMode).assertEqual(ArtifactPolicyExecutionMode.ACTIVE);
      expect(result.selectedArtifactDigest).assertEqual(digest('b'));
      expect(result.fallbackCode).assertEqual(ArtifactPolicyFallbackCode.CANARY_NOT_ASSIGNED);
    });

    it('fallsBackFromFailedCanaryToCurrentActive', 0, async () => {
      const registry: FixtureRegistryView = new FixtureRegistryView();
      registry.canary = entry('canary-a', digest('a'), ArtifactLifecycleStatus.CANARY);
      registry.active = entry('active-a', digest('b'), ArtifactLifecycleStatus.ACTIVE);
      const released: FixtureReleased = new FixtureReleased();
      released.throwingArtifactId = 'canary-a';
      const assignment: FixtureAssignment = new FixtureAssignment();
      assignment.value = true;
      const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        registry, new FixtureBaseline(), released, assignment, config());
      const result = await runner.run(request());
      expect(result.executionMode).assertEqual(ArtifactPolicyExecutionMode.ACTIVE);
      expect(result.selectedArtifactDigest).assertEqual(digest('b'));
      expect(result.fallbackCode).assertEqual(ArtifactPolicyFallbackCode.CANARY_FAILED);
      expect(released.calls.length).assertEqual(2);
    });

    it('fallsBackToBaselineWhenActiveDecisionIsOutsideCandidates', 0, async () => {
      const registry: FixtureRegistryView = new FixtureRegistryView();
      registry.active = entry('active-a', digest('a'), ArtifactLifecycleStatus.ACTIVE);
      const released: FixtureReleased = new FixtureReleased();
      released.selectedByArtifact.set('active-a', 'outside');
      const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        registry, new FixtureBaseline(), released, new FixtureAssignment(), config());
      const result = await runner.run(request());
      expect(result.executionMode).assertEqual(ArtifactPolicyExecutionMode.BASELINE);
      expect(result.decision?.selectedId).assertEqual('baseline');
      expect(result.fallbackCode).assertEqual(ArtifactPolicyFallbackCode.ACTIVE_REJECTED);
      expect(result.selectedArtifactDigest).assertEqual('');
    });

    it('rejectsMalformedRegistryViewsBeforeCandidateExecution', 0, async () => {
      const registry: FixtureRegistryView = new FixtureRegistryView();
      registry.active = entry('active-a', digest('a'), ArtifactLifecycleStatus.SHADOW);
      const released: FixtureReleased = new FixtureReleased();
      const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        registry, new FixtureBaseline(), released, new FixtureAssignment(), config());
      const result = await runner.run(request());
      expect(result.executionMode).assertEqual(ArtifactPolicyExecutionMode.BASELINE);
      expect(result.fallbackCode).assertEqual(ArtifactPolicyFallbackCode.ACTIVE_REJECTED);
      expect(released.calls.length).assertEqual(0);
    });

    it('keepsBaselineWhenRegistryOrAssignmentThrows', 0, async () => {
      const registry: FixtureRegistryView = new FixtureRegistryView();
      registry.throwOnRead = true;
      const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        registry, new FixtureBaseline(), new FixtureReleased(), new FixtureAssignment(), config());
      const registryFailure = await runner.run(request());
      expect(registryFailure.executionMode).assertEqual(ArtifactPolicyExecutionMode.BASELINE);
      expect(registryFailure.fallbackCode).assertEqual(ArtifactPolicyFallbackCode.REGISTRY_FAILED);

      registry.throwOnRead = false;
      registry.canary = entry('canary-a', digest('a'), ArtifactLifecycleStatus.CANARY);
      const assignment: FixtureAssignment = new FixtureAssignment();
      assignment.throwOnAssign = true;
      const assignmentRunner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        registry, new FixtureBaseline(), new FixtureReleased(), assignment, config());
      const assignmentFailure = await assignmentRunner.run(request());
      expect(assignmentFailure.executionMode).assertEqual(ArtifactPolicyExecutionMode.BASELINE);
      expect(assignmentFailure.fallbackCode)
        .assertEqual(ArtifactPolicyFallbackCode.CANARY_ASSIGNMENT_FAILED);
    });

    it('failsClosedWhenRequestOrBaselineIsInvalid', 0, async () => {
      const registry: FixtureRegistryView = new FixtureRegistryView();
      const baseline: FixtureBaseline = new FixtureBaseline();
      const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        registry, baseline, new FixtureReleased(), new FixtureAssignment(), config());
      const invalid: ArtifactPolicyRequest = request();
      invalid.candidateIds = [];
      expect((await runner.run(invalid)).code).assertEqual(ArtifactPolicyRunCode.INVALID_REQUEST);
      expect(baseline.calls).assertEqual(0);
      baseline.selectedId = 'outside';
      expect((await runner.run(request())).code).assertEqual(ArtifactPolicyRunCode.BASELINE_FAILED);
    });

    it('isolatesRequestsArtifactsAndReturnedDecisions', 0, async () => {
      const registry: FixtureRegistryView = new FixtureRegistryView();
      registry.active = entry('active-a', digest('a'), ArtifactLifecycleStatus.ACTIVE);
      const baseline: FixtureBaseline = new FixtureBaseline();
      baseline.mutateRequest = true;
      const released: FixtureReleased = new FixtureReleased();
      released.mutateInputs = true;
      const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        registry, baseline, released, new FixtureAssignment(), config());
      const original: ArtifactPolicyRequest = request();
      const result = await runner.run(original);
      expect(original.candidateIds[0]).assertEqual('baseline');
      expect(registry.active?.manifest.artifactId).assertEqual('active-a');
      if (result.decision !== undefined) result.decision.selectedId = 'mutated';
      expect(result.baselineDecision?.selectedId).assertEqual('baseline');
    });

    it('rejectsInvalidAttemptTimeoutBeforeRunningPolicies', 0, () => {
      const invalid: ArtifactPolicyReleaseConfig = config();
      invalid.attemptTimeoutMs = 0;
      let rejected: boolean = false;
      try {
        new ArtifactPolicyReleaseRunner(new FixtureRegistryView(), new FixtureBaseline(),
          new FixtureReleased(), new FixtureAssignment(), invalid, new FixtureTimer());
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('stopsBeforeBaselineWhenCancellationWasAlreadyRequested', 0, async () => {
      const baseline: FixtureBaseline = new FixtureBaseline();
      const cancellation: ArtifactPolicyCancellationSource = new ArtifactPolicyCancellationSource();
      cancellation.cancel();
      const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        new FixtureRegistryView(), baseline, new FixtureReleased(), new FixtureAssignment(),
        config(), new FixtureTimer());
      const result = await runner.run(request(), cancellation);
      expect(result.accepted).assertFalse();
      expect(result.code).assertEqual(ArtifactPolicyRunCode.CANCELLED);
      expect(baseline.calls).assertEqual(0);
    });

    it('timesOutBaselineAndPropagatesCooperativeCancellation', 0, async () => {
      const baseline: FixtureBaseline = new FixtureBaseline();
      baseline.pending = true;
      const timer: FixtureTimer = new FixtureTimer();
      const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        new FixtureRegistryView(), baseline, new FixtureReleased(), new FixtureAssignment(), config(), timer);
      const pending: Promise<ArtifactPolicyRunResult> = runner.run(request());
      expect(timer.handles.length).assertEqual(1);
      timer.latest().fire();
      const result = await pending;
      expect(result.accepted).assertFalse();
      expect(result.code).assertEqual(ArtifactPolicyRunCode.BASELINE_TIMED_OUT);
      expect(baseline.cancellationObserved).assertTrue();
      expect(timer.latest().cancelled).assertTrue();
    });

    it('fallsBackToBaselineWhenActivePolicyTimesOut', 0, async () => {
      const registry: FixtureRegistryView = new FixtureRegistryView();
      registry.active = entry('active-a', digest('a'), ArtifactLifecycleStatus.ACTIVE);
      const released: FixtureReleased = new FixtureReleased();
      released.pendingArtifactId = 'active-a';
      const timer: FixtureTimer = new FixtureTimer();
      const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        registry, new FixtureBaseline(), released, new FixtureAssignment(), config(), timer);
      const pending: Promise<ArtifactPolicyRunResult> = runner.run(request());
      await flushPromises();
      expect(timer.handles.length).assertEqual(2);
      timer.latest().fire();
      const result = await pending;
      expect(result.executionMode).assertEqual(ArtifactPolicyExecutionMode.BASELINE);
      expect(result.fallbackCode).assertEqual(ArtifactPolicyFallbackCode.ACTIVE_TIMED_OUT);
      expect(result.decision?.selectedId).assertEqual('baseline');
      expect(released.cancellationObserved).assertTrue();
    });

    it('fallsBackFromTimedOutCanaryToCurrentActive', 0, async () => {
      const registry: FixtureRegistryView = new FixtureRegistryView();
      registry.canary = entry('canary-a', digest('a'), ArtifactLifecycleStatus.CANARY);
      registry.active = entry('active-a', digest('b'), ArtifactLifecycleStatus.ACTIVE);
      const released: FixtureReleased = new FixtureReleased();
      released.pendingArtifactId = 'canary-a';
      const assignment: FixtureAssignment = new FixtureAssignment();
      assignment.value = true;
      const timer: FixtureTimer = new FixtureTimer();
      const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        registry, new FixtureBaseline(), released, assignment, config(), timer);
      const pending: Promise<ArtifactPolicyRunResult> = runner.run(request());
      await flushPromises();
      expect(timer.handles.length).assertEqual(2);
      timer.latest().fire();
      const result = await pending;
      expect(result.executionMode).assertEqual(ArtifactPolicyExecutionMode.ACTIVE);
      expect(result.fallbackCode).assertEqual(ArtifactPolicyFallbackCode.CANARY_TIMED_OUT);
      expect(result.selectedArtifactDigest).assertEqual(digest('b'));
    });

    it('recordsTimedOutShadowWithoutChangingBaselineSelection', 0, async () => {
      const registry: FixtureRegistryView = new FixtureRegistryView();
      registry.shadows = [entry('shadow-a', digest('a'), ArtifactLifecycleStatus.SHADOW)];
      const released: FixtureReleased = new FixtureReleased();
      released.pendingArtifactId = 'shadow-a';
      const timer: FixtureTimer = new FixtureTimer();
      const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        registry, new FixtureBaseline(), released, new FixtureAssignment(), config(), timer);
      const pending: Promise<ArtifactPolicyRunResult> = runner.run(request());
      await flushPromises();
      expect(timer.handles.length).assertEqual(2);
      timer.latest().fire();
      const result = await pending;
      expect(result.executionMode).assertEqual(ArtifactPolicyExecutionMode.BASELINE);
      expect(result.fallbackCode).assertEqual(ArtifactPolicyFallbackCode.NO_RELEASE);
      expect(result.decision?.selectedId).assertEqual('baseline');
      expect(result.shadowObservations.length).assertEqual(1);
      expect(result.shadowObservations[0].code).assertEqual(ArtifactShadowObservationCode.TIMED_OUT);
      expect(released.cancellationObserved).assertTrue();
    });

    it('cancelsPendingActiveWithoutSelectingFallbackOrLateDecision', 0, async () => {
      const registry: FixtureRegistryView = new FixtureRegistryView();
      registry.active = entry('active-a', digest('a'), ArtifactLifecycleStatus.ACTIVE);
      const released: FixtureReleased = new FixtureReleased();
      released.pendingArtifactId = 'active-a';
      const cancellation: ArtifactPolicyCancellationSource = new ArtifactPolicyCancellationSource();
      const timer: FixtureTimer = new FixtureTimer();
      const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        registry, new FixtureBaseline(), released, new FixtureAssignment(), config(), timer);
      const pending: Promise<ArtifactPolicyRunResult> = runner.run(request(), cancellation);
      await flushPromises();
      cancellation.cancel();
      const result = await pending;
      expect(result.accepted).assertFalse();
      expect(result.code).assertEqual(ArtifactPolicyRunCode.CANCELLED);
      expect(result.decision === undefined).assertTrue();
      expect(result.selectedArtifactDigest).assertEqual('');
      expect(released.cancellationObserved).assertTrue();
      expect(timer.latest().cancelled).assertTrue();
    });
  });
}
