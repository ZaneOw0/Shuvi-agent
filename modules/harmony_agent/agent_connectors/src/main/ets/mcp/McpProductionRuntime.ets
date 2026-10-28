import {
  AgentRuntimeFacade,
  CollaborationSelectorPort,
  ProductionAgentRuntimeConfig,
  ProductionAgentRuntimePorts,
  ProductionRuntimeAdapterFactoryPort,
  PlanningMemoryContextPort,
  RuntimeToolOutcomeSinkPort,
  SingleAgentCollaborationSelector,
  StepDispatchPort,
  StepDispatchReceipt,
  StepDispatchRequest,
  ToolRegistry,
  ToolRegistryEntry,
  createProductionAgentRuntime,
  createRecoveredProductionAgentRuntime
} from '@harmony_agent/agent-runtime';
import { ContractCodec, ToolOutcome, ToolSourceType } from '@harmony_agent/agent-contracts';
import { McpAgentAdapter } from './McpAgentAdapter';
import { McpCatalogRefreshResult, McpToolOutcomeSinkPort } from './McpConnectorTypes';
import { McpStepDispatchAdapter } from './McpStepDispatchAdapter';
import { ModelProvider } from '../provider/ProviderContracts';
import { RegisteredModelProvider } from '../provider/ProviderCatalog';
import {
  ProviderSemanticPlanner,
  ProviderSemanticPlannerConfig,
  ProviderSemanticPlannerObserverPort
} from '../provider/ProviderSemanticPlanner';
import { CollaborativeProviderSemanticPlanner } from
  '../provider/CollaborativeProviderSemanticPlanner';

function ignoreCompletionRejection(_error: Error): void {
  // ProductionAgentRuntime records its own persistence fault before rejecting the completion Promise.
}

export enum McpRuntimeCompositionErrorCode {
  REGISTRY_NOT_EMPTY = 'REGISTRY_NOT_EMPTY',
  CATALOG_REQUIREMENT_INVALID = 'CATALOG_REQUIREMENT_INVALID',
  CATALOG_REQUIRED_TOOL_MISSING = 'CATALOG_REQUIRED_TOOL_MISSING',
  CATALOG_DISCOVERY_FAILED = 'CATALOG_DISCOVERY_FAILED',
  CATALOG_PARTIAL_FAILURE = 'CATALOG_PARTIAL_FAILURE',
  CATALOG_EMPTY = 'CATALOG_EMPTY',
  CATALOG_ENTRY_REJECTED = 'CATALOG_ENTRY_REJECTED',
  PROVIDER_PLANNER_ALREADY_CONFIGURED = 'PROVIDER_PLANNER_ALREADY_CONFIGURED',
  PROVIDER_PLANNER_CLOCK_REQUIRED = 'PROVIDER_PLANNER_CLOCK_REQUIRED',
  PROVIDER_PLANNER_IDS_REQUIRED = 'PROVIDER_PLANNER_IDS_REQUIRED'
}

function withProviderPlanner(source: ProductionAgentRuntimePorts, registered: RegisteredModelProvider,
  provider: ModelProvider, plannerConfig: ProviderSemanticPlannerConfig,
  observer?: ProviderSemanticPlannerObserverPort,
  memoryContext?: PlanningMemoryContextPort): ProductionAgentRuntimePorts {
  if (source.planner !== undefined) {
    throw new McpRuntimeCompositionError(McpRuntimeCompositionErrorCode.PROVIDER_PLANNER_ALREADY_CONFIGURED,
      'Provider MCP production composition owns the Semantic Planner port');
  }
  if (source.clock === undefined) {
    throw new McpRuntimeCompositionError(McpRuntimeCompositionErrorCode.PROVIDER_PLANNER_CLOCK_REQUIRED,
      'Provider MCP production composition requires the Runtime clock port');
  }
  if (source.ids === undefined) {
    throw new McpRuntimeCompositionError(McpRuntimeCompositionErrorCode.PROVIDER_PLANNER_IDS_REQUIRED,
      'Provider MCP production composition requires the Runtime ID generator port');
  }
  const value: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
  value.clock = source.clock;
  value.ids = source.ids;
  const providerPlanner: ProviderSemanticPlanner = new ProviderSemanticPlanner(
    registered, provider, plannerConfig, source.clock, source.ids, observer, memoryContext);
  value.planner = source.collaborationPlan === undefined ? providerPlanner :
    new CollaborativeProviderSemanticPlanner(providerPlanner);
  value.collaboration = source.collaboration;
  value.collaborationPlan = source.collaborationPlan;
  value.collaborationPreparation = source.collaborationPreparation;
  value.toolPreparer = source.toolPreparer;
  value.persistence = source.persistence;
  value.recovery = source.recovery;
  return value;
}

export class McpRuntimeCompositionError extends Error {
  readonly code: McpRuntimeCompositionErrorCode;

  constructor(code: McpRuntimeCompositionErrorCode, message: string) {
    super(message);
    this.name = 'McpRuntimeCompositionError';
    this.code = code;
  }
}

/** Host-owned non-MCP catalog and dispatch factory; grants and persistence remain owned by Runtime. */
export class McpRuntimeToolExtension {
  readonly entries: ToolRegistryEntry[];
  readonly adapterFactory: ProductionRuntimeAdapterFactoryPort;

  constructor(entries: ToolRegistryEntry[], adapterFactory: ProductionRuntimeAdapterFactoryPort) {
    this.entries = entries;
    this.adapterFactory = adapterFactory;
  }
}

function captureExtensions(extensions: McpRuntimeToolExtension[]): McpRuntimeToolExtension[] {
  const result: McpRuntimeToolExtension[] = [];
  for (let i: number = 0; i < extensions.length; i++) {
    const entries: ToolRegistryEntry[] = [];
    for (let j: number = 0; j < extensions[i].entries.length; j++) {
      entries.push(JSON.parse(ContractCodec.stringify(extensions[i].entries[j])) as ToolRegistryEntry);
    }
    result.push(new McpRuntimeToolExtension(entries, extensions[i].adapterFactory));
  }
  return result;
}

class MixedToolDispatch implements StepDispatchPort {
  private readonly routes: Map<string, StepDispatchPort> = new Map<string, StepDispatchPort>();
  private readonly dispatchers: StepDispatchPort[] = [];

  constructor(mcp: StepDispatchPort, mcpEntries: ToolRegistryEntry[], extensions: McpRuntimeToolExtension[],
    sink: RuntimeToolOutcomeSinkPort) {
    this.dispatchers.push(mcp);
    for (let i: number = 0; i < mcpEntries.length; i++) this.routes.set(mcpEntries[i].descriptor.toolId, mcp);
    for (let i: number = 0; i < extensions.length; i++) {
      const dispatcher: StepDispatchPort = extensions[i].adapterFactory.create(sink);
      this.dispatchers.push(dispatcher);
      for (let j: number = 0; j < extensions[i].entries.length; j++) {
        this.routes.set(extensions[i].entries[j].descriptor.toolId, dispatcher);
      }
    }
  }

  dispatch(request: StepDispatchRequest): StepDispatchReceipt {
    const dispatcher: StepDispatchPort | undefined = request.toolInvocation === undefined ? undefined :
      this.routes.get(request.toolInvocation.toolId);
    if (dispatcher !== undefined) return dispatcher.dispatch(request);
    const rejected: StepDispatchReceipt = new StepDispatchReceipt();
    rejected.rejectionCode = 'TOOL_DISPATCH_NOT_REGISTERED';
    return rejected;
  }

  cancel(dispatchId: string): boolean {
    for (let i: number = 0; i < this.dispatchers.length; i++) {
      if (this.dispatchers[i].cancel(dispatchId)) return true;
    }
    return false;
  }
}

class RuntimeMcpOutcomeSink implements McpToolOutcomeSinkPort {
  private readonly sink: RuntimeToolOutcomeSinkPort;

  constructor(sink: RuntimeToolOutcomeSinkPort) {
    this.sink = sink;
  }

  complete(taskId: string, stepId: string, dispatchId: string, outcome: ToolOutcome): void {
    this.sink.complete(taskId, stepId, dispatchId, outcome).catch(ignoreCompletionRejection);
  }
}

class McpProductionAdapterFactory implements ProductionRuntimeAdapterFactoryPort {
  private readonly adapter: McpAgentAdapter;
  private readonly extensions: McpRuntimeToolExtension[];
  private readonly mcpEntries: ToolRegistryEntry[];

  constructor(adapter: McpAgentAdapter, mcpEntries: ToolRegistryEntry[], extensions: McpRuntimeToolExtension[]) {
    this.adapter = adapter;
    this.mcpEntries = mcpEntries;
    this.extensions = extensions;
  }

  create(sink: RuntimeToolOutcomeSinkPort): StepDispatchPort {
    const mcp: StepDispatchPort = new McpStepDispatchAdapter(this.adapter, new RuntimeMcpOutcomeSink(sink));
    return new MixedToolDispatch(mcp, this.mcpEntries, this.extensions, sink);
  }
}

function copyPorts(source: ProductionAgentRuntimePorts, adapter: McpAgentAdapter,
  registry: ToolRegistry, extensions: McpRuntimeToolExtension[]): ProductionAgentRuntimePorts {
  const value: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
  value.clock = source.clock;
  value.ids = source.ids;
  value.planner = source.planner;
  const collaboration: CollaborationSelectorPort = source.collaboration === undefined ?
    new SingleAgentCollaborationSelector() : source.collaboration;
  value.collaboration = collaboration;
  value.collaborationPlan = source.collaborationPlan;
  value.collaborationPreparation = source.collaborationPreparation;
  value.toolPreparer = source.toolPreparer;
  const mcpEntries: ToolRegistryEntry[] = registry.activeEntries().filter(
    (entry: ToolRegistryEntry): boolean => entry.descriptor.sourceType === ToolSourceType.MCP);
  value.adapterFactory = new McpProductionAdapterFactory(adapter, mcpEntries, extensions);
  value.persistence = source.persistence;
  value.recovery = source.recovery;
  return value;
}

function validRequiredToolIds(requiredToolIds: string[]): boolean {
  for (let index: number = 0; index < requiredToolIds.length; index++) {
    if (requiredToolIds[index].trim().length === 0 || requiredToolIds[index].trim() !== requiredToolIds[index] ||
      requiredToolIds.indexOf(requiredToolIds[index]) !== index) return false;
  }
  return true;
}

async function bindCatalog(adapter: McpAgentAdapter, registry: ToolRegistry,
  requiredToolIds: string[], extensions: McpRuntimeToolExtension[]): Promise<void> {
  const requirements: string[] = requiredToolIds.slice();
  if (!validRequiredToolIds(requirements)) {
    throw new McpRuntimeCompositionError(McpRuntimeCompositionErrorCode.CATALOG_REQUIREMENT_INVALID,
      'MCP production composition received invalid required Tool IDs');
  }
  if (registry.snapshot().snapshotVersion !== 0) {
    throw new McpRuntimeCompositionError(McpRuntimeCompositionErrorCode.REGISTRY_NOT_EMPTY,
      'MCP production composition requires an empty Tool Registry');
  }
  let refresh: McpCatalogRefreshResult;
  try {
    refresh = await adapter.refreshCatalog();
  } catch (error) {
    throw new McpRuntimeCompositionError(McpRuntimeCompositionErrorCode.CATALOG_DISCOVERY_FAILED,
      'MCP catalog discovery failed');
  }
  if (refresh.failures.length > 0) {
    throw new McpRuntimeCompositionError(McpRuntimeCompositionErrorCode.CATALOG_PARTIAL_FAILURE,
      'MCP catalog discovery returned one or more server failures');
  }
  const combined: ToolRegistryEntry[] = refresh.entries.slice();
  for (let i: number = 0; i < extensions.length; i++) {
    for (let j: number = 0; j < extensions[i].entries.length; j++) {
      const entry: ToolRegistryEntry = extensions[i].entries[j];
      if (entry.descriptor.sourceType === ToolSourceType.MCP || entry.descriptor.toolId.startsWith('mcp://')) {
        throw new McpRuntimeCompositionError(McpRuntimeCompositionErrorCode.CATALOG_ENTRY_REJECTED,
          'Non-MCP extensions cannot register MCP identities');
      }
      combined.push(entry);
    }
  }
  if (combined.length === 0) {
    throw new McpRuntimeCompositionError(McpRuntimeCompositionErrorCode.CATALOG_EMPTY,
      'Tool catalog contains no controlled tools');
  }
  const validated: ToolRegistry = new ToolRegistry();
  const identities: Set<string> = new Set<string>();
  for (let i: number = 0; i < combined.length; i++) {
    if (identities.has(combined[i].descriptor.toolId) || !validated.register(combined[i]).accepted) {
      throw new McpRuntimeCompositionError(McpRuntimeCompositionErrorCode.CATALOG_ENTRY_REJECTED,
        'MCP catalog contains an invalid or conflicting Tool Registry entry');
    }
    identities.add(combined[i].descriptor.toolId);
  }
  const entries: ToolRegistryEntry[] = validated.activeEntries();
  for (let requiredIndex: number = 0; requiredIndex < requirements.length; requiredIndex++) {
    let found: boolean = false;
    for (let entryIndex: number = 0; entryIndex < entries.length; entryIndex++) {
      if (entries[entryIndex].descriptor.toolId === requirements[requiredIndex]) found = true;
    }
    if (!found) {
      throw new McpRuntimeCompositionError(McpRuntimeCompositionErrorCode.CATALOG_REQUIRED_TOOL_MISSING,
        'MCP catalog does not contain a required controlled Tool');
    }
  }
  for (let i: number = 0; i < entries.length; i++) {
    if (!registry.register(entries[i]).accepted) {
      throw new McpRuntimeCompositionError(McpRuntimeCompositionErrorCode.CATALOG_ENTRY_REJECTED,
        'MCP Tool Registry rejected a validated catalog entry');
    }
  }
}

/**
 * Discovers and validates the controlled MCP/native catalog before exposing the sole task-control Facade.
 * The caller-owned registry may be shared with its planner and tool preparer, but must be empty.
 */
export async function createMcpProductionAgentRuntime(config: ProductionAgentRuntimeConfig,
  ports: ProductionAgentRuntimePorts, adapter: McpAgentAdapter,
  registry: ToolRegistry, requiredToolIds: string[] = [], extensions: McpRuntimeToolExtension[] = []): Promise<AgentRuntimeFacade> {
  const captured: McpRuntimeToolExtension[] = captureExtensions(extensions);
  await bindCatalog(adapter, registry, requiredToolIds, captured);
  return createProductionAgentRuntime(config, copyPorts(ports, adapter, registry, captured));
}

/** Restores durable tasks only after the controlled MCP catalog is discovered and bound. */
export async function createRecoveredMcpProductionAgentRuntime(config: ProductionAgentRuntimeConfig,
  ports: ProductionAgentRuntimePorts, adapter: McpAgentAdapter,
  registry: ToolRegistry, requiredToolIds: string[] = [], extensions: McpRuntimeToolExtension[] = []): Promise<AgentRuntimeFacade> {
  const captured: McpRuntimeToolExtension[] = captureExtensions(extensions);
  await bindCatalog(adapter, registry, requiredToolIds, captured);
  return await createRecoveredProductionAgentRuntime(config, copyPorts(ports, adapter, registry, captured));
}

/**
 * Owns the concrete Provider-backed Semantic Planner and exposes only the single production Facade.
 * The MCP catalog is still discovered and bound before the Facade is returned.
 */
export async function createProviderMcpProductionAgentRuntime(config: ProductionAgentRuntimeConfig,
  ports: ProductionAgentRuntimePorts, adapter: McpAgentAdapter, registry: ToolRegistry,
  registered: RegisteredModelProvider, provider: ModelProvider, plannerConfig: ProviderSemanticPlannerConfig,
  observer?: ProviderSemanticPlannerObserverPort,
  memoryContext?: PlanningMemoryContextPort,
  requiredToolIds: string[] = [], extensions: McpRuntimeToolExtension[] = []): Promise<AgentRuntimeFacade> {
  const composed: ProductionAgentRuntimePorts = withProviderPlanner(
    ports, registered, provider, plannerConfig, observer, memoryContext);
  return await createMcpProductionAgentRuntime(config, composed, adapter, registry, requiredToolIds, extensions);
}

/** Restores durable tasks through the same Provider Planner and catalog-before-Facade boundary. */
export async function createRecoveredProviderMcpProductionAgentRuntime(config: ProductionAgentRuntimeConfig,
  ports: ProductionAgentRuntimePorts, adapter: McpAgentAdapter, registry: ToolRegistry,
  registered: RegisteredModelProvider, provider: ModelProvider, plannerConfig: ProviderSemanticPlannerConfig,
  observer?: ProviderSemanticPlannerObserverPort,
  memoryContext?: PlanningMemoryContextPort,
  requiredToolIds: string[] = [], extensions: McpRuntimeToolExtension[] = []): Promise<AgentRuntimeFacade> {
  const composed: ProductionAgentRuntimePorts = withProviderPlanner(
    ports, registered, provider, plannerConfig, observer, memoryContext);
  return await createRecoveredMcpProductionAgentRuntime(config, composed, adapter, registry, requiredToolIds, extensions);
}
