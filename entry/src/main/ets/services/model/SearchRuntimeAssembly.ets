import common from '@ohos.app.ability.common';
import util from '@ohos.util';
import { PrivacyClass } from '@harmony_agent/agent-contracts';
import { AgentApplicationBackend, AgentApplicationBackendConfig, AgentFrontendTaskHandle, AgentFrontendTaskRequest,
  AgentRuntimeFacade, ProductionAgentRuntimeConfig, ProductionAgentRuntimePorts, RuntimeClockPort, RuntimeIdGeneratorPort,
  SingleAgentHostPorts, SingleAgentHostResourcePort, SingleAgentHostRuntimeFactoryPort, ToolRegistry } from '@harmony_agent/agent-runtime';
import { RuntimeExecutionRecoveryBridgeConfig } from '@harmony_agent/agent-storage';
import { McpClientManager, McpManagerOptions } from '@harmony_agent/mcp-client';
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
import { CredentialKeySource, TavilyKeyService } from './DeepSeekCredentialStore';
import { DirectTavilySearchManager } from './DirectTavilySearch';
import { ArkTsTavilyHttpClient, TAVILY_SEARCH_ENDPOINT, TavilyHttpClientPort } from './TavilyHttpClient';

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
    if (!this.execution.available()) throw new Error('SEARCH_HISTORY_FULL');
    return await super.submit(request);
  }
}
export class SearchRuntimeFactory implements ShuviRuntimeSessionFactory {
  onOutcomeRejected: (taskId: string) => void = (_taskId: string): void => {};
  readonly previews: SearchAuthorizationPreviews = new SearchAuthorizationPreviews();
  private readonly opener: AgentRdbOpenPort; private readonly debug: boolean;
  private readonly http: TavilyHttpClientPort; private readonly keys: CredentialKeySource;
  private execution?: SearchExecutionResource;
  /** Search goes straight from the phone to Tavily with the key saved in 我的 → API Key 管理; no computer service. */
  constructor(opener: AgentRdbOpenPort, debug: boolean, http: TavilyHttpClientPort = new ArkTsTavilyHttpClient(),
    keys: CredentialKeySource = TavilyKeyService.store) {
    this.opener = opener; this.debug = debug; this.http = http; this.keys = keys;
  }
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
    const options: McpManagerOptions = { debugBuild: true, invocationPolicy: policy, clientName: 'shuvi-search', clientVersion: '1.0.0' };
    const manager = new DirectTavilySearchManager(options, this.http, this.keys);
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
    // The registered profile names the real destination; the in-app manager never opens an MCP connection.
    search.endpoint = TAVILY_SEARCH_ENDPOINT; search.allowInsecureHttp = false;
    const host = new SingleAgentHostPorts(); host.credentialStore = resources.credentials; host.executionStorage = execution;
    host.memoryStorage = resources.memory; host.mcpClient = new ShuviWebSearchMcpHostResource(manager, providers, policies, search);
    host.runtimeFactory = new SearchBackendFactory(ports, adapter, registry);
    return new BoundedSearchSession(new AgentApplicationBackend(config, host), resources, manager, this.previews, usage);
  }
}
export function searchRuntimeFactory(context: common.Context, debug: boolean): SearchRuntimeFactory {
  return new SearchRuntimeFactory(new NativeAgentRdbOpen(context), debug);
}
