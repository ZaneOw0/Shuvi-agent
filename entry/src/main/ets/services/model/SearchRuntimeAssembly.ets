import common from '@ohos.app.ability.common';
import util from '@ohos.util';
import { PrivacyClass } from '@harmony_agent/agent-contracts';
import { AgentApplicationBackend, AgentApplicationBackendConfig, AgentFrontendTaskHandle, AgentFrontendTaskRequest,
  AgentRuntimeFacade, ProductionAgentRuntimeConfig, ProductionAgentRuntimePorts, RuntimeClockPort, RuntimeIdGeneratorPort,
  SingleAgentHostPorts, SingleAgentHostResourcePort, SingleAgentHostRuntimeFactoryPort, ToolRegistry } from '@harmony_agent/agent-runtime';
import { RuntimeExecutionRecoveryBridgeConfig } from '@harmony_agent/agent-storage';
import { McpClientManager, McpManagerOptions, McpServerProfile } from '@harmony_agent/mcp-client';
import { ConnectorClockPort, McpAgentAdapter, McpClientManagerToolPort, McpInvocationPolicyBridge, McpProviderRegistry,
  McpReadOnlyToolPolicyRegistry, SHUVI_WEB_SEARCH_TOOL_ID, ShuviWebSearchMcpClientToolPort, ShuviWebSearchMcpConfig,
  ShuviWebSearchMcpHostResource, ShuviWebSearchToolInvocationPreparer, ShuviWebSearchToolPreparationConfig,
  createMcpProductionAgentRuntime } from '@harmony_agent/agent-connectors';
import { AgentHostDigest } from './AgentHostDigest';
import { AgentRdbOpenPort, NativeAgentRdbOpen } from './AgentRdbResources';
import { SearchExecutionResource } from './SearchExecutionResource';
import { SearchUsageReceipts, SearchUsageMcpAdapter } from './SearchUsageReceipts';
import { SearchPendingInvoice } from './SearchPendingInvoice';
import { PreviewingSearchPreparer, SearchAuthorizationPreviews } from './SearchAuthorizationPreview';
import { SessionModelCredentials } from './SessionModelCredentials';
import { SessionModelHttpClient } from './SessionModelHttpClient';
import { ArkTsDeepSeekHttpClient } from './DeepSeekHttpClient';
import { ShuviRuntimeSession, ShuviRuntimeSessionFactory, ShuviRuntimeSessionPort, ShuviSessionResources } from './ShuviRuntimeSession';
import { UnsettledSearchAccounting } from './RuntimeStartupAssembly';
import { ExplicitSearchPlanner, SEARCH_ACCOUNT, SEARCH_CURRENCY, SEARCH_POLICY, SEARCH_RESERVATION } from './SearchTaskSupport';

class SearchClock implements RuntimeClockPort, ConnectorClockPort {
  nowMs(): number { return Date.now(); }
  nowIso(): string { return new Date().toISOString(); }
}
class SearchIds implements RuntimeIdGeneratorPort {
  nextId(kind: string, _request: string): string { return kind + '-' + util.generateRandomUUID(); }
}
class NoSearchMemory implements SingleAgentHostResourcePort {
  async open(): Promise<void> {}
  async close(): Promise<void> {}
}
class SearchResources implements ShuviSessionResources {
  credentials: SessionModelCredentials = new SessionModelCredentials();
  memory: SingleAgentHostResourcePort = new NoSearchMemory();
  execution: SearchExecutionResource;
  constructor(execution: SearchExecutionResource) { this.execution = execution; }
}
/** Never retry a potentially billed tool call when its MCP session expires. */
export class SingleAttemptSearchManager extends McpClientManager {
  registerServer(profile: McpServerProfile): void {
    const copy: McpServerProfile = JSON.parse(JSON.stringify(profile)); copy.retryToolCallOnExpiredSession = false;
    super.registerServer(copy);
  }
}
class SearchBackendFactory implements SingleAgentHostRuntimeFactoryPort {
  private readonly ports: ProductionAgentRuntimePorts; private readonly adapter: McpAgentAdapter;
  private readonly registry: ToolRegistry;
  constructor(ports: ProductionAgentRuntimePorts, adapter: McpAgentAdapter, registry: ToolRegistry) {
    this.ports = ports; this.adapter = adapter; this.registry = registry;
  }
  async create(): Promise<AgentRuntimeFacade> {
    const config = new ProductionAgentRuntimeConfig(); config.policyVersion = SEARCH_POLICY; config.grantTtlMs = 60000;
    return await createMcpProductionAgentRuntime(config, this.ports, this.adapter, this.registry, [SHUVI_WEB_SEARCH_TOOL_ID]);
  }
}
class BoundedSearchSession extends ShuviRuntimeSession {
  private readonly execution: SearchExecutionResource;
  constructor(backend: AgentApplicationBackend, resources: SearchResources, manager: McpClientManager,
    previews: SearchAuthorizationPreviews, usage: SearchUsageReceipts) {
    super(backend, resources, new SessionModelHttpClient(new ArkTsDeepSeekHttpClient()), manager, previews, usage);
    this.execution = resources.execution;
  }
  async submit(request: AgentFrontendTaskRequest): Promise<AgentFrontendTaskHandle> {
    if (!this.execution.available()) throw new Error('SEARCH_TRIAL_ALLOWANCE_EXHAUSTED');
    return await super.submit(request);
  }
}
export class SearchRuntimeFactory implements ShuviRuntimeSessionFactory {
  onOutcomeRejected: (taskId: string) => void = (_taskId: string): void => {};
  readonly previews: SearchAuthorizationPreviews = new SearchAuthorizationPreviews();
  private readonly opener: AgentRdbOpenPort; private readonly debug: boolean;
  private execution?: SearchExecutionResource;
  constructor(opener: AgentRdbOpenPort, debug: boolean) { this.opener = opener; this.debug = debug; }
  available(): boolean { return this.execution?.available() === true; }
  create(): ShuviRuntimeSessionPort {
    if (!this.debug) throw new Error('SEARCH_DEBUG_ONLY');
    const digest = new AgentHostDigest(); const usage = new SearchUsageReceipts(digest);
    const recovery = new RuntimeExecutionRecoveryBridgeConfig(); recovery.ownerId = 'shuvi-local-owner-v1';
    recovery.policyVersion = SEARCH_POLICY; recovery.leaseTtlMs = 60000;
    recovery.outcomeAccounting = new UnsettledSearchAccounting();
    recovery.pendingInvoice = new SearchPendingInvoice(usage, SEARCH_ACCOUNT, SEARCH_CURRENCY);
    const execution = new SearchExecutionResource(this.opener, recovery, digest); this.execution = execution;
    execution.onOutcomeRejected = (taskId: string): void => { this.onOutcomeRejected(taskId); };
    const resources = new SearchResources(execution); const policy = new McpInvocationPolicyBridge(digest);
    const options: McpManagerOptions = { debugBuild: true, invocationPolicy: policy, clientName: 'shuvi-search-trial', clientVersion: '1.0.0' };
    const manager = new SingleAttemptSearchManager(options);
    const providers = new McpProviderRegistry(digest); const policies = new McpReadOnlyToolPolicyRegistry();
    const adapter = new SearchUsageMcpAdapter(new ShuviWebSearchMcpClientToolPort(new McpClientManagerToolPort(manager)),
      providers, policies, digest, new SearchClock(), execution, policy, usage);
    const registry = new ToolRegistry(); const ports = new ProductionAgentRuntimePorts();
    ports.ids = new SearchIds(); ports.clock = new SearchClock(); ports.planner = new ExplicitSearchPlanner();
    ports.persistence = execution;
    const preparation = new ShuviWebSearchToolPreparationConfig(); preparation.defaultMaxResults = 3;
    ports.toolPreparer = new PreviewingSearchPreparer(new ShuviWebSearchToolInvocationPreparer(registry, digest, ports.ids, preparation), this.previews, digest);
    const config = new AgentApplicationBackendConfig(); config.userId = recovery.ownerId; config.privacyClass = PrivacyClass.PUBLIC;
    config.consentContext.interactiveAllowed = true;
    config.requestedBudget.maxWallTimeMs = 120000; config.requestedBudget.maxToolCalls = 1;
    config.requestedBudget.maxAgentActivations = 1; config.requestedBudget.maxMonetaryCostMicros = SEARCH_RESERVATION;
    const search = new ShuviWebSearchMcpConfig(); search.estimatedCostMicros = SEARCH_RESERVATION;
    const host = new SingleAgentHostPorts(); host.credentialStore = resources.credentials; host.executionStorage = execution;
    host.memoryStorage = resources.memory; host.mcpClient = new ShuviWebSearchMcpHostResource(manager, providers, policies, search);
    host.runtimeFactory = new SearchBackendFactory(ports, adapter, registry);
    return new BoundedSearchSession(new AgentApplicationBackend(config, host), resources, manager, this.previews, usage);
  }
}
export function searchRuntimeFactory(context: common.Context, debug: boolean): SearchRuntimeFactory {
  return new SearchRuntimeFactory(new NativeAgentRdbOpen(context), debug);
}
