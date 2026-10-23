import { AgentErrorClass, ContractCodec, SideEffect, WorkflowGraph, WorkflowStep } from '@harmony_agent/agent-contracts';
import { RecoveryAction, StepExecutionStatus, WorkflowRunState, WorkflowStepState } from './CoreEnums';
import {
  GraphValidationResult,
  RecoveryDecision,
  StepExecutionResult,
  StepRuntimeRecord,
  WorkflowEvent,
  WorkflowRuntimeSnapshot
} from './CoreTypes';
import { WorkflowGraphValidator } from './WorkflowGraphValidator';
import { WorkflowKernelError } from './WorkflowKernelError';

export class WorkflowScheduler {
  private graph: WorkflowGraph;
  private records: StepRuntimeRecord[] = [];
  private events: WorkflowEvent[] = [];
  private state: WorkflowRunState = WorkflowRunState.CREATED;
  private cancellationRequested: boolean = false;
  private deadlineAtMs: number = 0;
  private terminalReason: string = '';
  private nextSequence: number = 1;

  constructor(graph: WorkflowGraph) {
    const validation: GraphValidationResult = WorkflowGraphValidator.validate(graph);
    if (!validation.valid) {
      throw new WorkflowKernelError('Invalid workflow graph: ' + validation.issues.join('; '));
    }
    this.graph = ContractCodec.parseWorkflowGraph(ContractCodec.stringify(graph));
    for (let i: number = 0; i < this.graph.steps.length; i++) {
      const record: StepRuntimeRecord = new StepRuntimeRecord();
      record.stepId = this.graph.steps[i].stepId;
      this.records.push(record);
    }
  }

  start(nowMs: number, deadlineAtMs: number = 0): void {
    if (this.state !== WorkflowRunState.CREATED && this.state !== WorkflowRunState.RECOVERING) {
      throw new WorkflowKernelError('Workflow can only start from created or recovering state');
    }
    if (deadlineAtMs > 0 && deadlineAtMs <= nowMs) {
      this.deadlineAtMs = deadlineAtMs;
      this.failForDeadline(nowMs);
      return;
    }
    this.deadlineAtMs = deadlineAtMs;
    this.state = WorkflowRunState.RUNNING;
    this.appendEvent('workflow.started', '', WorkflowStepState.PENDING, nowMs);
    this.refreshReady(nowMs);
  }

  getRunState(): WorkflowRunState {
    return this.state;
  }

  getTerminalReason(): string {
    return this.terminalReason;
  }

  readyStepIds(): string[] {
    const result: string[] = [];
    if (this.state !== WorkflowRunState.RUNNING || this.cancellationRequested) {
      return result;
    }
    if (this.hasRunningSideEffect()) {
      return result;
    }
    const hasRunningStep: boolean = this.hasRunningStep();
    for (let i: number = 0; i < this.records.length; i++) {
      if (this.records[i].state === WorkflowStepState.READY) {
        if (this.graph.steps[i].sideEffect !== SideEffect.NONE) {
          if (!hasRunningStep && result.length === 0) {
            result.push(this.records[i].stepId);
          }
          break;
        }
        result.push(this.records[i].stepId);
      }
    }
    return result;
  }

  getStepRecord(stepId: string): StepRuntimeRecord {
    const index: number = this.findRecordIndex(stepId);
    if (index < 0) {
      throw new WorkflowKernelError('Unknown step ' + stepId);
    }
    return WorkflowScheduler.copyRecord(this.records[index]);
  }

  getEvents(): WorkflowEvent[] {
    const copies: WorkflowEvent[] = [];
    for (let i: number = 0; i < this.events.length; i++) {
      const copy: WorkflowEvent = new WorkflowEvent();
      copy.sequence = this.events[i].sequence;
      copy.eventType = this.events[i].eventType;
      copy.stepId = this.events[i].stepId;
      copy.stepState = this.events[i].stepState;
      copy.timestampMs = this.events[i].timestampMs;
      copies.push(copy);
    }
    return copies;
  }

  markRunning(stepId: string, nowMs: number): void {
    this.requireActive();
    this.enforceDeadline(nowMs);
    this.requireActive();
    const record: StepRuntimeRecord = this.requireRecord(stepId);
    if (record.state !== WorkflowStepState.READY) {
      throw new WorkflowKernelError('Step ' + stepId + ' is not ready');
    }
    if (!this.contains(this.readyStepIds(), stepId)) {
      throw new WorkflowKernelError('Step ' + stepId + ' conflicts with an in-flight step');
    }
    record.state = WorkflowStepState.RUNNING;
    record.attemptCount++;
    record.startedAtMs = nowMs;
    record.finishedAtMs = 0;
    this.appendEvent('step.running', stepId, record.state, nowMs);
  }

  markVerifying(stepId: string, nowMs: number): void {
    this.requireActive();
    this.enforceDeadline(nowMs);
    this.requireActive();
    const record: StepRuntimeRecord = this.requireRecord(stepId);
    if (record.state !== WorkflowStepState.RUNNING) {
      throw new WorkflowKernelError('Step ' + stepId + ' is not running');
    }
    record.state = WorkflowStepState.VERIFYING;
    this.appendEvent('step.verifying', stepId, record.state, nowMs);
  }

  completeStep(stepId: string, result: StepExecutionResult, nowMs: number): void {
    this.requireActive();
    this.enforceDeadline(nowMs);
    this.requireActive();
    const record: StepRuntimeRecord = this.requireRecord(stepId);
    if (record.state !== WorkflowStepState.RUNNING && record.state !== WorkflowStepState.VERIFYING) {
      throw new WorkflowKernelError('Step ' + stepId + ' is not running or verifying');
    }
    if (result.status === StepExecutionStatus.SUCCEEDED) {
      if (record.state !== WorkflowStepState.VERIFYING) {
        throw new WorkflowKernelError('Successful step ' + stepId + ' must be verified before completion');
      }
      record.finishedAtMs = nowMs;
      record.outputDigest = result.outputDigest;
      record.lastErrorClass = result.errorClass;
      record.state = WorkflowStepState.SUCCEEDED;
      this.appendEvent('step.succeeded', stepId, record.state, nowMs);
      this.refreshReady(nowMs);
      this.completeIfFinished(nowMs);
      return;
    }
    record.finishedAtMs = nowMs;
    record.outputDigest = result.outputDigest;
    record.lastErrorClass = result.errorClass;
    if (result.status === StepExecutionStatus.CANCELLED) {
      record.state = WorkflowStepState.CANCELLED;
      this.appendEvent('step.cancelled', stepId, record.state, nowMs);
      this.cancel('step cancelled: ' + stepId, nowMs);
      return;
    }
    if (result.status === StepExecutionStatus.UNKNOWN_OUTCOME) {
      record.state = WorkflowStepState.UNKNOWN_OUTCOME;
      this.state = WorkflowRunState.WAITING_RECONCILIATION;
      this.terminalReason = 'unknown outcome: ' + stepId;
      this.appendEvent('step.unknownOutcome', stepId, record.state, nowMs);
      return;
    }
    record.state = WorkflowStepState.FAILED;
    this.appendEvent('step.failed', stepId, record.state, nowMs);
    this.state = WorkflowRunState.RECOVERING;
    this.terminalReason = 'step failed: ' + stepId;
    this.appendEvent('workflow.recovering', stepId, record.state, nowMs);
  }

  applyRecoveryDecision(stepId: string, decision: RecoveryDecision, nowMs: number): void {
    const record: StepRuntimeRecord = this.requireRecord(stepId);
    if (decision.action === RecoveryAction.RETRY_STEP) {
      if (this.state !== WorkflowRunState.RECOVERING || record.state !== WorkflowStepState.FAILED) {
        throw new WorkflowKernelError('Retry requires a failed step in recovering state');
      }
      record.state = WorkflowStepState.PENDING;
      record.finishedAtMs = 0;
      record.lastErrorClass = AgentErrorClass.UNKNOWN;
      record.outputDigest = '';
      this.state = WorkflowRunState.RUNNING;
      this.terminalReason = '';
      this.appendEvent('step.retryScheduled', stepId, record.state, nowMs);
      this.refreshReady(nowMs);
      return;
    }
    if (decision.action === RecoveryAction.CANCEL_TASK) {
      this.cancel(decision.reason, nowMs);
      return;
    }
    if (decision.action === RecoveryAction.RECONCILE) {
      if (record.state !== WorkflowStepState.UNKNOWN_OUTCOME) {
        throw new WorkflowKernelError('Reconciliation requires an unknown step outcome');
      }
      this.state = WorkflowRunState.WAITING_RECONCILIATION;
      this.terminalReason = decision.reason;
      this.appendEvent('workflow.reconciliationRequired', stepId, record.state, nowMs);
      return;
    }
    if (decision.action === RecoveryAction.REPLAN_STEP) {
      if (this.state !== WorkflowRunState.RECOVERING || record.state !== WorkflowStepState.FAILED) {
        throw new WorkflowKernelError('Replan requires a failed step in recovering state');
      }
      this.terminalReason = decision.reason;
      this.appendEvent('workflow.replanRequired', stepId, record.state, nowMs);
      return;
    }
    this.fail(decision.reason, nowMs);
  }

  requestCancellation(reason: string, nowMs: number): void {
    this.cancel(reason, nowMs);
  }

  enforceDeadline(nowMs: number): boolean {
    if (this.enforceStepTimeout(nowMs)) {
      return true;
    }
    if (this.deadlineAtMs > 0 && nowMs >= this.deadlineAtMs &&
      this.state !== WorkflowRunState.COMPLETED && this.state !== WorkflowRunState.FAILED &&
      this.state !== WorkflowRunState.CANCELLED) {
      this.failForDeadline(nowMs);
      return true;
    }
    return false;
  }

  reconcileUnknownOutcome(stepId: string, result: StepExecutionResult, nowMs: number): void {
    if (this.state !== WorkflowRunState.WAITING_RECONCILIATION) {
      throw new WorkflowKernelError('Workflow is not waiting for reconciliation');
    }
    const record: StepRuntimeRecord = this.requireRecord(stepId);
    if (record.state !== WorkflowStepState.UNKNOWN_OUTCOME) {
      throw new WorkflowKernelError('Step ' + stepId + ' does not have an unknown outcome');
    }
    this.state = WorkflowRunState.RECOVERING;
    if (result.status === StepExecutionStatus.SUCCEEDED) {
      record.state = WorkflowStepState.SUCCEEDED;
      record.finishedAtMs = nowMs;
      record.outputDigest = result.outputDigest;
      this.appendEvent('step.reconciledSucceeded', stepId, record.state, nowMs);
      this.state = WorkflowRunState.RUNNING;
      if (this.cancellationRequested) {
        this.cancel(this.terminalReason, nowMs);
        return;
      }
      if (this.enforceDeadline(nowMs)) {
        return;
      }
      this.terminalReason = '';
      this.refreshReady(nowMs);
      this.completeIfFinished(nowMs);
      return;
    }
    record.state = WorkflowStepState.FAILED;
    record.finishedAtMs = nowMs;
    record.lastErrorClass = result.errorClass;
    this.appendEvent('step.reconciledFailed', stepId, record.state, nowMs);
    this.fail('reconciliation failed: ' + stepId, nowMs);
  }

  snapshot(): WorkflowRuntimeSnapshot {
    const snapshot: WorkflowRuntimeSnapshot = new WorkflowRuntimeSnapshot();
    snapshot.workflowId = this.graph.workflowId;
    snapshot.taskId = this.graph.taskId;
    snapshot.runState = this.state;
    snapshot.cancellationRequested = this.cancellationRequested;
    snapshot.deadlineAtMs = this.deadlineAtMs;
    snapshot.terminalReason = this.terminalReason;
    snapshot.nextEventSequence = this.nextSequence;
    for (let i: number = 0; i < this.records.length; i++) {
      snapshot.steps.push(WorkflowScheduler.copyRecord(this.records[i]));
    }
    return snapshot;
  }

  static restore(graph: WorkflowGraph, snapshot: WorkflowRuntimeSnapshot, nowMs: number): WorkflowScheduler {
    if (snapshot.workflowId !== graph.workflowId || snapshot.taskId !== graph.taskId) {
      throw new WorkflowKernelError('Snapshot identity does not match workflow graph');
    }
    const scheduler: WorkflowScheduler = new WorkflowScheduler(graph);
    if (snapshot.steps.length !== graph.steps.length) {
      throw new WorkflowKernelError('Snapshot step count does not match workflow graph');
    }
    scheduler.records = [];
    scheduler.state = WorkflowRunState.RECOVERING;
    scheduler.deadlineAtMs = snapshot.deadlineAtMs;
    scheduler.cancellationRequested = snapshot.cancellationRequested;
    scheduler.terminalReason = snapshot.terminalReason;
    scheduler.nextSequence = snapshot.nextEventSequence > 0 ? snapshot.nextEventSequence : 1;
    let mustReconcile: boolean = false;
    for (let i: number = 0; i < graph.steps.length; i++) {
      const source: StepRuntimeRecord = WorkflowScheduler.findSnapshotRecord(snapshot, graph.steps[i].stepId);
      const restored: StepRuntimeRecord = WorkflowScheduler.copyRecord(source);
      if (restored.state === WorkflowStepState.RUNNING || restored.state === WorkflowStepState.VERIFYING) {
        if (graph.steps[i].sideEffect === SideEffect.NONE) {
          restored.state = WorkflowStepState.PENDING;
          restored.startedAtMs = 0;
          restored.finishedAtMs = 0;
        } else {
          restored.state = WorkflowStepState.UNKNOWN_OUTCOME;
          mustReconcile = true;
        }
      } else if (restored.state === WorkflowStepState.UNKNOWN_OUTCOME) {
        mustReconcile = true;
      }
      scheduler.records.push(restored);
    }
    if (mustReconcile) {
      scheduler.state = WorkflowRunState.WAITING_RECONCILIATION;
      scheduler.terminalReason = 'restart requires reconciliation';
      scheduler.appendEvent('workflow.reconciliationRequired', '', WorkflowStepState.UNKNOWN_OUTCOME, nowMs);
    } else if (snapshot.runState === WorkflowRunState.COMPLETED ||
      snapshot.runState === WorkflowRunState.FAILED || snapshot.runState === WorkflowRunState.CANCELLED) {
      scheduler.state = snapshot.runState;
    } else if (scheduler.hasFailedStep()) {
      scheduler.state = WorkflowRunState.RECOVERING;
    } else if (snapshot.cancellationRequested) {
      scheduler.state = WorkflowRunState.RUNNING;
      scheduler.cancel(snapshot.terminalReason, nowMs);
    } else {
      scheduler.state = WorkflowRunState.RUNNING;
      scheduler.refreshReady(nowMs);
    }
    return scheduler;
  }

  private refreshReady(nowMs: number): void {
    if (this.state !== WorkflowRunState.RUNNING || this.cancellationRequested) {
      return;
    }
    for (let i: number = 0; i < this.records.length; i++) {
      if (this.records[i].state === WorkflowStepState.PENDING && this.dependenciesSucceeded(this.graph.steps[i])) {
        this.records[i].state = WorkflowStepState.READY;
        this.appendEvent('step.ready', this.records[i].stepId, this.records[i].state, nowMs);
      }
    }
  }

  private dependenciesSucceeded(step: WorkflowStep): boolean {
    for (let i: number = 0; i < step.dependencies.length; i++) {
      const dependency: StepRuntimeRecord = this.requireRecord(step.dependencies[i]);
      if (dependency.state !== WorkflowStepState.SUCCEEDED) {
        return false;
      }
    }
    return true;
  }

  private completeIfFinished(nowMs: number): void {
    for (let i: number = 0; i < this.records.length; i++) {
      if (this.records[i].state !== WorkflowStepState.SUCCEEDED) {
        return;
      }
    }
    this.state = WorkflowRunState.COMPLETED;
    this.terminalReason = '';
    this.appendEvent('workflow.completed', '', WorkflowStepState.SUCCEEDED, nowMs);
  }

  private cancel(reason: string, nowMs: number): void {
    if (this.state === WorkflowRunState.COMPLETED || this.state === WorkflowRunState.FAILED ||
      this.state === WorkflowRunState.CANCELLED) {
      return;
    }
    this.cancellationRequested = true;
    this.terminalReason = reason;
    this.promoteInFlightSideEffectsToUnknown(nowMs, 'step.cancelOutcomeUnknown');
    if (this.hasUnknownOutcome()) {
      this.state = WorkflowRunState.WAITING_RECONCILIATION;
      this.appendEvent('workflow.cancellationDeferred', '', WorkflowStepState.UNKNOWN_OUTCOME, nowMs);
      return;
    }
    for (let i: number = 0; i < this.records.length; i++) {
      if (!WorkflowScheduler.isTerminalStepState(this.records[i].state)) {
        this.records[i].state = WorkflowStepState.CANCELLED;
        this.records[i].finishedAtMs = nowMs;
        this.records[i].lastErrorClass = AgentErrorClass.CANCELLED;
        this.appendEvent('step.cancelled', this.records[i].stepId, this.records[i].state, nowMs);
      }
    }
    this.state = WorkflowRunState.CANCELLED;
    this.appendEvent('workflow.cancelled', '', WorkflowStepState.CANCELLED, nowMs);
  }

  private fail(reason: string, nowMs: number): void {
    this.terminalReason = reason;
    for (let i: number = 0; i < this.records.length; i++) {
      if (!WorkflowScheduler.isTerminalStepState(this.records[i].state)) {
        this.records[i].state = WorkflowStepState.CANCELLED;
        this.records[i].finishedAtMs = nowMs;
        this.appendEvent('step.cancelled', this.records[i].stepId, this.records[i].state, nowMs);
      }
    }
    this.state = WorkflowRunState.FAILED;
    this.appendEvent('workflow.failed', '', WorkflowStepState.FAILED, nowMs);
  }

  private failForDeadline(nowMs: number): void {
    this.promoteInFlightSideEffectsToUnknown(nowMs, 'step.deadlineOutcomeUnknown');
    if (this.hasUnknownOutcome()) {
      this.terminalReason = 'workflow deadline exceeded while reconciliation is required';
      this.state = WorkflowRunState.WAITING_RECONCILIATION;
      this.appendEvent('workflow.deadlineDeferred', '', WorkflowStepState.UNKNOWN_OUTCOME, nowMs);
      return;
    }
    for (let i: number = 0; i < this.records.length; i++) {
      if (!WorkflowScheduler.isTerminalStepState(this.records[i].state)) {
        this.records[i].lastErrorClass = AgentErrorClass.TIMEOUT;
      }
    }
    this.fail('workflow deadline exceeded', nowMs);
  }

  private enforceStepTimeout(nowMs: number): boolean {
    if (this.state !== WorkflowRunState.RUNNING) {
      return false;
    }
    for (let i: number = 0; i < this.records.length; i++) {
      const record: StepRuntimeRecord = this.records[i];
      const timeoutMs: number = this.graph.steps[i].timeoutMs;
      if ((record.state === WorkflowStepState.RUNNING || record.state === WorkflowStepState.VERIFYING) &&
        timeoutMs > 0 && nowMs - record.startedAtMs >= timeoutMs) {
        if (this.graph.steps[i].sideEffect !== SideEffect.NONE) {
          record.state = WorkflowStepState.UNKNOWN_OUTCOME;
          record.finishedAtMs = nowMs;
          record.lastErrorClass = AgentErrorClass.TIMEOUT;
          this.state = WorkflowRunState.WAITING_RECONCILIATION;
          this.terminalReason = 'step timeout outcome is unknown: ' + record.stepId;
          this.appendEvent('step.timeoutOutcomeUnknown', record.stepId, record.state, nowMs);
          return true;
        }
        record.state = WorkflowStepState.FAILED;
        record.finishedAtMs = nowMs;
        record.lastErrorClass = AgentErrorClass.TIMEOUT;
        this.appendEvent('step.timedOut', record.stepId, record.state, nowMs);
        this.fail('step timeout exceeded: ' + record.stepId, nowMs);
        return true;
      }
    }
    return false;
  }

  private hasRunningStep(): boolean {
    for (let i: number = 0; i < this.records.length; i++) {
      if (this.records[i].state === WorkflowStepState.RUNNING ||
        this.records[i].state === WorkflowStepState.VERIFYING) {
        return true;
      }
    }
    return false;
  }

  private hasRunningSideEffect(): boolean {
    for (let i: number = 0; i < this.records.length; i++) {
      if ((this.records[i].state === WorkflowStepState.RUNNING ||
        this.records[i].state === WorkflowStepState.VERIFYING) &&
        this.graph.steps[i].sideEffect !== SideEffect.NONE) {
        return true;
      }
    }
    return false;
  }

  private hasUnknownOutcome(): boolean {
    for (let i: number = 0; i < this.records.length; i++) {
      if (this.records[i].state === WorkflowStepState.UNKNOWN_OUTCOME) {
        return true;
      }
    }
    return false;
  }

  private hasFailedStep(): boolean {
    for (let i: number = 0; i < this.records.length; i++) {
      if (this.records[i].state === WorkflowStepState.FAILED) {
        return true;
      }
    }
    return false;
  }

  private promoteInFlightSideEffectsToUnknown(nowMs: number, eventType: string): void {
    for (let i: number = 0; i < this.records.length; i++) {
      if ((this.records[i].state === WorkflowStepState.RUNNING ||
        this.records[i].state === WorkflowStepState.VERIFYING) &&
        this.graph.steps[i].sideEffect !== SideEffect.NONE) {
        this.records[i].state = WorkflowStepState.UNKNOWN_OUTCOME;
        this.records[i].finishedAtMs = nowMs;
        this.appendEvent(eventType, this.records[i].stepId, this.records[i].state, nowMs);
      }
    }
  }

  private contains(values: string[], target: string): boolean {
    for (let i: number = 0; i < values.length; i++) {
      if (values[i] === target) {
        return true;
      }
    }
    return false;
  }

  private requireActive(): void {
    if (this.state !== WorkflowRunState.RUNNING) {
      throw new WorkflowKernelError('Workflow is not running');
    }
  }

  private requireRecord(stepId: string): StepRuntimeRecord {
    const index: number = this.findRecordIndex(stepId);
    if (index < 0) {
      throw new WorkflowKernelError('Unknown step ' + stepId);
    }
    return this.records[index];
  }

  private findRecordIndex(stepId: string): number {
    for (let i: number = 0; i < this.records.length; i++) {
      if (this.records[i].stepId === stepId) {
        return i;
      }
    }
    return -1;
  }

  private appendEvent(eventType: string, stepId: string, stepState: WorkflowStepState, nowMs: number): void {
    const event: WorkflowEvent = new WorkflowEvent();
    event.sequence = this.nextSequence;
    this.nextSequence++;
    event.eventType = eventType;
    event.stepId = stepId;
    event.stepState = stepState;
    event.timestampMs = nowMs;
    this.events.push(event);
  }

  private static findSnapshotRecord(snapshot: WorkflowRuntimeSnapshot, stepId: string): StepRuntimeRecord {
    for (let i: number = 0; i < snapshot.steps.length; i++) {
      if (snapshot.steps[i].stepId === stepId) {
        return snapshot.steps[i];
      }
    }
    throw new WorkflowKernelError('Snapshot is missing step ' + stepId);
  }

  private static copyRecord(source: StepRuntimeRecord): StepRuntimeRecord {
    const copy: StepRuntimeRecord = new StepRuntimeRecord();
    copy.stepId = source.stepId;
    copy.state = source.state;
    copy.attemptCount = source.attemptCount;
    copy.startedAtMs = source.startedAtMs;
    copy.finishedAtMs = source.finishedAtMs;
    copy.lastErrorClass = source.lastErrorClass;
    copy.outputDigest = source.outputDigest;
    return copy;
  }

  private static isTerminalStepState(state: WorkflowStepState): boolean {
    return state === WorkflowStepState.SUCCEEDED || state === WorkflowStepState.FAILED ||
      state === WorkflowStepState.CANCELLED || state === WorkflowStepState.UNKNOWN_OUTCOME;
  }
}
