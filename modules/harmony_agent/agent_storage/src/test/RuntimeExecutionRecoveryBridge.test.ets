import { describe, expect, it } from '@ohos/hypium';
import {
  AgentRuntimeEvent,
  AgentTaskStatus,
  AuthorizationDecision,
  AuthorizationDecisionType,
  ClarificationRequest,
  CollaborationMode,
  ContractCodec,
  ExecutionBudget,
  IdempotencyMode,
  PolicyRequest,
  ReconciliationReport,
  ReconciliationStatus,
  RiskLevel,
  SideEffect,
  TaskSubmission,
  ToolInvocation,
  ToolOutcome,
  ToolOutcomeStatus,
  WorkflowGraph,
  WorkflowStep,
  WorkflowStepKind
} from '@harmony_agent/agent-contracts';
import {
  BudgetAmount,
  BudgetReservationState,
  OperationJournalState
} from '@harmony_agent/agent-core';
import {
  AgentRuntimeFacade,
  AgentRuntimeObserver,
  AgentSubscription,
  CollaborationSelectorPort,
  PlanningRequest,
  PlanningResult,
  PlanningStatus,
  PreparedToolDispatch,
  ProductionAgentRuntimeConfig,
  ProductionAgentRuntimePorts,
  ProductionRuntimeAdapterFactoryPort,
  RuntimeClockPort,
  RuntimeIdGeneratorPort,
  RuntimeRecoveryAuthority,
  RuntimeRecoveryAuthorityValidator,
  RuntimeTaskRecoveryCheckpoint,
  RuntimeToolOutcomeSinkPort,
  SemanticPlannerPort,
  StepDispatchPort,
  StepDispatchReceipt,
  StepDispatchRequest,
  SubscriptionRequest,
  ToolInvocationPreparerPort,
  createProductionAgentRuntime,
  createRecoveredProductionAgentRuntime
} from '@harmony_agent/agent-runtime';
import {
  DurableExecutionRecoveryStore,
  DurableSnapshotBackendPort,
  RuntimeExecutionRecoveryBridge,
  RuntimeExecutionRecoveryBridgeConfig,
  RuntimeOutcomeAccountingPort,
  RuntimeReconciliationSettlement,
  RuntimeReconciliationSettlementPort,
  SnapshotIntegrityPort,
  StorageSnapshotCodec,
  StorageSnapshotEnvelope,
  StoredOperation
} from '../../Index';

class BridgeIntegrity implements SnapshotIntegrityPort {
  digest(payloadJson: string): string {
    return 'bridge-digest:' + payloadJson;
  }
}

class BridgeBackend implements DurableSnapshotBackendPort {
  snapshot?: StorageSnapshotEnvelope;
  failNextWrite: boolean = false;
  compareAndSetCalls: number = 0;

  async initialize(): Promise<void> {
  }

  async load(): Promise<StorageSnapshotEnvelope | undefined> {
    if (this.snapshot === undefined) return undefined;
    return StorageSnapshotCodec.decode(StorageSnapshotCodec.encode(this.snapshot));
  }

  async compareAndSet(expectedRevision: number, next: StorageSnapshotEnvelope): Promise<boolean> {
    this.compareAndSetCalls++;
    if (this.failNextWrite) {
      this.failNextWrite = false;
      return false;
    }
    const current: number = this.snapshot === undefined ? 0 : this.snapshot.revision;
    if (current !== expectedRevision || next.revision <= expectedRevision) return false;
    this.snapshot = StorageSnapshotCodec.decode(StorageSnapshotCodec.encode(next));
    return true;
  }
}

class BridgeClock implements RuntimeClockPort {
  nowMs(): number {
    return 1000;
  }
}

class BridgeIds implements RuntimeIdGeneratorPort {
  private next: number = 0;

  nextId(kind: string, requestId: string): string {
    this.next++;
    return kind + ':' + requestId + ':' + this.next.toString();
  }
}

class BridgeCollaboration implements CollaborationSelectorPort {
  select(): CollaborationMode {
    return CollaborationMode.SINGLE;
  }
}

class BridgePlanner implements SemanticPlannerPort {
  async plan(request: PlanningRequest): Promise<PlanningResult> {
    return bridgePlan(request);
  }

  async resume(request: PlanningRequest): Promise<PlanningResult> {
    return bridgePlan(request);
  }

  async replan(request: PlanningRequest): Promise<PlanningResult> {
    return bridgePlan(request);
  }

  interrupt(taskId: string): boolean {
    return false;
  }
}

class BridgeToolPreparer implements ToolInvocationPreparerPort {
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
    invocation.timeoutMs = step.timeoutMs;
    invocation.createdAt = new Date(nowMs).toISOString();
    return prepared;
  }
}

class BridgeAdapter implements StepDispatchPort {
  requests: StepDispatchRequest[] = [];
  sink?: RuntimeToolOutcomeSinkPort;
  accept: boolean = true;

  dispatch(request: StepDispatchRequest): StepDispatchReceipt {
    this.requests.push(request);
    const value: StepDispatchReceipt = new StepDispatchReceipt();
    value.accepted = this.accept;
    if (!this.accept) value.rejectionCode = 'BRIDGE_ADAPTER_REJECTED';
    return value;
  }

  cancel(_dispatchId: string): boolean {
    return false;
  }
}

class BridgeAdapterFactory implements ProductionRuntimeAdapterFactoryPort {
  readonly adapter: BridgeAdapter = new BridgeAdapter();

  create(sink: RuntimeToolOutcomeSinkPort): StepDispatchPort {
    this.adapter.sink = sink;
    return this.adapter;
  }
}

class BridgeObserver implements AgentRuntimeObserver {
  events: AgentRuntimeEvent[] = [];
  policies: PolicyRequest[] = [];

  onEvent(event: AgentRuntimeEvent): void {
    this.events.push(ContractCodec.parseAgentRuntimeEvent(ContractCodec.stringify(event)));
  }

  onPolicyRequest(request: PolicyRequest): void {
    this.policies.push(ContractCodec.parsePolicyRequest(ContractCodec.stringify(request)));
  }

  onClarificationRequest(request: ClarificationRequest): void {
  }
}

class BridgeAccounting implements RuntimeOutcomeAccountingPort {
  actualForOutcome(operation: StoredOperation, outcome: ToolOutcome): BudgetAmount | undefined {
    const value: BudgetAmount = new BudgetAmount();
    value.toolCalls = 1;
    value.monetaryCostMicros = 1;
    return value;
  }
}

class BridgeSettlementResolver implements RuntimeReconciliationSettlementPort {
  outcome?: ToolOutcome;

  resolve(report: ReconciliationReport, operation: StoredOperation): RuntimeReconciliationSettlement | undefined {
    const source: ToolOutcome | undefined = this.outcome;
    if (source === undefined) return undefined;
    const value: RuntimeReconciliationSettlement = new RuntimeReconciliationSettlement();
    value.outcome = ContractCodec.parseToolOutcome(ContractCodec.stringify(source));
    value.actual.toolCalls = 1;
    value.actual.monetaryCostMicros = 1;
    return value;
  }
}

class BridgeFixture {
  readonly backend: BridgeBackend;
  readonly store: DurableExecutionRecoveryStore;
  readonly bridge: RuntimeExecutionRecoveryBridge;
  readonly factory: BridgeAdapterFactory;
  readonly settlement: BridgeSettlementResolver;
  readonly runtime: AgentRuntimeFacade;

  constructor(backend: BridgeBackend, store: DurableExecutionRecoveryStore) {
    this.backend = backend;
    this.store = store;
    this.factory = new BridgeAdapterFactory();
    this.settlement = new BridgeSettlementResolver();
    const bridgeConfig: RuntimeExecutionRecoveryBridgeConfig = new RuntimeExecutionRecoveryBridgeConfig();
    bridgeConfig.ownerId = 'runtime-owner-1';
    bridgeConfig.leaseTtlMs = 30000;
    bridgeConfig.policyVersion = 'policy-v1';
    bridgeConfig.outcomeAccounting = new BridgeAccounting();
    bridgeConfig.reconciliationSettlement = this.settlement;
    this.bridge = new RuntimeExecutionRecoveryBridge(store, bridgeConfig);
    const config: ProductionAgentRuntimeConfig = new ProductionAgentRuntimeConfig();
    config.policyVersion = 'policy-v1';
    config.grantTtlMs = 30000;
    const ports: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
    ports.clock = new BridgeClock();
    ports.ids = new BridgeIds();
    ports.planner = new BridgePlanner();
    ports.collaboration = new BridgeCollaboration();
    ports.toolPreparer = new BridgeToolPreparer();
    ports.adapterFactory = this.factory;
    ports.persistence = this.bridge;
    this.runtime = createProductionAgentRuntime(config, ports);
  }
}

class RecoveredBridgeFixture {
  store: DurableExecutionRecoveryStore;
  bridge: RuntimeExecutionRecoveryBridge;
  factory: BridgeAdapterFactory;
  runtime: AgentRuntimeFacade;

  constructor(store: DurableExecutionRecoveryStore, bridge: RuntimeExecutionRecoveryBridge,
    factory: BridgeAdapterFactory, runtime: AgentRuntimeFacade) {
    this.store = store;
    this.bridge = bridge;
    this.factory = factory;
    this.runtime = runtime;
  }
}

function bridgeBudget(): ExecutionBudget {
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

function bridgeSubmission(requestId: string): TaskSubmission {
  const value: TaskSubmission = new TaskSubmission();
  value.requestId = requestId;
  value.userId = 'user-1';
  value.userIntent = 'prepare review';
  value.locale = 'zh-CN';
  value.timeZone = 'Asia/Shanghai';
  value.referenceTime = '2026-10-09T00:00:00.000Z';
  value.requestedBudget = bridgeBudget();
  value.submittedAt = '2026-10-09T00:00:00.000Z';
  return value;
}

function bridgePlan(request: PlanningRequest): PlanningResult {
  const step: WorkflowStep = new WorkflowStep();
  step.stepId = 'step-1';
  step.kind = WorkflowStepKind.TOOL;
  step.goal = 'execute tool';
  step.capabilityRequirements = ['calendar.write'];
  step.expectedOutputSchemaJson = '{"type":"object"}';
  step.sideEffect = SideEffect.REVERSIBLE;
  step.riskLevel = RiskLevel.MEDIUM;
  step.idempotencyMode = IdempotencyMode.PROVIDER_KEY;
  step.retryPolicyRef = 'retry-v1';
  step.verificationPolicyRef = 'verify-v1';
  step.timeoutMs = 10000;
  const graph: WorkflowGraph = new WorkflowGraph();
  graph.workflowId = 'workflow:' + request.envelope.taskId;
  graph.taskId = request.envelope.taskId;
  graph.workflowVersion = '1';
  graph.createdAt = '2026-10-09T00:00:00.000Z';
  graph.steps = [step];
  graph.entryStepIds = [step.stepId];
  const result: PlanningResult = new PlanningResult();
  result.status = PlanningStatus.READY;
  result.workflow = graph;
  return result;
}

function bridgeOutcome(request: StepDispatchRequest, status: ToolOutcomeStatus): ToolOutcome {
  const value: ToolOutcome = new ToolOutcome();
  value.invocationId = request.toolInvocation?.invocationId as string;
  value.status = status;
  if (status !== ToolOutcomeStatus.UNKNOWN_OUTCOME) {
    value.resultJson = '{"ok":true}';
    value.resultDigest = 'sha256:result';
  }
  value.startedAt = '2026-10-09T00:00:00.000Z';
  value.finishedAt = '2026-10-09T00:00:00.001Z';
  return value;
}

function bridgeDecision(taskId: string, request: PolicyRequest): AuthorizationDecision {
  const value: AuthorizationDecision = new AuthorizationDecision();
  value.commandId = 'decision:' + taskId;
  value.policyRequestId = request.requestId;
  value.userId = request.userId;
  value.taskId = taskId;
  value.decision = AuthorizationDecisionType.APPROVED;
  value.decidedAt = '1970-01-01T00:00:01.000Z';
  value.decidedAtMs = 1000;
  return value;
}

async function openBridgeFixture(): Promise<BridgeFixture> {
  const backend: BridgeBackend = new BridgeBackend();
  const opened = await DurableExecutionRecoveryStore.open(backend, new BridgeIntegrity());
  if (!opened.accepted || opened.store === undefined) throw new Error('bridge fixture store open failed');
  return new BridgeFixture(backend, opened.store);
}

async function reopenRecoveredBridgeFixture(source: BridgeFixture): Promise<RecoveredBridgeFixture> {
  const opened = await DurableExecutionRecoveryStore.openForRuntimeRecovery(source.backend, new BridgeIntegrity());
  if (!opened.accepted || opened.store === undefined) throw new Error('recovery fixture reopen failed');
  const bridgeConfig: RuntimeExecutionRecoveryBridgeConfig = new RuntimeExecutionRecoveryBridgeConfig();
  bridgeConfig.ownerId = 'runtime-owner-2';
  bridgeConfig.leaseTtlMs = 30000;
  bridgeConfig.policyVersion = 'policy-v1';
  bridgeConfig.outcomeAccounting = new BridgeAccounting();
  bridgeConfig.reconciliationSettlement = new BridgeSettlementResolver();
  const bridge: RuntimeExecutionRecoveryBridge =
    new RuntimeExecutionRecoveryBridge(opened.store, bridgeConfig);
  const config: ProductionAgentRuntimeConfig = new ProductionAgentRuntimeConfig();
  config.policyVersion = 'policy-v1';
  config.grantTtlMs = 30000;
  const factory: BridgeAdapterFactory = new BridgeAdapterFactory();
  const ports: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
  ports.clock = new BridgeClock();
  ports.ids = new BridgeIds();
  ports.planner = new BridgePlanner();
  ports.collaboration = new BridgeCollaboration();
  ports.toolPreparer = new BridgeToolPreparer();
  ports.adapterFactory = factory;
  ports.persistence = bridge;
  ports.recovery = bridge;
  const runtime: AgentRuntimeFacade = await createRecoveredProductionAgentRuntime(config, ports);
  return new RecoveredBridgeFixture(opened.store, bridge, factory, runtime);
}

async function observe(runtime: AgentRuntimeFacade, taskId: string,
  observer: BridgeObserver): Promise<AgentSubscription> {
  const request: SubscriptionRequest = new SubscriptionRequest();
  request.subscriptionId = 'subscription:' + taskId;
  request.taskId = taskId;
  return await runtime.subscribe(request, observer);
}

async function authorize(fixture: BridgeFixture, requestId: string): Promise<string> {
  const handle = await fixture.runtime.submitTask(bridgeSubmission(requestId));
  const observer: BridgeObserver = new BridgeObserver();
  await observe(fixture.runtime, handle.taskId, observer);
  expect(observer.policies.length).assertEqual(1);
  const receipt = await fixture.runtime.provideAuthorization(bridgeDecision(handle.taskId, observer.policies[0]));
  expect(receipt.accepted).assertTrue();
  return handle.taskId;
}

export default function runtimeExecutionRecoveryBridgeTest(): void {
  describe('RuntimeExecutionRecoveryBridge', () => {
    it('atomicallyFencesDispatchAndSettlesOutcomeThroughProductionFacade', 0, async () => {
      const fixture: BridgeFixture = await openBridgeFixture();
      const taskId: string = await authorize(fixture, 'bridge-success');
      expect(fixture.factory.adapter.requests.length).assertEqual(1);
      const dispatched: StepDispatchRequest = fixture.factory.adapter.requests[0];
      const operationId: string = dispatched.persistenceContext?.operationId as string;
      expect(fixture.store.getOperation(operationId)?.state).assertEqual(OperationJournalState.IN_FLIGHT);
      expect(fixture.store.getPolicyRecord(dispatched.persistenceContext?.policyRequestId as string)?.version)
        .assertEqual(3);
      expect(fixture.store.getLease(taskId)?.ownerId).assertEqual('runtime-owner-1');
      expect(fixture.store.getBudgetReservation(dispatched.persistenceContext?.budgetReservationId as string)?.
        snapshot.state).assertEqual(BudgetReservationState.RESERVED);
      expect(fixture.store.getTask(taskId)?.snapshot.snapshotVersion)
        .assertEqual((await fixture.runtime.getTaskSnapshot(taskId)).snapshotVersion);

      await (fixture.factory.adapter.sink as RuntimeToolOutcomeSinkPort).complete(
        taskId, dispatched.step.stepId, dispatched.dispatchId,
        bridgeOutcome(dispatched, ToolOutcomeStatus.SUCCEEDED));
      expect(fixture.store.getOperation(operationId)?.state).assertEqual(OperationJournalState.COMMITTED);
      expect(fixture.store.getLease(taskId) === undefined).assertTrue();
      expect(fixture.store.getBudgetReservation(dispatched.persistenceContext?.budgetReservationId as string)?.
        snapshot.state).assertEqual(BudgetReservationState.SETTLED);
      expect((await fixture.runtime.getTaskSnapshot(taskId)).status).assertEqual(AgentTaskStatus.COMPLETED);
      expect((await fixture.bridge.loadCheckpoint(taskId))?.snapshot.status).assertEqual(AgentTaskStatus.COMPLETED);
    });

    it('assemblesBoundRecoveryAuthorityFromDurableRecords', 0, async () => {
      const fixture: BridgeFixture = await openBridgeFixture();
      const handle = await fixture.runtime.submitTask(bridgeSubmission('bridge-recovery-authority'));
      const taskIds: string[] = await fixture.bridge.listRecoveryTaskIds();
      expect(taskIds.length).assertEqual(1);
      expect(taskIds[0]).assertEqual(handle.taskId);
      const waiting = await fixture.bridge.loadRecoveryAuthority(handle.taskId);
      const waitingCheckpoint = await fixture.bridge.loadCheckpoint(handle.taskId);
      expect(waiting !== undefined).assertTrue();
      expect(waiting?.policy?.version).assertEqual(1);
      expect(RuntimeRecoveryAuthorityValidator.validate(waitingCheckpoint as RuntimeTaskRecoveryCheckpoint,
        waiting as RuntimeRecoveryAuthority).valid).assertTrue();

      const observer: BridgeObserver = new BridgeObserver();
      await observe(fixture.runtime, handle.taskId, observer);
      await fixture.runtime.provideAuthorization(bridgeDecision(handle.taskId, observer.policies[0]));
      const active = await fixture.bridge.loadRecoveryAuthority(handle.taskId);
      const activeCheckpoint = await fixture.bridge.loadCheckpoint(handle.taskId);
      expect(active?.operation?.state).assertEqual(OperationJournalState.IN_FLIGHT);
      expect(active?.operation?.fencingToken).assertEqual(fixture.store.getLease(handle.taskId)?.fencingToken);
      expect(RuntimeRecoveryAuthorityValidator.validate(activeCheckpoint as RuntimeTaskRecoveryCheckpoint,
        active as RuntimeRecoveryAuthority).valid).assertTrue();
    });

    it('reopensDurableStoreRestoresFacadeAndContinuesWaitingAuthorization', 0, async () => {
      const source: BridgeFixture = await openBridgeFixture();
      const handle = await source.runtime.submitTask(bridgeSubmission('bridge-reopen-recovery'));
      const before = await source.runtime.getTaskSnapshot(handle.taskId);
      const recovered: RecoveredBridgeFixture = await reopenRecoveredBridgeFixture(source);
      const after = await recovered.runtime.getTaskSnapshot(handle.taskId);
      expect(after.snapshotVersion).assertEqual(before.snapshotVersion + 1);
      expect(after.status).assertEqual(AgentTaskStatus.WAITING_AUTHORIZATION);
      const observer: BridgeObserver = new BridgeObserver();
      await observe(recovered.runtime, handle.taskId, observer);
      expect(observer.events.length).assertEqual(after.lastEventSequence);
      expect(observer.policies.length).assertEqual(1);
      expect(recovered.factory.adapter.requests.length).assertEqual(0);
      const receipt = await recovered.runtime.provideAuthorization(
        bridgeDecision(handle.taskId, observer.policies[0]));
      expect(receipt.accepted).assertTrue();
      expect(recovered.factory.adapter.requests.length).assertEqual(1);
      expect(recovered.store.getTask(handle.taskId)?.snapshot.snapshotVersion)
        .assertEqual((await recovered.runtime.getTaskSnapshot(handle.taskId)).snapshotVersion);
    });

    it('atomicallyNormalizesActiveOperationAndTakesOverRecoveryFence', 0, async () => {
      const source: BridgeFixture = await openBridgeFixture();
      const taskId: string = await authorize(source, 'bridge-active-recovery');
      const dispatched: StepDispatchRequest = source.factory.adapter.requests[0];
      const operationId: string = dispatched.persistenceContext?.operationId as string;
      const oldFence: number = source.store.getOperation(operationId)?.fencingToken as number;
      expect(source.store.getLease(taskId) !== undefined).assertTrue();

      const recovered: RecoveredBridgeFixture = await reopenRecoveredBridgeFixture(source);
      const snapshot = await recovered.runtime.getTaskSnapshot(taskId);
      const checkpoint = await recovered.bridge.loadCheckpoint(taskId);
      const operation: StoredOperation | undefined = recovered.store.getOperation(operationId);
      expect(snapshot.status).assertEqual(AgentTaskStatus.WAITING_RECONCILIATION);
      expect(recovered.factory.adapter.requests.length).assertEqual(0);
      expect(checkpoint?.activeInvocation === undefined).assertTrue();
      expect(checkpoint?.pendingDispatchId).assertEqual('');
      expect(operation?.state).assertEqual(OperationJournalState.UNKNOWN_OUTCOME);
      expect((operation?.fencingToken as number) > oldFence).assertTrue();
      expect(recovered.store.getLease(taskId) === undefined).assertTrue();
      expect(recovered.store.getBudgetReservation(
        dispatched.persistenceContext?.budgetReservationId as string)?.snapshot.state)
        .assertEqual(BudgetReservationState.UNKNOWN);
    });

    it('failsClosedWhenActiveRecoveryNormalizationCasConflicts', 0, async () => {
      const source: BridgeFixture = await openBridgeFixture();
      await authorize(source, 'bridge-active-recovery-conflict');
      source.backend.failNextWrite = true;
      let rejected: boolean = false;
      try {
        await reopenRecoveredBridgeFixture(source);
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
      expect(source.factory.adapter.requests.length).assertEqual(1);
    });

    it('failsClosedBeforeAdapterWhenDurableCasRejectsAuthorizationWrite', 0, async () => {
      const fixture: BridgeFixture = await openBridgeFixture();
      const handle = await fixture.runtime.submitTask(bridgeSubmission('bridge-cas-failure'));
      const observer: BridgeObserver = new BridgeObserver();
      await observe(fixture.runtime, handle.taskId, observer);
      fixture.backend.failNextWrite = true;
      let rejected: boolean = false;
      try {
        await fixture.runtime.provideAuthorization(bridgeDecision(handle.taskId, observer.policies[0]));
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
      expect(fixture.factory.adapter.requests.length).assertEqual(0);
      expect(fixture.store.getOperation('operation:' + handle.taskId + ':step-1') === undefined).assertTrue();
    });

    it('recordsAdapterRejectionAsNotExecutedAndReleasesLease', 0, async () => {
      const fixture: BridgeFixture = await openBridgeFixture();
      fixture.factory.adapter.accept = false;
      const taskId: string = await authorize(fixture, 'bridge-adapter-rejected');
      expect(fixture.factory.adapter.requests.length).assertEqual(1);
      const dispatched: StepDispatchRequest = fixture.factory.adapter.requests[0];
      const operation: StoredOperation | undefined =
        fixture.store.getOperation(dispatched.persistenceContext?.operationId as string);
      expect(operation?.state).assertEqual(OperationJournalState.PREPARED);
      expect(operation?.dispatchCount).assertEqual(1);
      expect(fixture.store.getLease(taskId) === undefined).assertTrue();
    });

    it('keepsUnknownOutcomeHeldUntilEvidenceBackedReconciliation', 0, async () => {
      const fixture: BridgeFixture = await openBridgeFixture();
      const taskId: string = await authorize(fixture, 'bridge-unknown');
      const dispatched: StepDispatchRequest = fixture.factory.adapter.requests[0];
      const operationId: string = dispatched.persistenceContext?.operationId as string;
      const unknown: ToolOutcome = bridgeOutcome(dispatched, ToolOutcomeStatus.UNKNOWN_OUTCOME);
      await (fixture.factory.adapter.sink as RuntimeToolOutcomeSinkPort).complete(
        taskId, dispatched.step.stepId, dispatched.dispatchId, unknown);
      expect(fixture.store.getOperation(operationId)?.state).assertEqual(OperationJournalState.UNKNOWN_OUTCOME);
      expect(fixture.store.getLease(taskId) === undefined).assertTrue();

      const report: ReconciliationReport = new ReconciliationReport();
      report.commandId = 'reconcile:' + taskId;
      report.taskId = taskId;
      report.stepId = dispatched.step.stepId;
      report.operationId = operationId;
      report.status = ReconciliationStatus.STILL_UNKNOWN;
      report.evidenceDigest = 'sha256:evidence';
      report.reportedAt = '2026-10-09T00:00:01.000Z';
      expect((await fixture.bridge.recordReconciliation(report, 1100)).duplicate).assertTrue();
      expect(fixture.store.getOperation(operationId)?.state).assertEqual(OperationJournalState.UNKNOWN_OUTCOME);

      const settled: ToolOutcome = bridgeOutcome(dispatched, ToolOutcomeStatus.SUCCEEDED);
      settled.providerReceipt = 'receipt-1';
      fixture.settlement.outcome = settled;
      report.status = ReconciliationStatus.CONFIRMED_SUCCEEDED;
      report.providerReceipt = 'receipt-1';
      expect((await fixture.bridge.recordReconciliation(report, 1200)).accepted).assertTrue();
      expect(fixture.store.getOperation(operationId)?.state).assertEqual(OperationJournalState.COMMITTED);
      expect(fixture.store.getBudgetReservation(dispatched.persistenceContext?.budgetReservationId as string)?.
        snapshot.state).assertEqual(BudgetReservationState.SETTLED);
      expect(fixture.store.getLease(taskId) === undefined).assertTrue();
    });
  });
}
