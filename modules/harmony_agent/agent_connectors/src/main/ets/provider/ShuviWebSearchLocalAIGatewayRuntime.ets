import {
  AgentRuntimeFacade,
  ProductionAgentRuntimePorts,
  ToolRegistry
} from '@harmony_agent/agent-runtime';
import { McpAgentAdapter } from '../mcp/McpAgentAdapter';
import {
  SHUVI_WEB_SEARCH_TOOL_ID,
  ShuviWebSearchToolPreparationConfig,
  installShuviWebSearchToolPreparer,
  validShuviWebSearchToolPreparationConfig
} from '../mcp/ShuviWebSearchToolPreparer';
import {
  LocalAIGatewayMcpRuntimeConfig,
  LocalAIGatewayMcpRuntimePorts,
  createLocalAIGatewayMcpProductionAgentRuntime,
  createRecoveredLocalAIGatewayMcpProductionAgentRuntime
} from './LocalAIGatewayProductionRuntime';

export enum ShuviWebSearchRuntimeCompositionErrorCode {
  DIGEST_REQUIRED = 'DIGEST_REQUIRED',
  RUNTIME_IDS_REQUIRED = 'RUNTIME_IDS_REQUIRED',
  INVALID_TOOL_PREPARATION_CONFIG = 'INVALID_TOOL_PREPARATION_CONFIG',
  TOOL_PREPARER_CONFLICT = 'TOOL_PREPARER_CONFLICT'
}

export class ShuviWebSearchRuntimeCompositionError extends Error {
  readonly code: ShuviWebSearchRuntimeCompositionErrorCode;

  constructor(code: ShuviWebSearchRuntimeCompositionErrorCode, message: string) {
    super(message);
    this.name = 'ShuviWebSearchRuntimeCompositionError';
    this.code = code;
  }
}

function copyRuntimePorts(source: ProductionAgentRuntimePorts): ProductionAgentRuntimePorts {
  const value: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
  value.clock = source.clock;
  value.ids = source.ids;
  value.planner = source.planner;
  value.collaboration = source.collaboration;
  value.collaborationPlan = source.collaborationPlan;
  value.collaborationPreparation = source.collaborationPreparation;
  value.toolPreparer = source.toolPreparer;
  value.adapterFactory = source.adapterFactory;
  value.persistence = source.persistence;
  value.recovery = source.recovery;
  return value;
}

function copyGatewayPorts(source: LocalAIGatewayMcpRuntimePorts): LocalAIGatewayMcpRuntimePorts {
  const value: LocalAIGatewayMcpRuntimePorts = new LocalAIGatewayMcpRuntimePorts();
  value.runtimePorts = copyRuntimePorts(source.runtimePorts);
  value.digest = source.digest;
  value.credentials = source.credentials;
  value.timer = source.timer;
  value.httpClient = source.httpClient;
  value.plannerObserver = source.plannerObserver;
  value.memoryContext = source.memoryContext;
  return value;
}

/**
 * Returns an isolated Local AI Gateway port set with the Shuvi search preparer installed.
 * Caller-owned ports are never mutated or silently replaced.
 */
export function withShuviWebSearchToolPreparation(source: LocalAIGatewayMcpRuntimePorts,
  registry: ToolRegistry,
  config: ShuviWebSearchToolPreparationConfig = new ShuviWebSearchToolPreparationConfig()):
  LocalAIGatewayMcpRuntimePorts {
  if (source.digest === undefined) {
    throw new ShuviWebSearchRuntimeCompositionError(
      ShuviWebSearchRuntimeCompositionErrorCode.DIGEST_REQUIRED,
      'Shuvi web search production composition requires a digest port');
  }
  if (source.runtimePorts.ids === undefined) {
    throw new ShuviWebSearchRuntimeCompositionError(
      ShuviWebSearchRuntimeCompositionErrorCode.RUNTIME_IDS_REQUIRED,
      'Shuvi web search production composition requires the Runtime ID generator port');
  }
  if (!validShuviWebSearchToolPreparationConfig(config)) {
    throw new ShuviWebSearchRuntimeCompositionError(
      ShuviWebSearchRuntimeCompositionErrorCode.INVALID_TOOL_PREPARATION_CONFIG,
      'Shuvi web search Tool Invocation Preparer configuration is invalid');
  }
  if (source.runtimePorts.toolPreparer !== undefined) {
    throw new ShuviWebSearchRuntimeCompositionError(
      ShuviWebSearchRuntimeCompositionErrorCode.TOOL_PREPARER_CONFLICT,
      'Shuvi web search production composition owns the Tool Invocation Preparer port');
  }
  const value: LocalAIGatewayMcpRuntimePorts = copyGatewayPorts(source);
  if (!installShuviWebSearchToolPreparer(value.runtimePorts, registry, source.digest, config)) {
    throw new ShuviWebSearchRuntimeCompositionError(
      ShuviWebSearchRuntimeCompositionErrorCode.TOOL_PREPARER_CONFLICT,
      'Unable to install the Shuvi web search Tool Invocation Preparer');
  }
  return value;
}

/** Builds the Local AI Gateway + Shuvi web search chain behind the sole Agent Runtime Facade. */
export async function createShuviWebSearchLocalAIGatewayProductionRuntime(
  config: LocalAIGatewayMcpRuntimeConfig, ports: LocalAIGatewayMcpRuntimePorts,
  adapter: McpAgentAdapter, registry: ToolRegistry,
  toolConfig: ShuviWebSearchToolPreparationConfig = new ShuviWebSearchToolPreparationConfig()):
  Promise<AgentRuntimeFacade> {
  const composed: LocalAIGatewayMcpRuntimePorts =
    withShuviWebSearchToolPreparation(ports, registry, toolConfig);
  return await createLocalAIGatewayMcpProductionAgentRuntime(
    config, composed, adapter, registry, [SHUVI_WEB_SEARCH_TOOL_ID]);
}

/** Restores durable tasks through the same Local AI Gateway + Shuvi search composition. */
export async function createRecoveredShuviWebSearchLocalAIGatewayProductionRuntime(
  config: LocalAIGatewayMcpRuntimeConfig, ports: LocalAIGatewayMcpRuntimePorts,
  adapter: McpAgentAdapter, registry: ToolRegistry,
  toolConfig: ShuviWebSearchToolPreparationConfig = new ShuviWebSearchToolPreparationConfig()):
  Promise<AgentRuntimeFacade> {
  const composed: LocalAIGatewayMcpRuntimePorts =
    withShuviWebSearchToolPreparation(ports, registry, toolConfig);
  return await createRecoveredLocalAIGatewayMcpProductionAgentRuntime(
    config, composed, adapter, registry, [SHUVI_WEB_SEARCH_TOOL_ID]);
}
