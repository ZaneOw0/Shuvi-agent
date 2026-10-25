import { ExecutionBudget, TaskFrame } from '@harmony_agent/agent-contracts';
import { CollaborationPlan } from '../orchestration/OrchestrationTypes';
import { CollaborationPlanSelectorPort } from '../orchestration/RuntimePorts';
import {
  ArtifactPolicyCancellationSignalPort,
  ArtifactPolicyCancellationSubscriptionPort,
  ArtifactPolicyTimerHandlePort,
  ArtifactPolicyTimerPort
} from '../artifact/ArtifactPolicyReleaseTypes';
import {
  ArtifactPolicyCancellationSource,
  SystemArtifactPolicyTimer
} from '../artifact/ArtifactPolicyExecutionControl';

/** The same instance must be bound as both preparation port and synchronous selector. */
export interface CollaborationPolicyPreparationPort extends CollaborationPlanSelectorPort {
  prepare(frame: TaskFrame, budget: ExecutionBudget,
    cancellation: ArtifactPolicyCancellationSignalPort): Promise<void>;
  selectBaselinePlan(frame: TaskFrame, maxAgentActivations: number): CollaborationPlan;
}

export enum CollaborationPreparationOutcome {
  READY = 'READY',
  FALLBACK = 'FALLBACK',
  INTERRUPTED = 'INTERRUPTED'
}

/** Bounds the entire preparation, including loaders which do not honor cancellation. */
export function prepareCollaboration(port: CollaborationPolicyPreparationPort, frame: TaskFrame,
  budget: ExecutionBudget, interruption: ArtifactPolicyCancellationSignalPort, timeoutMs: number,
  timer: ArtifactPolicyTimerPort = new SystemArtifactPolicyTimer()): Promise<CollaborationPreparationOutcome> {
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) {
    return Promise.reject(new Error('invalid collaboration preparation timeout'));
  }
  return new Promise<CollaborationPreparationOutcome>((resolve) => {
    const child: ArtifactPolicyCancellationSource = new ArtifactPolicyCancellationSource();
    let done: boolean = false;
    let timeout: ArtifactPolicyTimerHandlePort | undefined;
    let subscription: ArtifactPolicyCancellationSubscriptionPort | undefined;
    const finish = (outcome: CollaborationPreparationOutcome): void => {
      if (done) return;
      done = true;
      if (timeout !== undefined) timeout.cancel();
      if (subscription !== undefined) subscription.dispose();
      if (outcome !== CollaborationPreparationOutcome.READY) child.cancel();
      resolve(outcome);
    };
    subscription = interruption.subscribe(() => finish(CollaborationPreparationOutcome.INTERRUPTED));
    if (done) { subscription.dispose(); return; }
    timeout = timer.schedule(timeoutMs, () => finish(CollaborationPreparationOutcome.FALLBACK));
    if (done) { timeout.cancel(); return; }
    // Promise callback also captures synchronous exceptions from a host port.
    Promise.resolve().then(() => {
      if (done) return;
      return port.prepare(frame, budget, child);
    }).then(() => finish(CollaborationPreparationOutcome.READY),
      () => finish(CollaborationPreparationOutcome.FALLBACK));
  });
}
