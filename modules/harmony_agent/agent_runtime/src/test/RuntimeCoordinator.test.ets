import { FakeCollaborationPreparation } from './FakeCollaborationPreparation';
import { describe, expect, it } from '@ohos/hypium';
import {
  AgentErrorClass,
  AgentTaskStatus,
  AuthorizationDecision,
  AuthorizationDecisionType,
  AuthorizationGrant,
  ClarificationRequest,
  ClarificationResponse,
  CollaborationMode,
  ExecutionBudget,
  IdempotencyMode,
  PolicyRequest,
  ReconciliationReport,
  ReconciliationStatus,
  RiskLevel,
  SideEffect,
  TaskFrame,
  TaskSubmission,
  ToolInvocation,
  WorkflowGraph,
  WorkflowStep,
  WorkflowStepKind
} from '@harmony_agent/agent-contracts';
import {
  BudgetReservationSnapshot,
  BudgetReservationState,
  BudgetScopeKind,
  BudgetScopeSnapshot,
  OperationJournalState,
  StepExecutionResult,
  StepExecutionStatus,
  WorkflowRuntimeSnapshot,
  WorkflowScheduler,
  WorkflowStepState
} from '@harmony_agent/agent-core';
import {
  CollaborationPlan,
  CollaborationRoleAssignment,
  OrchestrationAcceptance,
  PlanningRequest,
  PlanningResult,
  PlanningStatus,
  PreparedToolDispatch,
  RuntimeTaskRecoveryCheckpoint,
  StepCompletion,
  StepDispatchReceipt,
  StepDispatchRequest
} from '../main/ets/orchestration/OrchestrationTypes';
import {
  CollaborationPlanSelectorPort,
  CollaborationSelectorPort,
  NoopRuntimeStateObserver,
  RuntimeClockPort,
  RuntimeIdGeneratorPort,
  SemanticPlannerPort,
  StepDispatchPort,
  ToolInvocationPreparerPort
} from '../main/ets/orchestration/RuntimePorts';
import {
  RuntimeCoordinator,
  RuntimeCoordinatorConfig
} from '../main/ets/orchestration/RuntimeCoordinator';
import { WorkflowReplanController } from '../main/ets/orchestration/WorkflowReplanController';
import { RuntimeCheckpointValidator } from '../main/ets/orchestration/RuntimeCheckpointValidator';
import {
  RuntimeRecoveryAuthority,
  RuntimeRecoveryOperationAuthority,
  RuntimeRecoveryPolicyAuthority
} from '../main/ets/orchestration/RecoveryAuthorityTypes';
import { RuntimeRecoveryAuthorityValidator } from
  '../main/ets/orchestration/RuntimeRecoveryAuthorityValidator';

enum FixturePlanKind {
  BASIC = 'basic',
  TOOL = 'tool',
  CLARIFY = 'clarify',
  SIDE_EFFECT = 'sideEffect'
}

class FixtureClock implements RuntimeClockPort {
  value: number = 1000;

  nowMs(): number {
    return this.value;
  }
}

class FixtureIds implements RuntimeIdGeneratorPort {
  private counter: number = 0;

  nextId(kind: string, requestId: string): string {
    this.counter++;
    return kind + ':' + requestId + ':' + this.counter.toString();
  }
}

class FixtureCollaboration implements CollaborationSelectorPort {
  mode: CollaborationMode = CollaborationMode.SINGLE;

  select(): CollaborationMode {
    return this.mode;
  }
}

function digest(character: string): string {
  return 'sha256:' + character.repeat(64);
}

class FixtureCollaborationPlan implements CollaborationPlanSelectorPort {
  mode: CollaborationMode = CollaborationMode.MULTI;
  duplicateRole: boolean = false;
  invalidDigest: boolean = false;
  lastPlan?: CollaborationPlan;

  selectPlan(frame: TaskFrame, maxAgentActivations: number): CollaborationPlan {
    const value: CollaborationPlan = new CollaborationPlan();
    value.taskId = frame.taskId;
    value.mode = this.mode;
    value.roleRegistryDigest = this.invalidDigest ? 'sha256:invalid' : digest('a');
    value.decisionDigest = digest('b');
    value.assignments.push(this.assignment('planner', digest('c')));
    if (this.mode === CollaborationMode.MULTI && maxAgentActivations >= 2) {
      value.assignments.push(this.assignment(this.duplicateRole ? 'planner' : 'verifier', digest('d')));
    }
    this.lastPlan = value;
    return value;
  }

  private assignment(roleId: string, roleDigest: string): CollaborationRoleAssignment {
    const value: CollaborationRoleAssignment = new CollaborationRoleAssignment();
    value.roleId = roleId;
    value.roleVersion = '1';
    value.roleRegistryDigest = roleDigest;
    return value;
  }
}

class FixturePlanner implements SemanticPlannerPort {
  kind: FixturePlanKind = FixturePlanKind.BASIC;
  calls: number = 0;
  lastRequest?: PlanningRequest;
  rejectReplan: boolean = false;

  async plan(request: PlanningRequest): Promise<PlanningResult> {
    this.calls++;
    this.lastRequest = request;
    if (this.kind === FixturePlanKind.CLARIFY) {
      const result: PlanningResult = new PlanningResult();
      result.status = PlanningStatus.CLARIFICATION_REQUIRED;
      const clarification: ClarificationRequest = new ClarificationRequest();
      clarification.clarificationId = 'clarification:' + request.envelope.taskId;
      clarification.taskId = request.envelope.taskId;
      clarification.questionCode = 'MISSING_TARGET';
      clarification.prompt = 'target?';
      clarification.responseSchemaJson = '{"type":"object"}';
      clarification.requestedAt = '1970-01-01T00:00:01.000Z';
      clarification.expiresAt = '1970-01-01T00:01:01.000Z';
      clarification.expiresAtMs = 61000;
      result.clarification = clarification;
      return result;
    }
    return readyGraph(request, this.kind);
  }

  async resume(request: PlanningRequest, response: ClarificationResponse): Promise<PlanningResult> {
    this.calls++;
    return readyGraph(request, FixturePlanKind.BASIC);
  }

  async replan(request: PlanningRequest): Promise<PlanningResult> {
    this.calls++;
    if (this.rejectReplan) throw new Error('fixture replan failure');
    const result: PlanningResult = readyGraph(request, this.kind);
    if (result.workflow !== undefined) {
      result.workflow.workflowVersion = '2';
    }
    return result;
  }

  interrupt(taskId: string): boolean {
    return false;
  }
}

class FixtureToolPreparer implements ToolInvocationPreparerPort {
  omitIdempotencyKey: boolean = false;

  prepare(request: PlanningRequest, step: WorkflowStep, nowMs: number): PreparedToolDispatch {
    const prepared: PreparedToolDispatch = new PreparedToolDispatch();
    const policy: PolicyRequest = prepared.policyRequest;
    policy.requestId = 'policy:' + request.envelope.taskId + ':' + step.stepId;
    policy.userId = request.envelope.userId;
    policy.taskId = request.envelope.taskId;
    policy.stepId = step.stepId;
    policy.operationId = 'operation:' + request.envelope.taskId + ':' + step.stepId;
    policy.toolId = 'calendar.create';
    policy.toolIdentityVersion = 'tool-v1';
    policy.providerId = 'provider-v1';
    policy.schemaDigest = 'sha256:schema';
    policy.argumentsDigest = 'sha256:arguments';
    policy.riskLevel = step.riskLevel;
    policy.sideEffect = step.sideEffect;
    policy.estimatedCostMicros = 1;
    policy.requestedAt = new Date(nowMs).toISOString();
    policy.expiresAtMs = nowMs + 60000;
    policy.expiresAt = new Date(policy.expiresAtMs).toISOString();
    const invocation: ToolInvocation = prepared.invocation;
    invocation.invocationId = 'invocation:' + request.envelope.taskId;
    invocation.taskId = request.envelope.taskId;
    invocation.stepId = step.stepId;
    invocation.operationId = policy.operationId;
    invocation.attemptId = 'attempt-1';
    invocation.toolId = policy.toolId;
    invocation.toolIdentityVersion = policy.toolIdentityVersion;
    invocation.schemaDigest = policy.schemaDigest;
    invocation.argumentsJson = '{"title":"review"}';
    invocation.argumentsDigest = policy.argumentsDigest;
    if (!this.omitIdempotencyKey) {
      invocation.idempotencyKey = 'idempotency:' + invocation.operationId;
    }
    invocation.authorizationGrantId = '';
    invocation.timeoutMs = step.timeoutMs;
    invocation.createdAt = new Date(nowMs).toISOString();
    return prepared;
  }
}

class FixtureDispatcher implements StepDispatchPort {
  requests: StepDispatchRequest[] = [];
  accept: boolean = true;

  dispatch(request: StepDispatchRequest): StepDispatchReceipt {
    this.requests.push(request);
    const result: StepDispatchReceipt = new StepDispatchReceipt();
    result.accepted = this.accept;
    result.rejectionCode = this.accept ? '' : 'FIXTURE_REJECTED';
    return result;
  }

  cancel(_dispatchId: string): boolean {
    return false;
  }
}

function budget(): ExecutionBudget {
  const value: ExecutionBudget = new ExecutionBudget();
  value.maxWallTimeMs = 100000;
  value.maxInputTokens = 10000;
  value.maxOutputTokens = 10000;
  value.maxMonetaryCostMicros = 10000;
  value.maxToolCalls = 10;
  value.maxAgentActivations = 4;
  value.maxRetries = 1;
  value.maxReplans = 1;
  return value;
}

function submission(requestId: string): TaskSubmission {
  const value: TaskSubmission = new TaskSubmission();
  value.requestId = requestId;
  value.userId = 'user-1';
  value.userIntent = 'prepare review';
  value.locale = 'zh-CN';
  value.timeZone = 'Asia/Shanghai';
  value.referenceTime = '2026-09-29T06:00:00.000Z';
  value.requestedBudget = budget();
  value.submittedAt = '2026-09-29T06:00:00.000Z';
  return value;
}

function step(id: string, kind: WorkflowStepKind = WorkflowStepKind.LLM): WorkflowStep {
  const value: WorkflowStep = new WorkflowStep();
  value.stepId = id;
  value.kind = kind;
  value.goal = 'execute ' + id;
  value.expectedOutputSchemaJson = '{"type":"object"}';
  value.retryPolicyRef = 'retry-v1';
  value.verificationPolicyRef = 'verify-v1';
  value.timeoutMs = 10000;
  if (kind === WorkflowStepKind.TOOL) {
    value.capabilityRequirements = ['calendar.write'];
    value.sideEffect = SideEffect.REVERSIBLE;
    value.riskLevel = RiskLevel.MEDIUM;
    value.idempotencyMode = IdempotencyMode.PROVIDER_KEY;
  }
  return value;
}

function graph(request: PlanningRequest, kind: FixturePlanKind): WorkflowGraph {
  const value: WorkflowGraph = new WorkflowGraph();
  value.workflowId = 'workflow:' + request.envelope.taskId;
  value.taskId = request.envelope.taskId;
  value.workflowVersion = '1';
  value.createdAt = '2026-09-29T06:00:00.000Z';
  const first: WorkflowStep = kind === FixturePlanKind.TOOL ? step('step-1', WorkflowStepKind.TOOL) : step('step-1');
  if (kind === FixturePlanKind.SIDE_EFFECT) {
    first.sideEffect = SideEffect.REVERSIBLE;
    first.idempotencyMode = IdempotencyMode.PROVIDER_KEY;
  }
  value.steps = [first];
  value.entryStepIds = ['step-1'];
  return value;
}

function readyGraph(request: PlanningRequest, kind: FixturePlanKind): PlanningResult {
  const result: PlanningResult = new PlanningResult();
  result.status = PlanningStatus.READY;
  result.workflow = graph(request, kind);
  return result;
}

class FixtureRuntime {
  clock: FixtureClock = new FixtureClock();
  planner: FixturePlanner = new FixturePlanner();
  collaboration: FixtureCollaboration = new FixtureCollaboration();
  dispatcher: FixtureDispatcher = new FixtureDispatcher();
  toolPreparer: FixtureToolPreparer = new FixtureToolPreparer();
  collaborationPlan?: FixtureCollaborationPlan;
  coordinator: RuntimeCoordinator;

  constructor(kind: FixturePlanKind = FixturePlanKind.BASIC, withCollaborationPlan: boolean = false, preparation?: FakeCollaborationPreparation) {
    this.planner.kind = kind;
    const config: RuntimeCoordinatorConfig = new RuntimeCoordinatorConfig();
    config.policyVersion = 'policy-v1';
    config.grantTtlMs = 30000;
    if (withCollaborationPlan) this.collaborationPlan = new FixtureCollaborationPlan();
    this.coordinator = new RuntimeCoordinator(config, this.clock, new FixtureIds(), this.planner,
      this.collaboration, this.toolPreparer, this.dispatcher, new NoopRuntimeStateObserver(),
      preparation === undefined ? this.collaborationPlan : preparation, preparation);
  }
}

function success(taskId: string, dispatch: StepDispatchRequest): StepCompletion {
  const value: StepCompletion = new StepCompletion();
  value.taskId = taskId;
  value.stepId = dispatch.step.stepId;
  value.dispatchId = dispatch.dispatchId;
  value.result.status = StepExecutionStatus.SUCCEEDED;
  value.result.outputJson = '{"ok":true}';
  value.result.outputDigest = 'sha256:output';
  return value;
}

function budgetScope(kind: BudgetScopeKind, taskId: string, scopeId: string,
  source: ExecutionBudget): BudgetScopeSnapshot {
  const value: BudgetScopeSnapshot = new BudgetScopeSnapshot();
  value.kind = kind;
  value.taskId = taskId;
  value.scopeId = scopeId;
  value.limit = JSON.parse(JSON.stringify(source)) as ExecutionBudget;
  return value;
}

function recoveryAuthority(checkpoint: RuntimeTaskRecoveryCheckpoint): RuntimeRecoveryAuthority {
  const value: RuntimeRecoveryAuthority = new RuntimeRecoveryAuthority();
  value.taskId = checkpoint.snapshot.taskId;
  value.checkpointSnapshotVersion = checkpoint.snapshot.snapshotVersion;
  value.storageRevision = 7;
  value.policyVersion = 'policy-v1';
  value.budgetScopes.push(budgetScope(BudgetScopeKind.TASK, value.taskId, value.taskId,
    checkpoint.envelope.executionBudget));
  if (checkpoint.workflow !== undefined) {
    for (let i: number = 0; i < checkpoint.workflow.steps.length; i++) {
      value.budgetScopes.push(budgetScope(BudgetScopeKind.STEP, value.taskId,
        checkpoint.workflow.steps[i].stepId, checkpoint.envelope.executionBudget));
    }
  }
  for (let i: number = 0; i < checkpoint.registeredProviderIds.length; i++) {
    value.budgetScopes.push(budgetScope(BudgetScopeKind.PROVIDER, value.taskId,
      checkpoint.registeredProviderIds[i], checkpoint.envelope.executionBudget));
  }
  return value;
}

function pendingAuthority(checkpoint: RuntimeTaskRecoveryCheckpoint): RuntimeRecoveryAuthority {
  const value: RuntimeRecoveryAuthority = recoveryAuthority(checkpoint);
  const policy: RuntimeRecoveryPolicyAuthority = new RuntimeRecoveryPolicyAuthority();
  policy.version = 1;
  policy.request = JSON.parse(JSON.stringify(checkpoint.pendingPolicyRequest)) as PolicyRequest;
  value.policy = policy;
  return value;
}

function activeAuthority(checkpoint: RuntimeTaskRecoveryCheckpoint, request: PolicyRequest,
  decision: AuthorizationDecision): RuntimeRecoveryAuthority {
  const value: RuntimeRecoveryAuthority = recoveryAuthority(checkpoint);
  const active: ToolInvocation = checkpoint.activeInvocation as ToolInvocation;
  const grant: AuthorizationGrant = new AuthorizationGrant();
  grant.grantId = active.authorizationGrantId;
  grant.policyRequestId = request.requestId;
  grant.decisionCommandId = decision.commandId;
  grant.userId = request.userId;
  grant.taskId = request.taskId;
  grant.stepId = request.stepId;
  grant.operationId = request.operationId;
  grant.toolId = request.toolId;
  grant.toolIdentityVersion = request.toolIdentityVersion;
  grant.schemaDigest = request.schemaDigest;
  grant.argumentsDigest = request.argumentsDigest;
  grant.budgetReservationId = 'policy:' + request.requestId;
  grant.policyVersion = 'policy-v1';
  grant.issuedAtMs = decision.decidedAtMs;
  grant.expiresAtMs = Math.min(request.expiresAtMs, decision.decidedAtMs + 30000);
  grant.issuedAt = new Date(grant.issuedAtMs).toISOString();
  grant.expiresAt = new Date(grant.expiresAtMs).toISOString();
  const policy: RuntimeRecoveryPolicyAuthority = new RuntimeRecoveryPolicyAuthority();
  policy.version = 3;
  policy.request = JSON.parse(JSON.stringify(request)) as PolicyRequest;
  policy.decision = JSON.parse(JSON.stringify(decision)) as AuthorizationDecision;
  policy.grant = grant;
  value.policy = policy;

  const reservation: BudgetReservationSnapshot = new BudgetReservationSnapshot();
  reservation.reservationId = grant.budgetReservationId;
  reservation.taskId = request.taskId;
  reservation.stepId = request.stepId;
  reservation.providerId = request.providerId;
  reservation.requested.toolCalls = 1;
  reservation.requested.monetaryCostMicros = request.estimatedCostMicros;
  reservation.state = BudgetReservationState.RESERVED;
  value.budgetReservations.push(reservation);
  for (let i: number = 0; i < value.budgetScopes.length; i++) {
    value.budgetScopes[i].reserved.toolCalls = 1;
    value.budgetScopes[i].reserved.monetaryCostMicros = request.estimatedCostMicros;
  }

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
  operation.idempotencyKey = active.idempotencyKey as string;
  operation.idempotencyMode = IdempotencyMode.PROVIDER_KEY;
  operation.sideEffect = request.sideEffect;
  operation.policyRequestId = request.requestId;
  operation.budgetReservationId = reservation.reservationId;
  operation.state = OperationJournalState.PREPARED;
  value.operation = operation;
  return value;
}

export default function runtimeCoordinatorTest(): void {
  describe('RuntimeCoordinator', () => {
    it('T53LegacySingleRestoresAsBaselineOnly', 0, async () => {
      const fixture = new FixtureRuntime();
      const accepted = await fixture.coordinator.acceptTask(submission('t53-legacy'));
      const checkpoint = fixture.coordinator.getRecoveryCheckpoint(accepted.handle.taskId);
      checkpoint.checkpointVersion = '1.1';
      const restored = new FixtureRuntime(FixturePlanKind.BASIC, false, new FakeCollaborationPreparation());
      expect(restored.coordinator.restoreCheckpoint(checkpoint).accepted).assertTrue();
      const migrated = restored.coordinator.getRecoveryCheckpoint(accepted.handle.taskId);
      expect(migrated.checkpointVersion).assertEqual('1.2');
      expect(migrated.collaborationPreparation.baselineOnly).assertTrue();
      expect(migrated.collaborationPreparation.evaluations).assertEqual(2);
    });
    it('T53ReevaluationAndActivationCountersSurviveCheckpoint', 0, async () => {
      const preparation = new FakeCollaborationPreparation();
      const fixture = new FixtureRuntime(FixturePlanKind.BASIC, false, preparation);
      const request = submission('t53-replan'); request.requestedBudget.maxAgentActivations = 6;
      request.requestedBudget.maxReplans = 3;
      const accepted: OrchestrationAcceptance = await fixture.coordinator.acceptTask(request);
      const taskId: string = accepted.handle.taskId;
      fixture.planner.rejectReplan = true;
      fixture.coordinator.advance(taskId);
      const completion = success(taskId, fixture.dispatcher.requests[0]);
      completion.result.outputJson = 'not-json';
      expect(fixture.coordinator.completeStep(completion).code).assertEqual('REPLAN_REQUIRED');
      await fixture.coordinator.requestReplan(taskId, ['step-1']);
      expect(preparation.calls).assertEqual(2);
      expect(fixture.coordinator.getUsage(taskId).agentActivations).assertEqual(4);
      const checkpoint = fixture.coordinator.getRecoveryCheckpoint(taskId);
      expect(checkpoint.collaborationPreparation.evaluations).assertEqual(2);
      expect(RuntimeCheckpointValidator.validate(checkpoint).valid).assertTrue();
      const restoredPreparation = new FakeCollaborationPreparation();
      const restored = new FixtureRuntime(FixturePlanKind.BASIC, false, restoredPreparation);
      expect(restored.coordinator.restoreCheckpoint(checkpoint).accepted).assertTrue();
      expect(restored.coordinator.getRecoveryCheckpoint(taskId).collaborationPreparation.evaluations).assertEqual(2);
      expect(restored.coordinator.getUsage(taskId).agentActivations).assertEqual(4);
      expect(restored.coordinator.hydrateRecoveryAuthority(taskId, recoveryAuthority(checkpoint)).accepted).assertTrue();
      await restored.coordinator.requestReplan(taskId, ['step-1']);
      expect(restoredPreparation.calls).assertEqual(0);
      expect(restored.coordinator.getUsage(taskId).agentActivations).assertEqual(5);
      await fixture.coordinator.requestReplan(taskId, ['step-1']);
      expect(preparation.calls).assertEqual(2);
      expect(fixture.coordinator.getUsage(taskId).agentActivations).assertEqual(5);
    });
    it('T53RejectsUnsafeLegacyMultiAndPendingRecovery', 0, async () => {
      const preparation = new FakeCollaborationPreparation();
      const fixture = new FixtureRuntime(FixturePlanKind.BASIC, false, preparation);
      const accepted = await fixture.coordinator.acceptTask(submission('t53-recovery'));
      const checkpoint = fixture.coordinator.getRecoveryCheckpoint(accepted.handle.taskId);
      checkpoint.checkpointVersion = '1.1';
      expect(RuntimeCheckpointValidator.validate(checkpoint).valid).assertFalse();
      checkpoint.checkpointVersion = '1.2'; checkpoint.collaborationPreparation.pending = true;
      const restored = new FixtureRuntime();
      expect(restored.coordinator.restoreCheckpoint(checkpoint).code).assertEqual('PREPARATION_REQUIRES_RECONCILIATION');
    });
    it('T53WrongTaskInterruptionDoesNotCancelPreparation', 0, async () => {
      const preparation = new FakeCollaborationPreparation(); preparation.pending = true;
      const fixture = new FixtureRuntime(FixturePlanKind.BASIC, false, preparation);
      const submitted = fixture.coordinator.acceptTask(submission('t53-wrong-task'));
      await preparation.entered;
      expect(fixture.coordinator.interruptPreparation('wrong')).assertFalse();
      expect(preparation.cancelled).assertFalse();
      expect(fixture.coordinator.interruptPreparation(preparation.taskId)).assertTrue();
      await submitted;
      expect(fixture.planner.calls).assertEqual(0);
    });
    it('normalizesAndDeduplicatesSubmission', 0, async () => {
      const fixture: FixtureRuntime = new FixtureRuntime();
      const first = await fixture.coordinator.acceptTask(submission('request-1'));
      const second = await fixture.coordinator.acceptTask(submission('request-1'));
      expect(first.handle.taskId).assertEqual(second.handle.taskId);
      expect(second.duplicate).assertTrue();
      expect(first.snapshot.status).assertEqual(AgentTaskStatus.RUNNING);
      expect(fixture.planner.lastRequest?.envelope.referenceTime)
        .assertEqual('2026-09-29T06:00:00.000Z');
      let conflict: boolean = false;
      const changed: TaskSubmission = submission('request-1');
      changed.userIntent = 'different';
      try {
        await fixture.coordinator.acceptTask(changed);
      } catch (error) {
        conflict = true;
      }
      expect(conflict).assertTrue();
    });

    it('persistsValidFailureWhenMultiSelectionExceedsActivationBudget', 0, async () => {
      const fixture: FixtureRuntime = new FixtureRuntime();
      fixture.collaboration.mode = CollaborationMode.MULTI;
      const request: TaskSubmission = submission('request-multi-budget');
      request.requestedBudget.maxAgentActivations = 1;

      const accepted = await fixture.coordinator.acceptTask(request);
      const checkpoint: RuntimeTaskRecoveryCheckpoint =
        fixture.coordinator.getRecoveryCheckpoint(accepted.handle.taskId);

      expect(fixture.coordinator.getSnapshot(accepted.handle.taskId).status)
        .assertEqual(AgentTaskStatus.FAILED);
      expect(fixture.coordinator.getSnapshot(accepted.handle.taskId).resultJson)
        .assertEqual('{"reason":"agentActivationBudgetExhausted"}');
      expect(fixture.planner.calls).assertEqual(0);
      expect(checkpoint.collaborationMode).assertEqual(CollaborationMode.MULTI);
      expect(checkpoint.planningRequest.collaborationMode).assertEqual(CollaborationMode.MULTI);
      expect(RuntimeCheckpointValidator.validate(checkpoint).valid).assertTrue();
    });

    it('rejectsModeOnlyMultiBeforePlannerAndPersistsValidFailure', 0, async () => {
      const fixture: FixtureRuntime = new FixtureRuntime();
      fixture.collaboration.mode = CollaborationMode.MULTI;

      const accepted = await fixture.coordinator.acceptTask(submission('request-multi-without-plan'));
      const checkpoint: RuntimeTaskRecoveryCheckpoint =
        fixture.coordinator.getRecoveryCheckpoint(accepted.handle.taskId);

      expect(fixture.planner.calls).assertEqual(0);
      expect(checkpoint.snapshot.status).assertEqual(AgentTaskStatus.FAILED);
      expect(checkpoint.snapshot.resultJson).assertEqual('{"reason":"collaborationPlanRequired"}');
      expect(RuntimeCheckpointValidator.validate(checkpoint).valid).assertTrue();
    });

    it('bindsAndCopiesValidMultiRolePlanIntoPlannerCheckpoint', 0, async () => {
      const fixture: FixtureRuntime = new FixtureRuntime(FixturePlanKind.BASIC, true);

      const accepted = await fixture.coordinator.acceptTask(submission('request-multi-plan'));
      const checkpoint: RuntimeTaskRecoveryCheckpoint =
        fixture.coordinator.getRecoveryCheckpoint(accepted.handle.taskId);

      expect(fixture.planner.calls).assertEqual(1);
      expect(fixture.planner.lastRequest?.collaborationMode).assertEqual(CollaborationMode.MULTI);
      expect(fixture.planner.lastRequest?.collaborationPlan?.assignments.length).assertEqual(2);
      expect(checkpoint.usage.agentActivations).assertEqual(2);
      expect(checkpoint.planningRequest.collaborationPlan?.assignments[1].roleId).assertEqual('verifier');
      expect(RuntimeCheckpointValidator.validate(checkpoint).valid).assertTrue();
      const selected: CollaborationPlan | undefined = fixture.collaborationPlan?.lastPlan;
      if (selected !== undefined) selected.assignments[1].roleId = 'mutated';
      expect(checkpoint.planningRequest.collaborationPlan?.assignments[1].roleId).assertEqual('verifier');
      const restored: FixtureRuntime = new FixtureRuntime(FixturePlanKind.BASIC, true);
      expect(restored.coordinator.restoreCheckpoint(checkpoint).accepted).assertTrue();
      const restoredCheckpoint: RuntimeTaskRecoveryCheckpoint =
        restored.coordinator.getRecoveryCheckpoint(accepted.handle.taskId);
      expect(restoredCheckpoint.planningRequest.collaborationPlan?.decisionDigest).assertEqual(digest('b'));
      if (checkpoint.planningRequest.collaborationPlan !== undefined) {
        checkpoint.planningRequest.collaborationPlan.assignments[1].roleId = 'planner';
      }
      expect(RuntimeCheckpointValidator.validate(checkpoint).valid).assertFalse();
    });

    it('rejectsInvalidRolePlanBeforePlanner', 0, async () => {
      const fixture: FixtureRuntime = new FixtureRuntime(FixturePlanKind.BASIC, true);
      const selector: FixtureCollaborationPlan = fixture.collaborationPlan as FixtureCollaborationPlan;
      selector.duplicateRole = true;

      const accepted = await fixture.coordinator.acceptTask(submission('request-invalid-plan'));

      expect(fixture.planner.calls).assertEqual(0);
      expect(accepted.snapshot.status).assertEqual(AgentTaskStatus.FAILED);
      expect(accepted.snapshot.resultJson).assertEqual('{"reason":"collaborationPlanInvalid"}');
    });

    it('dispatchesOnlyValidatedWorkflowStepsAndCompletes', 0, async () => {
      const fixture: FixtureRuntime = new FixtureRuntime();
      const accepted = await fixture.coordinator.acceptTask(submission('request-2'));
      expect(fixture.coordinator.advance(accepted.handle.taskId).accepted).assertTrue();
      expect(fixture.dispatcher.requests.length).assertEqual(1);
      const applied = fixture.coordinator.completeStep(success(accepted.handle.taskId,
        fixture.dispatcher.requests[0]));
      expect(applied.accepted).assertTrue();
      expect(fixture.coordinator.getSnapshot(accepted.handle.taskId).status)
        .assertEqual(AgentTaskStatus.COMPLETED);
    });

    it('keepsClarificationSeparateFromDispatchAndAuthorization', 0, async () => {
      const fixture: FixtureRuntime = new FixtureRuntime(FixturePlanKind.CLARIFY);
      const accepted = await fixture.coordinator.acceptTask(submission('request-3'));
      expect(accepted.snapshot.status).assertEqual(AgentTaskStatus.WAITING_INPUT);
      expect(fixture.dispatcher.requests.length).assertEqual(0);
      expect(fixture.coordinator.getPendingPolicyRequest(accepted.handle.taskId) === undefined).assertTrue();
      const pending: ClarificationRequest | undefined =
        fixture.coordinator.getPendingClarification(accepted.handle.taskId);
      const response: ClarificationResponse = new ClarificationResponse();
      response.commandId = 'clarification-command';
      response.clarificationId = pending?.clarificationId as string;
      response.taskId = accepted.handle.taskId;
      response.answerJson = '{"target":"team"}';
      response.respondedAt = '1970-01-01T00:00:01.000Z';
      response.respondedAtMs = 1000;
      expect((await fixture.coordinator.provideClarification(response)).accepted).assertTrue();
      expect(fixture.coordinator.getSnapshot(accepted.handle.taskId).status)
        .assertEqual(AgentTaskStatus.RUNNING);
      expect(fixture.coordinator.getUsage(accepted.handle.taskId).plannerCalls).assertEqual(2);
    });

    it('requiresPolicyGrantBeforeToolDispatch', 0, async () => {
      const fixture: FixtureRuntime = new FixtureRuntime(FixturePlanKind.TOOL);
      const accepted = await fixture.coordinator.acceptTask(submission('request-4'));
      expect(fixture.coordinator.advance(accepted.handle.taskId).code).assertEqual('AUTHORIZATION_REQUIRED');
      expect(fixture.dispatcher.requests.length).assertEqual(0);
      const pending: PolicyRequest | undefined = fixture.coordinator.getPendingPolicyRequest(accepted.handle.taskId);
      const awaiting: RuntimeTaskRecoveryCheckpoint =
        fixture.coordinator.getRecoveryCheckpoint(accepted.handle.taskId);
      expect(awaiting.checkpointVersion).assertEqual('1.2');
      expect(awaiting.envelope.taskId).assertEqual(accepted.handle.taskId);
      expect(awaiting.pendingPolicyRequest?.requestId).assertEqual(pending?.requestId);
      expect(awaiting.scheduler?.steps[0].state).assertEqual(WorkflowStepState.READY);
      expect(awaiting.events.length).assertEqual(awaiting.snapshot.lastEventSequence);
      expect(RuntimeCheckpointValidator.validate(awaiting).valid).assertTrue();
      const restoredAuthorization: FixtureRuntime = new FixtureRuntime(FixturePlanKind.TOOL);
      expect(restoredAuthorization.coordinator.restoreCheckpoint(awaiting).code)
        .assertEqual('RESTORED_AUTHORITY_REQUIRED');
      expect((await restoredAuthorization.coordinator.acceptTask(submission('request-4'))).duplicate).assertTrue();
      expect(restoredAuthorization.dispatcher.requests.length).assertEqual(0);
      const legacy: RuntimeTaskRecoveryCheckpoint = JSON.parse(JSON.stringify(awaiting)) as
        RuntimeTaskRecoveryCheckpoint;
      legacy.checkpointVersion = '1.0';
      expect(RuntimeCheckpointValidator.validate(legacy).valid).assertFalse();
      awaiting.envelope.userIntent = 'mutated';
      awaiting.registeredProviderIds.push('mutated-provider');
      awaiting.snapshot.taskId = 'forged-task';
      expect(RuntimeCheckpointValidator.validate(awaiting).valid).assertFalse();
      const unreadable: RuntimeTaskRecoveryCheckpoint = JSON.parse('{}') as
        RuntimeTaskRecoveryCheckpoint;
      expect(RuntimeCheckpointValidator.validate(unreadable).valid).assertFalse();
      expect(fixture.coordinator.getRecoveryCheckpoint(accepted.handle.taskId).envelope.userIntent)
        .assertEqual('prepare review');
      expect(fixture.coordinator.getRecoveryCheckpoint(accepted.handle.taskId).registeredProviderIds.length)
        .assertEqual(1);
      const decision: AuthorizationDecision = new AuthorizationDecision();
      decision.commandId = 'authorization-command';
      decision.policyRequestId = pending?.requestId as string;
      decision.userId = 'user-1';
      decision.taskId = accepted.handle.taskId;
      decision.decision = AuthorizationDecisionType.APPROVED;
      decision.decidedAt = '1970-01-01T00:00:01.000Z';
      decision.decidedAtMs = 1000;
      expect(fixture.coordinator.provideAuthorization(decision).accepted).assertTrue();
      expect(restoredAuthorization.coordinator.provideAuthorization(decision).code)
        .assertEqual('RECOVERY_AUTHORITY_REQUIRED');
      expect(fixture.dispatcher.requests.length).assertEqual(1);
      expect((fixture.dispatcher.requests[0].toolInvocation?.authorizationGrantId as string).length > 0)
        .assertTrue();
      expect(fixture.dispatcher.requests[0].persistenceContext?.budgetReservationId)
        .assertEqual('policy:' + (pending?.requestId as string));
      expect(fixture.dispatcher.requests[0].persistenceContext?.providerId).assertEqual('provider-v1');
      expect(fixture.dispatcher.requests[0].persistenceContext?.dispatchId)
        .assertEqual(fixture.dispatcher.requests[0].dispatchId);
      expect(fixture.dispatcher.requests[0].persistenceContext?.idempotencyKey)
        .assertEqual('idempotency:operation:' + accepted.handle.taskId + ':step-1');
      const dispatchedCheckpoint: RuntimeTaskRecoveryCheckpoint =
        fixture.coordinator.getRecoveryCheckpoint(accepted.handle.taskId);
      expect(dispatchedCheckpoint.pendingDispatchId).assertEqual(fixture.dispatcher.requests[0].dispatchId);
      expect(dispatchedCheckpoint.activeInvocation?.invocationId)
        .assertEqual(fixture.dispatcher.requests[0].toolInvocation?.invocationId);
      expect(dispatchedCheckpoint.scheduler?.steps[0].state).assertEqual(WorkflowStepState.RUNNING);
      expect(RuntimeCheckpointValidator.validate(dispatchedCheckpoint).valid).assertTrue();

      const conflictSource: FixtureRuntime = new FixtureRuntime(FixturePlanKind.TOOL);
      const conflictAccepted = await conflictSource.coordinator.acceptTask(submission('request-policy-conflict'));
      conflictSource.coordinator.advance(conflictAccepted.handle.taskId);
      const cleanConflictCheckpoint: RuntimeTaskRecoveryCheckpoint =
        conflictSource.coordinator.getRecoveryCheckpoint(conflictAccepted.handle.taskId);
      const conflictCheckpoint: RuntimeTaskRecoveryCheckpoint =
        JSON.parse(JSON.stringify(cleanConflictCheckpoint)) as RuntimeTaskRecoveryCheckpoint;
      (conflictCheckpoint.pendingPolicyRequest as PolicyRequest).requestId = pending?.requestId as string;
      expect(RuntimeCheckpointValidator.validate(conflictCheckpoint).valid).assertTrue();
      expect(restoredAuthorization.coordinator.restoreCheckpoint(conflictCheckpoint).code)
        .assertEqual('POLICY_REQUEST_RESTORE_CONFLICT');
      expect(restoredAuthorization.coordinator.restoreCheckpoint(cleanConflictCheckpoint).accepted).assertTrue();

      const missingKey: FixtureRuntime = new FixtureRuntime(FixturePlanKind.TOOL);
      missingKey.toolPreparer.omitIdempotencyKey = true;
      const rejected = await missingKey.coordinator.acceptTask(submission('request-4-missing-key'));
      expect(missingKey.coordinator.advance(rejected.handle.taskId).code)
        .assertEqual('IDEMPOTENCY_KEY_REQUIRED');
      expect(missingKey.dispatcher.requests.length).assertEqual(0);
    });

    it('reconstructsInFlightTasksWithoutReplayingAdapters', 0, async () => {
      const original: FixtureRuntime = new FixtureRuntime();
      const accepted = await original.coordinator.acceptTask(submission('request-restore-read'));
      original.coordinator.advance(accepted.handle.taskId);
      const before: RuntimeTaskRecoveryCheckpoint =
        original.coordinator.getRecoveryCheckpoint(accepted.handle.taskId);
      const restored: FixtureRuntime = new FixtureRuntime();
      expect(restored.coordinator.restoreCheckpoint(before).code)
        .assertEqual('RESTORED_AUTHORITY_REQUIRED');
      const after: RuntimeTaskRecoveryCheckpoint =
        restored.coordinator.getRecoveryCheckpoint(accepted.handle.taskId);
      expect(after.snapshot.snapshotVersion).assertEqual(before.snapshot.snapshotVersion + 1);
      expect(after.pendingDispatchId).assertEqual('');
      expect(after.pendingStepId).assertEqual('');
      expect(after.pendingOperationId).assertEqual('');
      expect(after.scheduler?.steps[0].state).assertEqual(WorkflowStepState.READY);
      expect(RuntimeCheckpointValidator.validate(after).valid).assertTrue();
      expect(restored.coordinator.advance(accepted.handle.taskId).code)
        .assertEqual('RECOVERY_AUTHORITY_REQUIRED');
      expect(restored.dispatcher.requests.length).assertEqual(0);
      expect(restored.coordinator.completeStep(success(accepted.handle.taskId,
        original.dispatcher.requests[0])).code).assertEqual('RECOVERY_AUTHORITY_REQUIRED');

      const originalWrite: FixtureRuntime = new FixtureRuntime(FixturePlanKind.SIDE_EFFECT);
      const writeAccepted = await originalWrite.coordinator.acceptTask(submission('request-restore-write'));
      originalWrite.coordinator.advance(writeAccepted.handle.taskId);
      const writeBefore: RuntimeTaskRecoveryCheckpoint =
        originalWrite.coordinator.getRecoveryCheckpoint(writeAccepted.handle.taskId);
      const restoredWrite: FixtureRuntime = new FixtureRuntime(FixturePlanKind.SIDE_EFFECT);
      expect(restoredWrite.coordinator.restoreCheckpoint(writeBefore).accepted).assertTrue();
      const writeAfter: RuntimeTaskRecoveryCheckpoint =
        restoredWrite.coordinator.getRecoveryCheckpoint(writeAccepted.handle.taskId);
      expect(writeAfter.snapshot.status).assertEqual(AgentTaskStatus.WAITING_RECONCILIATION);
      expect(writeAfter.pendingDispatchId).assertEqual('');
      expect(writeAfter.pendingStepId).assertEqual('step-1');
      expect(writeAfter.pendingOperationId)
        .assertEqual('operation:' + writeAccepted.handle.taskId + ':step-1');
      expect(writeAfter.scheduler?.steps[0].state).assertEqual(WorkflowStepState.UNKNOWN_OUTCOME);
      expect(RuntimeCheckpointValidator.validate(writeAfter).valid).assertTrue();
      expect(restoredWrite.coordinator.cancel(writeAccepted.handle.taskId).code)
        .assertEqual('RECOVERY_AUTHORITY_REQUIRED');
      expect(restoredWrite.dispatcher.requests.length).assertEqual(0);
    });

    it('hydratesBoundDurableAuthorityBeforeUnlockingRecovery', 0, async () => {
      const waitingSource: FixtureRuntime = new FixtureRuntime(FixturePlanKind.TOOL);
      const waitingAccepted = await waitingSource.coordinator.acceptTask(submission('request-hydrate-waiting'));
      waitingSource.coordinator.advance(waitingAccepted.handle.taskId);
      const waitingCheckpoint: RuntimeTaskRecoveryCheckpoint =
        waitingSource.coordinator.getRecoveryCheckpoint(waitingAccepted.handle.taskId);
      const restoredWaiting: FixtureRuntime = new FixtureRuntime(FixturePlanKind.TOOL);
      restoredWaiting.coordinator.restoreCheckpoint(waitingCheckpoint);
      const corrupt: RuntimeRecoveryAuthority = pendingAuthority(waitingCheckpoint);
      corrupt.checkpointSnapshotVersion++;
      expect(restoredWaiting.coordinator.hydrateRecoveryAuthority(waitingAccepted.handle.taskId, corrupt).code)
        .assertEqual('AUTHORITY_BINDING_INVALID');
      const waitingAuthority: RuntimeRecoveryAuthority = pendingAuthority(waitingCheckpoint);
      expect(RuntimeRecoveryAuthorityValidator.validate(waitingCheckpoint, waitingAuthority).valid).assertTrue();
      expect(restoredWaiting.coordinator.hydrateRecoveryAuthority(waitingAccepted.handle.taskId,
        waitingAuthority).code).assertEqual('RECOVERY_AUTHORITY_HYDRATED');
      const waitingPolicy: PolicyRequest = waitingCheckpoint.pendingPolicyRequest as PolicyRequest;
      const waitingDecision: AuthorizationDecision = new AuthorizationDecision();
      waitingDecision.commandId = 'hydrate-waiting-command';
      waitingDecision.policyRequestId = waitingPolicy.requestId;
      waitingDecision.userId = waitingPolicy.userId;
      waitingDecision.taskId = waitingPolicy.taskId;
      waitingDecision.decision = AuthorizationDecisionType.APPROVED;
      waitingDecision.decidedAt = '1970-01-01T00:00:01.000Z';
      waitingDecision.decidedAtMs = 1000;
      expect(restoredWaiting.coordinator.provideAuthorization(waitingDecision).accepted).assertTrue();
      expect(restoredWaiting.dispatcher.requests.length).assertEqual(1);

      const activeCheckpoint: RuntimeTaskRecoveryCheckpoint =
        restoredWaiting.coordinator.getRecoveryCheckpoint(waitingAccepted.handle.taskId);
      const restoredActive: FixtureRuntime = new FixtureRuntime(FixturePlanKind.TOOL);
      restoredActive.coordinator.restoreCheckpoint(activeCheckpoint);
      const mismatched: RuntimeRecoveryAuthority = activeAuthority(activeCheckpoint, waitingPolicy, waitingDecision);
      (mismatched.operation as RuntimeRecoveryOperationAuthority).policyRequestId = 'policy:wrong';
      expect(restoredActive.coordinator.hydrateRecoveryAuthority(waitingAccepted.handle.taskId, mismatched).code)
        .assertEqual('OPERATION_AUTHORITY_INVALID');
      const durable: RuntimeRecoveryAuthority = activeAuthority(activeCheckpoint, waitingPolicy, waitingDecision);
      expect(RuntimeRecoveryAuthorityValidator.validate(activeCheckpoint, durable).valid).assertTrue();
      expect(restoredActive.coordinator.hydrateRecoveryAuthority(waitingAccepted.handle.taskId, durable).accepted)
        .assertTrue();
      const report: ReconciliationReport = new ReconciliationReport();
      report.commandId = 'hydrate-reconcile-command';
      report.taskId = waitingAccepted.handle.taskId;
      report.stepId = 'step-1';
      report.operationId = waitingPolicy.operationId;
      report.status = ReconciliationStatus.CONFIRMED_SUCCEEDED;
      report.evidenceDigest = 'sha256:hydrated-evidence';
      report.reportedAt = '1970-01-01T00:00:02.000Z';
      expect(restoredActive.coordinator.provideReconciliation(report).accepted).assertTrue();
      expect(restoredActive.coordinator.getSnapshot(waitingAccepted.handle.taskId).status)
        .assertEqual(AgentTaskStatus.COMPLETED);
      expect(restoredActive.dispatcher.requests.length).assertEqual(0);
    });

    it('pauseStopsNewDispatchAndResumeRestartsIt', 0, async () => {
      const fixture: FixtureRuntime = new FixtureRuntime();
      const accepted = await fixture.coordinator.acceptTask(submission('request-5'));
      expect(fixture.coordinator.pause(accepted.handle.taskId).accepted).assertTrue();
      expect(fixture.coordinator.advance(accepted.handle.taskId).accepted).assertFalse();
      expect(fixture.dispatcher.requests.length).assertEqual(0);
      expect(fixture.coordinator.resume(accepted.handle.taskId).accepted).assertTrue();
      expect(fixture.coordinator.advance(accepted.handle.taskId).accepted).assertTrue();
    });

    it('waitsForReconciliationAfterUnknownSideEffect', 0, async () => {
      const fixture: FixtureRuntime = new FixtureRuntime(FixturePlanKind.SIDE_EFFECT);
      const accepted = await fixture.coordinator.acceptTask(submission('request-6'));
      fixture.coordinator.advance(accepted.handle.taskId);
      const completion: StepCompletion = new StepCompletion();
      completion.taskId = accepted.handle.taskId;
      completion.stepId = 'step-1';
      completion.dispatchId = fixture.dispatcher.requests[0].dispatchId;
      completion.result.status = StepExecutionStatus.UNKNOWN_OUTCOME;
      completion.result.errorClass = AgentErrorClass.TIMEOUT;
      fixture.coordinator.completeStep(completion);
      expect(fixture.coordinator.getSnapshot(accepted.handle.taskId).status)
        .assertEqual(AgentTaskStatus.WAITING_RECONCILIATION);
      const report: ReconciliationReport = new ReconciliationReport();
      report.commandId = 'reconcile-command';
      report.taskId = accepted.handle.taskId;
      report.stepId = 'step-1';
      report.operationId = 'operation:' + accepted.handle.taskId + ':step-1';
      report.status = ReconciliationStatus.CONFIRMED_SUCCEEDED;
      report.evidenceDigest = 'sha256:evidence';
      report.reportedAt = '1970-01-01T00:00:01.000Z';
      expect(fixture.coordinator.provideReconciliation(report).accepted).assertTrue();
      expect(fixture.coordinator.getSnapshot(accepted.handle.taskId).status)
        .assertEqual(AgentTaskStatus.COMPLETED);
    });

    it('defersCancellationUntilInFlightSideEffectIsReconciled', 0, async () => {
      const fixture: FixtureRuntime = new FixtureRuntime(FixturePlanKind.SIDE_EFFECT);
      const accepted = await fixture.coordinator.acceptTask(submission('request-cancel'));
      fixture.coordinator.advance(accepted.handle.taskId);
      expect(fixture.coordinator.cancel(accepted.handle.taskId).code).assertEqual('CANCELLATION_DEFERRED');
      expect(fixture.coordinator.getSnapshot(accepted.handle.taskId).status)
        .assertEqual(AgentTaskStatus.WAITING_RECONCILIATION);
      expect(fixture.coordinator.completeStep(success(accepted.handle.taskId,
        fixture.dispatcher.requests[0])).code).assertEqual('STALE_OR_UNKNOWN_DISPATCH');
      const report: ReconciliationReport = new ReconciliationReport();
      report.commandId = 'cancel-reconcile-command';
      report.taskId = accepted.handle.taskId;
      report.stepId = 'step-1';
      report.operationId = 'operation:' + accepted.handle.taskId + ':step-1';
      report.status = ReconciliationStatus.CONFIRMED_SUCCEEDED;
      report.evidenceDigest = 'sha256:cancel-evidence';
      report.reportedAt = '1970-01-01T00:00:01.000Z';
      expect(fixture.coordinator.provideReconciliation(report).accepted).assertTrue();
      expect(fixture.coordinator.getSnapshot(accepted.handle.taskId).status)
        .assertEqual(AgentTaskStatus.CANCELLED);
    });

    it('ignoresLateCompletionAndKeepsVersionsMonotonic', 0, async () => {
      const fixture: FixtureRuntime = new FixtureRuntime();
      const accepted = await fixture.coordinator.acceptTask(submission('request-7'));
      fixture.coordinator.advance(accepted.handle.taskId);
      const completion: StepCompletion = success(accepted.handle.taskId, fixture.dispatcher.requests[0]);
      expect(fixture.coordinator.completeStep(completion).accepted).assertTrue();
      const version: number = fixture.coordinator.getSnapshot(accepted.handle.taskId).snapshotVersion;
      expect(fixture.coordinator.completeStep(completion).code).assertEqual('STALE_OR_UNKNOWN_DISPATCH');
      expect(fixture.coordinator.getSnapshot(accepted.handle.taskId).snapshotVersion).assertEqual(version);
      const events = fixture.coordinator.getEvents(accepted.handle.taskId);
      for (let i: number = 1; i < events.length; i++) {
        expect(events[i].sequence > events[i - 1].sequence).assertTrue();
        expect(events[i].snapshotVersion >= events[i - 1].snapshotVersion).assertTrue();
      }
    });

    it('partialReplanPreservesSucceededAndUnknownSteps', 0, () => {
      const request: PlanningRequest = new PlanningRequest();
      request.envelope.taskId = 'task-replan';
      const current: WorkflowGraph = graph(request, FixturePlanKind.BASIC);
      const second: WorkflowStep = step('step-2');
      second.dependencies = ['step-1'];
      current.steps.push(second);
      const scheduler: WorkflowScheduler = new WorkflowScheduler(current);
      scheduler.start(1000);
      scheduler.markRunning('step-1', 1000);
      scheduler.markVerifying('step-1', 1000);
      const done: StepExecutionResult = new StepExecutionResult();
      done.status = StepExecutionStatus.SUCCEEDED;
      done.outputDigest = 'sha256:first';
      scheduler.completeStep('step-1', done, 1000);
      const replacement: WorkflowGraph = graph(request, FixturePlanKind.BASIC);
      replacement.workflowVersion = '2';
      const changed: WorkflowStep = step('step-2');
      changed.goal = 'changed';
      changed.dependencies = ['step-1'];
      replacement.steps = [replacement.steps[0], changed];
      expect(WorkflowReplanController.replaceAffectedSubgraph(current, replacement, ['step-2'],
        scheduler.snapshot()).accepted).assertTrue();
      expect(WorkflowReplanController.replaceAffectedSubgraph(current, replacement, ['step-1'],
        scheduler.snapshot()).code).assertEqual('AFFECTED_STEP_IS_PROTECTED');
      const unknown: WorkflowRuntimeSnapshot = scheduler.snapshot();
      unknown.steps[1].state = WorkflowStepState.UNKNOWN_OUTCOME;
      expect(WorkflowReplanController.replaceAffectedSubgraph(current, replacement, ['step-2'], unknown).code)
        .assertEqual('AFFECTED_STEP_IS_PROTECTED');
    });

    it('closesInvalidOutputThroughBoundedRuntimeReplan', 0, async () => {
      const fixture: FixtureRuntime = new FixtureRuntime();
      const accepted = await fixture.coordinator.acceptTask(submission('request-replan-runtime'));
      fixture.coordinator.advance(accepted.handle.taskId);
      const completion: StepCompletion = new StepCompletion();
      completion.taskId = accepted.handle.taskId;
      completion.stepId = 'step-1';
      completion.dispatchId = fixture.dispatcher.requests[0].dispatchId;
      completion.result.status = StepExecutionStatus.SUCCEEDED;
      completion.result.outputJson = 'not-json';
      completion.result.outputDigest = 'sha256:invalid-output';
      expect(fixture.coordinator.completeStep(completion).code).assertEqual('REPLAN_REQUIRED');
      const failedCheckpoint: RuntimeTaskRecoveryCheckpoint =
        fixture.coordinator.getRecoveryCheckpoint(accepted.handle.taskId);
      const restoredFailed: FixtureRuntime = new FixtureRuntime();
      expect(restoredFailed.coordinator.restoreCheckpoint(failedCheckpoint).code)
        .assertEqual('RESTORED_AUTHORITY_REQUIRED');
      expect((await restoredFailed.coordinator.requestReplan(accepted.handle.taskId, ['step-1'])).code)
        .assertEqual('RECOVERY_AUTHORITY_REQUIRED');
      expect((await fixture.coordinator.requestReplan(accepted.handle.taskId, ['step-1'])).accepted).assertTrue();
      expect(fixture.coordinator.getSnapshot(accepted.handle.taskId).status)
        .assertEqual(AgentTaskStatus.RUNNING);
      expect(fixture.coordinator.getUsage(accepted.handle.taskId).replans).assertEqual(1);
      expect(fixture.coordinator.getUsage(accepted.handle.taskId).plannerCalls).assertEqual(2);

      const rejecting: FixtureRuntime = new FixtureRuntime();
      const rejectingAccepted = await rejecting.coordinator.acceptTask(
        submission('request-replan-reject'));
      rejecting.coordinator.advance(rejectingAccepted.handle.taskId);
      const rejectedCompletion: StepCompletion = new StepCompletion();
      rejectedCompletion.taskId = rejectingAccepted.handle.taskId;
      rejectedCompletion.stepId = 'step-1';
      rejectedCompletion.dispatchId = rejecting.dispatcher.requests[0].dispatchId;
      rejectedCompletion.result.status = StepExecutionStatus.SUCCEEDED;
      rejectedCompletion.result.outputJson = 'not-json';
      rejectedCompletion.result.outputDigest = 'sha256:invalid-output';
      rejecting.coordinator.completeStep(rejectedCompletion);
      rejecting.planner.rejectReplan = true;
      const rejectedReplan = await rejecting.coordinator.requestReplan(
        rejectingAccepted.handle.taskId, ['step-1']);
      expect(rejectedReplan.accepted).assertFalse();
      expect(rejectedReplan.code).assertEqual('PLANNER_INVOCATION_FAILED');
      expect(rejecting.coordinator.getSnapshot(rejectingAccepted.handle.taskId).resultJson)
        .assertEqual('{"reason":"plannerInvocationFailed"}');

    });
  });
}
