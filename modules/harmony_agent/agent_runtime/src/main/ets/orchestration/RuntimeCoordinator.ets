import { ArtifactPolicyCancellationSource } from '../artifact/ArtifactPolicyExecutionControl';
import { CollaborationPolicyPreparationPort, CollaborationPreparationOutcome,
  prepareCollaboration } from '../routing/CollaborationPreparation';
import { CollaborationPreparationState } from './OrchestrationTypes';
import {
  AgentErrorClass,
  AgentRuntimeEvent,
  AgentRuntimeEventType,
  AgentTaskSnapshot,
  AgentTaskStatus,
  AuthorizationGrant,
  AuthorizationDecision,
  ClarificationRequest,
  ClarificationResponse,
  CollaborationMode,
  ContractCodec,
  ContractValidator,
  ExecutionBudget,
  IdempotencyMode,
  PolicyRequest,
  ReconciliationReport,
  ReconciliationStatus,
  TaskEnvelope,
  TaskFrame,
  TaskHandle,
  TaskSubmission,
  ToolInvocation,
  ToolOutcome,
  ToolOutcomeStatus,
  WorkflowGraph,
  WorkflowInputBinding,
  WorkflowStep,
  WorkflowStepKind
} from '@harmony_agent/agent-contracts';
import {
  BudgetLedger,
  OperationJournalState,
  DeterministicRecoveryPolicy,
  RecoveryAction,
  RecoveryDecision,
  StepRuntimeRecord,
  StepExecutionResult,
  StepExecutionStatus,
  WorkflowGraphValidator,
  WorkflowRunState,
  WorkflowRuntimeSnapshot,
  WorkflowScheduler,
  WorkflowStepState
} from '@harmony_agent/agent-core';
import { AgentRuntimeError } from '../api/AgentRuntimeError';
import { AgentRuntimeErrorCode } from '../api/RuntimeApi';
import { PolicyGateway } from '../policy/PolicyGateway';
import { PolicyDecisionResult } from '../policy/PolicyTypes';
import {
  CollaborationPlan,
  CollaborationRoleAssignment,
  CoordinatorCommandResult,
  DispatchPersistenceContext,
  OrchestrationAcceptance,
  OrchestrationUsage,
  PlanningRequest,
  PlanningResult,
  PlanningStatus,
  PreparedToolDispatch,
  RuntimeTaskRecoveryCheckpoint,
  SessionAcceptance,
  StepCompletion,
  StepDispatchReceipt,
  StepDispatchRequest
} from './OrchestrationTypes';
import {
  CollaborationPlanSelectorPort,
  CollaborationSelectorPort,
  RuntimeClockPort,
  RuntimeIdGeneratorPort,
  RuntimeStateObserverPort,
  NoopRuntimeStateObserver,
  SemanticPlannerPort,
  StepDispatchPort,
  ToolInvocationPreparerPort
} from './RuntimePorts';
import { SessionController } from './SessionController';
import { TaskAnalyzer } from './TaskAnalyzer';
import { WorkflowReplanController } from './WorkflowReplanController';
import { RuntimeCheckpointValidator } from './RuntimeCheckpointValidator';
import { CollaborationPlanValidator } from './CollaborationPlanValidator';
import {
  RuntimeDurableAuthorityPayload,
  RuntimeRecoveryAuthority,
  RuntimeRecoveryOperationAuthority,
  RuntimeRecoveryPolicyAuthority
} from './RecoveryAuthorityTypes';
import { RuntimeRecoveryAuthorityValidator } from './RuntimeRecoveryAuthorityValidator';

export class RuntimeCoordinatorConfig {
  policyVersion: string = '';
  grantTtlMs: number = 0;
}

class RuntimeTaskRecord {
  recoveredBudgetAuthorityJson: string = '';
  collaborationPreparation: CollaborationPreparationState = new CollaborationPreparationState();
  preparationCancellation?: ArtifactPolicyCancellationSource;
  preparationInterrupted: boolean = false;
  planningActive: boolean = false;
  planningInterrupted: boolean = false;
  submission: TaskSubmission = new TaskSubmission();
  envelope: TaskEnvelope = new TaskEnvelope();
  frame: TaskFrame = new TaskFrame();
  collaborationMode: CollaborationMode = CollaborationMode.SINGLE;
  handle: TaskHandle = new TaskHandle();
  snapshot: AgentTaskSnapshot = new AgentTaskSnapshot();
  events: AgentRuntimeEvent[] = [];
  usage: OrchestrationUsage = new OrchestrationUsage();
  planningRequest: PlanningRequest = new PlanningRequest();
  workflow?: WorkflowGraph;
  scheduler?: WorkflowScheduler;
  pendingClarification?: ClarificationRequest;
  pendingPolicyRequest?: PolicyRequest;
  pendingInvocation?: ToolInvocation;
  activeInvocation?: ToolInvocation;
  pendingStepId: string = '';
  pendingDispatchId: string = '';
  pendingOperationId: string = '';
  registeredProviderIds: string[] = [];
  paused: boolean = false;
  recoveryBlocked: boolean = false;
  recoverySourceCheckpoint?: RuntimeTaskRecoveryCheckpoint;
}

function copySnapshot(value: AgentTaskSnapshot): AgentTaskSnapshot {
  return ContractCodec.parseAgentTaskSnapshot(ContractCodec.stringify(value));
}

function copyEvent(value: AgentRuntimeEvent): AgentRuntimeEvent {
  return ContractCodec.parseAgentRuntimeEvent(ContractCodec.stringify(value));
}

function copyPolicy(value: PolicyRequest): PolicyRequest {
  return ContractCodec.parsePolicyRequest(ContractCodec.stringify(value));
}

function copyClarification(value: ClarificationRequest): ClarificationRequest {
  return ContractCodec.parseClarificationRequest(ContractCodec.stringify(value));
}

function copyUsage(value: OrchestrationUsage): OrchestrationUsage {
  const result: OrchestrationUsage = new OrchestrationUsage();
  result.plannerCalls = value.plannerCalls;
  result.agentActivations = value.agentActivations;
  result.replans = value.replans;
  return result;
}

function copyExecutionResult(value: StepExecutionResult): StepExecutionResult {
  const result: StepExecutionResult = new StepExecutionResult();
  result.status = value.status;
  result.outputJson = value.outputJson;
  result.outputDigest = value.outputDigest;
  result.errorClass = value.errorClass;
  result.errorCode = value.errorCode;
  return result;
}

function copyWorkflowRuntimeSnapshot(value: WorkflowRuntimeSnapshot): WorkflowRuntimeSnapshot {
  const result: WorkflowRuntimeSnapshot = new WorkflowRuntimeSnapshot();
  result.workflowId = value.workflowId;
  result.taskId = value.taskId;
  result.runState = value.runState;
  result.cancellationRequested = value.cancellationRequested;
  result.deadlineAtMs = value.deadlineAtMs;
  result.terminalReason = value.terminalReason;
  result.nextEventSequence = value.nextEventSequence;
  for (let i: number = 0; i < value.steps.length; i++) {
    const step: StepRuntimeRecord = new StepRuntimeRecord();
    step.stepId = value.steps[i].stepId;
    step.state = value.steps[i].state;
    step.attemptCount = value.steps[i].attemptCount;
    step.startedAtMs = value.steps[i].startedAtMs;
    step.finishedAtMs = value.steps[i].finishedAtMs;
    step.lastErrorClass = value.steps[i].lastErrorClass;
    step.outputDigest = value.steps[i].outputDigest;
    result.steps.push(step);
  }
  return result;
}

function quoted(value: string): string {
  return JSON.stringify(value) as string;
}

function isJson(value: string): boolean {
  try {
    JSON.parse(value);
    return true;
  } catch (error) {
    return false;
  }
}

function copyFrame(value: TaskFrame): TaskFrame {
  const result: TaskFrame = new TaskFrame();
  result.schemaVersion = value.schemaVersion;
  result.taskId = value.taskId;
  result.goal = value.goal;
  result.constraints = value.constraints.slice();
  result.capabilityCategories = value.capabilityCategories.slice();
  result.riskLevel = value.riskLevel;
  result.canParallelize = value.canParallelize;
  result.featuresJson = value.featuresJson;
  return result;
}

function copyStep(value: WorkflowStep): WorkflowStep {
  const result: WorkflowStep = new WorkflowStep();
  result.stepId = value.stepId;
  result.kind = value.kind;
  result.goal = value.goal;
  result.dependencies = value.dependencies.slice();
  for (let i: number = 0; i < value.inputBindings.length; i++) {
    const binding: WorkflowInputBinding = new WorkflowInputBinding();
    binding.name = value.inputBindings[i].name;
    binding.sourceStepId = value.inputBindings[i].sourceStepId;
    binding.sourceOutputPath = value.inputBindings[i].sourceOutputPath;
    binding.literalJson = value.inputBindings[i].literalJson;
    result.inputBindings.push(binding);
  }
  result.expectedOutputSchemaJson = value.expectedOutputSchemaJson;
  result.capabilityRequirements = value.capabilityRequirements.slice();
  result.sideEffect = value.sideEffect;
  result.riskLevel = value.riskLevel;
  result.permissionRequirements = value.permissionRequirements.slice();
  result.idempotencyMode = value.idempotencyMode;
  result.timeoutMs = value.timeoutMs;
  result.retryPolicyRef = value.retryPolicyRef;
  result.verificationPolicyRef = value.verificationPolicyRef;
  return result;
}

export class RuntimeCoordinator {
  private clock: RuntimeClockPort;
  private ids: RuntimeIdGeneratorPort;
  private planner: SemanticPlannerPort;
  private collaboration: CollaborationSelectorPort;
  private collaborationPlan?: CollaborationPlanSelectorPort;
  private preparation?: CollaborationPolicyPreparationPort;
  private preparationTimeoutMs: number;
  private planningCheckpoint?: () => Promise<void>;
  private toolPreparer: ToolInvocationPreparerPort;
  private dispatcher: StepDispatchPort;
  private stateObserver: RuntimeStateObserverPort;
  private sessions: SessionController;
  private analyzer: TaskAnalyzer = new TaskAnalyzer();
  private ledger: BudgetLedger = new BudgetLedger();
  private policy: PolicyGateway;
  private policyVersion: string;
  private tasks: RuntimeTaskRecord[] = [];

  constructor(config: RuntimeCoordinatorConfig, clock: RuntimeClockPort, ids: RuntimeIdGeneratorPort,
    planner: SemanticPlannerPort, collaboration: CollaborationSelectorPort,
    toolPreparer: ToolInvocationPreparerPort, dispatcher: StepDispatchPort,
    stateObserver: RuntimeStateObserverPort = new NoopRuntimeStateObserver(),
    collaborationPlan?: CollaborationPlanSelectorPort,
    preparation?: CollaborationPolicyPreparationPort, preparationTimeoutMs: number = 5000,
    planningCheckpoint?: () => Promise<void>) {
    if (config.policyVersion.length === 0 || !Number.isSafeInteger(config.grantTtlMs) || config.grantTtlMs <= 0) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT,
        'invalid RuntimeCoordinator configuration');
    }
    this.clock = clock;
    this.ids = ids;
    this.planner = planner;
    this.collaboration = collaboration;
    if (preparation !== undefined && preparation !== collaborationPlan) {
      throw new Error('collaboration preparation and selector must share an instance');
    }
    this.collaborationPlan = collaborationPlan;
    this.preparation = preparation;
    this.preparationTimeoutMs = preparationTimeoutMs;
    this.planningCheckpoint = planningCheckpoint;
    this.toolPreparer = toolPreparer;
    this.dispatcher = dispatcher;
    this.stateObserver = stateObserver;
    this.sessions = new SessionController(clock, ids);
    this.policyVersion = config.policyVersion;
    this.policy = new PolicyGateway(config.policyVersion, config.grantTtlMs, this.ledger);
  }

  async acceptTask(submission: TaskSubmission): Promise<OrchestrationAcceptance> {
    const accepted: SessionAcceptance = this.sessions.accept(submission);
    const existing: number = this.findTask(accepted.handle.taskId);
    if (existing >= 0) {
      return this.acceptance(this.tasks[existing], true);
    }
    const record: RuntimeTaskRecord = new RuntimeTaskRecord();
    record.submission = ContractCodec.parseTaskSubmission(ContractCodec.stringify(submission));
    record.envelope = accepted.envelope;
    record.handle = accepted.handle;
    record.snapshot.requestId = accepted.handle.requestId;
    record.snapshot.taskId = accepted.handle.taskId;
    record.snapshot.sessionId = accepted.handle.sessionId;
    record.snapshot.status = AgentTaskStatus.RECEIVED;
    record.snapshot.snapshotVersion = accepted.handle.snapshotVersion;
    record.snapshot.updatedAt = accepted.handle.acceptedAt;
    this.tasks.push(record);
    this.ledger.registerTask(record.envelope.taskId, record.envelope.executionBudget);
    this.emit(record, AgentRuntimeEventType.TASK_ACCEPTED, '{"status":"received"}');
    await this.beginPlanning(record, false);
    return this.acceptance(record, false);
  }

  restoreCheckpoint(checkpoint: RuntimeTaskRecoveryCheckpoint,
    authority?: RuntimeRecoveryAuthority): CoordinatorCommandResult {
    const validation = RuntimeCheckpointValidator.validate(checkpoint);
    if (!validation.valid) return this.reconstruction(false, 'CHECKPOINT_INVALID', 0);
    if (checkpoint.checkpointVersion === '1.2' && checkpoint.collaborationPreparation.pending) {
      return this.reconstruction(false, 'PREPARATION_REQUIRES_RECONCILIATION', 0);
    }
    let recoveredOutcome: ToolOutcome | undefined;
    if (authority !== undefined) {
      if (!RuntimeRecoveryAuthorityValidator.validate(checkpoint, authority).valid) {
        return this.reconstruction(false, 'RECOVERY_AUTHORITY_INVALID', 0);
      }
      const operation = authority.operation;
      if (operation !== undefined && (operation.state === OperationJournalState.RESULT_RECORDED ||
        operation.state === OperationJournalState.COMMITTED)) recoveredOutcome = operation.outcome;
    }
    const existing: number = this.findTask(checkpoint.envelope.taskId);
    if (existing >= 0) return this.command(false, 'TASK_ALREADY_EXISTS', this.tasks[existing]);

    let workflow: WorkflowGraph | undefined;
    let scheduler: WorkflowScheduler | undefined;
    try {
      if (checkpoint.workflow !== undefined && checkpoint.scheduler !== undefined) {
        workflow = ContractCodec.parseWorkflowGraph(ContractCodec.stringify(checkpoint.workflow));
        const persisted: WorkflowRuntimeSnapshot = copyWorkflowRuntimeSnapshot(checkpoint.scheduler);
        if (recoveredOutcome !== undefined) {
          if (recoveredOutcome.status !== ToolOutcomeStatus.SUCCEEDED) return this.reconstruction(false, 'OUTCOME_INVALID', 0);
          let matched: boolean = false;
          for (let i: number = 0; i < persisted.steps.length; i++) {
            const step: StepRuntimeRecord = persisted.steps[i];
            if (step.stepId !== checkpoint.pendingStepId) continue;
            if (step.state !== WorkflowStepState.RUNNING && step.state !== WorkflowStepState.VERIFYING) {
              return this.reconstruction(false, 'OUTCOME_STEP_INVALID', 0);
            }
            step.state = WorkflowStepState.SUCCEEDED;
            step.outputDigest = recoveredOutcome.resultDigest === undefined ? '' : recoveredOutcome.resultDigest;
            step.finishedAtMs = this.clock.nowMs();
            matched = true;
          }
          if (!matched) return this.reconstruction(false, 'OUTCOME_STEP_MISSING', 0);
          persisted.runState = persisted.steps.every((step: StepRuntimeRecord): boolean =>
            step.state === WorkflowStepState.SUCCEEDED) ? WorkflowRunState.COMPLETED : WorkflowRunState.RUNNING;
        }
        scheduler = WorkflowScheduler.restore(workflow, persisted, this.clock.nowMs());
      }
    } catch (error) {
      return this.reconstruction(false, 'SCHEDULER_RESTORE_FAILED', 0);
    }
    if (!this.sessions.canRestore(checkpoint.submission, checkpoint.handle, checkpoint.envelope)) {
      return this.reconstruction(false, 'SESSION_RESTORE_CONFLICT', 0);
    }
    if (checkpoint.pendingPolicyRequest !== undefined &&
      this.policy.hasRequest(checkpoint.pendingPolicyRequest.requestId)) {
      return this.reconstruction(false, 'POLICY_REQUEST_RESTORE_CONFLICT', 0);
    }

    const record: RuntimeTaskRecord = new RuntimeTaskRecord();
    record.submission = ContractCodec.parseTaskSubmission(ContractCodec.stringify(checkpoint.submission));
    record.envelope = ContractCodec.parseTaskEnvelope(ContractCodec.stringify(checkpoint.envelope));
    record.frame = copyFrame(checkpoint.frame);
    record.collaborationMode = checkpoint.collaborationMode;
    record.handle = ContractCodec.parseTaskHandle(ContractCodec.stringify(checkpoint.handle));
    record.snapshot = copySnapshot(checkpoint.snapshot);
    for (let i: number = 0; i < checkpoint.events.length; i++) {
      record.events.push(copyEvent(checkpoint.events[i]));
    }
    record.usage = copyUsage(checkpoint.usage);
    if (checkpoint.checkpointVersion === '1.1') {
      record.collaborationPreparation.baselineOnly = true;
      record.collaborationPreparation.evaluations = 2;
    } else {
      record.collaborationPreparation = copyCollaborationPreparationState(checkpoint.collaborationPreparation);
    }
    record.planningRequest = this.copyPlanningRequest(checkpoint.planningRequest);
    record.workflow = workflow;
    record.scheduler = scheduler;
    if (checkpoint.pendingClarification !== undefined) {
      record.pendingClarification = copyClarification(checkpoint.pendingClarification);
    }
    if (checkpoint.pendingPolicyRequest !== undefined) {
      record.pendingPolicyRequest = copyPolicy(checkpoint.pendingPolicyRequest);
    }
    if (checkpoint.pendingInvocation !== undefined) {
      record.pendingInvocation = ContractCodec.parseToolInvocation(
        ContractCodec.stringify(checkpoint.pendingInvocation));
    }
    if (checkpoint.activeInvocation !== undefined) {
      record.activeInvocation = ContractCodec.parseToolInvocation(
        ContractCodec.stringify(checkpoint.activeInvocation));
    }
    record.pendingStepId = checkpoint.pendingStepId;
    record.pendingDispatchId = checkpoint.pendingDispatchId;
    record.pendingOperationId = checkpoint.pendingOperationId;
    record.registeredProviderIds = checkpoint.registeredProviderIds.slice();
    record.paused = checkpoint.paused;
    record.recoveryBlocked = record.snapshot.status !== AgentTaskStatus.COMPLETED &&
      record.snapshot.status !== AgentTaskStatus.CANCELLED;
    if (record.recoveryBlocked) {
      record.recoverySourceCheckpoint = JSON.parse(ContractCodec.stringify(checkpoint)) as
        RuntimeTaskRecoveryCheckpoint;
    }

    this.ledger.registerTask(record.envelope.taskId, record.envelope.executionBudget);
    if (record.workflow !== undefined) {
      for (let i: number = 0; i < record.workflow.steps.length; i++) {
        this.ledger.registerStep(record.envelope.taskId, record.workflow.steps[i].stepId,
          record.envelope.executionBudget);
      }
    }
    for (let i: number = 0; i < record.registeredProviderIds.length; i++) {
      this.ledger.registerProvider(record.envelope.taskId, record.registeredProviderIds[i],
        record.envelope.executionBudget);
    }
    if (record.pendingPolicyRequest !== undefined &&
      !this.policy.registerRequest(record.pendingPolicyRequest)) {
      return this.reconstruction(false, 'POLICY_REQUEST_RESTORE_FAILED', 0);
    }
    if (!this.sessions.restore(checkpoint.submission, checkpoint.handle, checkpoint.envelope)) {
      return this.reconstruction(false, 'SESSION_RESTORE_FAILED', 0);
    }
    if (recoveredOutcome !== undefined && authority !== undefined &&
      !this.ledger.hydrateTask(record.envelope.taskId, authority.budgetScopes, authority.budgetReservations)) {
      return this.reconstruction(false, 'BUDGET_AUTHORITY_HYDRATION_FAILED', 0);
    }
    if (recoveredOutcome !== undefined && authority !== undefined) {
      record.recoveredBudgetAuthorityJson = ContractCodec.stringify(authority);
    }
    this.tasks.push(record);

    if (recoveredOutcome !== undefined) {
      // Persisted success must never be replayed just because its invoice is absent.
      record.pendingDispatchId = '';
      record.pendingStepId = '';
      record.pendingOperationId = '';
      record.activeInvocation = undefined;
      record.paused = scheduler !== undefined && scheduler.getRunState() !== WorkflowRunState.COMPLETED;
      if (record.paused) record.snapshot.status = AgentTaskStatus.PAUSED;
      record.snapshot.resultJson = recoveredOutcome.resultJson === undefined ? '' : recoveredOutcome.resultJson;
      this.bump(record, AgentRuntimeEventType.RESULT_UPDATED, record.snapshot.resultJson);
      this.syncSchedulerState(record);
    } else if (record.pendingDispatchId.length > 0 && record.scheduler !== undefined) {
      record.pendingDispatchId = '';
      if (record.scheduler.getRunState() === WorkflowRunState.WAITING_RECONCILIATION) {
        record.paused = false;
        record.pendingPolicyRequest = undefined;
        record.pendingInvocation = undefined;
        record.activeInvocation = undefined;
        this.transition(record, AgentTaskStatus.WAITING_RECONCILIATION,
          AgentRuntimeEventType.RECONCILIATION_REQUIRED,
          '{"reason":"restartRequiresReconciliation","stepId":' + quoted(record.pendingStepId) +
            ',"operationId":' + quoted(record.pendingOperationId) + '}');
      } else {
        record.pendingStepId = '';
        record.pendingOperationId = '';
        record.activeInvocation = undefined;
        this.bump(record, AgentRuntimeEventType.TASK_STATE_CHANGED,
          '{"status":"running","reason":"restartReplayBlocked"}');
      }
    }
    return this.command(true, record.recoveryBlocked ?
      'RESTORED_AUTHORITY_REQUIRED' : 'RESTORED_TERMINAL', record);
  }

  hydrateRecoveryAuthority(taskId: string, authority: RuntimeRecoveryAuthority): CoordinatorCommandResult {
    const record: RuntimeTaskRecord = this.requireTask(taskId);
    if (!record.recoveryBlocked || record.recoverySourceCheckpoint === undefined) {
      return this.command(false, 'RECOVERY_AUTHORITY_NOT_REQUIRED', record);
    }
    if (authority.policyVersion !== this.policyVersion) {
      return this.command(false, 'RECOVERY_POLICY_VERSION_MISMATCH', record);
    }
    const validation = RuntimeRecoveryAuthorityValidator.validate(record.recoverySourceCheckpoint, authority);
    if (!validation.valid) return this.command(false, validation.code, record);
    if (record.recoveredBudgetAuthorityJson.length > 0 ?
      record.recoveredBudgetAuthorityJson !== ContractCodec.stringify(authority) :
      !this.ledger.hydrateTask(taskId, authority.budgetScopes, authority.budgetReservations)) {
      return this.command(false, 'BUDGET_AUTHORITY_HYDRATION_FAILED', record);
    }
    record.recoveredBudgetAuthorityJson = '';
    record.recoveryBlocked = false;
    record.recoverySourceCheckpoint = undefined;
    this.bump(record, AgentRuntimeEventType.TASK_STATE_CHANGED,
      '{"status":"recoveryAuthorityHydrated","storageRevision":' + authority.storageRevision.toString() + '}');
    return this.command(true, 'RECOVERY_AUTHORITY_HYDRATED', record);
  }

  advance(taskId: string): CoordinatorCommandResult {
    const record: RuntimeTaskRecord = this.requireTask(taskId);
    if (record.recoveryBlocked) return this.command(false, 'RECOVERY_AUTHORITY_REQUIRED', record);
    if (record.snapshot.status !== AgentTaskStatus.RUNNING || record.paused ||
      record.pendingDispatchId.length > 0 || record.pendingPolicyRequest !== undefined) {
      return this.command(false, 'TASK_NOT_DISPATCHABLE', record);
    }
    const scheduler: WorkflowScheduler = this.requireScheduler(record);
    if (scheduler.enforceDeadline(this.clock.nowMs())) {
      this.syncSchedulerState(record);
      return this.command(false, 'DEADLINE_EXCEEDED', record);
    }
    const ready: string[] = scheduler.readyStepIds();
    if (ready.length === 0) {
      this.syncSchedulerState(record);
      return this.command(false, 'NO_READY_STEP', record);
    }
    const step: WorkflowStep = this.requireStep(record, ready[0]);
    if (step.kind === WorkflowStepKind.TOOL) {
      return this.prepareTool(record, step);
    }
    return this.dispatch(record, step, undefined);
  }

  completeStep(completion: StepCompletion): CoordinatorCommandResult {
    const record: RuntimeTaskRecord = this.requireTask(completion.taskId);
    if (record.recoveryBlocked) return this.command(false, 'RECOVERY_AUTHORITY_REQUIRED', record);
    if (record.pendingDispatchId.length === 0 || completion.dispatchId !== record.pendingDispatchId ||
      completion.stepId !== record.pendingStepId) {
      return this.command(false, 'STALE_OR_UNKNOWN_DISPATCH', record);
    }
    const scheduler: WorkflowScheduler = this.requireScheduler(record);
    const step: WorkflowStep = this.requireStep(record, completion.stepId);
    record.pendingDispatchId = '';
    const safeResult: StepExecutionResult = copyExecutionResult(completion.result);
    if (safeResult.status === StepExecutionStatus.SUCCEEDED && !isJson(safeResult.outputJson)) {
      safeResult.status = StepExecutionStatus.FAILED;
      safeResult.errorClass = AgentErrorClass.SCHEMA_MISMATCH;
      safeResult.errorCode = 'INVALID_OUTPUT_JSON';
    }
    if (safeResult.status === StepExecutionStatus.SUCCEEDED) {
      scheduler.markVerifying(step.stepId, this.clock.nowMs());
    }
    scheduler.completeStep(step.stepId, safeResult, this.clock.nowMs());
    if (scheduler.getRunState() === WorkflowRunState.RECOVERING) {
      const recovery: DeterministicRecoveryPolicy =
        new DeterministicRecoveryPolicy(record.envelope.executionBudget.maxRetries);
      const decision: RecoveryDecision = recovery.decide(step, scheduler.getStepRecord(step.stepId), safeResult);
      scheduler.applyRecoveryDecision(step.stepId, decision, this.clock.nowMs());
      if (decision.action === RecoveryAction.REPLAN_STEP) {
        record.pendingStepId = '';
        record.pendingOperationId = '';
        record.activeInvocation = undefined;
        this.transition(record, AgentTaskStatus.FAILED, AgentRuntimeEventType.TASK_FAILED,
          '{"reason":"partialReplanRequired","stepId":' + quoted(step.stepId) + '}');
        return this.command(true, 'REPLAN_REQUIRED', record);
      }
    }
    if (scheduler.getRunState() !== WorkflowRunState.WAITING_RECONCILIATION) {
      record.pendingStepId = '';
      record.pendingOperationId = '';
      record.activeInvocation = undefined;
    }
    if (safeResult.status === StepExecutionStatus.SUCCEEDED && safeResult.outputJson.length > 0) {
      record.snapshot.resultJson = safeResult.outputJson;
      this.bump(record, AgentRuntimeEventType.RESULT_UPDATED, safeResult.outputJson);
    }
    this.syncSchedulerState(record);
    return this.command(true, 'COMPLETION_APPLIED', record);
  }

  provideAuthorization(decision: AuthorizationDecision): CoordinatorCommandResult {
    if (!ContractValidator.validateAuthorizationDecision(decision).valid) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'invalid AuthorizationDecision');
    }
    const record: RuntimeTaskRecord = this.requireTask(decision.taskId);
    if (record.recoveryBlocked) return this.command(false, 'RECOVERY_AUTHORITY_REQUIRED', record);
    const pending: PolicyRequest | undefined = record.pendingPolicyRequest;
    if (pending === undefined || pending.requestId !== decision.policyRequestId ||
      record.snapshot.status !== AgentTaskStatus.WAITING_AUTHORIZATION) {
      return this.command(false, 'AUTHORIZATION_NOT_PENDING', record);
    }
    const result: PolicyDecisionResult = this.policy.applyDecision(decision, this.clock.nowMs());
    if (!result.processed) {
      return this.command(false, result.code, record);
    }
    record.pendingPolicyRequest = undefined;
    if (!result.authorized || result.grant === undefined) {
      this.failReadyStep(record, pending.stepId, AgentErrorClass.POLICY_DENIED, result.code);
      return this.command(true, result.code, record);
    }
    const invocation: ToolInvocation | undefined = record.pendingInvocation;
    if (invocation === undefined) {
      return this.command(false, 'PREPARED_INVOCATION_MISSING', record);
    }
    invocation.authorizationGrantId = result.grant.grantId;
    if (!this.policy.authorizeInvocation(invocation, this.clock.nowMs()).allowed) {
      this.failReadyStep(record, pending.stepId, AgentErrorClass.POLICY_DENIED, 'GRANT_REJECTED');
      return this.command(false, 'GRANT_REJECTED', record);
    }
    record.pendingInvocation = undefined;
    this.transition(record, AgentTaskStatus.RUNNING, AgentRuntimeEventType.TASK_STATE_CHANGED,
      '{"status":"running","authorization":"granted"}');
    return this.dispatch(record, this.requireStep(record, pending.stepId), invocation, pending, result.grant);
  }

  async provideClarification(response: ClarificationResponse): Promise<CoordinatorCommandResult> {
    if (!ContractValidator.validateClarificationResponse(response).valid) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'invalid ClarificationResponse');
    }
    const record: RuntimeTaskRecord = this.requireTask(response.taskId);
    if (record.recoveryBlocked) return this.command(false, 'RECOVERY_AUTHORITY_REQUIRED', record);
    const pending: ClarificationRequest | undefined = record.pendingClarification;
    if (pending === undefined || pending.clarificationId !== response.clarificationId ||
      record.snapshot.status !== AgentTaskStatus.WAITING_INPUT) {
      return this.command(false, 'CLARIFICATION_NOT_PENDING', record);
    }
    if (response.respondedAtMs > this.clock.nowMs() || this.clock.nowMs() >= pending.expiresAtMs) {
      return this.command(false, 'CLARIFICATION_EXPIRED', record);
    }
    try {
      JSON.parse(response.answerJson);
    } catch (error) {
      return this.command(false, 'INVALID_ANSWER_JSON', record);
    }
    if (!this.consumePlannerCall(record, false)) {
      return this.command(false, 'PLANNER_BUDGET_EXHAUSTED', record);
    }
    const isolatedResponse: ClarificationResponse =
      ContractCodec.parseClarificationResponse(ContractCodec.stringify(response));
    let planned: PlanningResult;
    record.planningActive = true;
    record.planningInterrupted = false;
    try {
      if (this.preparation !== undefined && !await this.reservePlanning(record)) {
        record.planningActive = false;
        return this.command(false, 'AGENT_ACTIVATION_BUDGET_EXHAUSTED', record);
      }
      planned = await this.planner.resume(this.copyPlanningRequest(record.planningRequest), isolatedResponse);
    } catch (error) {
      record.planningActive = false;
      if (record.planningInterrupted) return this.command(false, 'PLANNING_INTERRUPTED', record);
      record.pendingClarification = undefined;
      this.failPlannerInvocation(record);
      return this.command(false, 'PLANNER_INVOCATION_FAILED', record);
    }
    record.planningActive = false;
    if (record.planningInterrupted) return this.command(false, 'PLANNING_INTERRUPTED', record);
    record.pendingClarification = undefined;
    this.applyPlanningResult(record, planned);
    return this.command(true, 'CLARIFICATION_APPLIED', record);
  }

  provideReconciliation(report: ReconciliationReport): CoordinatorCommandResult {
    if (!ContractValidator.validateReconciliationReport(report).valid) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'invalid ReconciliationReport');
    }
    const record: RuntimeTaskRecord = this.requireTask(report.taskId);
    if (record.recoveryBlocked) return this.command(false, 'RECOVERY_AUTHORITY_REQUIRED', record);
    if (record.snapshot.status !== AgentTaskStatus.WAITING_RECONCILIATION ||
      report.stepId !== record.pendingStepId || report.operationId !== record.pendingOperationId) {
      return this.command(false, 'RECONCILIATION_NOT_PENDING', record);
    }
    if (report.status === ReconciliationStatus.STILL_UNKNOWN) {
      return this.command(true, 'STILL_UNKNOWN', record);
    }
    const result: StepExecutionResult = new StepExecutionResult();
    if (report.status === ReconciliationStatus.CONFIRMED_SUCCEEDED) {
      result.status = StepExecutionStatus.SUCCEEDED;
      result.outputDigest = report.evidenceDigest;
      record.snapshot.resultJson = '{"status":"success","reconciled":true,"evidenceDigest":' +
        quoted(report.evidenceDigest) + '}';
    } else {
      result.status = StepExecutionStatus.FAILED;
      result.errorClass = AgentErrorClass.PROVIDER;
      result.errorCode = report.status;
    }
    const scheduler: WorkflowScheduler = this.requireScheduler(record);
    const step: WorkflowStep = this.requireStep(record, report.stepId);
    scheduler.reconcileUnknownOutcome(report.stepId, result, this.clock.nowMs());
    if (scheduler.getRunState() === WorkflowRunState.RECOVERING) {
      const recovery: RecoveryDecision =
        new DeterministicRecoveryPolicy(record.envelope.executionBudget.maxRetries)
          .decide(step, scheduler.getStepRecord(step.stepId), result);
      scheduler.applyRecoveryDecision(step.stepId, recovery, this.clock.nowMs());
    }
    record.pendingStepId = '';
    record.pendingOperationId = '';
    record.activeInvocation = undefined;
    this.syncSchedulerState(record);
    return this.command(true, 'RECONCILED', record);
  }

  async requestReplan(taskId: string, affectedStepIds: string[]): Promise<CoordinatorCommandResult> {
    const record: RuntimeTaskRecord = this.requireTask(taskId);
    if (record.recoveryBlocked) return this.command(false, 'RECOVERY_AUTHORITY_REQUIRED', record);
    const current: WorkflowGraph | undefined = record.workflow;
    const scheduler: WorkflowScheduler | undefined = record.scheduler;
    if (current === undefined || scheduler === undefined ||
      (record.snapshot.status !== AgentTaskStatus.FAILED &&
      scheduler.getRunState() !== WorkflowRunState.RECOVERING)) {
      return this.command(false, 'REPLAN_NOT_ALLOWED', record);
    }
    const affected: string[] = affectedStepIds.length > 0 ? affectedStepIds.slice() :
      this.replaceableStepIds(scheduler.snapshot());
    if (affected.length === 0 || !this.consumePlannerCall(record, true)) {
      return this.command(false, affected.length === 0 ? 'NO_REPLACEABLE_STEPS' :
        'REPLAN_BUDGET_EXHAUSTED', record);
    }
    record.planningRequest.previousWorkflow =
      ContractCodec.parseWorkflowGraph(ContractCodec.stringify(current));
    record.planningRequest.affectedStepIds = affected.slice();
    record.planningActive = true;
    record.planningInterrupted = false;
    if (this.preparation !== undefined && !await this.preparePlanning(record)) {
      record.planningActive = false;
      return this.command(false, 'COLLABORATION_PREPARATION_STOPPED', record);
    }
    let planned: PlanningResult;
    try {
      planned = await this.planner.replan(this.copyPlanningRequest(record.planningRequest));
    } catch (error) {
      record.planningActive = false;
      if (record.planningInterrupted) return this.command(false, 'PLANNING_INTERRUPTED', record);
      this.failPlannerInvocation(record);
      return this.command(false, 'PLANNER_INVOCATION_FAILED', record);
    }
    record.planningActive = false;
    if (record.planningInterrupted) return this.command(false, 'PLANNING_INTERRUPTED', record);
    if (planned.status !== PlanningStatus.READY || planned.workflow === undefined) {
      return this.command(false, 'INVALID_REPLAN_RESULT', record);
    }
    const replaced = WorkflowReplanController.replaceAffectedSubgraph(current, planned.workflow,
      affected, scheduler.snapshot());
    if (!replaced.accepted || replaced.workflow === undefined) {
      return this.command(false, replaced.code, record);
    }
    const restored: WorkflowRuntimeSnapshot = scheduler.snapshot();
    restored.runState = WorkflowRunState.RECOVERING;
    restored.terminalReason = '';
    for (let i: number = 0; i < restored.steps.length; i++) {
      if (this.contains(affected, restored.steps[i].stepId)) {
        restored.steps[i].state = WorkflowStepState.PENDING;
        restored.steps[i].startedAtMs = 0;
        restored.steps[i].finishedAtMs = 0;
        restored.steps[i].lastErrorClass = AgentErrorClass.UNKNOWN;
        restored.steps[i].outputDigest = '';
      }
    }
    record.workflow = replaced.workflow;
    record.planningRequest.previousWorkflow = replaced.workflow;
    record.planningRequest.affectedStepIds = [];
    record.scheduler = WorkflowScheduler.restore(replaced.workflow, restored, this.clock.nowMs());
    record.pendingStepId = '';
    record.pendingOperationId = '';
    this.transition(record, AgentTaskStatus.RUNNING, AgentRuntimeEventType.TASK_STATE_CHANGED,
      '{"status":"running","replanned":true,"workflowVersion":' +
        quoted(replaced.workflow.workflowVersion) + '}');
    return this.command(true, 'REPLANNED', record);
  }

  pause(taskId: string): CoordinatorCommandResult {
    const record: RuntimeTaskRecord = this.requireTask(taskId);
    if (record.recoveryBlocked) return this.command(false, 'RECOVERY_AUTHORITY_REQUIRED', record);
    if (record.snapshot.status !== AgentTaskStatus.RUNNING) {
      return this.command(false, 'TASK_NOT_RUNNING', record);
    }
    record.paused = true;
    this.transition(record, AgentTaskStatus.PAUSED, AgentRuntimeEventType.TASK_STATE_CHANGED,
      '{"status":"paused"}');
    return this.command(true, 'PAUSED', record);
  }

  resume(taskId: string): CoordinatorCommandResult {
    const record: RuntimeTaskRecord = this.requireTask(taskId);
    if (record.recoveryBlocked) return this.command(false, 'RECOVERY_AUTHORITY_REQUIRED', record);
    if (!record.paused || record.snapshot.status !== AgentTaskStatus.PAUSED) {
      return this.command(false, 'TASK_NOT_PAUSED', record);
    }
    record.paused = false;
    this.transition(record, AgentTaskStatus.RUNNING, AgentRuntimeEventType.TASK_STATE_CHANGED,
      '{"status":"running"}');
    return this.command(true, 'RESUMED', record);
  }

  cancel(taskId: string): CoordinatorCommandResult {
    const record: RuntimeTaskRecord = this.requireTask(taskId);
    if (record.recoveryBlocked) return this.command(false, 'RECOVERY_AUTHORITY_REQUIRED', record);
    if (!record.preparationInterrupted && this.isTerminal(record.snapshot.status)) {
      return this.command(false, 'TASK_TERMINAL', record);
    }
    const scheduler: WorkflowScheduler | undefined = record.scheduler;
    if (scheduler === undefined) {
      record.pendingClarification = undefined;
      record.pendingPolicyRequest = undefined;
      record.pendingInvocation = undefined;
      this.transition(record, AgentTaskStatus.CANCELLED, AgentRuntimeEventType.TASK_CANCELLED,
        '{"reason":"callerRequested"}');
      return this.command(true, 'CANCELLED', record);
    }
    scheduler.requestCancellation('caller requested', this.clock.nowMs());
    record.pendingDispatchId = '';
    record.pendingClarification = undefined;
    record.pendingPolicyRequest = undefined;
    record.pendingInvocation = undefined;
    if (scheduler.getRunState() !== WorkflowRunState.WAITING_RECONCILIATION) {
      record.activeInvocation = undefined;
      record.pendingStepId = '';
      record.pendingOperationId = '';
    }
    this.syncSchedulerState(record);
    return this.command(true, scheduler.getRunState() === WorkflowRunState.WAITING_RECONCILIATION ?
      'CANCELLATION_DEFERRED' : 'CANCELLED', record);
  }

  getSnapshot(taskId: string): AgentTaskSnapshot {
    return copySnapshot(this.requireTask(taskId).snapshot);
  }

  getEvents(taskId: string): AgentRuntimeEvent[] {
    const record: RuntimeTaskRecord = this.requireTask(taskId);
    const values: AgentRuntimeEvent[] = [];
    for (let i: number = 0; i < record.events.length; i++) {
      values.push(copyEvent(record.events[i]));
    }
    return values;
  }

  getUsage(taskId: string): OrchestrationUsage {
    return copyUsage(this.requireTask(taskId).usage);
  }

  getRecoveryCheckpoint(taskId: string): RuntimeTaskRecoveryCheckpoint {
    const record: RuntimeTaskRecord = this.requireTask(taskId);
    const value: RuntimeTaskRecoveryCheckpoint = new RuntimeTaskRecoveryCheckpoint();
    value.submission = ContractCodec.parseTaskSubmission(ContractCodec.stringify(record.submission));
    value.envelope = ContractCodec.parseTaskEnvelope(ContractCodec.stringify(record.envelope));
    value.frame = copyFrame(record.frame);
    value.collaborationMode = record.collaborationMode;
    value.handle = ContractCodec.parseTaskHandle(ContractCodec.stringify(record.handle));
    value.snapshot = copySnapshot(record.snapshot);
    for (let i: number = 0; i < record.events.length; i++) {
      value.events.push(copyEvent(record.events[i]));
    }
    value.usage = copyUsage(record.usage);
    value.collaborationPreparation = copyCollaborationPreparationState(record.collaborationPreparation);
    value.planningRequest = this.copyPlanningRequest(record.planningRequest);
    if (record.workflow !== undefined) {
      value.workflow = ContractCodec.parseWorkflowGraph(ContractCodec.stringify(record.workflow));
    }
    if (record.scheduler !== undefined) {
      value.scheduler = copyWorkflowRuntimeSnapshot(record.scheduler.snapshot());
    }
    if (record.pendingClarification !== undefined) {
      value.pendingClarification = copyClarification(record.pendingClarification);
    }
    if (record.pendingPolicyRequest !== undefined) {
      value.pendingPolicyRequest = copyPolicy(record.pendingPolicyRequest);
    }
    if (record.pendingInvocation !== undefined) {
      value.pendingInvocation = ContractCodec.parseToolInvocation(
        ContractCodec.stringify(record.pendingInvocation));
    }
    if (record.activeInvocation !== undefined) {
      value.activeInvocation = ContractCodec.parseToolInvocation(
        ContractCodec.stringify(record.activeInvocation));
    }
    value.pendingStepId = record.pendingStepId;
    value.pendingDispatchId = record.pendingDispatchId;
    value.pendingOperationId = record.pendingOperationId;
    value.registeredProviderIds = record.registeredProviderIds.slice();
    value.paused = record.paused;
    return value;
  }

  /**
   * Captures the authority owned by the coordinator at the same logical state
   * as getRecoveryCheckpoint. It exposes data only and cannot control a task.
   */
  getDurableAuthorityPayload(taskId: string): RuntimeDurableAuthorityPayload {
    const record: RuntimeTaskRecord = this.requireTask(taskId);
    const value: RuntimeDurableAuthorityPayload = new RuntimeDurableAuthorityPayload();
    value.taskId = taskId;
    value.checkpointSnapshotVersion = record.snapshot.snapshotVersion;
    value.policyVersion = this.policyVersion;
    value.budgetScopes = this.ledger.getTaskScopes(taskId);
    value.budgetReservations = this.ledger.getTaskReservations(taskId);

    if (record.pendingPolicyRequest !== undefined) {
      const pendingPolicy: RuntimeRecoveryPolicyAuthority = new RuntimeRecoveryPolicyAuthority();
      pendingPolicy.version = 1;
      pendingPolicy.request = copyPolicy(record.pendingPolicyRequest);
      value.policy = pendingPolicy;
      return value;
    }
    if (record.activeInvocation === undefined || record.pendingDispatchId.length === 0) return value;

    const active: ToolInvocation = record.activeInvocation;
    const grant: AuthorizationGrant | undefined = this.policy.getGrant(active.authorizationGrantId);
    const request: PolicyRequest | undefined = grant === undefined ? undefined :
      this.policy.getRequest(grant.policyRequestId);
    const decision: AuthorizationDecision | undefined = request === undefined ? undefined :
      this.policy.getDecisionForRequest(request.requestId);
    if (grant === undefined || request === undefined || decision === undefined) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'active invocation authority is incomplete');
    }

    const policy: RuntimeRecoveryPolicyAuthority = new RuntimeRecoveryPolicyAuthority();
    policy.version = 3;
    policy.request = request;
    policy.decision = decision;
    policy.grant = grant;
    value.policy = policy;

    const step: WorkflowStep = this.requireStep(record, active.stepId);
    const operation: RuntimeRecoveryOperationAuthority = new RuntimeRecoveryOperationAuthority();
    operation.operationId = active.operationId;
    operation.invocationId = active.invocationId;
    operation.taskId = active.taskId;
    operation.stepId = active.stepId;
    operation.attemptId = active.attemptId;
    operation.toolId = active.toolId;
    operation.toolIdentityVersion = active.toolIdentityVersion;
    operation.schemaDigest = active.schemaDigest;
    operation.argumentsDigest = active.argumentsDigest;
    operation.idempotencyKey = active.idempotencyKey === undefined ?
      'attempt:' + active.attemptId : active.idempotencyKey;
    operation.idempotencyMode = step.idempotencyMode;
    operation.sideEffect = step.sideEffect;
    operation.policyRequestId = request.requestId;
    operation.budgetReservationId = grant.budgetReservationId;
    operation.state = OperationJournalState.PREPARED;
    value.operation = operation;
    return value;
  }

  getPendingPolicyRequest(taskId: string): PolicyRequest | undefined {
    const value: PolicyRequest | undefined = this.requireTask(taskId).pendingPolicyRequest;
    return value === undefined ? undefined : copyPolicy(value);
  }

  getPendingClarification(taskId: string): ClarificationRequest | undefined {
    const value: ClarificationRequest | undefined = this.requireTask(taskId).pendingClarification;
    return value === undefined ? undefined : copyClarification(value);
  }

  private async beginPlanning(record: RuntimeTaskRecord, replan: boolean): Promise<void> {
    record.planningActive = true;
    record.planningInterrupted = false;
    try {
    if (!this.consumePlannerCall(record, replan)) {
      this.transition(record, AgentTaskStatus.FAILED, AgentRuntimeEventType.TASK_FAILED,
        '{"reason":"plannerBudgetExhausted"}');
      return;
    }
    record.frame = this.analyzer.analyze(record.envelope);
    record.planningRequest.envelope = ContractCodec.parseTaskEnvelope(ContractCodec.stringify(record.envelope));
    record.planningRequest.frame = copyFrame(record.frame);
    record.planningRequest.collaborationPlan = undefined;
    if (this.preparation !== undefined) {
      if (!await this.preparePlanning(record)) return;
    }
    const planSelector: CollaborationPlanSelectorPort | undefined = this.preparation === undefined ?
      this.collaborationPlan : undefined;
    if (planSelector === undefined && this.preparation === undefined) {
      record.collaborationMode = this.collaboration.select(copyFrame(record.frame));
    } else if (planSelector !== undefined) {
      let selectedPlan: CollaborationPlan;
      try {
        selectedPlan = planSelector.selectPlan(copyFrame(record.frame),
          record.envelope.executionBudget.maxAgentActivations);
      } catch (error) {
        this.transition(record, AgentTaskStatus.FAILED, AgentRuntimeEventType.TASK_FAILED,
          '{"reason":"collaborationPlanSelectionFailed"}');
        return;
      }
      if (!CollaborationPlanValidator.validate(selectedPlan, record.frame,
        record.envelope.executionBudget.maxAgentActivations).valid) {
        this.transition(record, AgentTaskStatus.FAILED, AgentRuntimeEventType.TASK_FAILED,
          '{"reason":"collaborationPlanInvalid"}');
        return;
      }
      record.collaborationMode = selectedPlan.mode;
      record.planningRequest.collaborationPlan = this.copyCollaborationPlan(selectedPlan);
    }
    record.planningRequest.collaborationMode = record.collaborationMode;
    if (record.collaborationMode === CollaborationMode.MULTI &&
      record.envelope.executionBudget.maxAgentActivations < 2) {
      this.transition(record, AgentTaskStatus.FAILED, AgentRuntimeEventType.TASK_FAILED,
        '{"reason":"agentActivationBudgetExhausted"}');
      return;
    }
    if (record.collaborationMode === CollaborationMode.MULTI &&
      record.planningRequest.collaborationPlan === undefined) {
      this.transition(record, AgentTaskStatus.FAILED, AgentRuntimeEventType.TASK_FAILED,
        '{"reason":"collaborationPlanRequired"}');
      return;
    }
    const collaborationPlan: CollaborationPlan | undefined = record.planningRequest.collaborationPlan;
    if (this.preparation === undefined) {
      record.usage.agentActivations = collaborationPlan === undefined ? 1 : collaborationPlan.assignments.length;
    }
    const isolated: PlanningRequest = this.copyPlanningRequest(record.planningRequest);
    let result: PlanningResult;
    try {
      if (record.planningInterrupted) return;
      result = replan ? await this.planner.replan(isolated) : await this.planner.plan(isolated);
    } catch (error) {
      if (record.planningInterrupted) return;
      this.failPlannerInvocation(record);
      return;
    }
    if (record.planningInterrupted) return;
    this.applyPlanningResult(record, result);
    } finally {
      record.planningActive = false;
    }
  }

  /** Signals only computation; all task state changes remain inside the Facade queue. */
  interruptPreparation(taskId: string): boolean {
    const index: number = this.findTask(taskId);
    if (index < 0) return false;
    const source: ArtifactPolicyCancellationSource | undefined = this.tasks[index].preparationCancellation;
    if (source === undefined) return false;
    this.tasks[index].preparationInterrupted = true;
    source.cancel();
    return true;
  }

  /** Signals preparation and Provider work without mutating task state outside the Facade FIFO. */
  interruptPlanning(taskId: string): boolean {
    const index: number = this.findTask(taskId);
    if (index < 0 || !this.tasks[index].planningActive) return false;
    const record: RuntimeTaskRecord = this.tasks[index];
    record.planningInterrupted = true;
    this.interruptPreparation(taskId);
    this.planner.interrupt(taskId);
    return true;
  }

  interruptAllPlanning(): string[] {
    const ids: string[] = [];
    for (let i: number = 0; i < this.tasks.length; i++) {
      const taskId: string = this.tasks[i].envelope.taskId;
      if (this.interruptPlanning(taskId)) ids.push(taskId);
    }
    return ids;
  }

  interruptAllPreparations(): string[] {
    const ids: string[] = [];
    for (let i: number = 0; i < this.tasks.length; i++) {
      const taskId: string = this.tasks[i].envelope.taskId;
      if (this.interruptPreparation(taskId)) ids.push(taskId);
    }
    return ids;
  }

  private async preparePlanning(record: RuntimeTaskRecord): Promise<boolean> {
    const port: CollaborationPolicyPreparationPort | undefined = this.preparation;
    if (port === undefined) return true;
    const remaining: number = record.envelope.executionBudget.maxAgentActivations - record.usage.agentActivations;
    if (remaining < 1) {
      this.transition(record, AgentTaskStatus.FAILED, AgentRuntimeEventType.TASK_FAILED,
        '{"reason":"agentActivationBudgetExhausted"}');
      return false;
    }
    const budget: ExecutionBudget =
      ContractCodec.parseTaskEnvelope(ContractCodec.stringify(record.envelope)).executionBudget;
    budget.maxAgentActivations = remaining;
    let fallback: boolean = record.collaborationPreparation.baselineOnly ||
      record.collaborationPreparation.evaluations >= 2;
    const cancellation: ArtifactPolicyCancellationSource = new ArtifactPolicyCancellationSource();
    record.preparationCancellation = cancellation;
    if (!fallback) {
      record.collaborationPreparation.evaluations++;
      record.collaborationPreparation.pending = true;
      try {
        await this.persistPlanning(record);
        const outcome: CollaborationPreparationOutcome = await prepareCollaboration(port,
          copyFrame(record.frame), budget, cancellation, this.preparationTimeoutMs);
        if (outcome === CollaborationPreparationOutcome.INTERRUPTED) {
          record.collaborationPreparation.pending = false;
          record.preparationCancellation = undefined;
          return false;
        }
        fallback = outcome !== CollaborationPreparationOutcome.READY;
      } catch (error) {
        record.preparationCancellation = undefined;
        throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
          'collaboration preparation checkpoint could not be saved');
      }
      record.collaborationPreparation.pending = false;
    }
    try {
      const plan: CollaborationPlan = fallback ? port.selectBaselinePlan(copyFrame(record.frame), remaining) :
        port.selectPlan(copyFrame(record.frame), remaining);
      if (!CollaborationPlanValidator.validate(plan, record.frame, remaining).valid) {
        throw new Error('invalid prepared collaboration plan');
      }
      record.collaborationMode = plan.mode;
      record.planningRequest.collaborationMode = plan.mode;
      record.planningRequest.collaborationPlan = this.copyCollaborationPlan(plan);
    } catch (error) {
      record.preparationCancellation = undefined;
      this.transition(record, AgentTaskStatus.FAILED, AgentRuntimeEventType.TASK_FAILED,
        '{"reason":"collaborationPlanInvalid"}');
      return false;
    }
    try {
      const reserved: boolean = await this.reservePlanning(record);
      return reserved && !record.preparationInterrupted;
    } finally {
      record.preparationCancellation = undefined;
    }
  }

  private async reservePlanning(record: RuntimeTaskRecord): Promise<boolean> {
    const plan: CollaborationPlan | undefined = record.planningRequest.collaborationPlan;
    const required: number = plan === undefined ? 1 : plan.assignments.length;
    if (record.usage.agentActivations + required > record.envelope.executionBudget.maxAgentActivations) {
      record.pendingClarification = undefined;
      this.transition(record, AgentTaskStatus.FAILED, AgentRuntimeEventType.TASK_FAILED,
        '{"reason":"agentActivationBudgetExhausted"}');
      return false;
    }
    // Conservatively consume the complete planned activation set before any provider invocation.
    record.usage.agentActivations += required;
    await this.persistPlanning(record);
    return true;
  }

  private async persistPlanning(record: RuntimeTaskRecord): Promise<void> {
    this.bump(record, AgentRuntimeEventType.TASK_STATE_CHANGED, '{"collaborationPreparation":true}');
    const persist: (() => Promise<void>) | undefined = this.planningCheckpoint;
    if (persist !== undefined) await persist();
  }

  private failPlannerInvocation(record: RuntimeTaskRecord): void {
    this.transition(record, AgentTaskStatus.FAILED, AgentRuntimeEventType.TASK_FAILED,
      '{"reason":"plannerInvocationFailed"}');
  }

  private applyPlanningResult(record: RuntimeTaskRecord, result: PlanningResult): void {
    if (result.status === PlanningStatus.CLARIFICATION_REQUIRED && result.clarification !== undefined) {
      if (result.clarification.taskId !== record.envelope.taskId ||
        result.clarification.clarificationId.length === 0 || result.clarification.expiresAtMs <= this.clock.nowMs()) {
        this.transition(record, AgentTaskStatus.FAILED, AgentRuntimeEventType.TASK_FAILED,
          '{"reason":"invalidClarificationRequest"}');
        return;
      }
      record.pendingClarification = copyClarification(result.clarification);
      this.transition(record, AgentTaskStatus.WAITING_INPUT, AgentRuntimeEventType.CLARIFICATION_REQUIRED,
        '{"clarificationId":' + quoted(result.clarification.clarificationId) + '}');
      return;
    }
    if (result.status !== PlanningStatus.READY || result.workflow === undefined ||
      result.workflow.taskId !== record.envelope.taskId || !WorkflowGraphValidator.validate(result.workflow).valid) {
      this.transition(record, AgentTaskStatus.FAILED, AgentRuntimeEventType.TASK_FAILED,
        '{"reason":"invalidPlannerResult"}');
      return;
    }
    record.workflow = ContractCodec.parseWorkflowGraph(ContractCodec.stringify(result.workflow));
    record.planningRequest.previousWorkflow = record.workflow;
    record.scheduler = new WorkflowScheduler(record.workflow);
    for (let i: number = 0; i < record.workflow.steps.length; i++) {
      this.ledger.registerStep(record.envelope.taskId, record.workflow.steps[i].stepId,
        record.envelope.executionBudget);
    }
    let deadlineAtMs: number = 0;
    if (record.envelope.executionBudget.deadlineAt !== undefined) {
      deadlineAtMs = Date.parse(record.envelope.executionBudget.deadlineAt as string);
    } else if (record.envelope.executionBudget.maxWallTimeMs > 0) {
      deadlineAtMs = this.clock.nowMs() + record.envelope.executionBudget.maxWallTimeMs;
    }
    record.scheduler.start(this.clock.nowMs(), deadlineAtMs);
    this.transition(record, AgentTaskStatus.RUNNING, AgentRuntimeEventType.TASK_STATE_CHANGED,
      '{"status":"running","workflowId":' + quoted(record.workflow.workflowId) + '}');
  }

  private prepareTool(record: RuntimeTaskRecord, step: WorkflowStep): CoordinatorCommandResult {
    const prepared: PreparedToolDispatch = this.toolPreparer.prepare(this.copyPlanningRequest(record.planningRequest),
      copyStep(step),
      this.clock.nowMs());
    const request: PolicyRequest = prepared.policyRequest;
    const invocation: ToolInvocation = prepared.invocation;
    if (!ContractValidator.validatePolicyRequest(request).valid || request.userId !== record.envelope.userId ||
      request.taskId !== record.envelope.taskId || request.stepId !== step.stepId ||
      request.riskLevel !== step.riskLevel || request.sideEffect !== step.sideEffect ||
      invocation.taskId !== request.taskId || invocation.stepId !== request.stepId ||
      invocation.operationId !== request.operationId || invocation.toolId !== request.toolId ||
      invocation.toolIdentityVersion !== request.toolIdentityVersion ||
      invocation.schemaDigest !== request.schemaDigest || invocation.argumentsDigest !== request.argumentsDigest ||
      invocation.authorizationGrantId.length !== 0) {
      this.failReadyStep(record, step.stepId, AgentErrorClass.CONFIGURATION, 'INVALID_TOOL_PREPARATION');
      return this.command(false, 'INVALID_TOOL_PREPARATION', record);
    }
    const idempotencyKey: string | undefined = invocation.idempotencyKey;
    if (step.idempotencyMode !== IdempotencyMode.NONE &&
      (idempotencyKey === undefined || idempotencyKey.trim().length === 0)) {
      this.failReadyStep(record, step.stepId, AgentErrorClass.CONFIGURATION, 'IDEMPOTENCY_KEY_REQUIRED');
      return this.command(false, 'IDEMPOTENCY_KEY_REQUIRED', record);
    }
    if (!this.contains(record.registeredProviderIds, request.providerId)) {
      this.ledger.registerProvider(record.envelope.taskId, request.providerId, record.envelope.executionBudget);
      record.registeredProviderIds.push(request.providerId);
    }
    if (!this.policy.registerRequest(request)) {
      this.failReadyStep(record, step.stepId, AgentErrorClass.CONFIGURATION, 'POLICY_REQUEST_REJECTED');
      return this.command(false, 'POLICY_REQUEST_REJECTED', record);
    }
    record.pendingPolicyRequest = copyPolicy(request);
    record.pendingInvocation = ContractCodec.parseToolInvocation(ContractCodec.stringify(invocation));
    record.pendingStepId = step.stepId;
    record.pendingOperationId = request.operationId;
    this.transition(record, AgentTaskStatus.WAITING_AUTHORIZATION,
      AgentRuntimeEventType.AUTHORIZATION_REQUIRED, '{"policyRequestId":' + quoted(request.requestId) + '}');
    return this.command(true, 'AUTHORIZATION_REQUIRED', record);
  }

  private dispatch(record: RuntimeTaskRecord, step: WorkflowStep,
    invocation: ToolInvocation | undefined, policyRequest?: PolicyRequest,
    grant?: AuthorizationGrant): CoordinatorCommandResult {
    const dispatchId: string = this.ids.nextId('dispatch', record.envelope.requestId + ':' + step.stepId);
    const request: StepDispatchRequest = new StepDispatchRequest();
    request.task = ContractCodec.parseTaskEnvelope(ContractCodec.stringify(record.envelope));
    request.workflowId = record.workflow === undefined ? '' : record.workflow.workflowId;
    request.workflowVersion = record.workflow === undefined ? '' : record.workflow.workflowVersion;
    request.step = copyStep(step);
    request.dispatchId = dispatchId;
    request.toolInvocation = invocation;
    if (invocation !== undefined && policyRequest !== undefined && grant !== undefined) {
      request.persistenceContext = this.dispatchPersistenceContext(
        dispatchId, step, invocation, policyRequest, grant);
    }
    const scheduler: WorkflowScheduler = this.requireScheduler(record);
    scheduler.markRunning(step.stepId, this.clock.nowMs());
    record.pendingDispatchId = dispatchId;
    record.pendingStepId = step.stepId;
    if (invocation !== undefined) {
      record.pendingOperationId = invocation.operationId;
      record.activeInvocation = ContractCodec.parseToolInvocation(ContractCodec.stringify(invocation));
    } else {
      record.pendingOperationId = 'operation:' + record.envelope.taskId + ':' + step.stepId;
    }
    this.bump(record, AgentRuntimeEventType.TASK_STATE_CHANGED,
      '{"status":"dispatchPrepared","stepId":' + quoted(step.stepId) +
        ',"dispatchId":' + quoted(dispatchId) + '}');
    const receipt: StepDispatchReceipt = this.dispatcher.dispatch(request);
    if (!receipt.accepted) {
      record.pendingDispatchId = '';
      record.pendingStepId = '';
      record.pendingOperationId = '';
      record.activeInvocation = undefined;
      const result: StepExecutionResult = new StepExecutionResult();
      result.status = StepExecutionStatus.FAILED;
      result.errorClass = AgentErrorClass.PROVIDER;
      result.errorCode = receipt.rejectionCode;
      scheduler.completeStep(step.stepId, result, this.clock.nowMs());
      const recovery: RecoveryDecision =
        new DeterministicRecoveryPolicy(record.envelope.executionBudget.maxRetries)
          .decide(step, scheduler.getStepRecord(step.stepId), result);
      scheduler.applyRecoveryDecision(step.stepId, recovery, this.clock.nowMs());
      this.syncSchedulerState(record);
      return this.command(false, receipt.rejectionCode, record);
    }
    this.bump(record, AgentRuntimeEventType.TASK_STATE_CHANGED,
      '{"status":"dispatched","stepId":' + quoted(step.stepId) + ',"dispatchId":' + quoted(dispatchId) + '}');
    return this.command(true, 'DISPATCHED', record);
  }

  private dispatchPersistenceContext(dispatchId: string, step: WorkflowStep, invocation: ToolInvocation,
    policyRequest: PolicyRequest, grant: AuthorizationGrant): DispatchPersistenceContext {
    const context: DispatchPersistenceContext = new DispatchPersistenceContext();
    context.operationId = invocation.operationId;
    context.dispatchId = dispatchId;
    context.invocationId = invocation.invocationId;
    context.attemptId = invocation.attemptId;
    context.taskId = invocation.taskId;
    context.stepId = invocation.stepId;
    context.toolId = invocation.toolId;
    context.toolIdentityVersion = invocation.toolIdentityVersion;
    context.schemaDigest = invocation.schemaDigest;
    context.argumentsDigest = invocation.argumentsDigest;
    const idempotencyKey: string | undefined = invocation.idempotencyKey;
    context.idempotencyKey = idempotencyKey === undefined ? 'attempt:' + invocation.attemptId : idempotencyKey;
    context.idempotencyMode = step.idempotencyMode;
    context.sideEffect = step.sideEffect;
    context.policyRequestId = policyRequest.requestId;
    context.budgetReservationId = grant.budgetReservationId;
    context.providerId = policyRequest.providerId;
    context.requestedToolCalls = 1;
    context.requestedCostMicros = policyRequest.estimatedCostMicros;
    context.createdAt = invocation.createdAt;
    return context;
  }

  private failReadyStep(record: RuntimeTaskRecord, stepId: string, errorClass: AgentErrorClass,
    errorCode: string): void {
    const scheduler: WorkflowScheduler = this.requireScheduler(record);
    const step: WorkflowStep = this.requireStep(record, stepId);
    scheduler.markRunning(stepId, this.clock.nowMs());
    const result: StepExecutionResult = new StepExecutionResult();
    result.status = StepExecutionStatus.FAILED;
    result.errorClass = errorClass;
    result.errorCode = errorCode;
    scheduler.completeStep(stepId, result, this.clock.nowMs());
    const decision: RecoveryDecision =
      new DeterministicRecoveryPolicy(record.envelope.executionBudget.maxRetries)
        .decide(step, scheduler.getStepRecord(stepId), result);
    scheduler.applyRecoveryDecision(stepId, decision, this.clock.nowMs());
    record.pendingInvocation = undefined;
    record.pendingPolicyRequest = undefined;
    // A denied ready step was never dispatched. Its authorization bindings must not
    // survive into a terminal checkpoint (nor be reused by a later scheduler step).
    record.pendingStepId = '';
    record.pendingOperationId = '';
    this.syncSchedulerState(record);
  }

  private consumePlannerCall(record: RuntimeTaskRecord, replan: boolean): boolean {
    if (replan && record.usage.replans >= record.envelope.executionBudget.maxReplans) {
      return false;
    }
    if (record.usage.plannerCalls >= 2 + record.envelope.executionBudget.maxReplans) {
      return false;
    }
    if (record.envelope.executionBudget.maxAgentActivations <= 0) {
      return false;
    }
    record.usage.plannerCalls++;
    if (replan) {
      record.usage.replans++;
    }
    return true;
  }

  private syncSchedulerState(record: RuntimeTaskRecord): void {
    const scheduler: WorkflowScheduler = this.requireScheduler(record);
    const state: WorkflowRunState = scheduler.getRunState();
    if (state === WorkflowRunState.COMPLETED) {
      this.transition(record, AgentTaskStatus.COMPLETED, AgentRuntimeEventType.TASK_COMPLETED,
        record.snapshot.resultJson.length === 0 ? '{"status":"success"}' : record.snapshot.resultJson);
    } else if (state === WorkflowRunState.FAILED) {
      this.transition(record, AgentTaskStatus.FAILED, AgentRuntimeEventType.TASK_FAILED,
        '{"reason":' + quoted(scheduler.getTerminalReason()) + '}');
    } else if (state === WorkflowRunState.CANCELLED) {
      this.transition(record, AgentTaskStatus.CANCELLED, AgentRuntimeEventType.TASK_CANCELLED,
        '{"reason":' + quoted(scheduler.getTerminalReason()) + '}');
    } else if (state === WorkflowRunState.WAITING_RECONCILIATION) {
      this.transition(record, AgentTaskStatus.WAITING_RECONCILIATION,
        AgentRuntimeEventType.RECONCILIATION_REQUIRED, '{"stepId":' + quoted(record.pendingStepId) +
          ',"operationId":' + quoted(record.pendingOperationId) + '}');
    } else if (!record.paused && record.snapshot.status !== AgentTaskStatus.RUNNING) {
      this.transition(record, AgentTaskStatus.RUNNING, AgentRuntimeEventType.TASK_STATE_CHANGED,
        '{"status":"running"}');
    }
  }

  private transition(record: RuntimeTaskRecord, status: AgentTaskStatus,
    eventType: AgentRuntimeEventType, payloadJson: string): void {
    record.snapshot.status = status;
    record.snapshot.snapshotVersion++;
    record.snapshot.resultJson = payloadJson;
    record.snapshot.updatedAt = new Date(this.clock.nowMs()).toISOString();
    this.emit(record, eventType, payloadJson);
  }

  private bump(record: RuntimeTaskRecord, eventType: AgentRuntimeEventType, payloadJson: string): void {
    record.snapshot.snapshotVersion++;
    record.snapshot.updatedAt = new Date(this.clock.nowMs()).toISOString();
    this.emit(record, eventType, payloadJson);
  }

  private emit(record: RuntimeTaskRecord, eventType: AgentRuntimeEventType, payloadJson: string): void {
    const event: AgentRuntimeEvent = new AgentRuntimeEvent();
    event.sequence = record.events.length + 1;
    event.eventId = record.envelope.taskId + ':event:' + event.sequence.toString();
    event.taskId = record.envelope.taskId;
    event.snapshotVersion = record.snapshot.snapshotVersion;
    event.eventType = eventType;
    event.timestamp = record.snapshot.updatedAt;
    event.payloadJson = payloadJson;
    record.events.push(event);
    record.snapshot.lastEventSequence = event.sequence;
    this.stateObserver.onStateChanged(copySnapshot(record.snapshot), copyEvent(event));
  }

  private acceptance(record: RuntimeTaskRecord, duplicate: boolean): OrchestrationAcceptance {
    const result: OrchestrationAcceptance = new OrchestrationAcceptance();
    result.duplicate = duplicate;
    result.handle = ContractCodec.parseTaskHandle(ContractCodec.stringify(record.handle));
    result.handle.snapshotVersion = record.snapshot.snapshotVersion;
    result.snapshot = copySnapshot(record.snapshot);
    return result;
  }

  private command(accepted: boolean, code: string, record: RuntimeTaskRecord): CoordinatorCommandResult {
    const result: CoordinatorCommandResult = new CoordinatorCommandResult();
    result.accepted = accepted;
    result.code = code;
    result.snapshotVersion = record.snapshot.snapshotVersion;
    return result;
  }

  private reconstruction(accepted: boolean, code: string, snapshotVersion: number): CoordinatorCommandResult {
    const result: CoordinatorCommandResult = new CoordinatorCommandResult();
    result.accepted = accepted;
    result.code = code;
    result.snapshotVersion = snapshotVersion;
    return result;
  }

  private requireTask(taskId: string): RuntimeTaskRecord {
    const index: number = this.findTask(taskId);
    if (index < 0) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.TASK_NOT_FOUND, 'unknown taskId');
    }
    return this.tasks[index];
  }

  private findTask(taskId: string): number {
    for (let i: number = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].envelope.taskId === taskId) {
        return i;
      }
    }
    return -1;
  }

  private requireScheduler(record: RuntimeTaskRecord): WorkflowScheduler {
    const scheduler: WorkflowScheduler | undefined = record.scheduler;
    if (scheduler === undefined) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'workflow is not planned');
    }
    return scheduler;
  }

  private requireStep(record: RuntimeTaskRecord, stepId: string): WorkflowStep {
    const graph: WorkflowGraph | undefined = record.workflow;
    if (graph !== undefined) {
      for (let i: number = 0; i < graph.steps.length; i++) {
        if (graph.steps[i].stepId === stepId) {
          return graph.steps[i];
        }
      }
    }
    throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'unknown workflow step');
  }

  private contains(values: string[], value: string): boolean {
    for (let i: number = 0; i < values.length; i++) {
      if (values[i] === value) {
        return true;
      }
    }
    return false;
  }

  private isTerminal(status: AgentTaskStatus): boolean {
    return status === AgentTaskStatus.COMPLETED || status === AgentTaskStatus.FAILED ||
      status === AgentTaskStatus.CANCELLED;
  }

  private replaceableStepIds(snapshot: WorkflowRuntimeSnapshot): string[] {
    const values: string[] = [];
    for (let i: number = 0; i < snapshot.steps.length; i++) {
      const state: WorkflowStepState = snapshot.steps[i].state;
      if (state !== WorkflowStepState.SUCCEEDED && state !== WorkflowStepState.UNKNOWN_OUTCOME &&
        state !== WorkflowStepState.RUNNING && state !== WorkflowStepState.VERIFYING) {
        values.push(snapshot.steps[i].stepId);
      }
    }
    return values;
  }

  private copyPlanningRequest(value: PlanningRequest): PlanningRequest {
    const result: PlanningRequest = new PlanningRequest();
    result.envelope = ContractCodec.parseTaskEnvelope(ContractCodec.stringify(value.envelope));
    result.frame = copyFrame(value.frame);
    result.collaborationMode = value.collaborationMode;
    if (value.collaborationPlan !== undefined) {
      result.collaborationPlan = this.copyCollaborationPlan(value.collaborationPlan);
    }
    if (value.previousWorkflow !== undefined) {
      result.previousWorkflow = ContractCodec.parseWorkflowGraph(ContractCodec.stringify(value.previousWorkflow));
    }
    result.affectedStepIds = value.affectedStepIds.slice();
    return result;
  }

  private copyCollaborationPlan(source: CollaborationPlan): CollaborationPlan {
    const value: CollaborationPlan = new CollaborationPlan();
    value.planVersion = source.planVersion;
    value.taskId = source.taskId;
    value.mode = source.mode;
    value.roleRegistryDigest = source.roleRegistryDigest;
    value.decisionDigest = source.decisionDigest;
    for (let i: number = 0; i < source.assignments.length; i++) {
      const assignment: CollaborationRoleAssignment = new CollaborationRoleAssignment();
      assignment.roleId = source.assignments[i].roleId;
      assignment.roleVersion = source.assignments[i].roleVersion;
      assignment.roleRegistryDigest = source.assignments[i].roleRegistryDigest;
      value.assignments.push(assignment);
    }
    return value;
  }
}

function copyCollaborationPreparationState(value: CollaborationPreparationState): CollaborationPreparationState {
  const copy = new CollaborationPreparationState();
  copy.version = value.version;
  copy.evaluations = value.evaluations;
  copy.pending = value.pending;
  copy.baselineOnly = value.baselineOnly;
  return copy;
}
