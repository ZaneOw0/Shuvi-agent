export enum WorkflowRunState {
  CREATED = 'created',
  RUNNING = 'running',
  RECOVERING = 'recovering',
  WAITING_RECONCILIATION = 'waitingReconciliation',
  COMPLETED = 'completed',
  FAILED = 'failed',
  CANCELLED = 'cancelled'
}

export enum WorkflowStepState {
  PENDING = 'pending',
  READY = 'ready',
  RUNNING = 'running',
  VERIFYING = 'verifying',
  SUCCEEDED = 'succeeded',
  FAILED = 'failed',
  CANCELLED = 'cancelled',
  UNKNOWN_OUTCOME = 'unknownOutcome'
}

export enum StepExecutionStatus {
  SUCCEEDED = 'succeeded',
  FAILED = 'failed',
  CANCELLED = 'cancelled',
  UNKNOWN_OUTCOME = 'unknownOutcome'
}

export enum RecoveryAction {
  RETRY_STEP = 'retryStep',
  RECONCILE = 'reconcile',
  REPLAN_STEP = 'replanStep',
  FAIL_TASK = 'failTask',
  CANCEL_TASK = 'cancelTask'
}

export enum OperationJournalState {
  PREPARED = 'prepared',
  IN_FLIGHT = 'inFlight',
  RESULT_RECORDED = 'resultRecorded',
  COMMITTED = 'committed',
  UNKNOWN_OUTCOME = 'unknownOutcome'
}

export enum BudgetScopeKind {
  TASK = 'task',
  STEP = 'step',
  PROVIDER = 'provider'
}

export enum BudgetReservationState {
  RESERVED = 'reserved',
  SETTLED = 'settled',
  RELEASED = 'released',
  UNKNOWN = 'unknown'
}
