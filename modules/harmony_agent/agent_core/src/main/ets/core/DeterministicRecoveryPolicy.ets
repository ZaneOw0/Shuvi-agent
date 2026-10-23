import { AgentErrorClass, SideEffect, WorkflowStep } from '@harmony_agent/agent-contracts';
import { RecoveryAction, StepExecutionStatus } from './CoreEnums';
import { RecoveryDecision, StepExecutionResult, StepRuntimeRecord } from './CoreTypes';

export class DeterministicRecoveryPolicy {
  private maxRetries: number;

  constructor(maxRetries: number) {
    this.maxRetries = maxRetries < 0 ? 0 : Math.floor(maxRetries);
  }

  decide(step: WorkflowStep, record: StepRuntimeRecord, result: StepExecutionResult): RecoveryDecision {
    const decision: RecoveryDecision = new RecoveryDecision();
    if (result.status === StepExecutionStatus.CANCELLED || result.errorClass === AgentErrorClass.CANCELLED) {
      decision.action = RecoveryAction.CANCEL_TASK;
      decision.reason = 'execution was cancelled';
      return decision;
    }
    if (result.status === StepExecutionStatus.UNKNOWN_OUTCOME) {
      decision.action = RecoveryAction.RECONCILE;
      decision.reason = 'execution outcome is unknown';
      return decision;
    }
    if (result.errorClass === AgentErrorClass.POLICY_DENIED ||
      result.errorClass === AgentErrorClass.PERMISSION_DENIED ||
      result.errorClass === AgentErrorClass.AUTHENTICATION ||
      result.errorClass === AgentErrorClass.BUDGET_EXHAUSTED ||
      result.errorClass === AgentErrorClass.INVALID_INPUT ||
      result.errorClass === AgentErrorClass.CONFIGURATION) {
      decision.action = RecoveryAction.FAIL_TASK;
      decision.reason = 'failure requires external correction';
      return decision;
    }
    if (result.errorClass === AgentErrorClass.VERIFICATION_FAILED ||
      result.errorClass === AgentErrorClass.SCHEMA_MISMATCH) {
      decision.action = RecoveryAction.REPLAN_STEP;
      decision.reason = 'output did not satisfy verification requirements';
      return decision;
    }
    if (step.sideEffect === SideEffect.NONE && record.attemptCount <= this.maxRetries &&
      (result.errorClass === AgentErrorClass.NETWORK || result.errorClass === AgentErrorClass.TIMEOUT ||
      result.errorClass === AgentErrorClass.PROVIDER || result.errorClass === AgentErrorClass.UNKNOWN)) {
      decision.action = RecoveryAction.RETRY_STEP;
      decision.reason = 'transient side-effect-free failure is within retry budget';
      return decision;
    }
    decision.action = RecoveryAction.FAIL_TASK;
    decision.reason = 'no safe deterministic recovery action remains';
    return decision;
  }
}
