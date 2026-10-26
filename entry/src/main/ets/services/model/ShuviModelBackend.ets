import {
  AgentApplicationBackend, AgentApplicationBackendConfig, AgentApplicationBackendIdentityPort,
  AgentRuntimeFacade, PlanningMemoryContextPort, ProductionAgentRuntimeConfig, ProductionAgentRuntimePorts,
  SingleAgentHostPorts, SingleAgentHostRuntimeFactoryPort, SystemAgentApplicationBackendIdentity, ToolRegistry
} from '@harmony_agent/agent-runtime';
import { McpClientManager } from '@harmony_agent/mcp-client';
import {
  ConnectorDigestPort, McpAgentAdapter, McpProviderRegistry, McpReadOnlyToolPolicyRegistry,
  ModelProvider, ProviderSemanticPlannerConfig, ProviderSemanticPlannerObserverPort, RegisteredModelProvider,
  SHUVI_WEB_SEARCH_TOOL_ID, ShuviWebSearchMcpConfig, ShuviWebSearchMcpHostResource,
  ShuviWebSearchToolPreparationConfig, createRecoveredProviderMcpProductionAgentRuntime,
  installShuviWebSearchToolPreparer, validShuviWebSearchToolPreparationConfig
} from '@harmony_agent/agent-connectors';
import { PreviewingSearchPreparer, SearchAuthorizationPreviews } from './SearchAuthorizationPreview';
import { SearchUsageReceipts } from './SearchUsageReceipts';

export class ShuviModelBackendConfig {
  frontend: AgentApplicationBackendConfig = new AgentApplicationBackendConfig();
  runtime: ProductionAgentRuntimeConfig = new ProductionAgentRuntimeConfig();
  planner: ProviderSemanticPlannerConfig = new ProviderSemanticPlannerConfig();
  search: ShuviWebSearchMcpConfig = new ShuviWebSearchMcpConfig();
  searchTool: ShuviWebSearchToolPreparationConfig = new ShuviWebSearchToolPreparationConfig();
}

// The application supplies real host resources. Model selection is independent of the Runtime.
export class ShuviModelBackendPorts {
  searchUsage?: SearchUsageReceipts;
  readonly authorizations: SearchAuthorizationPreviews = new SearchAuthorizationPreviews();
  host: SingleAgentHostPorts = new SingleAgentHostPorts();
  runtime: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
  digest?: ConnectorDigestPort;
  manager?: McpClientManager;
  providers?: McpProviderRegistry;
  policies?: McpReadOnlyToolPolicyRegistry;
  adapter?: McpAgentAdapter;
  registry?: ToolRegistry;
  identity?: AgentApplicationBackendIdentityPort;
  plannerObserver?: ProviderSemanticPlannerObserverPort;
  memoryContext?: PlanningMemoryContextPort;
}

class ShuviProviderRuntimeFactory implements SingleAgentHostRuntimeFactoryPort {
  private readonly config: ShuviModelBackendConfig;
  private readonly runtime: ProductionAgentRuntimePorts;
  private readonly adapter: McpAgentAdapter;
  private readonly registry: ToolRegistry;
  private readonly registered: RegisteredModelProvider;
  private readonly provider: ModelProvider;
  private readonly observer?: ProviderSemanticPlannerObserverPort;
  private readonly memory?: PlanningMemoryContextPort;

  constructor(config: ShuviModelBackendConfig, runtime: ProductionAgentRuntimePorts,
    adapter: McpAgentAdapter, registry: ToolRegistry, registered: RegisteredModelProvider,
    provider: ModelProvider, observer?: ProviderSemanticPlannerObserverPort, memory?: PlanningMemoryContextPort) {
    this.config = config;
    this.runtime = runtime;
    this.adapter = adapter;
    this.registry = registry;
    this.registered = registered;
    this.provider = provider;
    this.observer = observer;
    this.memory = memory;
  }

  async create(): Promise<AgentRuntimeFacade> {
    return await createRecoveredProviderMcpProductionAgentRuntime(this.config.runtime, this.runtime,
      this.adapter, this.registry, this.registered, this.provider, this.config.planner,
      this.observer, this.memory, [SHUVI_WEB_SEARCH_TOOL_ID]);
  }
}

/** New app-owned composition entry. The upstream Windows factory remains unchanged. */
export function createShuviModelBackend(config: ShuviModelBackendConfig, ports: ShuviModelBackendPorts,
  registered: RegisteredModelProvider, provider: ModelProvider): AgentApplicationBackend {
  const adapter: McpAgentAdapter | undefined = ports.adapter;
  const registry: ToolRegistry | undefined = ports.registry;
  const manager: McpClientManager | undefined = ports.manager;
  const providers: McpProviderRegistry | undefined = ports.providers;
  const policies: McpReadOnlyToolPolicyRegistry | undefined = ports.policies;
  const digest: ConnectorDigestPort | undefined = ports.digest;
  if (adapter === undefined || registry === undefined || manager === undefined || providers === undefined ||
    policies === undefined || digest === undefined || ports.runtime.ids === undefined ||
    ports.runtime.persistence === undefined || ports.runtime.recovery === undefined ||
    ports.host.credentialStore === undefined || ports.host.executionStorage === undefined ||
    ports.host.memoryStorage === undefined || !validShuviWebSearchToolPreparationConfig(config.searchTool)) {
    throw new Error('Shuvi model backend requires real host resources and recovery configuration');
  }
  if (ports.host.runtimeFactory !== undefined || ports.host.mcpClient !== undefined ||
    ports.runtime.toolPreparer !== undefined) {
    throw new Error('Shuvi model backend composition conflicts with caller-owned ports');
  }
  const runtime: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
  runtime.clock = ports.runtime.clock;
  runtime.ids = ports.runtime.ids;
  runtime.planner = ports.runtime.planner;
  runtime.collaboration = ports.runtime.collaboration;
  runtime.collaborationPlan = ports.runtime.collaborationPlan;
  runtime.collaborationPreparation = ports.runtime.collaborationPreparation;
  runtime.adapterFactory = ports.runtime.adapterFactory;
  runtime.persistence = ports.runtime.persistence;
  runtime.recovery = ports.runtime.recovery;
  if (!installShuviWebSearchToolPreparer(runtime, registry, digest, config.searchTool)) {
    throw new Error('Shuvi model backend could not install search preparation');
  }
  const searchPreparer = runtime.toolPreparer;
  if (searchPreparer === undefined) throw new Error('Shuvi search preparer is unavailable');
  runtime.toolPreparer = new PreviewingSearchPreparer(searchPreparer, ports.authorizations, digest);
  const host: SingleAgentHostPorts = new SingleAgentHostPorts();
  host.credentialStore = ports.host.credentialStore;
  host.executionStorage = ports.host.executionStorage;
  host.memoryStorage = ports.host.memoryStorage;
  host.mcpClient = new ShuviWebSearchMcpHostResource(manager, providers, policies, config.search);
  host.runtimeFactory = new ShuviProviderRuntimeFactory(config, runtime, adapter, registry,
    registered, provider, ports.plannerObserver, ports.memoryContext);
  const identity: AgentApplicationBackendIdentityPort = ports.identity === undefined ?
    new SystemAgentApplicationBackendIdentity() : ports.identity;
  return new AgentApplicationBackend(config.frontend, host, identity);
}
