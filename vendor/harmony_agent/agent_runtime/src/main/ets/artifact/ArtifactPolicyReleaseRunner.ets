import { ArtifactKind, ArtifactLifecycleStatus } from '@harmony_agent/agent-contracts';
import { ArtifactRegistryEntry } from './ArtifactRegistryTypes';
import {
  ARTIFACT_POLICY_RELEASE_VERSION,
  ArtifactBaselinePolicyPort,
  ArtifactCanaryAssignmentPort,
  ArtifactCanaryBucketPort,
  ArtifactPolicyCancellationSignalPort,
  ArtifactPolicyCancellationSubscriptionPort,
  ArtifactPolicyDecision,
  ArtifactPolicyExecutionMode,
  ArtifactPolicyFallbackCode,
  ArtifactPolicyReleaseConfig,
  ArtifactPolicyRequest,
  ArtifactPolicyRunCode,
  ArtifactPolicyRunResult,
  ArtifactPolicyTimerHandlePort,
  ArtifactPolicyTimerPort,
  ArtifactReleaseRegistryViewPort,
  ArtifactReleasedPolicyPort,
  ArtifactShadowObservation,
  ArtifactShadowObservationCode,
  copyArtifactForRelease,
  copyArtifactPolicyDecision,
  copyArtifactPolicyRequest
} from './ArtifactPolicyReleaseTypes';
import {
  ArtifactPolicyCancellationSource,
  SystemArtifactPolicyTimer
} from './ArtifactPolicyExecutionControl';

function validText(value: string): boolean {
  return value.trim().length > 0;
}

function validKind(value: ArtifactKind): boolean {
  return value === ArtifactKind.CHECKPOINT || value === ArtifactKind.POLICY || value === ArtifactKind.WORKFLOW;
}

function validJsonObject(value: string, requireNonEmpty: boolean): boolean {
  if (!validText(value)) return false;
  let parsed: Object;
  try {
    parsed = JSON.parse(value) as Object;
  } catch (error) {
    return false;
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return false;
  return !requireNonEmpty || Object.keys(parsed).length > 0;
}

function validRequest(value: ArtifactPolicyRequest): boolean {
  if (value.version !== ARTIFACT_POLICY_RELEASE_VERSION || !validText(value.requestId) ||
    !validKind(value.artifactKind) || value.candidateIds.length === 0 ||
    !validJsonObject(value.inputJson, false)) return false;
  for (let i: number = 0; i < value.candidateIds.length; i++) {
    if (!validText(value.candidateIds[i])) return false;
    for (let j: number = 0; j < i; j++) {
      if (value.candidateIds[i] === value.candidateIds[j]) return false;
    }
  }
  return true;
}

function includes(values: string[], expected: string): boolean {
  for (let i: number = 0; i < values.length; i++) if (values[i] === expected) return true;
  return false;
}

function cancellationRequested(signal: ArtifactPolicyCancellationSignalPort): boolean {
  try {
    return signal.isCancellationRequested();
  } catch (error) {
    return true;
  }
}

function validDecision(value: ArtifactPolicyDecision, candidates: string[]): boolean {
  return validText(value.selectedId) && includes(candidates, value.selectedId) &&
    validJsonObject(value.evidenceJson, true);
}

function validRegistryEntry(value: ArtifactRegistryEntry, kind: ArtifactKind,
  expectedStatus: ArtifactLifecycleStatus): boolean {
  return validText(value.manifest.artifactId) && value.manifest.artifactKind === kind &&
    value.manifest.lifecycleStatus === expectedStatus &&
    /^sha256:[0-9a-f]{64}$/.test(value.manifest.artifactDigest) &&
    /^sha256:[0-9a-f]{64}$/.test(value.packageDigest);
}

enum CandidateAttemptCode {
  ACCEPTED = 'ACCEPTED',
  REJECTED = 'REJECTED',
  FAILED = 'FAILED',
  TIMED_OUT = 'TIMED_OUT',
  CANCELLED = 'CANCELLED'
}

class CandidateAttempt {
  code: CandidateAttemptCode = CandidateAttemptCode.REJECTED;
  decision?: ArtifactPolicyDecision;
}

type ArtifactPolicyDecisionFactory =
  (cancellation: ArtifactPolicyCancellationSignalPort) => Promise<ArtifactPolicyDecision>;

export class DeterministicArtifactCanaryAssignment implements ArtifactCanaryAssignmentPort {
  private readonly bucketPort: ArtifactCanaryBucketPort;

  constructor(bucketPort: ArtifactCanaryBucketPort) {
    this.bucketPort = bucketPort;
  }

  assigned(requestId: string, artifactDigest: string, trafficBasisPoints: number): boolean {
    if (!validText(requestId) || !/^sha256:[0-9a-f]{64}$/.test(artifactDigest) ||
      !Number.isSafeInteger(trafficBasisPoints) || trafficBasisPoints < 0 || trafficBasisPoints > 10000) {
      throw new Error('canary assignment input is invalid');
    }
    if (trafficBasisPoints === 0) return false;
    if (trafficBasisPoints === 10000) return true;
    const bucket: number = this.bucketPort.bucket(requestId, artifactDigest);
    if (!Number.isSafeInteger(bucket) || bucket < 0 || bucket >= 10000) {
      throw new Error('canary bucket must be between 0 and 9999');
    }
    return bucket < trafficBasisPoints;
  }
}

export class ArtifactPolicyReleaseRunner {
  private readonly registry: ArtifactReleaseRegistryViewPort;
  private readonly baseline: ArtifactBaselinePolicyPort;
  private readonly released: ArtifactReleasedPolicyPort;
  private readonly assignment: ArtifactCanaryAssignmentPort;
  private readonly config: ArtifactPolicyReleaseConfig;
  private readonly timer: ArtifactPolicyTimerPort;

  constructor(registry: ArtifactReleaseRegistryViewPort, baseline: ArtifactBaselinePolicyPort,
    released: ArtifactReleasedPolicyPort, assignment: ArtifactCanaryAssignmentPort,
    config: ArtifactPolicyReleaseConfig, timer?: ArtifactPolicyTimerPort) {
    if (!Number.isSafeInteger(config.canaryTrafficBasisPoints) || config.canaryTrafficBasisPoints < 0 ||
      config.canaryTrafficBasisPoints > 10000 || !Number.isSafeInteger(config.maxShadowEvaluations) ||
      config.maxShadowEvaluations < 0 || !Number.isSafeInteger(config.attemptTimeoutMs) ||
      config.attemptTimeoutMs <= 0) {
      throw new Error('artifact release config is invalid');
    }
    this.registry = registry;
    this.baseline = baseline;
    this.released = released;
    this.assignment = assignment;
    this.config = new ArtifactPolicyReleaseConfig();
    this.config.canaryTrafficBasisPoints = config.canaryTrafficBasisPoints;
    this.config.maxShadowEvaluations = config.maxShadowEvaluations;
    this.config.attemptTimeoutMs = config.attemptTimeoutMs;
    this.timer = timer === undefined ? new SystemArtifactPolicyTimer() : timer;
  }

  async run(request: ArtifactPolicyRequest,
    cancellation?: ArtifactPolicyCancellationSignalPort): Promise<ArtifactPolicyRunResult> {
    const result: ArtifactPolicyRunResult = new ArtifactPolicyRunResult();
    if (!validRequest(request)) return result;
    const signal: ArtifactPolicyCancellationSignalPort = cancellation === undefined ?
      new ArtifactPolicyCancellationSource() : cancellation;
    if (cancellationRequested(signal)) return this.cancelled(result);
    const baselineAttempt: CandidateAttempt = await this.execute(signal,
      (attemptCancellation: ArtifactPolicyCancellationSignalPort): Promise<ArtifactPolicyDecision> => {
        return this.baseline.decide(copyArtifactPolicyRequest(request), attemptCancellation);
      }, request.candidateIds);
    if (baselineAttempt.code === CandidateAttemptCode.CANCELLED) return this.cancelled(result);
    if (baselineAttempt.code === CandidateAttemptCode.TIMED_OUT) {
      result.code = ArtifactPolicyRunCode.BASELINE_TIMED_OUT;
      return result;
    }
    if (baselineAttempt.code !== CandidateAttemptCode.ACCEPTED || baselineAttempt.decision === undefined) {
      result.code = ArtifactPolicyRunCode.BASELINE_FAILED;
      return result;
    }
    const baselineDecision: ArtifactPolicyDecision = baselineAttempt.decision;
    if (!validDecision(baselineDecision, request.candidateIds)) {
      result.code = ArtifactPolicyRunCode.BASELINE_FAILED;
      return result;
    }
    result.baselineDecision = copyArtifactPolicyDecision(baselineDecision);
    if (cancellationRequested(signal)) return this.cancelled(result);

    let shadows: ArtifactRegistryEntry[];
    let canary: ArtifactRegistryEntry | undefined;
    let active: ArtifactRegistryEntry | undefined;
    try {
      shadows = this.registry.shadowArtifacts(request.artifactKind);
      canary = this.registry.canaryArtifact(request.artifactKind);
      active = this.registry.activeArtifact(request.artifactKind);
    } catch (error) {
      return this.useBaseline(result, baselineDecision, ArtifactPolicyFallbackCode.REGISTRY_FAILED);
    }
    const shadowCancelled: boolean = await this.observeShadows(result, shadows, request, signal);
    if (shadowCancelled || cancellationRequested(signal)) return this.cancelled(result);

    let canaryFallback: ArtifactPolicyFallbackCode = ArtifactPolicyFallbackCode.NONE;
    if (canary !== undefined) {
      if (!validRegistryEntry(canary, request.artifactKind, ArtifactLifecycleStatus.CANARY)) {
        canaryFallback = ArtifactPolicyFallbackCode.CANARY_REJECTED;
      }
      let assigned: boolean = false;
      if (canaryFallback === ArtifactPolicyFallbackCode.NONE && this.config.canaryTrafficBasisPoints > 0) {
        try {
          assigned = this.assignment.assigned(
            request.requestId, canary.manifest.artifactDigest, this.config.canaryTrafficBasisPoints);
        } catch (error) {
          canaryFallback = ArtifactPolicyFallbackCode.CANARY_ASSIGNMENT_FAILED;
        }
      }
      if (canaryFallback === ArtifactPolicyFallbackCode.NONE && assigned) {
        const attempt: CandidateAttempt = await this.attempt(canary, request, signal);
        if (attempt.code === CandidateAttemptCode.CANCELLED) return this.cancelled(result);
        if (attempt.code === CandidateAttemptCode.ACCEPTED && attempt.decision !== undefined) {
          return this.useReleased(result, attempt.decision, canary.manifest.artifactDigest,
            ArtifactPolicyExecutionMode.CANARY, ArtifactPolicyFallbackCode.NONE);
        }
        if (attempt.code === CandidateAttemptCode.TIMED_OUT) {
          canaryFallback = ArtifactPolicyFallbackCode.CANARY_TIMED_OUT;
        } else {
          canaryFallback = attempt.code === CandidateAttemptCode.FAILED ?
            ArtifactPolicyFallbackCode.CANARY_FAILED : ArtifactPolicyFallbackCode.CANARY_REJECTED;
        }
      } else if (canaryFallback === ArtifactPolicyFallbackCode.NONE) {
        canaryFallback = ArtifactPolicyFallbackCode.CANARY_NOT_ASSIGNED;
      }
    }

    if (active !== undefined) {
      if (!validRegistryEntry(active, request.artifactKind, ArtifactLifecycleStatus.ACTIVE)) {
        return this.useBaseline(result, baselineDecision, ArtifactPolicyFallbackCode.ACTIVE_REJECTED);
      }
      if (cancellationRequested(signal)) return this.cancelled(result);
      const attempt: CandidateAttempt = await this.attempt(active, request, signal);
      if (attempt.code === CandidateAttemptCode.CANCELLED) return this.cancelled(result);
      if (attempt.code === CandidateAttemptCode.ACCEPTED && attempt.decision !== undefined) {
        return this.useReleased(result, attempt.decision, active.manifest.artifactDigest,
          ArtifactPolicyExecutionMode.ACTIVE, canaryFallback);
      }
      if (attempt.code === CandidateAttemptCode.TIMED_OUT) {
        return this.useBaseline(result, baselineDecision, ArtifactPolicyFallbackCode.ACTIVE_TIMED_OUT);
      }
      return this.useBaseline(result, baselineDecision, attempt.code === CandidateAttemptCode.FAILED ?
        ArtifactPolicyFallbackCode.ACTIVE_FAILED : ArtifactPolicyFallbackCode.ACTIVE_REJECTED);
    }
    return this.useBaseline(result, baselineDecision,
      canaryFallback === ArtifactPolicyFallbackCode.NONE ? ArtifactPolicyFallbackCode.NO_RELEASE : canaryFallback);
  }

  private async observeShadows(result: ArtifactPolicyRunResult, shadows: ArtifactRegistryEntry[],
    request: ArtifactPolicyRequest, cancellation: ArtifactPolicyCancellationSignalPort): Promise<boolean> {
    const count: number = Math.min(shadows.length, this.config.maxShadowEvaluations);
    for (let i: number = 0; i < count; i++) {
      if (cancellationRequested(cancellation)) return true;
      const observation: ArtifactShadowObservation = new ArtifactShadowObservation();
      observation.artifactId = shadows[i].manifest.artifactId;
      observation.artifactDigest = shadows[i].manifest.artifactDigest;
      if (!validRegistryEntry(shadows[i], request.artifactKind, ArtifactLifecycleStatus.SHADOW)) {
        observation.code = ArtifactShadowObservationCode.REJECTED;
        result.shadowObservations.push(observation);
        continue;
      }
      const attempt: CandidateAttempt = await this.attempt(shadows[i], request, cancellation);
      if (attempt.code === CandidateAttemptCode.CANCELLED) {
        observation.code = ArtifactShadowObservationCode.CANCELLED;
        result.shadowObservations.push(observation);
        return true;
      }
      if (attempt.code === CandidateAttemptCode.ACCEPTED && attempt.decision !== undefined) {
        observation.code = ArtifactShadowObservationCode.ACCEPTED;
        observation.selectedId = attempt.decision.selectedId;
      } else if (attempt.code === CandidateAttemptCode.TIMED_OUT) {
        observation.code = ArtifactShadowObservationCode.TIMED_OUT;
      } else {
        observation.code = attempt.code === CandidateAttemptCode.FAILED ?
          ArtifactShadowObservationCode.FAILED : ArtifactShadowObservationCode.REJECTED;
      }
      result.shadowObservations.push(observation);
    }
    return false;
  }

  private attempt(artifact: ArtifactRegistryEntry, request: ArtifactPolicyRequest,
    cancellation: ArtifactPolicyCancellationSignalPort): Promise<CandidateAttempt> {
    return this.execute(cancellation,
      (attemptCancellation: ArtifactPolicyCancellationSignalPort): Promise<ArtifactPolicyDecision> => {
        return this.released.decide(copyArtifactForRelease(artifact),
          copyArtifactPolicyRequest(request), attemptCancellation);
      }, request.candidateIds);
  }

  private execute(cancellation: ArtifactPolicyCancellationSignalPort,
    factory: ArtifactPolicyDecisionFactory, candidates?: string[]): Promise<CandidateAttempt> {
    return new Promise<CandidateAttempt>((resolve: (value: CandidateAttempt) => void): void => {
      const attemptCancellation: ArtifactPolicyCancellationSource = new ArtifactPolicyCancellationSource();
      let settled: boolean = false;
      let timerHandle: ArtifactPolicyTimerHandlePort | undefined = undefined;
      let subscription: ArtifactPolicyCancellationSubscriptionPort | undefined = undefined;

      const cleanup = (): void => {
        const timer: ArtifactPolicyTimerHandlePort | undefined = timerHandle;
        const observer: ArtifactPolicyCancellationSubscriptionPort | undefined = subscription;
        if (timer !== undefined) {
          try {
            timer.cancel();
          } catch (error) {
          }
        }
        if (observer !== undefined) {
          try {
            observer.dispose();
          } catch (error) {
          }
        }
      };
      const finish = (code: CandidateAttemptCode, decision?: ArtifactPolicyDecision): void => {
        if (settled) return;
        settled = true;
        if (code === CandidateAttemptCode.TIMED_OUT || code === CandidateAttemptCode.CANCELLED ||
          code === CandidateAttemptCode.FAILED) attemptCancellation.cancel();
        cleanup();
        const result: CandidateAttempt = new CandidateAttempt();
        result.code = code;
        if (decision !== undefined) result.decision = copyArtifactPolicyDecision(decision);
        resolve(result);
      };

      try {
        subscription = cancellation.subscribe((): void => {
          finish(CandidateAttemptCode.CANCELLED);
        });
      } catch (error) {
        finish(CandidateAttemptCode.FAILED);
        return;
      }
      if (settled) {
        // A cancellation source may invoke the listener synchronously before subscribe returns.
        const observer: ArtifactPolicyCancellationSubscriptionPort | undefined = subscription;
        if (observer !== undefined) observer.dispose();
        return;
      }
      if (cancellationRequested(cancellation)) {
        finish(CandidateAttemptCode.CANCELLED);
        return;
      }
      try {
        timerHandle = this.timer.schedule(this.config.attemptTimeoutMs, (): void => {
          finish(CandidateAttemptCode.TIMED_OUT);
        });
      } catch (error) {
        finish(CandidateAttemptCode.FAILED);
        return;
      }
      let operation: Promise<ArtifactPolicyDecision>;
      try {
        operation = factory(attemptCancellation);
      } catch (error) {
        finish(CandidateAttemptCode.FAILED);
        return;
      }
      operation.then((decision: ArtifactPolicyDecision): void => {
        if (settled) return;
        if (candidates !== undefined && !validDecision(decision, candidates)) {
          finish(CandidateAttemptCode.REJECTED);
          return;
        }
        finish(CandidateAttemptCode.ACCEPTED, decision);
      }).catch((error: Object): void => {
        finish(CandidateAttemptCode.FAILED);
      });
    });
  }

  private cancelled(result: ArtifactPolicyRunResult): ArtifactPolicyRunResult {
    result.accepted = false;
    result.code = ArtifactPolicyRunCode.CANCELLED;
    result.executionMode = ArtifactPolicyExecutionMode.BASELINE;
    result.fallbackCode = ArtifactPolicyFallbackCode.NONE;
    result.selectedArtifactDigest = '';
    result.decision = undefined;
    return result;
  }

  private useReleased(result: ArtifactPolicyRunResult, decision: ArtifactPolicyDecision,
    artifactDigest: string, mode: ArtifactPolicyExecutionMode,
    fallback: ArtifactPolicyFallbackCode): ArtifactPolicyRunResult {
    result.accepted = true;
    result.code = ArtifactPolicyRunCode.SUCCESS;
    result.executionMode = mode;
    result.fallbackCode = fallback;
    result.selectedArtifactDigest = artifactDigest;
    result.decision = copyArtifactPolicyDecision(decision);
    return result;
  }

  private useBaseline(result: ArtifactPolicyRunResult, baseline: ArtifactPolicyDecision,
    fallback: ArtifactPolicyFallbackCode): ArtifactPolicyRunResult {
    result.accepted = true;
    result.code = ArtifactPolicyRunCode.SUCCESS;
    result.executionMode = ArtifactPolicyExecutionMode.BASELINE;
    result.fallbackCode = fallback;
    result.selectedArtifactDigest = '';
    result.decision = copyArtifactPolicyDecision(baseline);
    return result;
  }
}
