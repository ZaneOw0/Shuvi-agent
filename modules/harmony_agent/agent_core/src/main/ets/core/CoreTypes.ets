import { AgentErrorClass } from '@harmony_agent/agent-contracts';
import {
  OperationJournalState,
  RecoveryAction,
  StepExecutionStatus,
  WorkflowRunState,
  WorkflowStepState
} from './CoreEnums';

export class GraphValidationResult {
  valid: boolean = true;
  issues: string[] = [];
}

export class StepExecutionResult {
  status: StepExecutionStatus = StepExecutionStatus.SUCCEEDED;
  outputJson: string = '';
  outputDigest: string = '';
  errorClass: AgentErrorClass = AgentErrorClass.UNKNOWN;
  errorCode: string = '';
}

export class StepRuntimeRecord {
  stepId: string = '';
  state: WorkflowStepState = WorkflowStepState.PENDING;
  attemptCount: number = 0;
  startedAtMs: number = 0;
  finishedAtMs: number = 0;
  lastErrorClass: AgentErrorClass = AgentErrorClass.UNKNOWN;
  outputDigest: string = '';
}

export class WorkflowRuntimeSnapshot {
  workflowId: string = '';
  taskId: string = '';
  runState: WorkflowRunState = WorkflowRunState.CREATED;
  steps: StepRuntimeRecord[] = [];
  cancellationRequested: boolean = false;
  deadlineAtMs: number = 0;
  terminalReason: string = '';
  nextEventSequence: number = 1;
}

export class RecoveryDecision {
  action: RecoveryAction = RecoveryAction.FAIL_TASK;
  reason: string = '';
}

export class WorkflowEvent {
  sequence: number = 0;
  eventType: string = '';
  stepId: string = '';
  stepState: WorkflowStepState = WorkflowStepState.PENDING;
  timestampMs: number = 0;
}

export class OperationJournalEntry {
  operationId: string = '';
  stepId: string = '';
  idempotencyKey: string = '';
  state: OperationJournalState = OperationJournalState.PREPARED;
  updatedAtMs: number = 0;
}
