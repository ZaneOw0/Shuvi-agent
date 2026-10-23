import {
  AgentRuntimeEvent,
  AgentTaskStatus,
  CollaborationMode,
  ContractCodec,
  ContractValidator,
  ToolInvocation,
  WorkflowGraph
} from '@harmony_agent/agent-contracts';
import { WorkflowGraphValidator, WorkflowRuntimeSnapshot } from '@harmony_agent/agent-core';
import {
  RUNTIME_TASK_RECOVERY_CHECKPOINT_VERSION,
  RuntimeTaskRecoveryCheckpoint
} from './OrchestrationTypes';
import { CollaborationPlanValidator } from './CollaborationPlanValidator';
import { normalizeTaskSubmission } from './SessionNormalization';

export class RuntimeCheckpointValidationResult {
  valid: boolean = false;
  issues: string[] = [];
}

function text(value: string): boolean {
  return value.trim().length > 0;
}

function count(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function json(value: string): boolean {
  try {
    JSON.parse(value);
    return true;
  } catch (error) {
    return false;
  }
}

function permitsMissingMultiPlan(value: RuntimeTaskRecoveryCheckpoint): boolean {
  if (value.snapshot.status !== AgentTaskStatus.FAILED) return false;
  return value.snapshot.resultJson === '{"reason":"agentActivationBudgetExhausted"}' ||
    value.snapshot.resultJson === '{"reason":"collaborationPlanRequired"}' ||
    value.snapshot.resultJson === '{"reason":"collaborationPlanSelectionFailed"}' ||
    value.snapshot.resultJson === '{"reason":"collaborationPlanInvalid"}';
}

/** Strict structural and binding validation before a checkpoint is trusted. */
export class RuntimeCheckpointValidator {
  static validate(value: RuntimeTaskRecoveryCheckpoint): RuntimeCheckpointValidationResult {
    const result: RuntimeCheckpointValidationResult = new RuntimeCheckpointValidationResult();
    try {
      if (value.checkpointVersion !== RUNTIME_TASK_RECOVERY_CHECKPOINT_VERSION && value.checkpointVersion !== '1.1') {
        result.issues.push('unsupported checkpointVersion');
      }
      if (!ContractValidator.validateTaskSubmission(value.submission).valid) {
        result.issues.push('invalid submission');
      }
      if (!ContractValidator.validateTaskEnvelope(value.envelope).valid) {
        result.issues.push('invalid envelope');
      }
      if (!ContractValidator.validateTaskHandle(value.handle).valid) {
        result.issues.push('invalid handle');
      }
      if (!ContractValidator.validateAgentTaskSnapshot(value.snapshot).valid) {
        result.issues.push('invalid snapshot');
      }
      if (value.checkpointVersion === '1.1') {
        if (value.collaborationMode !== CollaborationMode.SINGLE) result.issues.push('legacy MULTI is unsafe');
      } else {
        const preparation = value.collaborationPreparation;
        if (preparation.version !== '1.0' || !count(preparation.evaluations) || preparation.evaluations > 2 ||
          typeof preparation.pending !== 'boolean' || typeof preparation.baselineOnly !== 'boolean' ||
          (preparation.pending && preparation.evaluations === 0)) {
          result.issues.push('invalid collaboration preparation state');
        }
        if (preparation.evaluations > 0 && value.usage.agentActivations > value.envelope.executionBudget.maxAgentActivations) {
          result.issues.push('activation budget exceeded');
        }
      }
      RuntimeCheckpointValidator.validateIdentity(value, result);
      RuntimeCheckpointValidator.validateEvents(value, result);
      RuntimeCheckpointValidator.validatePlanning(value, result);
      RuntimeCheckpointValidator.validateWorkflow(value, result);
      RuntimeCheckpointValidator.validatePending(value, result);
      RuntimeCheckpointValidator.validateUsageAndProviders(value, result);
    } catch (error) {
      result.issues.push('checkpoint structure is unreadable');
    }
    result.valid = result.issues.length === 0;
    return result;
  }

  private static validateIdentity(value: RuntimeTaskRecoveryCheckpoint,
    result: RuntimeCheckpointValidationResult): void {
    const taskId: string = value.envelope.taskId;
    if (value.submission.requestId !== value.envelope.requestId ||
      ContractCodec.stringify(normalizeTaskSubmission(value.submission, value.handle)) !==
        ContractCodec.stringify(value.envelope)) {
      result.issues.push('submission normalization mismatch');
    }
    if (value.handle.requestId !== value.envelope.requestId ||
      value.snapshot.requestId !== value.envelope.requestId) {
      result.issues.push('requestId binding mismatch');
    }
    if (value.handle.taskId !== taskId || value.snapshot.taskId !== taskId) {
      result.issues.push('taskId binding mismatch');
    }
    if (value.handle.sessionId !== value.envelope.sessionId ||
      value.snapshot.sessionId !== value.envelope.sessionId) {
      result.issues.push('sessionId binding mismatch');
    }
    if (value.handle.snapshotVersion > value.snapshot.snapshotVersion) {
      result.issues.push('handle snapshotVersion is ahead of snapshot');
    }
    if (!json(value.snapshot.resultJson)) {
      result.issues.push('snapshot resultJson must be valid JSON');
    }
    if (value.paused !== (value.snapshot.status === AgentTaskStatus.PAUSED)) {
      result.issues.push('paused flag does not match snapshot status');
    }
  }

  private static validateEvents(value: RuntimeTaskRecoveryCheckpoint,
    result: RuntimeCheckpointValidationResult): void {
    if (value.events.length !== value.snapshot.lastEventSequence) {
      result.issues.push('event count does not match lastEventSequence');
    }
    for (let i: number = 0; i < value.events.length; i++) {
      const event: AgentRuntimeEvent = value.events[i];
      if (!ContractValidator.validateAgentRuntimeEvent(event).valid) {
        result.issues.push('events[' + i.toString() + '] is invalid');
      }
      if (event.taskId !== value.envelope.taskId || event.sequence !== i + 1) {
        result.issues.push('events[' + i.toString() + '] binding or sequence mismatch');
      }
      if (event.snapshotVersion > value.snapshot.snapshotVersion || !json(event.payloadJson)) {
        result.issues.push('events[' + i.toString() + '] version or payload is invalid');
      }
      if (i > 0 && event.snapshotVersion < value.events[i - 1].snapshotVersion) {
        result.issues.push('event snapshotVersion must be monotonic');
      }
    }
    if (value.events.length > 0 &&
      value.events[value.events.length - 1].snapshotVersion !== value.snapshot.snapshotVersion) {
      result.issues.push('last event version does not match snapshot');
    }
  }

  private static validatePlanning(value: RuntimeTaskRecoveryCheckpoint,
    result: RuntimeCheckpointValidationResult): void {
    if (value.snapshot.status === AgentTaskStatus.RECEIVED) return;
    if (value.frame.taskId !== value.envelope.taskId || !text(value.frame.goal) ||
      !json(value.frame.featuresJson)) {
      result.issues.push('frame is incomplete or bound to another task');
    }
    if (value.planningRequest.envelope.taskId !== value.envelope.taskId ||
      value.planningRequest.frame.taskId !== value.envelope.taskId ||
      value.planningRequest.collaborationMode !== value.collaborationMode) {
      result.issues.push('planningRequest binding mismatch');
    }
    if (value.planningRequest.collaborationPlan !== undefined) {
      const planValidation = CollaborationPlanValidator.validate(value.planningRequest.collaborationPlan,
        value.frame, value.envelope.executionBudget.maxAgentActivations);
      if (!planValidation.valid ||
        value.planningRequest.collaborationPlan.mode !== value.collaborationMode) {
        result.issues.push('collaborationPlan is invalid or not bound to collaborationMode');
      }
    } else if (value.collaborationMode === CollaborationMode.MULTI && !permitsMissingMultiPlan(value)) {
      result.issues.push('multi collaboration requires a collaborationPlan');
    }
    const previous: WorkflowGraph | undefined = value.planningRequest.previousWorkflow;
    if (previous !== undefined && (previous.taskId !== value.envelope.taskId ||
      !WorkflowGraphValidator.validate(previous).valid)) {
      result.issues.push('previousWorkflow is invalid');
    }
  }

  private static validateWorkflow(value: RuntimeTaskRecoveryCheckpoint,
    result: RuntimeCheckpointValidationResult): void {
    const workflow: WorkflowGraph | undefined = value.workflow;
    const scheduler: WorkflowRuntimeSnapshot | undefined = value.scheduler;
    if ((workflow === undefined) !== (scheduler === undefined)) {
      result.issues.push('workflow and scheduler must be present together');
      return;
    }
    if (workflow === undefined || scheduler === undefined) return;
    if (workflow.taskId !== value.envelope.taskId || !WorkflowGraphValidator.validate(workflow).valid) {
      result.issues.push('workflow is invalid or bound to another task');
    }
    if (scheduler.taskId !== value.envelope.taskId || scheduler.workflowId !== workflow.workflowId ||
      scheduler.steps.length !== workflow.steps.length || !count(scheduler.deadlineAtMs) ||
      !Number.isSafeInteger(scheduler.nextEventSequence) || scheduler.nextEventSequence <= 0) {
      result.issues.push('scheduler identity or counters are invalid');
    }
    for (let i: number = 0; i < scheduler.steps.length; i++) {
      const stepId: string = scheduler.steps[i].stepId;
      let workflowMatches: number = 0;
      for (let j: number = 0; j < workflow.steps.length; j++) {
        if (workflow.steps[j].stepId === stepId) workflowMatches++;
      }
      for (let j: number = 0; j < i; j++) {
        if (scheduler.steps[j].stepId === stepId) workflowMatches++;
      }
      if (workflowMatches !== 1 || !count(scheduler.steps[i].attemptCount) ||
        !count(scheduler.steps[i].startedAtMs) || !count(scheduler.steps[i].finishedAtMs)) {
        result.issues.push('scheduler step ' + stepId + ' is invalid');
      }
    }
  }

  private static validatePending(value: RuntimeTaskRecoveryCheckpoint,
    result: RuntimeCheckpointValidationResult): void {
    const taskId: string = value.envelope.taskId;
    if (value.pendingClarification !== undefined) {
      if (value.snapshot.status !== AgentTaskStatus.WAITING_INPUT ||
        value.pendingClarification.taskId !== taskId ||
        !ContractValidator.validateClarificationRequest(value.pendingClarification).valid) {
        result.issues.push('pendingClarification is invalid');
      }
    } else if (value.snapshot.status === AgentTaskStatus.WAITING_INPUT) {
      result.issues.push('waitingInput snapshot requires pendingClarification');
    }

    if (value.pendingPolicyRequest !== undefined) {
      if (value.snapshot.status !== AgentTaskStatus.WAITING_AUTHORIZATION ||
        value.pendingPolicyRequest.taskId !== taskId ||
        value.pendingPolicyRequest.stepId !== value.pendingStepId ||
        value.pendingPolicyRequest.operationId !== value.pendingOperationId ||
        !ContractValidator.validatePolicyRequest(value.pendingPolicyRequest).valid) {
        result.issues.push('pendingPolicyRequest is invalid');
      }
    } else if (value.snapshot.status === AgentTaskStatus.WAITING_AUTHORIZATION) {
      result.issues.push('waitingAuthorization snapshot requires pendingPolicyRequest');
    }

    if (value.pendingInvocation !== undefined) {
      RuntimeCheckpointValidator.validateInvocation(value, value.pendingInvocation,
        'pendingInvocation', false, result);
      if (value.pendingPolicyRequest === undefined) {
        result.issues.push('pendingInvocation requires pendingPolicyRequest');
      }
    }
    if (value.activeInvocation !== undefined) {
      RuntimeCheckpointValidator.validateInvocation(value, value.activeInvocation,
        'activeInvocation', true, result);
    }
    if (value.pendingInvocation !== undefined && value.activeInvocation !== undefined) {
      result.issues.push('pending and active invocation cannot coexist');
    }
    if (text(value.pendingDispatchId)) {
      if (!text(value.pendingStepId) || !text(value.pendingOperationId) || value.scheduler === undefined) {
        result.issues.push('pending dispatch binding is incomplete');
      }
    }
    if (value.snapshot.status === AgentTaskStatus.WAITING_RECONCILIATION &&
      (!text(value.pendingStepId) || !text(value.pendingOperationId))) {
      result.issues.push('waitingReconciliation snapshot requires step and operation');
    }
    if (RuntimeCheckpointValidator.terminal(value.snapshot.status) &&
      (text(value.pendingDispatchId) || text(value.pendingStepId) ||
      text(value.pendingOperationId) || value.pendingPolicyRequest !== undefined ||
      value.pendingClarification !== undefined || value.pendingInvocation !== undefined ||
      value.activeInvocation !== undefined)) {
      result.issues.push('terminal checkpoint retains pending state');
    }
  }

  private static validateInvocation(value: RuntimeTaskRecoveryCheckpoint, invocation: ToolInvocation,
    path: string, requireGrant: boolean, result: RuntimeCheckpointValidationResult): void {
    if (!text(invocation.invocationId) || invocation.taskId !== value.envelope.taskId ||
      invocation.stepId !== value.pendingStepId || invocation.operationId !== value.pendingOperationId ||
      !text(invocation.attemptId) || !text(invocation.toolId) ||
      !text(invocation.toolIdentityVersion) || !text(invocation.schemaDigest) ||
      !text(invocation.argumentsDigest) || !json(invocation.argumentsJson) ||
      !count(invocation.timeoutMs) ||
      (requireGrant ? !text(invocation.authorizationGrantId) : text(invocation.authorizationGrantId))) {
      result.issues.push(path + ' is invalid or not bound to pending state');
    }
  }

  private static validateUsageAndProviders(value: RuntimeTaskRecoveryCheckpoint,
    result: RuntimeCheckpointValidationResult): void {
    if (!count(value.usage.plannerCalls) || !count(value.usage.agentActivations) ||
      !count(value.usage.replans)) {
      result.issues.push('usage counters are invalid');
    }
    for (let i: number = 0; i < value.registeredProviderIds.length; i++) {
      if (!text(value.registeredProviderIds[i])) {
        result.issues.push('registeredProviderIds must not contain empty values');
      }
      for (let j: number = 0; j < i; j++) {
        if (value.registeredProviderIds[j] === value.registeredProviderIds[i]) {
          result.issues.push('registeredProviderIds must be unique');
        }
      }
    }
  }

  private static terminal(status: AgentTaskStatus): boolean {
    return status === AgentTaskStatus.COMPLETED || status === AgentTaskStatus.FAILED ||
      status === AgentTaskStatus.CANCELLED;
  }
}
