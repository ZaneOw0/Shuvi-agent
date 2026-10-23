import { describe, expect, it } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import common from '@ohos.app.ability.common';
import relationalStore from '@ohos.data.relationalStore';
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
  RiskLevel,
  SideEffect,
  TaskSubmission,
  ToolInvocation,
  WorkflowGraph,
  WorkflowStep,
  WorkflowStepKind
} from '@harmony_agent/agent-contracts';
import {
  BudgetReservationState,
  OperationJournalState
} from '@harmony_agent/agent-core';
import {
  AgentRuntimeFacade,
  AgentRuntimeObserver,
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
  RuntimeToolOutcomeSinkPort,
  SemanticPlannerPort,
  ShutdownMode,
  StepDispatchPort,
  StepDispatchReceipt,
  StepDispatchRequest,
  SubscriptionRequest,
  ToolInvocationPreparerPort
} from '@harmony_agent/agent-runtime';
import {
  AGENT_STORAGE_VERSION,
  DurableExecutionRecoveryStore,
  RdbSnapshotBackend,
  RuntimeExecutionRecoveryBridgeConfig,
  SnapshotIntegrityPort,
  createRdbRecoveredAgentRuntime
} from '@harmony_agent/agent-storage';

const DATABASE_NAME: string = 'harmony_agent_runtime_recovery.db';

class DeviceRuntimeIntegrity implements SnapshotIntegrityPort {
  digest(payloadJson: string): string {
    return 'runtime-device-digest:' + payloadJson;
  }
}

class DeviceRuntimeClock implements RuntimeClockPort {
  nowMs(): number {
    return 1000;
  }
}

class DeviceRuntimeIds implements RuntimeIdGeneratorPort {
  private next: number = 0;

  nextId(kind: string, requestId: string): string {
    this.next++;
    return kind + ':' + requestId + ':' + this.next.toString();
  }
}

class DeviceRuntimeCollaboration implements CollaborationSelectorPort {
  select(): CollaborationMode {
    return CollaborationMode.SINGLE;
  }
}

function devicePlan(request: PlanningRequest): PlanningResult {
  const step: WorkflowStep = new WorkflowStep();
  step.stepId = 'step-1';
  step.kind = WorkflowStepKind.TOOL;
  step.goal = 'persist a device-side active operation';
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
  graph.createdAt = '2026-10-11T00:00:00.000Z';
  graph.steps = [step];
  graph.entryStepIds = [step.stepId];
  const result: PlanningResult = new PlanningResult();
  result.status = PlanningStatus.READY;
  result.workflow = graph;
  return result;
}

class DeviceRuntimePlanner implements SemanticPlannerPort {
  async plan(request: PlanningRequest): Promise<PlanningResult> {
    return devicePlan(request);
  }

  async resume(request: PlanningRequest): Promise<PlanningResult> {
    return devicePlan(request);
  }

  async replan(request: PlanningRequest): Promise<PlanningResult> {
    return devicePlan(request);
  }

  interrupt(taskId: string): boolean {
    return false;
  }
}

class DeviceRuntimeToolPreparer implements ToolInvocationPreparerPort {
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
    policy.schemaDigest = 'sha256:schema-device-runtime';
    policy.argumentsDigest = 'sha256:arguments-device-runtime';
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
    invocation.argumentsJson = '{"title":"device recovery"}';
    invocation.argumentsDigest = policy.argumentsDigest;
    invocation.idempotencyKey = 'idempotency:' + invocation.operationId;
    invocation.timeoutMs = step.timeoutMs;
    invocation.createdAt = new Date(nowMs).toISOString();
    return prepared;
  }
}

class DeviceRuntimeAdapter implements StepDispatchPort {
  requests: StepDispatchRequest[] = [];

  dispatch(request: StepDispatchRequest): StepDispatchReceipt {
    this.requests.push(request);
    const receipt: StepDispatchReceipt = new StepDispatchReceipt();
    receipt.accepted = true;
    return receipt;
  }

  cancel(_dispatchId: string): boolean {
    return false;
  }
}

class DeviceRuntimeAdapterFactory implements ProductionRuntimeAdapterFactoryPort {
  readonly adapter: DeviceRuntimeAdapter = new DeviceRuntimeAdapter();

  create(_sink: RuntimeToolOutcomeSinkPort): StepDispatchPort {
    return this.adapter;
  }
}

class DeviceRuntimeObserver implements AgentRuntimeObserver {
  policies: PolicyRequest[] = [];

  onEvent(_event: AgentRuntimeEvent): void {
  }

  onPolicyRequest(request: PolicyRequest): void {
    this.policies.push(ContractCodec.parsePolicyRequest(ContractCodec.stringify(request)));
  }

  onClarificationRequest(_request: ClarificationRequest): void {
  }
}

function runtimeConfig(): ProductionAgentRuntimeConfig {
  const value: ProductionAgentRuntimeConfig = new ProductionAgentRuntimeConfig();
  value.policyVersion = 'policy-v1';
  value.grantTtlMs = 30000;
  return value;
}

function bridgeConfig(ownerId: string): RuntimeExecutionRecoveryBridgeConfig {
  const value: RuntimeExecutionRecoveryBridgeConfig = new RuntimeExecutionRecoveryBridgeConfig();
  value.ownerId = ownerId;
  value.leaseTtlMs = 30000;
  value.policyVersion = 'policy-v1';
  return value;
}

function runtimePorts(factory: DeviceRuntimeAdapterFactory): ProductionAgentRuntimePorts {
  const value: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
  value.clock = new DeviceRuntimeClock();
  value.ids = new DeviceRuntimeIds();
  value.planner = new DeviceRuntimePlanner();
  value.collaboration = new DeviceRuntimeCollaboration();
  value.toolPreparer = new DeviceRuntimeToolPreparer();
  value.adapterFactory = factory;
  return value;
}

function requestedBudget(): ExecutionBudget {
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

function submission(): TaskSubmission {
  const value: TaskSubmission = new TaskSubmission();
  value.requestId = 'runtime-rdb-device-recovery';
  value.userId = 'device-user';
  value.userIntent = 'persist active operation for process restart';
  value.locale = 'zh-CN';
  value.timeZone = 'Asia/Shanghai';
  value.referenceTime = '2026-10-11T00:00:00.000Z';
  value.requestedBudget = requestedBudget();
  value.submittedAt = '2026-10-11T00:00:00.000Z';
  return value;
}

function decision(taskId: string, request: PolicyRequest): AuthorizationDecision {
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

function selectedTestCases(): string {
  return abilityDelegatorRegistry.getArguments().testCaseNames;
}

async function appContext(): Promise<common.UIAbilityContext> {
  try {
    const ability = await abilityDelegatorRegistry.getAbilityDelegator().getCurrentTopAbility();
    return ability.context;
  } catch (error) {
    throw error as Error;
  }
}

function storeConfig(): relationalStore.StoreConfig {
  return {
    name: DATABASE_NAME,
    securityLevel: relationalStore.SecurityLevel.S1
  };
}

async function deleteStore(context: common.Context, config: relationalStore.StoreConfig): Promise<void> {
  try {
    await relationalStore.deleteRdbStore(context, config);
  } catch (error) {
    throw error as Error;
  }
}

async function openStore(context: common.Context,
  config: relationalStore.StoreConfig): Promise<relationalStore.RdbStore> {
  try {
    return await relationalStore.getRdbStore(context, config);
  } catch (error) {
    throw error as Error;
  }
}

function closeStore(store: relationalStore.RdbStore): void {
  try {
    store.close();
  } catch (error) {
    throw error as Error;
  }
}

async function printSeedReady(marker: string): Promise<void> {
  try {
    await abilityDelegatorRegistry.getAbilityDelegator().print(marker);
  } catch (error) {
    throw error as Error;
  }
}

async function seedActiveOperation(context: common.Context,
  config: relationalStore.StoreConfig): Promise<void> {
  await deleteStore(context, config);
  const rdb: relationalStore.RdbStore = await openStore(context, config);
  const factory: DeviceRuntimeAdapterFactory = new DeviceRuntimeAdapterFactory();
  const runtime: AgentRuntimeFacade = await createRdbRecoveredAgentRuntime(
    rdb, new DeviceRuntimeIntegrity(), bridgeConfig('device-owner-seed'),
    runtimeConfig(), runtimePorts(factory));
  const handle = await runtime.submitTask(submission());
  const observer: DeviceRuntimeObserver = new DeviceRuntimeObserver();
  const request: SubscriptionRequest = new SubscriptionRequest();
  request.subscriptionId = 'runtime-rdb-seed-subscription';
  request.taskId = handle.taskId;
  await runtime.subscribe(request, observer);
  expect(observer.policies.length).assertEqual(1);
  expect((await runtime.provideAuthorization(decision(handle.taskId, observer.policies[0]))).accepted).assertTrue();
  expect(factory.adapter.requests.length).assertEqual(1);
  expect((await runtime.getTaskSnapshot(handle.taskId)).status).assertEqual(AgentTaskStatus.RUNNING);
  // Deliberately keep Runtime and RDB open. The acceptance script force-stops
  // this process after the seed invocation to create the crash boundary.
}

async function recoverActiveOperation(context: common.Context,
  config: relationalStore.StoreConfig): Promise<void> {
  let rdb: relationalStore.RdbStore | undefined = undefined;
  let runtime: AgentRuntimeFacade | undefined = undefined;
  try {
    rdb = await openStore(context, config);
    const factory: DeviceRuntimeAdapterFactory = new DeviceRuntimeAdapterFactory();
    runtime = await createRdbRecoveredAgentRuntime(
      rdb, new DeviceRuntimeIntegrity(), bridgeConfig('device-owner-recover'),
      runtimeConfig(), runtimePorts(factory));
    const opened = await DurableExecutionRecoveryStore.openForRuntimeRecovery(
      new RdbSnapshotBackend(rdb), new DeviceRuntimeIntegrity());
    expect(opened.accepted).assertTrue();
    if (opened.store === undefined) throw new Error('recovered RDB session is missing');
    const taskIds: string[] = opened.store.listTaskIds();
    expect(taskIds.length).assertEqual(1);
    const taskId: string = taskIds[0];
    const operationId: string = 'operation:' + taskId + ':step-1';
    expect((await runtime.getTaskSnapshot(taskId)).status)
      .assertEqual(AgentTaskStatus.WAITING_RECONCILIATION);
    expect(factory.adapter.requests.length).assertEqual(0);
    const operation = opened.store.getOperation(operationId);
    expect(operation?.state).assertEqual(OperationJournalState.UNKNOWN_OUTCOME);
    expect(opened.store.getBudgetReservation(operation?.intent.budgetReservationId as string)?.snapshot.state)
      .assertEqual(BudgetReservationState.UNKNOWN);
    expect(opened.store.getLease(taskId) === undefined).assertTrue();
  } finally {
    if (runtime !== undefined) await runtime.shutdown(ShutdownMode.IMMEDIATE);
    if (rdb !== undefined) closeStore(rdb);
    await deleteStore(context, config);
  }
}

export default function runtimeRdbDeviceRecoveryTest(): void {
  describe('RuntimeRdbDeviceRecoverySeed', () => {
    it('persistsActiveOperationUntilForceStop', 0, async () => {
      expect(AGENT_STORAGE_VERSION).assertEqual('0.8.0');
      if (selectedTestCases().indexOf('RuntimeRdbDeviceRecoverySeed') < 0) return;
      const context: common.Context = await appContext();
      const config: relationalStore.StoreConfig = storeConfig();
      await seedActiveOperation(context, config);
      await printSeedReady('T26_SEED_READY');
      // Keep the instrumented process alive. The host acceptance script
      // observes the marker and PID, then force-stops it.
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 600000);
      });
    });
  });

  describe('RuntimeRdbDeviceRecoveryRecover', () => {
    it('normalizesActiveOperationAfterForceStop', 0, async () => {
      expect(AGENT_STORAGE_VERSION).assertEqual('0.8.0');
      if (selectedTestCases().indexOf('RuntimeRdbDeviceRecoveryRecover') < 0) return;
      const context: common.Context = await appContext();
      const config: relationalStore.StoreConfig = storeConfig();
      await recoverActiveOperation(context, config);
    });
  });
}
