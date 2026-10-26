import { describe, expect, it } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import {
  AgentTaskSnapshot,
  AgentTaskStatus,
  AuthorizationDecision,
  AuthorizationDecisionType,
  DataBoundary,
  ExecutionBudget,
  PrivacyClass,
  RiskLevel,
  TaskHandle,
  TaskSubmission
} from '@harmony_agent/agent-contracts';
import {
  AgentRuntimeFacade,
  AgentSubscription,
  PlanningStatus,
  ProductionAgentRuntimeConfig,
  ProductionAgentRuntimePorts,
  ShutdownMode,
  SubscriptionRequest,
  ToolRegistry
} from '@harmony_agent/agent-runtime';
import {
  ArkTsLocalAIGatewayHttpClient,
  LocalAIGatewayMcpRuntimeConfig,
  LocalAIGatewayMcpRuntimePorts,
  McpAgentAdapter,
  McpClientManagerToolPort,
  McpInvocationPolicyBridge,
  McpProviderRegistry,
  McpReadOnlyToolPolicy,
  McpReadOnlyToolPolicyRegistry,
  ProviderCredential,
  ProviderCredentialPort,
  ProviderPlannerTrace,
  ProviderPriceSnapshot,
  ProviderSemanticPlannerConfig,
  ProviderSemanticPlannerObserverPort,
  SystemProviderTimer,
  createLocalAIGatewayMcpProductionAgentRuntime
} from '@harmony_agent/agent-connectors';
import {
  MCP_CLIENT_VERSION,
  McpCapabilityKind,
  McpClientManager,
  McpProtocolMode,
  McpServerProfile
} from '@harmony_agent/mcp-client';
import {
  DeviceConnectorClock,
  DeviceDigest,
  DeviceGrantVerifier,
  DeviceIds,
  DeviceObserver,
  DevicePersistence,
  DeviceRuntimeClock,
  DeviceToolPreparer,
  stats,
  waitForCompletion
} from './McpFacadeDevice.test';

function parameter(name: string): string {
  const parameters: Record<string, string> = abilityDelegatorRegistry.getArguments().parameters;
  const direct: string | undefined = parameters[name];
  if (direct !== undefined) return direct;
  const literal: string | undefined = parameters['-s ' + name];
  return literal === undefined ? '' : literal;
}

function port(name: string): number {
  const text: string = parameter(name);
  if (!/^\d+$/.test(text)) return 0;
  const value: number = Number(text);
  return value >= 1 && value <= 65535 ? value : 0;
}

class DeviceGatewayCredentialPort implements ProviderCredentialPort {
  calls: number = 0;

  resolve(providerId: string, scope: string): Promise<ProviderCredential> {
    this.calls++;
    if (providerId !== 'local-ai-gateway' || scope !== 'gateway.invoke') {
      return Promise.reject(new Error('Unexpected device gateway credential scope'));
    }
    const credential: ProviderCredential = new ProviderCredential();
    credential.headers['Authorization'] = 'Bearer device-test';
    return Promise.resolve(credential);
  }
}

class DevicePlannerObserver implements ProviderSemanticPlannerObserverPort {
  traces: ProviderPlannerTrace[] = [];

  onGenerationCompleted(trace: ProviderPlannerTrace): void {
    this.traces.push(trace);
  }
}

function gatewayConfig(gatewayPort: number): LocalAIGatewayMcpRuntimeConfig {
  const result: LocalAIGatewayMcpRuntimeConfig = new LocalAIGatewayMcpRuntimeConfig();
  result.runtimeConfig = new ProductionAgentRuntimeConfig();
  result.runtimeConfig.policyVersion = 'policy-v1';
  result.runtimeConfig.grantTtlMs = 30000;
  result.plannerConfig = new ProviderSemanticPlannerConfig();
  result.plannerConfig.promptVersion = 'typed-workflow-v1';
  result.plannerConfig.estimatedInputTokens = 1000;
  result.plannerConfig.maxOutputTokens = 8192;
  result.plannerConfig.temperature = 0;
  result.plannerConfig.timeoutMs = 60000;
  result.plannerConfig.clarificationTtlMs = 60000;
  result.plannerConfig.maxSteps = 2;
  result.plannerConfig.maxPromptCharacters = 30000;
  result.transportProfile.baseUrl = `http://127.0.0.1:${gatewayPort}/v1`;
  result.transportProfile.modelVersion = 'device-facade-revision-12';
  result.transportProfile.maxInputTokens = 8192;
  result.transportProfile.maxOutputTokens = 8192;
  result.transportProfile.qualityTier = 1;
  result.transportProfile.privacyClasses = [PrivacyClass.PUBLIC];
  result.transportProfile.available = true;
  result.transportProfile.connectTimeoutMs = 5000;
  const price: ProviderPriceSnapshot = result.priceSnapshot;
  price.snapshotId = 'device-facade-price-revision-12';
  price.providerId = result.transportProfile.providerId;
  price.capabilityId = result.transportProfile.publicModelAlias;
  price.capabilityVersion = result.transportProfile.modelVersion;
  price.region = result.transportProfile.region;
  price.currency = 'USD';
  // Fixed acceptance-only cost snapshot; this is not production billing evidence.
  price.inputMicrosPerMillionTokens = 1000000;
  price.outputMicrosPerMillionTokens = 2000000;
  price.fixedCostMicros = 3;
  price.effectiveAt = '2026-10-15T00:00:00.000Z';
  price.snapshotDigest = 'device-facade-price-digest-revision-12';
  return result;
}

function submission(): TaskSubmission {
  const budget: ExecutionBudget = new ExecutionBudget();
  budget.maxWallTimeMs = 90000;
  budget.maxInputTokens = 4096;
  budget.maxOutputTokens = 8192;
  budget.maxMonetaryCostMicros = 10000000;
  budget.maxToolCalls = 2;
  budget.maxAgentActivations = 1;
  budget.maxRetries = 0;
  budget.maxReplans = 0;
  const now: string = new Date().toISOString();
  const result: TaskSubmission = new TaskSubmission();
  result.requestId = 'request-local-gateway-facade-device';
  result.userId = 'device-user';
  result.userIntent = 'Create exactly one read-only tool step using the echo and read-only capabilities. ' +
    'Use sideEffect none, idempotency none, risk low, no dependencies, no permissions, a JSON object output, ' +
    'and do not create LLM, confirmation, verification, or join steps.';
  result.locale = 'en-US';
  result.timeZone = 'Asia/Shanghai';
  result.referenceTime = now;
  result.privacyClass = PrivacyClass.PUBLIC;
  result.requestedBudget = budget;
  result.submittedAt = now;
  return result;
}

export default function localAIGatewayFacadeDeviceTest(): void {
  describe('LocalAIGatewayFacadeDevice', () => {
    it('plansWithOfficialProviderAndCompletesAuthorizedMcpTaskExactlyOnce', 0, async () => {
      const gatewayPort: number = port('gatewayPort');
      const mcpPort: number = port('mcpPort');
      expect(gatewayPort > 0).assertTrue();
      expect(mcpPort > 0).assertTrue();
      const digest: DeviceDigest = new DeviceDigest();
      const bridge: McpInvocationPolicyBridge = new McpInvocationPolicyBridge(digest);
      const manager: McpClientManager = new McpClientManager({
        clientName: 'harmony_agent Gateway Facade Device Test',
        clientVersion: MCP_CLIENT_VERSION,
        debugBuild: true,
        invocationPolicy: bridge
      });
      const mcpProfile: McpServerProfile = {
        id: 'gateway-facade-device',
        endpoint: `http://127.0.0.1:${mcpPort}/modern`,
        protocolMode: McpProtocolMode.MODERN,
        allowInsecureHttp: true,
        connectTimeoutMs: 5000,
        requestTimeoutMs: 5000
      };
      manager.registerServer(mcpProfile);
      let runtime: AgentRuntimeFacade | undefined = undefined;
      let subscription: AgentSubscription | undefined = undefined;
      try {
        await manager.connect(mcpProfile.id);
        const before: number = stats(await manager.readResource({
          serverId: mcpProfile.id,
          kind: McpCapabilityKind.RESOURCE,
          name: 'fixture://stats'
        }));
        const providers: McpProviderRegistry = new McpProviderRegistry(digest);
        expect(providers.register(mcpProfile, 'profile-t36')).assertTrue();
        const policies: McpReadOnlyToolPolicyRegistry = new McpReadOnlyToolPolicyRegistry();
        const policy: McpReadOnlyToolPolicy = new McpReadOnlyToolPolicy();
        policy.serverId = mcpProfile.id;
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
        const credentials: DeviceGatewayCredentialPort = new DeviceGatewayCredentialPort();
        const plannerObserver: DevicePlannerObserver = new DevicePlannerObserver();
        const runtimePorts: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
        runtimePorts.clock = new DeviceRuntimeClock();
        runtimePorts.ids = new DeviceIds();
        runtimePorts.toolPreparer = new DeviceToolPreparer(registry, digest);
        runtimePorts.persistence = new DevicePersistence();
        const ports: LocalAIGatewayMcpRuntimePorts = new LocalAIGatewayMcpRuntimePorts();
        ports.runtimePorts = runtimePorts;
        ports.digest = digest;
        ports.credentials = credentials;
        ports.timer = new SystemProviderTimer();
        ports.httpClient = new ArkTsLocalAIGatewayHttpClient();
        ports.plannerObserver = plannerObserver;
        runtime = await createLocalAIGatewayMcpProductionAgentRuntime(
          gatewayConfig(gatewayPort), ports, adapter, registry);
        const handle: TaskHandle = await runtime.submitTask(submission());
        expect(credentials.calls).assertEqual(1);
        expect(plannerObserver.traces.length).assertEqual(1);
        expect(plannerObserver.traces[0].planningStatus).assertEqual(PlanningStatus.READY);
        expect(plannerObserver.traces[0].usage.totalTokens > 0).assertTrue();
        expect((await runtime.getTaskSnapshot(handle.taskId)).status)
          .assertEqual(AgentTaskStatus.WAITING_AUTHORIZATION);
        const observer: DeviceObserver = new DeviceObserver();
        const subscriptionRequest: SubscriptionRequest = new SubscriptionRequest();
        subscriptionRequest.subscriptionId = 'subscription:gateway-facade-device';
        subscriptionRequest.taskId = handle.taskId;
        subscription = await runtime.subscribe(subscriptionRequest, observer);
        expect(observer.policies.length).assertEqual(1);
        const decision: AuthorizationDecision = new AuthorizationDecision();
        decision.commandId = 'authorize:gateway-facade-device';
        decision.policyRequestId = observer.policies[0].requestId;
        decision.userId = 'device-user';
        decision.taskId = handle.taskId;
        decision.decision = AuthorizationDecisionType.APPROVED;
        decision.decidedAtMs = Date.now();
        decision.decidedAt = new Date(decision.decidedAtMs).toISOString();
        await runtime.provideAuthorization(decision);
        const snapshot: AgentTaskSnapshot = await waitForCompletion(runtime, handle.taskId);
        const after: number = stats(await manager.readResource({
          serverId: mcpProfile.id,
          kind: McpCapabilityKind.RESOURCE,
          name: 'fixture://stats'
        }));
        expect(snapshot.status).assertEqual(AgentTaskStatus.COMPLETED);
        expect(after - before).assertEqual(1);
      } finally {
        if (subscription !== undefined) subscription.close();
        try {
          if (runtime !== undefined) await runtime.shutdown(ShutdownMode.GRACEFUL);
        } finally {
          await manager.disconnectAll();
        }
      }
    });
  });
}
