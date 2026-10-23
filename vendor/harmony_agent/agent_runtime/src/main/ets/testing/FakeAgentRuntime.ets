import {
  AgentRuntimeEvent,
  AgentRuntimeEventType,
  AgentTaskSnapshot,
  AgentTaskStatus,
  AuthorizationDecision,
  AuthorizationDecisionType,
  ClarificationRequest,
  ClarificationResponse,
  CommandReceipt,
  ContractCodec,
  ContractValidator,
  ExecutionBudget,
  PolicyRequest,
  ReconciliationReport,
  ReconciliationStatus,
  RiskLevel,
  SideEffect,
  TaskControlAction,
  TaskControlCommand,
  TaskHandle,
  TaskSubmission
} from '@harmony_agent/agent-contracts';
import { BudgetLedger } from '@harmony_agent/agent-core';
import {
  AgentRuntimeErrorCode,
  AgentRuntimeFacade,
  AgentRuntimeObserver,
  AgentSubscription,
  ShutdownMode,
  SubscriptionRequest
} from '../api/RuntimeApi';
import { AgentRuntimeError } from '../api/AgentRuntimeError';
import { PolicyGateway } from '../policy/PolicyGateway';
import { PolicyDecisionResult } from '../policy/PolicyTypes';
import { FakeAgentRuntimeConfig, FakeTaskScript, FakeTaskScriptKind } from './FakeRuntimeTypes';

class FakeCommandRecord {
  commandId: string = '';
  fingerprint: string = '';
  receipt: CommandReceipt = new CommandReceipt();
}

class FakeTaskRecord {
  submissionJson: string = '';
  handle: TaskHandle = new TaskHandle();
  snapshot: AgentTaskSnapshot = new AgentTaskSnapshot();
  events: AgentRuntimeEvent[] = [];
  scriptKind: FakeTaskScriptKind = FakeTaskScriptKind.COMPLETE;
  pendingPolicyRequest?: PolicyRequest;
  pendingClarificationRequest?: ClarificationRequest;
  pendingStepId: string = '';
  pendingOperationId: string = '';
  cancellationRequested: boolean = false;
  commands: FakeCommandRecord[] = [];
}

class FakeObserverRegistration {
  request: SubscriptionRequest = new SubscriptionRequest();
  observer?: AgentRuntimeObserver;
  closed: boolean = false;
}

class FakeAgentSubscription implements AgentSubscription {
  private registration: FakeObserverRegistration;

  constructor(registration: FakeObserverRegistration) {
    this.registration = registration;
  }

  close(): void {
    this.registration.closed = true;
  }

  isClosed(): boolean {
    return this.registration.closed;
  }
}

function copyHandle(value: TaskHandle): TaskHandle {
  return ContractCodec.parseTaskHandle(ContractCodec.stringify(value));
}

function copySnapshot(value: AgentTaskSnapshot): AgentTaskSnapshot {
  return ContractCodec.parseAgentTaskSnapshot(ContractCodec.stringify(value));
}

function copyEvent(value: AgentRuntimeEvent): AgentRuntimeEvent {
  return ContractCodec.parseAgentRuntimeEvent(ContractCodec.stringify(value));
}

function copyPolicyRequest(value: PolicyRequest): PolicyRequest {
  return ContractCodec.parsePolicyRequest(ContractCodec.stringify(value));
}

function copyClarificationRequest(value: ClarificationRequest): ClarificationRequest {
  return ContractCodec.parseClarificationRequest(ContractCodec.stringify(value));
}

function copyReceipt(value: CommandReceipt): CommandReceipt {
  return ContractCodec.parseCommandReceipt(ContractCodec.stringify(value));
}

function copyBudget(source: ExecutionBudget): ExecutionBudget {
  const value: ExecutionBudget = new ExecutionBudget();
  value.maxWallTimeMs = source.maxWallTimeMs;
  value.maxInputTokens = source.maxInputTokens;
  value.maxOutputTokens = source.maxOutputTokens;
  value.maxMonetaryCostMicros = source.maxMonetaryCostMicros;
  value.maxToolCalls = source.maxToolCalls;
  value.maxAgentActivations = source.maxAgentActivations;
  value.maxRetries = source.maxRetries;
  value.maxReplans = source.maxReplans;
  value.deadlineAt = source.deadlineAt;
  return value;
}

export class FakeAgentRuntime implements AgentRuntimeFacade {
  private nowMs: number;
  private scripts: FakeTaskScript[] = [];
  private tasks: FakeTaskRecord[] = [];
  private registrations: FakeObserverRegistration[] = [];
  private budgetLedger: BudgetLedger = new BudgetLedger();
  private policyGateway: PolicyGateway;
  private shutdownRequested: boolean = false;

  constructor(config: FakeAgentRuntimeConfig) {
    if (!Number.isSafeInteger(config.startTimeMs) || config.startTimeMs < 0) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'invalid fake clock');
    }
    this.nowMs = config.startTimeMs;
    for (let i: number = 0; i < config.scripts.length; i++) {
      if (config.scripts[i].requestId.length === 0 || this.hasScript(config.scripts[i].requestId)) {
        throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT,
          'invalid or duplicate fake script requestId');
      }
      const script: FakeTaskScript = new FakeTaskScript();
      script.requestId = config.scripts[i].requestId;
      script.kind = config.scripts[i].kind;
      this.scripts.push(script);
    }
    this.policyGateway = new PolicyGateway('fake-policy-v1', 30000, this.budgetLedger);
  }

  async submitTask(submission: TaskSubmission): Promise<TaskHandle> {
    this.requireActive();
    if (!ContractValidator.validateTaskSubmission(submission).valid) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'invalid TaskSubmission');
    }
    const submissionJson: string = ContractCodec.stringify(submission);
    const existingIndex: number = this.findTaskByRequestId(submission.requestId);
    if (existingIndex >= 0) {
      if (this.tasks[existingIndex].submissionJson !== submissionJson) {
        throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT,
          'requestId reused with different submission');
      }
      return copyHandle(this.tasks[existingIndex].handle);
    }

    const record: FakeTaskRecord = new FakeTaskRecord();
    record.submissionJson = submissionJson;
    record.scriptKind = this.scriptFor(submission.requestId);
    record.handle.requestId = submission.requestId;
    record.handle.taskId = 'fake-task:' + submission.requestId;
    record.handle.sessionId = 'fake-session:' + submission.requestId;
    record.handle.acceptedAt = this.nextTimestamp();
    record.handle.snapshotVersion = 1;
    record.snapshot.requestId = submission.requestId;
    record.snapshot.taskId = record.handle.taskId;
    record.snapshot.sessionId = record.handle.sessionId;
    record.snapshot.status = AgentTaskStatus.RECEIVED;
    record.snapshot.snapshotVersion = 1;
    record.snapshot.lastEventSequence = 0;
    record.snapshot.resultJson = '{}';
    record.snapshot.updatedAt = record.handle.acceptedAt;
    this.tasks.push(record);
    this.registerBudgets(record.handle.taskId, submission.requestedBudget);
    this.emit(record, AgentRuntimeEventType.TASK_ACCEPTED, '{"status":"received"}');
    this.startScript(record, submission);
    return copyHandle(record.handle);
  }

  async getTaskSnapshot(taskId: string): Promise<AgentTaskSnapshot> {
    this.requireActive();
    return copySnapshot(this.requireTask(taskId).snapshot);
  }

  async cancelTask(command: TaskControlCommand): Promise<CommandReceipt> {
    return this.applyControl(command, TaskControlAction.CANCEL);
  }

  async pauseTask(command: TaskControlCommand): Promise<CommandReceipt> {
    return this.applyControl(command, TaskControlAction.PAUSE);
  }

  async resumeTask(command: TaskControlCommand): Promise<CommandReceipt> {
    return this.applyControl(command, TaskControlAction.RESUME);
  }

  async provideAuthorization(decision: AuthorizationDecision): Promise<CommandReceipt> {
    this.requireActive();
    if (!ContractValidator.validateAuthorizationDecision(decision).valid) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'invalid AuthorizationDecision');
    }
    const record: FakeTaskRecord | undefined = this.taskOrUndefined(decision.taskId);
    if (record === undefined) {
      return this.rejectedReceipt(decision.commandId, decision.taskId, 0, 'TASK_NOT_FOUND');
    }
    const fingerprint: string = 'authorization:' + ContractCodec.stringify(decision);
    const replay: CommandReceipt | undefined = this.replayReceipt(record, decision.commandId, fingerprint);
    if (replay !== undefined) {
      return replay;
    }
    const pending: PolicyRequest | undefined = record.pendingPolicyRequest;
    if (pending === undefined || pending.requestId !== decision.policyRequestId ||
      record.snapshot.status !== AgentTaskStatus.WAITING_AUTHORIZATION) {
      return this.rememberRejected(record, decision.commandId, fingerprint, 'AUTHORIZATION_NOT_PENDING');
    }
    const result: PolicyDecisionResult = this.policyGateway.applyDecision(decision, this.tick());
    if (!result.processed) {
      return this.rememberRejected(record, decision.commandId, fingerprint, result.code);
    }
    record.pendingPolicyRequest = undefined;
    if (!result.authorized) {
      this.transition(record, AgentTaskStatus.FAILED, AgentRuntimeEventType.TASK_FAILED,
        '{"reason":"authorizationDenied"}');
    } else {
      this.transition(record, AgentTaskStatus.COMPLETED, AgentRuntimeEventType.TASK_COMPLETED,
        '{"status":"success","source":"fakeTool"}');
    }
    return this.rememberAccepted(record, decision.commandId, fingerprint);
  }

  async provideClarification(response: ClarificationResponse): Promise<CommandReceipt> {
    this.requireActive();
    if (!ContractValidator.validateClarificationResponse(response).valid) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'invalid ClarificationResponse');
    }
    const record: FakeTaskRecord | undefined = this.taskOrUndefined(response.taskId);
    if (record === undefined) {
      return this.rejectedReceipt(response.commandId, response.taskId, 0, 'TASK_NOT_FOUND');
    }
    const fingerprint: string = 'clarification:' + ContractCodec.stringify(response);
    const replay: CommandReceipt | undefined = this.replayReceipt(record, response.commandId, fingerprint);
    if (replay !== undefined) {
      return replay;
    }
    const pending: ClarificationRequest | undefined = record.pendingClarificationRequest;
    if (pending === undefined || pending.clarificationId !== response.clarificationId ||
      record.snapshot.status !== AgentTaskStatus.WAITING_INPUT) {
      return this.rememberRejected(record, response.commandId, fingerprint, 'CLARIFICATION_NOT_PENDING');
    }
    if (this.nowMs >= pending.expiresAtMs || response.respondedAtMs > this.nowMs) {
      return this.rememberRejected(record, response.commandId, fingerprint, 'CLARIFICATION_EXPIRED');
    }
    try {
      JSON.parse(response.answerJson);
    } catch (error) {
      return this.rememberRejected(record, response.commandId, fingerprint, 'INVALID_ANSWER_JSON');
    }
    record.pendingClarificationRequest = undefined;
    this.transition(record, AgentTaskStatus.COMPLETED, AgentRuntimeEventType.TASK_COMPLETED,
      '{"status":"success","clarificationApplied":true}');
    return this.rememberAccepted(record, response.commandId, fingerprint);
  }

  async provideReconciliation(report: ReconciliationReport): Promise<CommandReceipt> {
    this.requireActive();
    if (!ContractValidator.validateReconciliationReport(report).valid) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'invalid ReconciliationReport');
    }
    const record: FakeTaskRecord | undefined = this.taskOrUndefined(report.taskId);
    if (record === undefined) {
      return this.rejectedReceipt(report.commandId, report.taskId, 0, 'TASK_NOT_FOUND');
    }
    const fingerprint: string = 'reconciliation:' + ContractCodec.stringify(report);
    const replay: CommandReceipt | undefined = this.replayReceipt(record, report.commandId, fingerprint);
    if (replay !== undefined) {
      return replay;
    }
    if (record.snapshot.status !== AgentTaskStatus.WAITING_RECONCILIATION ||
      record.pendingStepId !== report.stepId || record.pendingOperationId !== report.operationId) {
      return this.rememberRejected(record, report.commandId, fingerprint, 'RECONCILIATION_NOT_PENDING');
    }
    if (report.status === ReconciliationStatus.STILL_UNKNOWN) {
      return this.rememberAccepted(record, report.commandId, fingerprint);
    }
    if (record.cancellationRequested) {
      this.transition(record, AgentTaskStatus.CANCELLED, AgentRuntimeEventType.TASK_CANCELLED,
        '{"reason":"cancelledAfterReconciliation"}');
    } else if (report.status === ReconciliationStatus.CONFIRMED_SUCCEEDED) {
      this.transition(record, AgentTaskStatus.COMPLETED, AgentRuntimeEventType.TASK_COMPLETED,
        '{"status":"success","reconciled":true}');
    } else {
      this.transition(record, AgentTaskStatus.FAILED, AgentRuntimeEventType.TASK_FAILED,
        '{"reason":"reconciliationFailed"}');
    }
    return this.rememberAccepted(record, report.commandId, fingerprint);
  }

  async subscribe(request: SubscriptionRequest, observer: AgentRuntimeObserver): Promise<AgentSubscription> {
    this.requireActive();
    if (request.subscriptionId.length === 0 || request.taskId.length === 0 ||
      !Number.isSafeInteger(request.afterSequence) || request.afterSequence < 0) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'invalid SubscriptionRequest');
    }
    if (this.findRegistration(request.subscriptionId) >= 0) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.SUBSCRIPTION_CONFLICT, 'duplicate subscriptionId');
    }
    const record: FakeTaskRecord = this.requireTask(request.taskId);
    if (request.afterSequence > record.snapshot.lastEventSequence) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT,
        'afterSequence is ahead of the task event stream');
    }
    const registration: FakeObserverRegistration = new FakeObserverRegistration();
    registration.request.subscriptionId = request.subscriptionId;
    registration.request.taskId = request.taskId;
    registration.request.afterSequence = request.afterSequence;
    registration.observer = observer;
    this.registrations.push(registration);
    for (let i: number = 0; i < record.events.length; i++) {
      if (record.events[i].sequence > request.afterSequence) {
        this.notifyEvent(registration, record.events[i]);
      }
    }
    const policy: PolicyRequest | undefined = record.pendingPolicyRequest;
    if (policy !== undefined) {
      this.notifyPolicy(registration, policy);
    }
    const clarification: ClarificationRequest | undefined = record.pendingClarificationRequest;
    if (clarification !== undefined) {
      this.notifyClarification(registration, clarification);
    }
    return new FakeAgentSubscription(registration);
  }

  async shutdown(mode: ShutdownMode): Promise<void> {
    if (this.shutdownRequested) {
      return;
    }
    this.shutdownRequested = true;
    for (let i: number = 0; i < this.registrations.length; i++) {
      this.registrations[i].closed = true;
    }
  }

  private startScript(record: FakeTaskRecord, submission: TaskSubmission): void {
    if (record.scriptKind === FakeTaskScriptKind.COMPLETE) {
      this.transition(record, AgentTaskStatus.RUNNING, AgentRuntimeEventType.TASK_STATE_CHANGED,
        '{"status":"running"}');
      this.transition(record, AgentTaskStatus.COMPLETED, AgentRuntimeEventType.TASK_COMPLETED,
        '{"status":"success","source":"fakeTool"}');
      return;
    }
    if (record.scriptKind === FakeTaskScriptKind.PARTIAL_SUCCESS) {
      this.transition(record, AgentTaskStatus.RUNNING, AgentRuntimeEventType.TASK_STATE_CHANGED,
        '{"status":"running"}');
      this.transition(record, AgentTaskStatus.RUNNING, AgentRuntimeEventType.RESULT_UPDATED,
        '{"status":"partial","completed":1,"failed":1}');
      this.transition(record, AgentTaskStatus.COMPLETED, AgentRuntimeEventType.TASK_COMPLETED,
        '{"status":"partial","completed":1,"failed":1}');
      return;
    }
    if (record.scriptKind === FakeTaskScriptKind.AUTHORIZATION) {
      this.createPolicyRequest(record, submission);
      this.transition(record, AgentTaskStatus.WAITING_AUTHORIZATION,
        AgentRuntimeEventType.AUTHORIZATION_REQUIRED, '{"requestId":"fake-policy:' +
          submission.requestId + '"}');
      this.dispatchPolicy(record);
      return;
    }
    if (record.scriptKind === FakeTaskScriptKind.CLARIFICATION) {
      this.createClarificationRequest(record);
      this.transition(record, AgentTaskStatus.WAITING_INPUT,
        AgentRuntimeEventType.CLARIFICATION_REQUIRED, '{"questionCode":"MISSING_DETAIL"}');
      this.dispatchClarification(record);
      return;
    }
    if (record.scriptKind === FakeTaskScriptKind.RECONCILIATION) {
      record.pendingStepId = 'fake-step';
      record.pendingOperationId = 'fake-operation:' + submission.requestId;
      this.transition(record, AgentTaskStatus.WAITING_RECONCILIATION,
        AgentRuntimeEventType.RECONCILIATION_REQUIRED, '{"stepId":"fake-step","operationId":"' +
          record.pendingOperationId + '"}');
      return;
    }
    this.transition(record, AgentTaskStatus.RUNNING, AgentRuntimeEventType.TASK_STATE_CHANGED,
      '{"status":"running"}');
  }

  private createPolicyRequest(record: FakeTaskRecord, submission: TaskSubmission): void {
    const request: PolicyRequest = new PolicyRequest();
    request.requestId = 'fake-policy:' + submission.requestId;
    request.userId = submission.userId;
    request.taskId = record.handle.taskId;
    request.stepId = 'fake-step';
    request.operationId = 'fake-operation:' + submission.requestId;
    request.toolId = 'fake.tool';
    request.toolIdentityVersion = 'fake-tool-v1';
    request.providerId = 'fake-provider';
    request.schemaDigest = 'sha256:fake-schema-v1';
    request.argumentsDigest = 'sha256:fake-arguments:' + submission.requestId;
    request.riskLevel = RiskLevel.MEDIUM;
    request.sideEffect = SideEffect.REVERSIBLE;
    request.estimatedCostMicros = 1;
    request.requestedAt = this.timestamp(this.nowMs);
    request.expiresAtMs = this.nowMs + 60000;
    request.expiresAt = this.timestamp(request.expiresAtMs);
    record.pendingPolicyRequest = request;
    this.policyGateway.registerRequest(request);
  }

  private createClarificationRequest(record: FakeTaskRecord): void {
    const request: ClarificationRequest = new ClarificationRequest();
    request.clarificationId = 'fake-clarification:' + record.handle.requestId;
    request.taskId = record.handle.taskId;
    request.questionCode = 'MISSING_DETAIL';
    request.prompt = '请补充完成任务所需的信息';
    request.responseSchemaJson = '{"type":"object"}';
    request.requestedAt = this.timestamp(this.nowMs);
    request.expiresAtMs = this.nowMs + 60000;
    request.expiresAt = this.timestamp(request.expiresAtMs);
    record.pendingClarificationRequest = request;
  }

  private applyControl(command: TaskControlCommand, expected: TaskControlAction): CommandReceipt {
    this.requireActive();
    if (!ContractValidator.validateTaskControlCommand(command).valid || command.action !== expected) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'invalid TaskControlCommand');
    }
    const record: FakeTaskRecord | undefined = this.taskOrUndefined(command.taskId);
    if (record === undefined) {
      return this.rejectedReceipt(command.commandId, command.taskId, 0, 'TASK_NOT_FOUND');
    }
    const fingerprint: string = 'control:' + ContractCodec.stringify(command);
    const replay: CommandReceipt | undefined = this.replayReceipt(record, command.commandId, fingerprint);
    if (replay !== undefined) {
      return replay;
    }
    if (expected === TaskControlAction.CANCEL) {
      if (this.isTerminal(record.snapshot.status)) {
        return this.rememberRejected(record, command.commandId, fingerprint, 'TASK_TERMINAL');
      }
      if (record.snapshot.status === AgentTaskStatus.WAITING_RECONCILIATION) {
        record.cancellationRequested = true;
        record.snapshot.snapshotVersion += 1;
        record.snapshot.updatedAt = this.nextTimestamp();
        this.emit(record, AgentRuntimeEventType.TASK_STATE_CHANGED,
          '{"status":"waitingReconciliation","cancellationRequested":true}');
      } else {
        this.transition(record, AgentTaskStatus.CANCELLED, AgentRuntimeEventType.TASK_CANCELLED,
          '{"reason":"callerRequested"}');
      }
      return this.rememberAccepted(record, command.commandId, fingerprint);
    }
    if (expected === TaskControlAction.PAUSE) {
      if (record.snapshot.status !== AgentTaskStatus.RUNNING) {
        return this.rememberRejected(record, command.commandId, fingerprint, 'TASK_NOT_RUNNING');
      }
      this.transition(record, AgentTaskStatus.PAUSED, AgentRuntimeEventType.TASK_STATE_CHANGED,
        '{"status":"paused"}');
      return this.rememberAccepted(record, command.commandId, fingerprint);
    }
    if (record.snapshot.status !== AgentTaskStatus.PAUSED) {
      return this.rememberRejected(record, command.commandId, fingerprint, 'TASK_NOT_PAUSED');
    }
    this.transition(record, AgentTaskStatus.RUNNING, AgentRuntimeEventType.TASK_STATE_CHANGED,
      '{"status":"running"}');
    if (record.scriptKind === FakeTaskScriptKind.PAUSABLE) {
      this.transition(record, AgentTaskStatus.COMPLETED, AgentRuntimeEventType.TASK_COMPLETED,
        '{"status":"success","resumed":true}');
    }
    return this.rememberAccepted(record, command.commandId, fingerprint);
  }

  private transition(record: FakeTaskRecord, status: AgentTaskStatus, eventType: AgentRuntimeEventType,
    payloadJson: string): void {
    record.snapshot.status = status;
    record.snapshot.snapshotVersion += 1;
    record.snapshot.resultJson = payloadJson;
    record.snapshot.updatedAt = this.nextTimestamp();
    this.emit(record, eventType, payloadJson);
  }

  private emit(record: FakeTaskRecord, eventType: AgentRuntimeEventType, payloadJson: string): void {
    const event: AgentRuntimeEvent = new AgentRuntimeEvent();
    event.sequence = record.events.length + 1;
    event.eventId = record.handle.taskId + ':event:' + event.sequence.toString();
    event.taskId = record.handle.taskId;
    event.snapshotVersion = record.snapshot.snapshotVersion;
    event.eventType = eventType;
    event.timestamp = record.snapshot.updatedAt;
    event.payloadJson = payloadJson;
    record.events.push(event);
    record.snapshot.lastEventSequence = event.sequence;
    for (let i: number = 0; i < this.registrations.length; i++) {
      if (!this.registrations[i].closed && this.registrations[i].request.taskId === event.taskId) {
        this.notifyEvent(this.registrations[i], event);
      }
    }
  }

  private dispatchPolicy(record: FakeTaskRecord): void {
    const request: PolicyRequest | undefined = record.pendingPolicyRequest;
    if (request === undefined) return;
    for (let i: number = 0; i < this.registrations.length; i++) {
      if (!this.registrations[i].closed && this.registrations[i].request.taskId === record.handle.taskId) {
        this.notifyPolicy(this.registrations[i], request);
      }
    }
  }

  private dispatchClarification(record: FakeTaskRecord): void {
    const request: ClarificationRequest | undefined = record.pendingClarificationRequest;
    if (request === undefined) return;
    for (let i: number = 0; i < this.registrations.length; i++) {
      if (!this.registrations[i].closed && this.registrations[i].request.taskId === record.handle.taskId) {
        this.notifyClarification(this.registrations[i], request);
      }
    }
  }

  private notifyEvent(registration: FakeObserverRegistration, event: AgentRuntimeEvent): void {
    const observer: AgentRuntimeObserver | undefined = registration.observer;
    if (observer === undefined || registration.closed) return;
    try {
      observer.onEvent(copyEvent(event));
    } catch (error) {
    }
  }

  private notifyPolicy(registration: FakeObserverRegistration, request: PolicyRequest): void {
    const observer: AgentRuntimeObserver | undefined = registration.observer;
    if (observer === undefined || registration.closed) return;
    try {
      observer.onPolicyRequest(copyPolicyRequest(request));
    } catch (error) {
    }
  }

  private notifyClarification(registration: FakeObserverRegistration, request: ClarificationRequest): void {
    const observer: AgentRuntimeObserver | undefined = registration.observer;
    if (observer === undefined || registration.closed) return;
    try {
      observer.onClarificationRequest(copyClarificationRequest(request));
    } catch (error) {
    }
  }

  private registerBudgets(taskId: string, source: ExecutionBudget): void {
    const limit: ExecutionBudget = copyBudget(source);
    this.budgetLedger.registerTask(taskId, limit);
    this.budgetLedger.registerStep(taskId, 'fake-step', copyBudget(limit));
    this.budgetLedger.registerProvider(taskId, 'fake-provider', copyBudget(limit));
  }

  private rememberAccepted(record: FakeTaskRecord, commandId: string, fingerprint: string): CommandReceipt {
    const receipt: CommandReceipt = new CommandReceipt();
    receipt.commandId = commandId;
    receipt.taskId = record.handle.taskId;
    receipt.accepted = true;
    receipt.snapshotVersion = record.snapshot.snapshotVersion;
    return this.remember(record, fingerprint, receipt);
  }

  private rememberRejected(record: FakeTaskRecord, commandId: string, fingerprint: string,
    rejectionCode: string): CommandReceipt {
    const receipt: CommandReceipt = this.rejectedReceipt(commandId, record.handle.taskId,
      record.snapshot.snapshotVersion, rejectionCode);
    return this.remember(record, fingerprint, receipt);
  }

  private remember(record: FakeTaskRecord, fingerprint: string, receipt: CommandReceipt): CommandReceipt {
    const command: FakeCommandRecord = new FakeCommandRecord();
    command.commandId = receipt.commandId;
    command.fingerprint = fingerprint;
    command.receipt = copyReceipt(receipt);
    record.commands.push(command);
    return copyReceipt(receipt);
  }

  private replayReceipt(record: FakeTaskRecord, commandId: string, fingerprint: string): CommandReceipt | undefined {
    for (let i: number = 0; i < record.commands.length; i++) {
      if (record.commands[i].commandId === commandId) {
        if (record.commands[i].fingerprint !== fingerprint) {
          return this.rejectedReceipt(commandId, record.handle.taskId, record.snapshot.snapshotVersion,
            'COMMAND_ID_CONFLICT');
        }
        const receipt: CommandReceipt = copyReceipt(record.commands[i].receipt);
        receipt.duplicate = true;
        return receipt;
      }
    }
    return undefined;
  }

  private rejectedReceipt(commandId: string, taskId: string, snapshotVersion: number,
    rejectionCode: string): CommandReceipt {
    const receipt: CommandReceipt = new CommandReceipt();
    receipt.commandId = commandId;
    receipt.taskId = taskId;
    receipt.accepted = false;
    receipt.snapshotVersion = snapshotVersion;
    receipt.rejectionCode = rejectionCode;
    return receipt;
  }

  private findTask(taskId: string): number {
    for (let i: number = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].handle.taskId === taskId) return i;
    }
    return -1;
  }

  private findTaskByRequestId(requestId: string): number {
    for (let i: number = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].handle.requestId === requestId) return i;
    }
    return -1;
  }

  private taskOrUndefined(taskId: string): FakeTaskRecord | undefined {
    const index: number = this.findTask(taskId);
    if (index < 0) return undefined;
    return this.tasks[index];
  }

  private requireTask(taskId: string): FakeTaskRecord {
    const record: FakeTaskRecord | undefined = this.taskOrUndefined(taskId);
    if (record === undefined) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.TASK_NOT_FOUND, 'task not found: ' + taskId);
    }
    return record;
  }

  private findRegistration(subscriptionId: string): number {
    for (let i: number = 0; i < this.registrations.length; i++) {
      if (this.registrations[i].request.subscriptionId === subscriptionId) return i;
    }
    return -1;
  }

  private scriptFor(requestId: string): FakeTaskScriptKind {
    for (let i: number = 0; i < this.scripts.length; i++) {
      if (this.scripts[i].requestId === requestId) return this.scripts[i].kind;
    }
    return FakeTaskScriptKind.COMPLETE;
  }

  private hasScript(requestId: string): boolean {
    for (let i: number = 0; i < this.scripts.length; i++) {
      if (this.scripts[i].requestId === requestId) return true;
    }
    return false;
  }

  private isTerminal(status: AgentTaskStatus): boolean {
    return status === AgentTaskStatus.COMPLETED || status === AgentTaskStatus.FAILED ||
      status === AgentTaskStatus.CANCELLED;
  }

  private nextTimestamp(): string {
    return this.timestamp(this.tick());
  }

  private tick(): number {
    this.nowMs += 1;
    return this.nowMs;
  }

  private timestamp(value: number): string {
    return new Date(value).toISOString();
  }

  private requireActive(): void {
    if (this.shutdownRequested) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.RUNTIME_SHUTDOWN, 'runtime is shut down');
    }
  }
}

export function createFakeAgentRuntime(config: FakeAgentRuntimeConfig): AgentRuntimeFacade {
  return new FakeAgentRuntime(config);
}
