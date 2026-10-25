import { FakeCollaborationPreparation } from './FakeCollaborationPreparation';
import { describe, expect, it } from '@ohos/hypium';
import {
  AgentRuntimeEvent,
  AgentTaskSnapshot,
  AgentTaskStatus,
  AuthorizationDecision,
  AuthorizationDecisionType,
  ClarificationRequest,
  ClarificationResponse,
  CollaborationMode,
  CommandReceipt,
  ContractCodec,
  ExecutionBudget,
  IdempotencyMode,
  PolicyRequest,
  ReconciliationReport,
  ReconciliationStatus,
  RiskLevel,
  SideEffect,
  TaskControlAction,
  TaskControlCommand,
  TaskHandle,
  TaskSubmission,
  ToolInvocation,
  ToolOutcome,
  ToolOutcomeStatus,
  WorkflowGraph,
  WorkflowStep,
  WorkflowStepKind
} from '@harmony_agent/agent-contracts';
import {
  AgentRuntimeFacade,
  AgentRuntimeObserver,
  AgentSubscription,
  AgentRuntimeError,
  AgentRuntimeErrorCode,
  ShutdownMode,
  SubscriptionRequest,
  PlanningRequest,
  PlanningResult,
  PlanningStatus,
  DispatchPersistenceContext,
  PreparedToolDispatch,
  StepDispatchReceipt,
  StepDispatchRequest,
  CollaborationSelectorPort,
  RuntimeClockPort,
  RuntimeIdGeneratorPort,
  SemanticPlannerPort,
  StepDispatchPort,
  ToolInvocationPreparerPort,
  createProductionAgentRuntime,
  createRecoveredProductionAgentRuntime,
  ProductionAgentRuntimeConfig,
  ProductionAgentRuntimePorts,
  ProductionRuntimeAdapterFactoryPort,
  ProductionRuntimePersistencePort,
  ProductionRuntimeRecoverySourcePort,
  RuntimePersistenceCode,
  RuntimePersistenceResult,
  RuntimeDurableAuthorityPayload,
  RuntimeRecoveryAuthority,
  RuntimeRecoveryAuthorityValidator,
  RuntimeTaskRecoveryCheckpoint,
  RuntimeToolOutcomeSinkPort
} from '../../Index';

enum ProductionPlanKind {
  BASIC = 'basic',
  TOOL = 'tool',
  CLARIFY = 'clarify',
  SIDE_EFFECT = 'sideEffect'
}

class FixtureJournal {
  values: string[] = [];
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
  select(): CollaborationMode {
    return CollaborationMode.SINGLE;
  }
}

class FixturePlanner implements SemanticPlannerPort {
  calls: number = 0;
  kind: ProductionPlanKind = ProductionPlanKind.BASIC;
  gate?: FixtureAsyncGate;
  rejectPlan: boolean = false;
  rejectResume: boolean = false;
  interruptedTaskId: string = '';
  activeTaskId: string = '';

  async plan(request: PlanningRequest): Promise<PlanningResult> {
    this.calls++;
    this.activeTaskId = request.envelope.taskId;
    const currentGate: FixtureAsyncGate | undefined = this.gate;
    if (currentGate !== undefined) await currentGate.wait();
    if (this.rejectPlan) throw new Error('fixture provider secret must not escape');
    if (this.kind === ProductionPlanKind.CLARIFY) {
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
    return readyPlan(request, this.kind);
  }

  async resume(request: PlanningRequest, response: ClarificationResponse): Promise<PlanningResult> {
    if (this.rejectResume) throw new Error('fixture resume failure');
    return readyPlan(request, ProductionPlanKind.BASIC);
  }

  async replan(request: PlanningRequest): Promise<PlanningResult> {
    return readyPlan(request, this.kind);
  }

  interrupt(taskId: string): boolean {
    this.interruptedTaskId = taskId;
    const currentGate: FixtureAsyncGate | undefined = this.gate;
    if (currentGate === undefined) return false;
    currentGate.release();
    return true;
  }
}

class FixtureToolPreparer implements ToolInvocationPreparerPort {
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
    invocation.idempotencyKey = 'idempotency:' + invocation.operationId;
    invocation.authorizationGrantId = '';
    invocation.timeoutMs = step.timeoutMs;
    invocation.createdAt = new Date(nowMs).toISOString();
    return prepared;
  }
}

function persistenceResult(accepted: boolean, code: RuntimePersistenceCode): RuntimePersistenceResult {
  const result: RuntimePersistenceResult = new RuntimePersistenceResult();
  result.accepted = accepted;
  result.code = code;
  return result;
}

class FixtureAsyncGate {
  entered: boolean = false;
  private releaseGate?: () => void;
  private readonly gate: Promise<void>;

  constructor() {
    this.gate = new Promise<void>((resolve: () => void) => {
      this.releaseGate = resolve;
    });
  }

  async wait(): Promise<void> {
    this.entered = true;
    await this.gate;
  }

  release(): void {
    const callback: (() => void) | undefined = this.releaseGate;
    if (callback !== undefined) {
      this.releaseGate = undefined;
      callback();
    }
  }
}

class FixturePersistence implements ProductionRuntimePersistencePort, ProductionRuntimeRecoverySourcePort {
  readonly snapshots: AgentTaskSnapshot[] = [];
  readonly checkpoints: RuntimeTaskRecoveryCheckpoint[] = [];
  readonly authorities: RuntimeDurableAuthorityPayload[] = [];
  readonly journal: FixtureJournal;
  readonly preparedContexts: DispatchPersistenceContext[] = [];
  readonly preparedAuthorities: RuntimeDurableAuthorityPayload[] = [];
  readonly rejectedContexts: DispatchPersistenceContext[] = [];
  allowBeforeDispatch: boolean = true;
  allowRecoveryNormalization: boolean = true;
  throwBeforeDispatch: boolean = false;
  mutateContextBeforeDispatch: boolean = false;
  mutateAuthorityBeforeDispatch: boolean = false;
  beforeDispatchGate?: FixtureAsyncGate;
  overrideCheckpoint?: RuntimeTaskRecoveryCheckpoint;
  recoveryTaskIds: string[] = [];
  recoveryAuthorities: RuntimeRecoveryAuthority[] = [];
  recoveryNormalizations: number = 0;

  constructor(journal: FixtureJournal) {
    this.journal = journal;
  }

  private storeCheckpoint(checkpoint: RuntimeTaskRecoveryCheckpoint,
    expectedPreviousVersion: number, authority: RuntimeDurableAuthorityPayload): RuntimePersistenceResult {
    const snapshot: AgentTaskSnapshot = checkpoint.snapshot;
    let current: number = 0;
    for (let i: number = this.snapshots.length - 1; i >= 0; i--) {
      if (this.snapshots[i].taskId === snapshot.taskId) {
        current = this.snapshots[i].snapshotVersion;
        break;
      }
    }
    if (current !== expectedPreviousVersion || snapshot.snapshotVersion !== current + 1) {
      return persistenceResult(false, RuntimePersistenceCode.VERSION_CONFLICT);
    }
    this.snapshots.push(ContractCodec.parseAgentTaskSnapshot(ContractCodec.stringify(snapshot)));
    this.checkpoints.push(JSON.parse(ContractCodec.stringify(checkpoint)) as RuntimeTaskRecoveryCheckpoint);
    this.authorities.push(JSON.parse(ContractCodec.stringify(authority)) as RuntimeDurableAuthorityPayload);
    this.journal.values.push('save:' + snapshot.snapshotVersion.toString());
    return persistenceResult(true, RuntimePersistenceCode.SAVED);
  }

  async saveCheckpoint(checkpoint: RuntimeTaskRecoveryCheckpoint, expectedPreviousVersion: number,
    authority: RuntimeDurableAuthorityPayload, nowMs: number): Promise<RuntimePersistenceResult> {
    return this.storeCheckpoint(checkpoint, expectedPreviousVersion, authority);
  }

  async loadCheckpoint(taskId: string): Promise<RuntimeTaskRecoveryCheckpoint | undefined> {
    if (this.overrideCheckpoint !== undefined) {
      return JSON.parse(ContractCodec.stringify(this.overrideCheckpoint)) as RuntimeTaskRecoveryCheckpoint;
    }
    for (let i: number = this.checkpoints.length - 1; i >= 0; i--) {
      if (this.checkpoints[i].snapshot.taskId === taskId) {
        return JSON.parse(ContractCodec.stringify(this.checkpoints[i])) as RuntimeTaskRecoveryCheckpoint;
      }
    }
    return undefined;
  }

  async normalizeRecoveredOperation(checkpoint: RuntimeTaskRecoveryCheckpoint,
    expectedPreviousVersion: number, nowMs: number): Promise<RuntimePersistenceResult> {
    if (!this.allowRecoveryNormalization) {
      return persistenceResult(false, RuntimePersistenceCode.REJECTED);
    }
    const authority: RuntimeDurableAuthorityPayload = new RuntimeDurableAuthorityPayload();
    authority.taskId = checkpoint.snapshot.taskId;
    authority.checkpointSnapshotVersion = checkpoint.snapshot.snapshotVersion;
    authority.policyVersion = 'policy-v1';
    const stored: RuntimePersistenceResult = this.storeCheckpoint(
      checkpoint, expectedPreviousVersion, authority);
    if (stored.accepted) this.recoveryNormalizations++;
    return stored;
  }

  async listRecoveryTaskIds(): Promise<string[]> {
    return this.recoveryTaskIds.slice();
  }

  async loadRecoveryAuthority(taskId: string): Promise<RuntimeRecoveryAuthority | undefined> {
    for (let i: number = this.recoveryAuthorities.length - 1; i >= 0; i--) {
      if (this.recoveryAuthorities[i].taskId === taskId) {
        return JSON.parse(ContractCodec.stringify(this.recoveryAuthorities[i])) as RuntimeRecoveryAuthority;
      }
    }
    return undefined;
  }

  async beforeDispatch(checkpoint: RuntimeTaskRecoveryCheckpoint, expectedPreviousVersion: number,
    context: DispatchPersistenceContext | undefined,
    authority: RuntimeDurableAuthorityPayload,
    nowMs: number): Promise<RuntimePersistenceResult> {
    const gate: FixtureAsyncGate | undefined = this.beforeDispatchGate;
    if (gate !== undefined) await gate.wait();
    if (this.throwBeforeDispatch) throw new Error('fixture persistence unavailable');
    if (!this.allowBeforeDispatch) {
      this.journal.values.push('beforeDispatch');
      return persistenceResult(false, RuntimePersistenceCode.REJECTED);
    }
    const saved: RuntimePersistenceResult = this.storeCheckpoint(checkpoint, expectedPreviousVersion, authority);
    if (!saved.accepted) return saved;
    this.journal.values.push('beforeDispatch');
    if (context !== undefined) {
      this.preparedContexts.push(context);
      if (this.mutateContextBeforeDispatch) context.providerId = 'mutated-by-persistence';
    }
    this.preparedAuthorities.push(JSON.parse(ContractCodec.stringify(authority)) as
      RuntimeDurableAuthorityPayload);
    if (this.mutateAuthorityBeforeDispatch) {
      authority.taskId = 'mutated-by-persistence';
      if (authority.policy !== undefined) authority.policy.request.taskId = 'mutated-by-persistence';
    }
    return saved;
  }

  async recordDispatchRejected(context: DispatchPersistenceContext | undefined, dispatchId: string,
    rejectionCode: string,
    nowMs: number): Promise<RuntimePersistenceResult> {
    this.journal.values.push('dispatchRejected:' + rejectionCode);
    if (context !== undefined) this.rejectedContexts.push(context);
    return persistenceResult(true, RuntimePersistenceCode.SAVED);
  }

  async recordOutcome(taskId: string, stepId: string, dispatchId: string, outcome: ToolOutcome,
    nowMs: number): Promise<RuntimePersistenceResult> {
    this.journal.values.push('outcome:' + dispatchId);
    return persistenceResult(true, RuntimePersistenceCode.SAVED);
  }

  async recordReconciliation(report: ReconciliationReport,
    nowMs: number): Promise<RuntimePersistenceResult> {
    this.journal.values.push('reconciliation:' + report.operationId);
    return persistenceResult(true, RuntimePersistenceCode.SAVED);
  }
}

class FixtureAdapter implements StepDispatchPort {
  readonly requests: StepDispatchRequest[] = [];
  readonly cancelledDispatchIds: string[] = [];
  private readonly journal: FixtureJournal;
  sink?: RuntimeToolOutcomeSinkPort;
  completeSynchronously: boolean = false;
  accept: boolean = true;
  mutateRequestBeforeReturn: boolean = false;

  constructor(journal: FixtureJournal) {
    this.journal = journal;
  }

  dispatch(request: StepDispatchRequest): StepDispatchReceipt {
    this.requests.push(request);
    this.journal.values.push('adapterDispatch');
    if (this.mutateRequestBeforeReturn && request.persistenceContext !== undefined) {
      request.persistenceContext.providerId = 'mutated-by-adapter';
    }
    const receipt: StepDispatchReceipt = new StepDispatchReceipt();
    receipt.accepted = this.accept;
    receipt.rejectionCode = this.accept ? '' : 'FIXTURE_ADAPTER_REJECTED';
    if (this.accept && this.completeSynchronously && this.sink !== undefined) {
      this.sink.complete(request.task.taskId, request.step.stepId, request.dispatchId,
        successfulOutcome(request));
    }
    return receipt;
  }

  cancel(dispatchId: string): boolean {
    this.cancelledDispatchIds.push(dispatchId);
    return true;
  }
}

class FixtureAdapterFactory implements ProductionRuntimeAdapterFactoryPort {
  readonly adapter: FixtureAdapter;
  sink?: RuntimeToolOutcomeSinkPort;

  constructor(journal: FixtureJournal) {
    this.adapter = new FixtureAdapter(journal);
  }

  create(sink: RuntimeToolOutcomeSinkPort): StepDispatchPort {
    this.sink = sink;
    this.adapter.sink = sink;
    return this.adapter;
  }
}

class FixtureObserver implements AgentRuntimeObserver {
  events: AgentRuntimeEvent[] = [];
  policies: PolicyRequest[] = [];
  clarifications: ClarificationRequest[] = [];

  onEvent(event: AgentRuntimeEvent): void {
    this.events.push(event);
  }

  onPolicyRequest(request: PolicyRequest): void {
    this.policies.push(request);
  }

  onClarificationRequest(request: ClarificationRequest): void {
    this.clarifications.push(request);
  }
}

class ProductionFixture {
  readonly clock: FixtureClock = new FixtureClock();
  readonly planner: FixturePlanner = new FixturePlanner();
  readonly journal: FixtureJournal = new FixtureJournal();
  readonly persistence: FixturePersistence = new FixturePersistence(this.journal);
  readonly factory: FixtureAdapterFactory = new FixtureAdapterFactory(this.journal);
  readonly runtime: AgentRuntimeFacade;

  constructor(kind: ProductionPlanKind = ProductionPlanKind.BASIC, preparation?: FakeCollaborationPreparation) {
    this.planner.kind = kind;
    const config: ProductionAgentRuntimeConfig = new ProductionAgentRuntimeConfig();
    config.policyVersion = 'policy-v1';
    config.grantTtlMs = 30000;
    const ports: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
    ports.clock = this.clock;
    ports.ids = new FixtureIds();
    ports.planner = this.planner;
    ports.collaboration = new FixtureCollaboration();
    ports.collaborationPlan = preparation;
    ports.collaborationPreparation = preparation;
    ports.toolPreparer = new FixtureToolPreparer();
    ports.adapterFactory = this.factory;
    ports.persistence = this.persistence;
    this.runtime = createProductionAgentRuntime(config, ports);
  }
}

async function recoveredRuntime(source: ProductionFixture): Promise<AgentRuntimeFacade> {
  const config: ProductionAgentRuntimeConfig = new ProductionAgentRuntimeConfig();
  config.policyVersion = 'policy-v1';
  config.grantTtlMs = 30000;
  const ports: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
  ports.clock = source.clock;
  ports.ids = new FixtureIds();
  ports.planner = source.planner;
  ports.collaboration = new FixtureCollaboration();
  ports.toolPreparer = new FixtureToolPreparer();
  ports.adapterFactory = new FixtureAdapterFactory(source.journal);
  ports.persistence = source.persistence;
  ports.recovery = source.persistence;
  return await createRecoveredProductionAgentRuntime(config, ports);
}

function enableRecovery(source: ProductionFixture, taskId: string): void {
  source.persistence.recoveryTaskIds = [taskId];
  const durable: RuntimeRecoveryAuthority = JSON.parse(ContractCodec.stringify(
    source.persistence.authorities[source.persistence.authorities.length - 1])) as RuntimeRecoveryAuthority;
  durable.storageRevision = 1;
  source.persistence.recoveryAuthorities = [durable];
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
  value.referenceTime = '2026-10-07T15:00:00.000Z';
  value.requestedBudget = budget();
  value.submittedAt = '2026-10-07T15:00:00.000Z';
  return value;
}

function workflowStep(kind: ProductionPlanKind): WorkflowStep {
  const value: WorkflowStep = new WorkflowStep();
  value.stepId = 'step-1';
  value.kind = kind === ProductionPlanKind.TOOL ? WorkflowStepKind.TOOL : WorkflowStepKind.LLM;
  value.goal = 'execute step';
  value.expectedOutputSchemaJson = '{"type":"object"}';
  value.retryPolicyRef = 'retry-v1';
  value.verificationPolicyRef = 'verify-v1';
  value.timeoutMs = 10000;
  if (kind === ProductionPlanKind.TOOL) {
    value.capabilityRequirements = ['calendar.write'];
    value.sideEffect = SideEffect.REVERSIBLE;
    value.riskLevel = RiskLevel.MEDIUM;
    value.idempotencyMode = IdempotencyMode.PROVIDER_KEY;
  } else if (kind === ProductionPlanKind.SIDE_EFFECT) {
    value.sideEffect = SideEffect.REVERSIBLE;
    value.idempotencyMode = IdempotencyMode.PROVIDER_KEY;
  }
  return value;
}

function readyPlan(request: PlanningRequest, kind: ProductionPlanKind): PlanningResult {
  const graph: WorkflowGraph = new WorkflowGraph();
  graph.workflowId = 'workflow:' + request.envelope.taskId;
  graph.taskId = request.envelope.taskId;
  graph.workflowVersion = '1';
  graph.createdAt = '2026-10-07T15:00:00.000Z';
  graph.steps = [workflowStep(kind)];
  graph.entryStepIds = ['step-1'];
  const result: PlanningResult = new PlanningResult();
  result.status = PlanningStatus.READY;
  result.workflow = graph;
  return result;
}

function successfulOutcome(request: StepDispatchRequest): ToolOutcome {
  const value: ToolOutcome = new ToolOutcome();
  value.invocationId = request.toolInvocation === undefined ?
    'provider:' + request.dispatchId : request.toolInvocation.invocationId;
  value.status = ToolOutcomeStatus.SUCCEEDED;
  value.resultJson = '{"ok":true}';
  value.resultDigest = 'sha256:output';
  value.startedAt = '2026-10-07T15:00:00.000Z';
  value.finishedAt = '2026-10-07T15:00:00.001Z';
  return value;
}

function unknownOutcome(request: StepDispatchRequest): ToolOutcome {
  const value: ToolOutcome = successfulOutcome(request);
  value.status = ToolOutcomeStatus.UNKNOWN_OUTCOME;
  value.resultJson = undefined;
  value.resultDigest = undefined;
  return value;
}

function control(commandId: string, taskId: string, action: TaskControlAction): TaskControlCommand {
  const value: TaskControlCommand = new TaskControlCommand();
  value.commandId = commandId;
  value.taskId = taskId;
  value.action = action;
  value.reasonCode = 'caller-requested';
  value.requestedAt = '2026-10-07T15:00:00.000Z';
  return value;
}

async function subscribe(runtime: AgentRuntimeFacade, taskId: string,
  observer: AgentRuntimeObserver): Promise<AgentSubscription> {
  const request: SubscriptionRequest = new SubscriptionRequest();
  request.subscriptionId = 'subscription:' + taskId;
  request.taskId = taskId;
  return await runtime.subscribe(request, observer);
}

export default function productionAgentRuntimeTest(): void {
  describe('ProductionAgentRuntime', () => {
    it('T53QueuedConflictingCancelCannotInterruptPreparation', 0, async () => {
      const preparation = new FakeCollaborationPreparation(); preparation.pending = true;
      const fixture = new ProductionFixture(ProductionPlanKind.BASIC, preparation);
      const submitted = fixture.runtime.submitTask(submission('t53-conflict'));
      await preparation.entered;
      const pause = fixture.runtime.pauseTask(control('shared-id', preparation.taskId, TaskControlAction.PAUSE));
      const conflicting = fixture.runtime.cancelTask(control('shared-id', preparation.taskId, TaskControlAction.CANCEL));
      expect(preparation.cancelled).assertFalse();
      const valid = fixture.runtime.cancelTask(control('unique-id', preparation.taskId, TaskControlAction.CANCEL));
      await submitted; await pause;
      expect((await conflicting).rejectionCode).assertEqual('COMMAND_ID_CONFLICT');
      expect((await valid).accepted).assertTrue();
      expect(fixture.planner.calls).assertEqual(0);
    });
    it('T53CancelInterruptsPreparationWithoutInvokingPlannerOrAdapter', 0, async () => {
      const preparation = new FakeCollaborationPreparation(); preparation.pending = true;
      const fixture = new ProductionFixture(ProductionPlanKind.BASIC, preparation);
      const submitted = fixture.runtime.submitTask(submission('t53-cancel'));
      await preparation.entered;
      const cancelled = fixture.runtime.cancelTask(control('cancel-t53', preparation.taskId, TaskControlAction.CANCEL));
      const handle = await submitted;
      expect((await cancelled).accepted).assertTrue();
      expect(preparation.cancelled).assertTrue(); expect(fixture.planner.calls).assertEqual(0);
      expect((await fixture.runtime.getTaskSnapshot(handle.taskId)).status).assertEqual(AgentTaskStatus.CANCELLED);
      expect(fixture.persistence.preparedContexts.length).assertEqual(0);
      const pending = fixture.persistence.checkpoints.find((value: RuntimeTaskRecoveryCheckpoint) => value.collaborationPreparation.pending);
      expect(pending !== undefined).assertTrue();
    });
    it('T53ShutdownInterruptsPreparation', 0, async () => {
      const preparation = new FakeCollaborationPreparation(); preparation.pending = true;
      const fixture = new ProductionFixture(ProductionPlanKind.BASIC, preparation);
      const submitted = fixture.runtime.submitTask(submission('t53-shutdown'));
      await preparation.entered;
      const shutdown = fixture.runtime.shutdown(ShutdownMode.GRACEFUL);
      await submitted; await shutdown;
      expect(preparation.cancelled).assertTrue(); expect(fixture.planner.calls).assertEqual(0);
    });
    it('T53ReservesWholePlanBeforePlannerAndRejectsUnpairedComposition', 0, async () => {
      const preparation = new FakeCollaborationPreparation();
      const fixture = new ProductionFixture(ProductionPlanKind.BASIC, preparation);
      await fixture.runtime.submitTask(submission('t53-budget'));
      expect(fixture.planner.calls).assertEqual(1);
      const saved = fixture.persistence.checkpoints.find((value: RuntimeTaskRecoveryCheckpoint) =>
        value.usage.agentActivations === 2 && value.snapshot.status === AgentTaskStatus.RECEIVED);
      expect(saved !== undefined).assertTrue();
      const config = new ProductionAgentRuntimeConfig(); config.policyVersion = 'p'; config.grantTtlMs = 10;
      const ports = new ProductionAgentRuntimePorts(); ports.collaborationPreparation = preparation;
      let rejected: boolean = false;
      try { createProductionAgentRuntime(config, ports); } catch (error) { rejected = true; }
      expect(rejected).assertTrue();
    });
    it('persistsBeforeDispatchAndCompletesThroughBoundSink', 0, async () => {
      const fixture: ProductionFixture = new ProductionFixture();
      const handle = await fixture.runtime.submitTask(submission('production-basic'));
      expect(fixture.factory.adapter.requests.length).assertEqual(1);
      expect(fixture.journal.values.indexOf('beforeDispatch') <
        fixture.journal.values.indexOf('adapterDispatch')).assertTrue();
      const beforeDispatchIndex: number = fixture.journal.values.indexOf('beforeDispatch');
      expect(beforeDispatchIndex > 0).assertTrue();
      expect(fixture.journal.values[beforeDispatchIndex - 1].startsWith('save:')).assertTrue();
      const request: StepDispatchRequest = fixture.factory.adapter.requests[0];
      const sink: RuntimeToolOutcomeSinkPort = fixture.factory.sink as RuntimeToolOutcomeSinkPort;
      await sink.complete(handle.taskId, request.step.stepId, 'forged-dispatch', successfulOutcome(request));
      expect((await fixture.runtime.getTaskSnapshot(handle.taskId)).status)
        .assertEqual(AgentTaskStatus.RUNNING);
      await sink.complete(handle.taskId, request.step.stepId, request.dispatchId, successfulOutcome(request));
      expect((await fixture.runtime.getTaskSnapshot(handle.taskId)).status)
        .assertEqual(AgentTaskStatus.COMPLETED);
      const finalVersion: number = fixture.persistence.snapshots[fixture.persistence.snapshots.length - 1]
        .snapshotVersion;
      expect(finalVersion).assertEqual(fixture.persistence.snapshots.length);
      expect(fixture.persistence.checkpoints.length).assertEqual(fixture.persistence.snapshots.length);
      expect(fixture.persistence.checkpoints[fixture.persistence.checkpoints.length - 1].snapshot.status)
        .assertEqual(AgentTaskStatus.COMPLETED);
      const invalid: RuntimeTaskRecoveryCheckpoint = JSON.parse(ContractCodec.stringify(
        fixture.persistence.checkpoints[fixture.persistence.checkpoints.length - 1])) as
        RuntimeTaskRecoveryCheckpoint;
      invalid.snapshot.taskId = 'forged-task';
      fixture.persistence.overrideCheckpoint = invalid;
      let invalidRejected: boolean = false;
      try {
        await fixture.runtime.getTaskSnapshot('persisted-only');
      } catch (error) {
        invalidRejected = error instanceof AgentRuntimeError &&
          (error as AgentRuntimeError).code === AgentRuntimeErrorCode.PERSISTENCE_FAILURE;
      }
      expect(invalidRejected).assertTrue();
    });

    it('doesNotInvokeAdapterUntilDurableDispatchCommitResolves', 0, async () => {
      const fixture: ProductionFixture = new ProductionFixture();
      const gate: FixtureAsyncGate = new FixtureAsyncGate();
      fixture.persistence.beforeDispatchGate = gate;
      const pending = fixture.runtime.submitTask(submission('production-async-gate'));
      for (let i: number = 0; i < 20 && !gate.entered; i++) await Promise.resolve();
      expect(gate.entered).assertTrue();
      expect(fixture.factory.adapter.requests.length).assertEqual(0);
      gate.release();
      await pending;
      expect(fixture.factory.adapter.requests.length).assertEqual(1);
      expect(fixture.journal.values.indexOf('beforeDispatch') <
        fixture.journal.values.indexOf('adapterDispatch')).assertTrue();
    });

    it('doesNotDispatchUntilAsyncPlannerResolves', 0, async () => {
      const fixture: ProductionFixture = new ProductionFixture();
      const gate: FixtureAsyncGate = new FixtureAsyncGate();
      fixture.planner.gate = gate;
      let settled: boolean = false;
      const pending: Promise<TaskHandle> = fixture.runtime.submitTask(
        submission('production-planner-async-gate'));
      const observed: Promise<TaskHandle> = pending.then((handle: TaskHandle): TaskHandle => {
        settled = true;
        return handle;
      });
      for (let i: number = 0; i < 20 && !gate.entered; i++) await Promise.resolve();
      expect(gate.entered).assertTrue();
      expect(settled).assertFalse();
      expect(fixture.factory.adapter.requests.length).assertEqual(0);

      gate.release();
      await observed;
      expect(settled).assertTrue();
      expect(fixture.factory.adapter.requests.length).assertEqual(1);
    });

    it('interruptsInFlightPlannerBeforeQueuedCancellationChangesTaskState', 0, async () => {
      const fixture: ProductionFixture = new ProductionFixture();
      const gate: FixtureAsyncGate = new FixtureAsyncGate();
      fixture.planner.gate = gate;
      const submitted: Promise<TaskHandle> = fixture.runtime.submitTask(submission('production-planner-cancel'));
      for (let i: number = 0; i < 20 && !gate.entered; i++) await Promise.resolve();
      expect(gate.entered).assertTrue();
      const cancelled: Promise<CommandReceipt> = fixture.runtime.cancelTask(
        control('cancel-planner', fixture.planner.activeTaskId, TaskControlAction.CANCEL));
      const handle: TaskHandle = await submitted;
      const receipt: CommandReceipt = await cancelled;
      expect(receipt.accepted).assertTrue();
      expect(fixture.planner.interruptedTaskId).assertEqual(handle.taskId);
      expect(fixture.factory.adapter.requests.length).assertEqual(0);
      expect((await fixture.runtime.getTaskSnapshot(handle.taskId)).status).assertEqual(AgentTaskStatus.CANCELLED);
    });

    it('failsClosedAndPersistsStableEvidenceWhenPlannerRejects', 0, async () => {
      const fixture: ProductionFixture = new ProductionFixture();
      fixture.planner.rejectPlan = true;
      const handle: TaskHandle = await fixture.runtime.submitTask(
        submission('production-planner-reject'));
      const snapshot: AgentTaskSnapshot = await fixture.runtime.getTaskSnapshot(handle.taskId);
      expect(snapshot.status).assertEqual(AgentTaskStatus.FAILED);
      expect(snapshot.resultJson).assertEqual('{"reason":"plannerInvocationFailed"}');
      expect(snapshot.resultJson.indexOf('secret')).assertEqual(-1);
      expect(fixture.factory.adapter.requests.length).assertEqual(0);
      expect(fixture.persistence.checkpoints.length > 0).assertTrue();
      const checkpoint: RuntimeTaskRecoveryCheckpoint =
        fixture.persistence.checkpoints[fixture.persistence.checkpoints.length - 1];
      expect(checkpoint.snapshot.status).assertEqual(AgentTaskStatus.FAILED);
      expect(checkpoint.events[checkpoint.events.length - 1].payloadJson)
        .assertEqual('{"reason":"plannerInvocationFailed"}');
    });

    it('serializesOverlappingFacadeCommandsBehindDurableLifecycle', 0, async () => {
      const fixture: ProductionFixture = new ProductionFixture();
      const gate: FixtureAsyncGate = new FixtureAsyncGate();
      fixture.persistence.beforeDispatchGate = gate;
      const firstPending: Promise<TaskHandle> = fixture.runtime.submitTask(
        submission('production-serialized-first'));
      for (let i: number = 0; i < 20 && !gate.entered; i++) await Promise.resolve();
      expect(gate.entered).assertTrue();

      let secondSettled: boolean = false;
      const secondPending: Promise<TaskHandle> = fixture.runtime.submitTask(
        submission('production-serialized-second'));
      const observedSecond: Promise<TaskHandle> = secondPending.then((handle: TaskHandle): TaskHandle => {
        secondSettled = true;
        return handle;
      });
      for (let i: number = 0; i < 20; i++) await Promise.resolve();
      expect(secondSettled).assertFalse();
      expect(fixture.factory.adapter.requests.length).assertEqual(0);

      gate.release();
      const first: TaskHandle = await firstPending;
      const second: TaskHandle = await observedSecond;
      expect(first.taskId === second.taskId).assertFalse();
      expect(secondSettled).assertTrue();
      expect(fixture.factory.adapter.requests.length).assertEqual(2);
    });

    it('continuesSerializedFacadeQueueAfterRejectedCommand', 0, async () => {
      const fixture: ProductionFixture = new ProductionFixture();
      const invalid: TaskSubmission = submission('production-serialized-invalid');
      invalid.requestId = '';
      const rejected: Promise<TaskHandle> = fixture.runtime.submitTask(invalid);
      const accepted: Promise<TaskHandle> = fixture.runtime.submitTask(
        submission('production-serialized-after-rejection'));
      let invalidRejected: boolean = false;
      try {
        await rejected;
      } catch (error) {
        invalidRejected = error instanceof AgentRuntimeError &&
          (error as AgentRuntimeError).code === AgentRuntimeErrorCode.INVALID_CONTRACT;
      }
      expect(invalidRejected).assertTrue();
      const handle: TaskHandle = await accepted;
      expect(handle.taskId.length > 0).assertTrue();
      expect(fixture.factory.adapter.requests.length).assertEqual(1);
    });

    it('keepsToolDispatchBehindPolicyAndDeduplicatesDecision', 0, async () => {
      const fixture: ProductionFixture = new ProductionFixture(ProductionPlanKind.TOOL);
      fixture.persistence.mutateContextBeforeDispatch = true;
      fixture.persistence.mutateAuthorityBeforeDispatch = true;
      const handle = await fixture.runtime.submitTask(submission('production-tool'));
      expect((await fixture.runtime.getTaskSnapshot(handle.taskId)).status)
        .assertEqual(AgentTaskStatus.WAITING_AUTHORIZATION);
      expect(fixture.factory.adapter.requests.length).assertEqual(0);
      const observer: FixtureObserver = new FixtureObserver();
      await subscribe(fixture.runtime, handle.taskId, observer);
      expect(observer.policies.length).assertEqual(1);
      const waitingAuthority: RuntimeDurableAuthorityPayload =
        fixture.persistence.authorities[fixture.persistence.authorities.length - 1];
      expect(waitingAuthority.taskId).assertEqual(handle.taskId);
      expect(waitingAuthority.checkpointSnapshotVersion)
        .assertEqual((await fixture.runtime.getTaskSnapshot(handle.taskId)).snapshotVersion);
      expect(waitingAuthority.policy?.version).assertEqual(1);
      expect(waitingAuthority.policy?.request.requestId).assertEqual(observer.policies[0].requestId);
      expect(waitingAuthority.policy?.decision === undefined).assertTrue();
      expect(waitingAuthority.policy?.grant === undefined).assertTrue();
      expect(waitingAuthority.operation === undefined).assertTrue();
      const decision: AuthorizationDecision = new AuthorizationDecision();
      decision.commandId = 'authorize-1';
      decision.policyRequestId = observer.policies[0].requestId;
      decision.userId = 'user-1';
      decision.taskId = handle.taskId;
      decision.decision = AuthorizationDecisionType.APPROVED;
      decision.decidedAt = '1970-01-01T00:00:01.000Z';
      decision.decidedAtMs = 1000;
      expect((await fixture.runtime.provideAuthorization(decision)).accepted).assertTrue();
      expect(fixture.factory.adapter.requests.length).assertEqual(1);
      expect((await fixture.runtime.provideAuthorization(decision)).duplicate).assertTrue();
      const dispatched: StepDispatchRequest = fixture.factory.adapter.requests[0];
      expect(dispatched.persistenceContext?.budgetReservationId)
        .assertEqual('policy:' + observer.policies[0].requestId);
      expect(dispatched.persistenceContext?.dispatchId).assertEqual(dispatched.dispatchId);
      expect(dispatched.persistenceContext?.providerId).assertEqual('provider-v1');
      expect(dispatched.persistenceContext?.requestedCostMicros).assertEqual(1);
      expect(fixture.persistence.preparedContexts.length).assertEqual(1);
      expect(fixture.persistence.preparedContexts[0].operationId)
        .assertEqual(dispatched.toolInvocation?.operationId);
      const dispatchCheckpoint: RuntimeTaskRecoveryCheckpoint =
        fixture.persistence.checkpoints[fixture.persistence.checkpoints.length - 1];
      expect(dispatchCheckpoint.pendingDispatchId).assertEqual(dispatched.dispatchId);
      expect(dispatchCheckpoint.activeInvocation?.invocationId)
        .assertEqual(dispatched.toolInvocation?.invocationId);
      expect(fixture.persistence.preparedAuthorities.length).assertEqual(1);
      const dispatchPayload: RuntimeDurableAuthorityPayload = fixture.persistence.preparedAuthorities[0];
      expect(dispatchPayload.taskId).assertEqual(handle.taskId);
      expect(dispatchPayload.checkpointSnapshotVersion)
        .assertEqual(dispatchCheckpoint.snapshot.snapshotVersion);
      expect(dispatchPayload.policy?.version).assertEqual(3);
      expect(dispatchPayload.policy?.decision?.commandId).assertEqual(decision.commandId);
      expect(dispatchPayload.policy?.grant?.grantId)
        .assertEqual(dispatched.toolInvocation?.authorizationGrantId);
      expect(dispatchPayload.operation?.operationId).assertEqual(dispatched.toolInvocation?.operationId);
      expect(dispatchPayload.budgetScopes.length).assertEqual(3);
      expect(dispatchPayload.budgetReservations.length).assertEqual(1);
      const durable: RuntimeRecoveryAuthority = JSON.parse(ContractCodec.stringify(dispatchPayload)) as
        RuntimeRecoveryAuthority;
      durable.storageRevision = 1;
      expect(RuntimeRecoveryAuthorityValidator.validate(dispatchCheckpoint, durable).valid).assertTrue();
      const forged: ToolOutcome = successfulOutcome(dispatched);
      forged.invocationId = 'invocation:forged';
      const sink: RuntimeToolOutcomeSinkPort = fixture.factory.sink as RuntimeToolOutcomeSinkPort;
      await sink.complete(handle.taskId, dispatched.step.stepId, dispatched.dispatchId, forged);
      expect((await fixture.runtime.getTaskSnapshot(handle.taskId)).status)
        .assertEqual(AgentTaskStatus.RUNNING);
      await sink.complete(handle.taskId, dispatched.step.stepId, dispatched.dispatchId,
        successfulOutcome(dispatched));
      expect((await fixture.runtime.getTaskSnapshot(handle.taskId)).status)
        .assertEqual(AgentTaskStatus.COMPLETED);
      const completedCheckpoint: RuntimeTaskRecoveryCheckpoint =
        fixture.persistence.checkpoints[fixture.persistence.checkpoints.length - 1];
      expect(completedCheckpoint.pendingDispatchId).assertEqual('');
      expect(completedCheckpoint.activeInvocation === undefined).assertTrue();
      const completedAuthority: RuntimeDurableAuthorityPayload =
        fixture.persistence.authorities[fixture.persistence.authorities.length - 1];
      expect(completedAuthority.taskId).assertEqual(handle.taskId);
      expect(completedAuthority.budgetScopes[0].taskId).assertEqual(handle.taskId);

      const isolated: ProductionFixture = new ProductionFixture(ProductionPlanKind.TOOL);
      isolated.factory.adapter.accept = false;
      isolated.factory.adapter.mutateRequestBeforeReturn = true;
      const isolatedHandle = await isolated.runtime.submitTask(submission('production-tool-isolation'));
      const isolatedObserver: FixtureObserver = new FixtureObserver();
      await subscribe(isolated.runtime, isolatedHandle.taskId, isolatedObserver);
      const isolatedDecision: AuthorizationDecision = new AuthorizationDecision();
      isolatedDecision.commandId = 'authorize-isolation';
      isolatedDecision.policyRequestId = isolatedObserver.policies[0].requestId;
      isolatedDecision.userId = 'user-1';
      isolatedDecision.taskId = isolatedHandle.taskId;
      isolatedDecision.decision = AuthorizationDecisionType.APPROVED;
      isolatedDecision.decidedAt = '1970-01-01T00:00:01.000Z';
      isolatedDecision.decidedAtMs = 1000;
      await isolated.runtime.provideAuthorization(isolatedDecision);
      expect(isolated.persistence.rejectedContexts.length).assertEqual(1);
      expect(isolated.persistence.rejectedContexts[0].providerId).assertEqual('provider-v1');
    });

    it('appliesSynchronousAdapterCompletionAfterDispatchReturns', 0, async () => {
      const fixture: ProductionFixture = new ProductionFixture();
      fixture.factory.adapter.completeSynchronously = true;
      const handle = await fixture.runtime.submitTask(submission('production-sync-completion'));
      expect((await fixture.runtime.getTaskSnapshot(handle.taskId)).status)
        .assertEqual(AgentTaskStatus.COMPLETED);
      expect(fixture.factory.adapter.requests.length).assertEqual(1);
    });

    it('failsClosedBeforeAdapterWhenPersistenceRejectsDispatch', 0, async () => {
      const fixture: ProductionFixture = new ProductionFixture();
      fixture.persistence.allowBeforeDispatch = false;
      let rejected: boolean = false;
      try {
        await fixture.runtime.submitTask(submission('production-persistence-reject'));
      } catch (error) {
        rejected = error instanceof AgentRuntimeError &&
          (error as AgentRuntimeError).code === AgentRuntimeErrorCode.PERSISTENCE_FAILURE;
      }
      expect(rejected).assertTrue();
      expect(fixture.factory.adapter.requests.length).assertEqual(0);
      expect(fixture.journal.values.indexOf('beforeDispatch') >= 0).assertTrue();
      expect(fixture.journal.values.indexOf('adapterDispatch')).assertEqual(-1);
      const throwing: ProductionFixture = new ProductionFixture();
      throwing.persistence.throwBeforeDispatch = true;
      let threw: boolean = false;
      try {
        await throwing.runtime.submitTask(submission('production-persistence-throws'));
      } catch (error) {
        threw = error instanceof AgentRuntimeError;
      }
      expect(threw).assertTrue();
      expect(throwing.factory.adapter.requests.length).assertEqual(0);
    });

    it('routesPauseResumeCancelThroughFacadeWithCommandReplay', 0, async () => {
      const fixture: ProductionFixture = new ProductionFixture();
      const handle = await fixture.runtime.submitTask(submission('production-control'));
      const pause: TaskControlCommand = control('pause-1', handle.taskId, TaskControlAction.PAUSE);
      expect((await fixture.runtime.pauseTask(pause)).accepted).assertTrue();
      expect((await fixture.runtime.getTaskSnapshot(handle.taskId)).status).assertEqual(AgentTaskStatus.PAUSED);
      expect((await fixture.runtime.pauseTask(pause)).duplicate).assertTrue();
      const resume: TaskControlCommand = control('resume-1', handle.taskId, TaskControlAction.RESUME);
      expect((await fixture.runtime.resumeTask(resume)).accepted).assertTrue();
      expect((await fixture.runtime.getTaskSnapshot(handle.taskId)).status).assertEqual(AgentTaskStatus.RUNNING);
      const cancel: TaskControlCommand = control('cancel-1', handle.taskId, TaskControlAction.CANCEL);
      expect((await fixture.runtime.cancelTask(cancel)).accepted).assertTrue();
      expect((await fixture.runtime.getTaskSnapshot(handle.taskId)).status).assertEqual(AgentTaskStatus.CANCELLED);
      expect(fixture.factory.adapter.cancelledDispatchIds.length).assertEqual(1);
      expect(fixture.factory.adapter.cancelledDispatchIds[0])
        .assertEqual(fixture.factory.adapter.requests[0].dispatchId);
    });

    it('deliversClarificationAndResumesPlanningThroughFacade', 0, async () => {
      const fixture: ProductionFixture = new ProductionFixture(ProductionPlanKind.CLARIFY);
      const handle = await fixture.runtime.submitTask(submission('production-clarification'));
      const observer: FixtureObserver = new FixtureObserver();
      await subscribe(fixture.runtime, handle.taskId, observer);
      expect(observer.clarifications.length).assertEqual(1);
      const response: ClarificationResponse = new ClarificationResponse();
      response.commandId = 'clarify-1';
      response.clarificationId = observer.clarifications[0].clarificationId;
      response.taskId = handle.taskId;
      response.answerJson = '{"target":"team"}';
      response.respondedAt = '1970-01-01T00:00:01.000Z';
      response.respondedAtMs = 1000;
      expect((await fixture.runtime.provideClarification(response)).accepted).assertTrue();
      expect(fixture.factory.adapter.requests.length).assertEqual(1);
    });

    it('failsClosedWhenAsyncClarificationResumeRejects', 0, async () => {
      const fixture: ProductionFixture = new ProductionFixture(ProductionPlanKind.CLARIFY);
      const handle: TaskHandle = await fixture.runtime.submitTask(
        submission('production-clarification-reject'));
      const observer: FixtureObserver = new FixtureObserver();
      await subscribe(fixture.runtime, handle.taskId, observer);
      fixture.planner.rejectResume = true;
      const response: ClarificationResponse = new ClarificationResponse();
      response.commandId = 'clarify-reject-1';
      response.clarificationId = observer.clarifications[0].clarificationId;
      response.taskId = handle.taskId;
      response.answerJson = '{"target":"team"}';
      response.respondedAt = '1970-01-01T00:00:01.000Z';
      response.respondedAtMs = 1000;
      const receipt = await fixture.runtime.provideClarification(response);
      expect(receipt.accepted).assertFalse();
      expect(receipt.rejectionCode).assertEqual('PLANNER_INVOCATION_FAILED');
      const snapshot: AgentTaskSnapshot = await fixture.runtime.getTaskSnapshot(handle.taskId);
      expect(snapshot.status).assertEqual(AgentTaskStatus.FAILED);
      expect(snapshot.resultJson).assertEqual('{"reason":"plannerInvocationFailed"}');
      expect(fixture.factory.adapter.requests.length).assertEqual(0);
    });

    it('persistsUnknownOutcomeAndReconciliationBeforeCompletion', 0, async () => {
      const fixture: ProductionFixture = new ProductionFixture(ProductionPlanKind.SIDE_EFFECT);
      const handle = await fixture.runtime.submitTask(submission('production-reconcile'));
      const request: StepDispatchRequest = fixture.factory.adapter.requests[0];
      const sink: RuntimeToolOutcomeSinkPort = fixture.factory.sink as RuntimeToolOutcomeSinkPort;
      await sink.complete(handle.taskId, request.step.stepId, request.dispatchId, unknownOutcome(request));
      expect((await fixture.runtime.getTaskSnapshot(handle.taskId)).status)
        .assertEqual(AgentTaskStatus.WAITING_RECONCILIATION);
      const waitingReconciliationAuthority: RuntimeDurableAuthorityPayload =
        fixture.persistence.authorities[fixture.persistence.authorities.length - 1];
      expect(waitingReconciliationAuthority.operation === undefined).assertTrue();
      const report: ReconciliationReport = new ReconciliationReport();
      report.commandId = 'reconcile-1';
      report.taskId = handle.taskId;
      report.stepId = request.step.stepId;
      report.operationId = 'operation:' + handle.taskId + ':' + request.step.stepId;
      report.status = ReconciliationStatus.CONFIRMED_SUCCEEDED;
      report.evidenceDigest = 'sha256:evidence';
      report.reportedAt = '2026-10-07T15:00:01.000Z';
      expect((await fixture.runtime.provideReconciliation(report)).accepted).assertTrue();
      expect((await fixture.runtime.getTaskSnapshot(handle.taskId)).status)
        .assertEqual(AgentTaskStatus.COMPLETED);
      expect(fixture.journal.values.indexOf('reconciliation:' + report.operationId) >= 0).assertTrue();
    });

    it('replaysEventsClosesSubscriptionsAndRejectsAfterShutdown', 0, async () => {
      const fixture: ProductionFixture = new ProductionFixture();
      const handle = await fixture.runtime.submitTask(submission('production-lifecycle'));
      const observer: FixtureObserver = new FixtureObserver();
      const subscription: AgentSubscription = await subscribe(fixture.runtime, handle.taskId, observer);
      expect(observer.events.length > 0).assertTrue();
      subscription.close();
      expect(subscription.isClosed()).assertTrue();
      await fixture.runtime.shutdown(ShutdownMode.GRACEFUL);
      let shutdownRejected: boolean = false;
      try {
        await fixture.runtime.submitTask(submission('after-shutdown'));
      } catch (error) {
        shutdownRejected = error instanceof AgentRuntimeError;
      }
      expect(shutdownRejected).assertTrue();
    });

    it('restoresDurableWaitingPolicyBeforeExposingFacadeAndReplaysEvents', 0, async () => {
      const source: ProductionFixture = new ProductionFixture(ProductionPlanKind.TOOL);
      const handle: TaskHandle = await source.runtime.submitTask(submission('production-recovery-policy'));
      enableRecovery(source, handle.taskId);
      const before: AgentTaskSnapshot = await source.runtime.getTaskSnapshot(handle.taskId);
      const restored: AgentRuntimeFacade = await recoveredRuntime(source);
      const after: AgentTaskSnapshot = await restored.getTaskSnapshot(handle.taskId);
      expect(after.snapshotVersion).assertEqual(before.snapshotVersion + 1);
      expect(after.status).assertEqual(before.status);
      const observer: FixtureObserver = new FixtureObserver();
      const request: SubscriptionRequest = new SubscriptionRequest();
      request.subscriptionId = 'recovery-subscription';
      request.taskId = handle.taskId;
      request.afterSequence = 0;
      await restored.subscribe(request, observer);
      expect(observer.events.length).assertEqual(after.lastEventSequence);
      expect(observer.policies.length).assertEqual(1);
      expect(source.factory.adapter.requests.length).assertEqual(0);
    });

    it('normalizesActiveOperationBeforeExposingRecoveredFacade', 0, async () => {
      const source: ProductionFixture = new ProductionFixture(ProductionPlanKind.TOOL);
      const handle: TaskHandle = await source.runtime.submitTask(submission('production-recovery-active'));
      const observer: FixtureObserver = new FixtureObserver();
      await subscribe(source.runtime, handle.taskId, observer);
      const decision: AuthorizationDecision = new AuthorizationDecision();
      decision.commandId = 'recovery-active-decision';
      decision.policyRequestId = observer.policies[0].requestId;
      decision.userId = 'user-1';
      decision.taskId = handle.taskId;
      decision.decision = AuthorizationDecisionType.APPROVED;
      decision.decidedAt = '1970-01-01T00:00:01.000Z';
      decision.decidedAtMs = 1000;
      await source.runtime.provideAuthorization(decision);
      enableRecovery(source, handle.taskId);
      const restored: AgentRuntimeFacade = await recoveredRuntime(source);
      const snapshot: AgentTaskSnapshot = await restored.getTaskSnapshot(handle.taskId);
      expect(snapshot.status).assertEqual(AgentTaskStatus.WAITING_RECONCILIATION);
      expect(source.persistence.recoveryNormalizations).assertEqual(1);
      const normalized: RuntimeTaskRecoveryCheckpoint | undefined =
        await source.persistence.loadCheckpoint(handle.taskId);
      expect(normalized?.activeInvocation === undefined).assertTrue();
      expect(normalized?.pendingDispatchId).assertEqual('');
    });

    it('failsClosedWhenActiveOperationNormalizationIsRejected', 0, async () => {
      const source: ProductionFixture = new ProductionFixture(ProductionPlanKind.TOOL);
      const handle: TaskHandle = await source.runtime.submitTask(submission('production-recovery-active-rejected'));
      const observer: FixtureObserver = new FixtureObserver();
      await subscribe(source.runtime, handle.taskId, observer);
      const decision: AuthorizationDecision = new AuthorizationDecision();
      decision.commandId = 'recovery-active-rejected-decision';
      decision.policyRequestId = observer.policies[0].requestId;
      decision.userId = 'user-1';
      decision.taskId = handle.taskId;
      decision.decision = AuthorizationDecisionType.APPROVED;
      decision.decidedAt = '1970-01-01T00:00:01.000Z';
      decision.decidedAtMs = 1000;
      await source.runtime.provideAuthorization(decision);
      enableRecovery(source, handle.taskId);
      source.persistence.allowRecoveryNormalization = false;
      let rejected: boolean = false;
      try {
        await recoveredRuntime(source);
      } catch (error) {
        rejected = error instanceof AgentRuntimeError;
      }
      expect(rejected).assertTrue();
    });
  });
}
