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
  ToolRegistry,
  ToolRegistryEntry,
  createProductionAgentRuntime,
  createRecoveredProductionAgentRuntime
} from '@harmony_agent/agent-runtime';
import { ToolOutcome } from '@harmony_agent/agent-contracts';
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

  constructor(adapter: McpAgentAdapter) {
    this.adapter = adapter;
  }

  create(sink: RuntimeToolOutcomeSinkPort): StepDispatchPort {
    return new McpStepDispatchAdapter(this.adapter, new RuntimeMcpOutcomeSink(sink));
  }
}

function copyPorts(source: ProductionAgentRuntimePorts, adapter: McpAgentAdapter): ProductionAgentRuntimePorts {
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
  value.adapterFactory = new McpProductionAdapterFactory(adapter);
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
  requiredToolIds: string[]): Promise<void> {
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
  if (refresh.entries.length === 0) {
    throw new McpRuntimeCompositionError(McpRuntimeCompositionErrorCode.CATALOG_EMPTY,
      'MCP catalog contains no controlled read-only tools');
  }
  const validated: ToolRegistry = new ToolRegistry();
  for (let i: number = 0; i < refresh.entries.length; i++) {
    if (!validated.register(refresh.entries[i]).accepted) {
      throw new McpRuntimeCompositionError(McpRuntimeCompositionErrorCode.CATALOG_ENTRY_REJECTED,
        'MCP catalog contains an invalid or conflicting Tool Registry entry');
    }
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
 * Discovers the controlled read-only MCP catalog before exposing the sole task-control Facade.
 * The caller-owned registry may be shared with its planner and tool preparer, but must be empty.
 */
export async function createMcpProductionAgentRuntime(config: ProductionAgentRuntimeConfig,
  ports: ProductionAgentRuntimePorts, adapter: McpAgentAdapter,
  registry: ToolRegistry, requiredToolIds: string[] = []): Promise<AgentRuntimeFacade> {
  await bindCatalog(adapter, registry, requiredToolIds);
  return createProductionAgentRuntime(config, copyPorts(ports, adapter));
}

/** Restores durable tasks only after the controlled MCP catalog is discovered and bound. */
export async function createRecoveredMcpProductionAgentRuntime(config: ProductionAgentRuntimeConfig,
  ports: ProductionAgentRuntimePorts, adapter: McpAgentAdapter,
  registry: ToolRegistry, requiredToolIds: string[] = []): Promise<AgentRuntimeFacade> {
  await bindCatalog(adapter, registry, requiredToolIds);
  return await createRecoveredProductionAgentRuntime(config, copyPorts(ports, adapter));
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
  requiredToolIds: string[] = []): Promise<AgentRuntimeFacade> {
  const composed: ProductionAgentRuntimePorts = withProviderPlanner(
    ports, registered, provider, plannerConfig, observer, memoryContext);
  return await createMcpProductionAgentRuntime(config, composed, adapter, registry, requiredToolIds);
}

/** Restores durable tasks through the same Provider Planner and catalog-before-Facade boundary. */
export async function createRecoveredProviderMcpProductionAgentRuntime(config: ProductionAgentRuntimeConfig,
  ports: ProductionAgentRuntimePorts, adapter: McpAgentAdapter, registry: ToolRegistry,
  registered: RegisteredModelProvider, provider: ModelProvider, plannerConfig: ProviderSemanticPlannerConfig,
  observer?: ProviderSemanticPlannerObserverPort,
  memoryContext?: PlanningMemoryContextPort,
  requiredToolIds: string[] = []): Promise<AgentRuntimeFacade> {
  const composed: ProductionAgentRuntimePorts = withProviderPlanner(
    ports, registered, provider, plannerConfig, observer, memoryContext);
  return await createRecoveredMcpProductionAgentRuntime(config, composed, adapter, registry, requiredToolIds);
}
