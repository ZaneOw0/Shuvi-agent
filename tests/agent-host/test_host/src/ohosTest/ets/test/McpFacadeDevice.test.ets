import { describe, expect, it } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import {
  AgentRuntimeEvent,
  AgentTaskSnapshot,
  AgentTaskStatus,
  AuthorizationDecision,
  AuthorizationDecisionType,
  ClarificationRequest,
  ClarificationResponse,
  CollaborationMode,
  DataBoundary,
  ExecutionBudget,
  IdempotencyMode,
  PolicyRequest,
  ReconciliationReport,
  RiskLevel,
  SideEffect,
  TaskHandle,
  TaskSubmission,
  ToolInvocation,
  ToolOutcome,
  WorkflowGraph,
  WorkflowStep,
  WorkflowStepKind
} from '@harmony_agent/agent-contracts';
import {
  AgentRuntimeFacade,
  AgentRuntimeObserver,
  AgentSubscription,
  DispatchPersistenceContext,
  PlanningRequest,
  PlanningResult,
  PlanningStatus,
  PreparedToolDispatch,
  ProductionAgentRuntimeConfig,
  ProductionAgentRuntimePorts,
  ProductionRuntimePersistencePort,
  RuntimeClockPort,
  RuntimeDurableAuthorityPayload,
  RuntimeIdGeneratorPort,
  RuntimePersistenceCode,
  RuntimePersistenceResult,
  RuntimeTaskRecoveryCheckpoint,
  SemanticPlannerPort,
  ShutdownMode,
  SubscriptionRequest,
  ToolInvocationPreparerPort,
  ToolRegistry
} from '@harmony_agent/agent-runtime';
import {
  ConnectorClockPort,
  ConnectorDigestPort,
  McpAgentAdapter,
  McpClientManagerToolPort,
  McpGrantVerification,
  McpGrantVerifierPort,
  McpInvocationPolicyBridge,
  McpProviderRegistry,
  McpReadOnlyToolPolicy,
  McpReadOnlyToolPolicyRegistry,
  canonicalJson,
  createMcpProductionAgentRuntime
} from '@harmony_agent/agent-connectors';
import {
  MCP_CLIENT_VERSION,
  McpCapabilityKind,
  McpClientManager,
  McpProtocolMode,
  McpReadResourceResult,
  McpServerProfile
} from '@harmony_agent/mcp-client';

function fixtureUrl(): string {
  const parameters: Record<string, string> = abilityDelegatorRegistry.getArguments().parameters;
  const directValue: string | undefined = parameters['fixtureUrl'];
  if (directValue !== undefined) return directValue;
  const literalValue: string | undefined = parameters['-s fixtureUrl'];
  return literalValue === undefined ? '' : literalValue;
}

export class DeviceDigest implements ConnectorDigestPort {
  digest(value: string): string {
    return 'device-digest:' + value;
  }
}

export class DeviceConnectorClock implements ConnectorClockPort {
  nowIso(): string {
    return new Date().toISOString();
  }
}

export class DeviceGrantVerifier implements McpGrantVerifierPort {
  verify(invocation: ToolInvocation): McpGrantVerification {
    const result: McpGrantVerification = new McpGrantVerification();
    result.allowed = invocation.authorizationGrantId.trim().length > 0;
    result.code = result.allowed ? 'GRANT_ACCEPTED' : 'GRANT_REQUIRED';
    return result;
  }
}

export class DeviceRuntimeClock implements RuntimeClockPort {
  nowMs(): number {
    return Date.now();
  }
}

export class DeviceIds implements RuntimeIdGeneratorPort {
  private next: number = 0;

  nextId(kind: string, requestId: string): string {
    this.next++;
    return kind + ':' + requestId + ':' + this.next.toString();
  }
}

class DevicePlanner implements SemanticPlannerPort {
  private readonly registry: ToolRegistry;

  constructor(registry: ToolRegistry) {
    this.registry = registry;
  }

  async plan(request: PlanningRequest): Promise<PlanningResult> {
    return this.ready(request);
  }

  async resume(request: PlanningRequest, _response: ClarificationResponse): Promise<PlanningResult> {
    return this.ready(request);
  }

  async replan(request: PlanningRequest): Promise<PlanningResult> {
    return this.ready(request);
  }

  interrupt(taskId: string): boolean {
    return false;
  }

  private ready(request: PlanningRequest): PlanningResult {
    const result: PlanningResult = new PlanningResult();
    if (request.collaborationMode !== CollaborationMode.SINGLE ||
      this.registry.activeEntries().length !== 1) {
      result.status = PlanningStatus.REJECTED;
      result.rejectionCode = 'MCP_DEVICE_CATALOG_NOT_READY';
      return result;
    }
    const graph: WorkflowGraph = new WorkflowGraph();
    graph.workflowId = 'workflow:' + request.envelope.taskId;
    graph.taskId = request.envelope.taskId;
    graph.workflowVersion = '1';
    graph.createdAt = new Date().toISOString();
    const step: WorkflowStep = new WorkflowStep();
    step.stepId = 'echo-device';
    step.kind = WorkflowStepKind.TOOL;
    step.goal = 'Echo one controlled device-network value';
    step.capabilityRequirements = ['echo', 'read-only'];
    step.expectedOutputSchemaJson = '{"type":"object"}';
    step.riskLevel = RiskLevel.LOW;
    step.sideEffect = SideEffect.NONE;
    step.idempotencyMode = IdempotencyMode.NONE;
    step.retryPolicyRef = 'no-tool-retry';
    step.verificationPolicyRef = 'fixture-echo-result';
    step.timeoutMs = 5000;
    graph.steps = [step];
    graph.entryStepIds = [step.stepId];
    result.status = PlanningStatus.READY;
    result.workflow = graph;
    return result;
  }
}

export class DeviceToolPreparer implements ToolInvocationPreparerPort {
  private readonly registry: ToolRegistry;
  private readonly digest: ConnectorDigestPort;

  constructor(registry: ToolRegistry, digest: ConnectorDigestPort) {
    this.registry = registry;
    this.digest = digest;
  }

  prepare(request: PlanningRequest, step: WorkflowStep, nowMs: number): PreparedToolDispatch {
    const entry = this.registry.activeEntries()[0];
    const argumentsJson: string = '{"text":"facade-device-network"}';
    const argumentsDigest: string = this.digest.digest(canonicalJson(JSON.parse(argumentsJson) as Object));
    const prepared: PreparedToolDispatch = new PreparedToolDispatch();
    const policy: PolicyRequest = prepared.policyRequest;
    policy.requestId = 'policy:' + request.envelope.taskId + ':' + step.stepId;
    policy.userId = request.envelope.userId;
    policy.taskId = request.envelope.taskId;
    policy.stepId = step.stepId;
    policy.operationId = 'operation:' + request.envelope.taskId + ':' + step.stepId;
    policy.toolId = entry.descriptor.toolId;
    policy.toolIdentityVersion = entry.descriptor.toolIdentityVersion;
    policy.providerId = entry.descriptor.providerId;
    policy.schemaDigest = entry.descriptor.schemaDigest;
    policy.argumentsDigest = argumentsDigest;
    policy.riskLevel = step.riskLevel;
    policy.sideEffect = step.sideEffect;
    policy.estimatedCostMicros = entry.estimatedCostMicros;
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
    invocation.argumentsJson = argumentsJson;
    invocation.argumentsDigest = argumentsDigest;
    invocation.idempotencyKey = 'read:' + invocation.operationId;
    invocation.authorizationGrantId = '';
    invocation.timeoutMs = step.timeoutMs;
    invocation.createdAt = policy.requestedAt;
    return prepared;
  }
}

function saved(): Promise<RuntimePersistenceResult> {
  const result: RuntimePersistenceResult = new RuntimePersistenceResult();
  result.accepted = true;
  result.code = RuntimePersistenceCode.SAVED;
  return Promise.resolve(result);
}

export class DevicePersistence implements ProductionRuntimePersistencePort {
  saveCheckpoint(_checkpoint: RuntimeTaskRecoveryCheckpoint, _expectedPreviousVersion: number,
    _authority: RuntimeDurableAuthorityPayload, _nowMs: number): Promise<RuntimePersistenceResult> {
    return saved();
  }

  loadCheckpoint(_taskId: string): Promise<RuntimeTaskRecoveryCheckpoint | undefined> {
    return Promise.resolve(undefined);
  }

  normalizeRecoveredOperation(_checkpoint: RuntimeTaskRecoveryCheckpoint, _expectedPreviousVersion: number,
    _nowMs: number): Promise<RuntimePersistenceResult> {
    return saved();
  }

  beforeDispatch(_checkpoint: RuntimeTaskRecoveryCheckpoint, _expectedPreviousVersion: number,
    _context: DispatchPersistenceContext | undefined, _authority: RuntimeDurableAuthorityPayload,
    _nowMs: number): Promise<RuntimePersistenceResult> {
    return saved();
  }

  recordDispatchRejected(_context: DispatchPersistenceContext | undefined, _dispatchId: string,
    _rejectionCode: string, _nowMs: number): Promise<RuntimePersistenceResult> {
    return saved();
  }

  recordOutcome(_taskId: string, _stepId: string, _dispatchId: string, _outcome: ToolOutcome,
    _nowMs: number): Promise<RuntimePersistenceResult> {
    return saved();
  }

  recordReconciliation(_report: ReconciliationReport, _nowMs: number): Promise<RuntimePersistenceResult> {
    return saved();
  }
}

export class DeviceObserver implements AgentRuntimeObserver {
  policies: PolicyRequest[] = [];

  onEvent(_event: AgentRuntimeEvent): void {
  }

  onPolicyRequest(request: PolicyRequest): void {
    this.policies.push(request);
  }

  onClarificationRequest(_request: ClarificationRequest): void {
  }
}

function submission(): TaskSubmission {
  const budget: ExecutionBudget = new ExecutionBudget();
  budget.maxWallTimeMs = 60000;
  budget.maxInputTokens = 1000;
  budget.maxOutputTokens = 1000;
  budget.maxMonetaryCostMicros = 1000;
  budget.maxToolCalls = 2;
  budget.maxAgentActivations = 1;
  budget.maxRetries = 0;
  budget.maxReplans = 0;
  const now: string = new Date().toISOString();
  const value: TaskSubmission = new TaskSubmission();
  value.requestId = 'request-mcp-facade-device';
  value.userId = 'device-user';
  value.userIntent = 'Echo one controlled value through MCP';
  value.locale = 'zh-CN';
  value.timeZone = 'Asia/Shanghai';
  value.referenceTime = now;
  value.requestedBudget = budget;
  value.submittedAt = now;
  return value;
}

export function stats(result: McpReadResourceResult): number {
  const resource: Record<string, Object> = result.contents[0].resource as Record<string, Object>;
  const value: Record<string, Object> = JSON.parse(String(resource['text'])) as Record<string, Object>;
  return Number(value['toolCalls']);
}

export async function waitForCompletion(runtime: AgentRuntimeFacade, taskId: string): Promise<AgentTaskSnapshot> {
  let snapshot: AgentTaskSnapshot = await runtime.getTaskSnapshot(taskId);
  for (let i: number = 0; i < 100 && snapshot.status !== AgentTaskStatus.COMPLETED; i++) {
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 50);
    });
    snapshot = await runtime.getTaskSnapshot(taskId);
  }
  return snapshot;
}

export default function mcpFacadeDeviceTest(): void {
  describe('McpFacadeDevice', () => {
    it('completesAuthorizedReadOnlyTaskOverRealMcpNetworkExactlyOnce', 0, async () => {
      const baseUrl: string = fixtureUrl();
      expect(baseUrl.length > 0).assertTrue();
      const digest: DeviceDigest = new DeviceDigest();
      const bridge: McpInvocationPolicyBridge = new McpInvocationPolicyBridge(digest);
      const manager: McpClientManager = new McpClientManager({
        clientName: 'harmony_agent Facade Device Test',
        clientVersion: MCP_CLIENT_VERSION,
        debugBuild: true,
        invocationPolicy: bridge
      });
      const profile: McpServerProfile = {
        id: 'facade-device',
        endpoint: `${baseUrl}/modern`,
        protocolMode: McpProtocolMode.MODERN,
        allowInsecureHttp: true,
        connectTimeoutMs: 5000,
        requestTimeoutMs: 5000
      };
      manager.registerServer(profile);
      let runtime: AgentRuntimeFacade | undefined = undefined;
      try {
        await manager.connect(profile.id);
        const before: number = stats(await manager.readResource({
          serverId: profile.id,
          kind: McpCapabilityKind.RESOURCE,
          name: 'fixture://stats'
        }));
        const providers: McpProviderRegistry = new McpProviderRegistry(digest);
        expect(providers.register(profile, 'profile-v1')).assertTrue();
        const policies: McpReadOnlyToolPolicyRegistry = new McpReadOnlyToolPolicyRegistry();
        const policy: McpReadOnlyToolPolicy = new McpReadOnlyToolPolicy();
        policy.serverId = profile.id;
        policy.toolName = 'echo';
        policy.capabilityTags = ['echo', 'read-only'];
        policy.permissionRequirements = ['network'];
        policy.riskLevel = RiskLevel.LOW;
        policy.dataBoundary = DataBoundary.REMOTE_ALLOWED;
        policy.estimatedCostMicros = 0;
        expect(policies.register(policy)).assertTrue();
        const adapter: McpAgentAdapter = new McpAgentAdapter(
          new McpClientManagerToolPort(manager), providers, policies, digest,
          new DeviceConnectorClock(), new DeviceGrantVerifier(), bridge);
        const registry: ToolRegistry = new ToolRegistry();
        const config: ProductionAgentRuntimeConfig = new ProductionAgentRuntimeConfig();
        config.policyVersion = 'policy-v1';
        config.grantTtlMs = 30000;
        const ports: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
        ports.clock = new DeviceRuntimeClock();
        ports.ids = new DeviceIds();
        ports.planner = new DevicePlanner(registry);
        ports.toolPreparer = new DeviceToolPreparer(registry, digest);
        ports.persistence = new DevicePersistence();
        runtime = await createMcpProductionAgentRuntime(config, ports, adapter, registry);
        const handle: TaskHandle = await runtime.submitTask(submission());
        expect((await runtime.getTaskSnapshot(handle.taskId)).status)
          .assertEqual(AgentTaskStatus.WAITING_AUTHORIZATION);
        const observer: DeviceObserver = new DeviceObserver();
        const subscriptionRequest: SubscriptionRequest = new SubscriptionRequest();
        subscriptionRequest.subscriptionId = 'subscription:mcp-facade-device';
        subscriptionRequest.taskId = handle.taskId;
        const subscription: AgentSubscription = await runtime.subscribe(subscriptionRequest, observer);
        expect(observer.policies.length).assertEqual(1);
        const decision: AuthorizationDecision = new AuthorizationDecision();
        decision.commandId = 'authorize:mcp-facade-device';
        decision.policyRequestId = observer.policies[0].requestId;
        decision.userId = 'device-user';
        decision.taskId = handle.taskId;
        decision.decision = AuthorizationDecisionType.APPROVED;
        decision.decidedAtMs = Date.now();
        decision.decidedAt = new Date(decision.decidedAtMs).toISOString();
        await runtime.provideAuthorization(decision);
        const snapshot: AgentTaskSnapshot = await waitForCompletion(runtime, handle.taskId);
        const after: number = stats(await manager.readResource({
          serverId: profile.id,
          kind: McpCapabilityKind.RESOURCE,
          name: 'fixture://stats'
        }));
        expect(snapshot.status).assertEqual(AgentTaskStatus.COMPLETED);
        expect(after - before).assertEqual(1);
        subscription.close();
      } finally {
        if (runtime !== undefined) await runtime.shutdown(ShutdownMode.GRACEFUL);
        await manager.disconnectAll();
      }
    });
  });
}
