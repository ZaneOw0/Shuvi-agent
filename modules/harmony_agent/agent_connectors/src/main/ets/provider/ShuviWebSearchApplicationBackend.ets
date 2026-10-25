import {
  AgentApplicationBackend,
  AgentApplicationBackendConfig,
  AgentApplicationBackendIdentityPort,
  AgentRuntimeFacade,
  SingleAgentHostPorts,
  SingleAgentHostRuntimeFactoryPort,
  SystemAgentApplicationBackendIdentity,
  ToolRegistry
} from '@harmony_agent/agent-runtime';
import { McpClientManager } from '@harmony_agent/mcp-client';
import { McpAgentAdapter } from '../mcp/McpAgentAdapter';
import { McpProviderRegistry } from '../mcp/McpProviderRegistry';
import { McpReadOnlyToolPolicyRegistry } from '../mcp/McpToolPolicyRegistry';
import { ShuviWebSearchMcpConfig } from '../mcp/ShuviWebSearch';
import { ShuviWebSearchMcpHostResource } from '../mcp/ShuviWebSearchHostResource';
import { ShuviWebSearchToolPreparationConfig } from '../mcp/ShuviWebSearchToolPreparer';
import {
  LocalAIGatewayMcpRuntimeConfig,
  LocalAIGatewayMcpRuntimePorts
} from './LocalAIGatewayProductionRuntime';
import { createRecoveredShuviWebSearchLocalAIGatewayProductionRuntime } from
  './ShuviWebSearchLocalAIGatewayRuntime';

export const SHUVI_APPLICATION_BACKEND_COMPOSITION_VERSION: string = '1.0';

export enum ShuviApplicationBackendCompositionErrorCode {
  INVALID_CONFIGURATION = 'INVALID_CONFIGURATION',
  RUNTIME_FACTORY_CONFLICT = 'RUNTIME_FACTORY_CONFLICT'
}

export class ShuviApplicationBackendCompositionError extends Error {
  readonly code: ShuviApplicationBackendCompositionErrorCode;

  constructor(code: ShuviApplicationBackendCompositionErrorCode, message: string) {
    super(message);
    this.name = 'ShuviApplicationBackendCompositionError';
    this.code = code;
  }
}

export class ShuviApplicationBackendConfig {
  compositionVersion: string = SHUVI_APPLICATION_BACKEND_COMPOSITION_VERSION;
  frontend: AgentApplicationBackendConfig = new AgentApplicationBackendConfig();
  runtime: LocalAIGatewayMcpRuntimeConfig = new LocalAIGatewayMcpRuntimeConfig();
  searchTool: ShuviWebSearchToolPreparationConfig = new ShuviWebSearchToolPreparationConfig();
}

export class ShuviApplicationBackendPorts {
  host: SingleAgentHostPorts = new SingleAgentHostPorts();
  runtime: LocalAIGatewayMcpRuntimePorts = new LocalAIGatewayMcpRuntimePorts();
  mcpManager?: McpClientManager;
  mcpProviders?: McpProviderRegistry;
  mcpPolicies?: McpReadOnlyToolPolicyRegistry;
  searchMcp: ShuviWebSearchMcpConfig = new ShuviWebSearchMcpConfig();
  adapter?: McpAgentAdapter;
  registry?: ToolRegistry;
  identity?: AgentApplicationBackendIdentityPort;
}

class ShuviApplicationRuntimeFactory implements SingleAgentHostRuntimeFactoryPort {
  private readonly config: ShuviApplicationBackendConfig;
  private readonly ports: ShuviApplicationBackendPorts;

  constructor(config: ShuviApplicationBackendConfig, ports: ShuviApplicationBackendPorts) {
    this.config = config;
    this.ports = ports;
  }

  async create(): Promise<AgentRuntimeFacade> {
    const adapter: McpAgentAdapter | undefined = this.ports.adapter;
    const registry: ToolRegistry | undefined = this.ports.registry;
    if (adapter === undefined || registry === undefined) {
      throw new ShuviApplicationBackendCompositionError(
        ShuviApplicationBackendCompositionErrorCode.INVALID_CONFIGURATION,
        'Shuvi application backend requires MCP adapter and Tool Registry');
    }
    return await createRecoveredShuviWebSearchLocalAIGatewayProductionRuntime(
      this.config.runtime, this.ports.runtime, adapter, registry, this.config.searchTool);
  }
}

function hostPorts(config: ShuviApplicationBackendConfig,
  ports: ShuviApplicationBackendPorts): SingleAgentHostPorts {
  if (config.compositionVersion !== SHUVI_APPLICATION_BACKEND_COMPOSITION_VERSION) {
    throw new ShuviApplicationBackendCompositionError(
      ShuviApplicationBackendCompositionErrorCode.INVALID_CONFIGURATION,
      'Shuvi application backend composition version is invalid');
  }
  if (ports.host.runtimeFactory !== undefined) {
    throw new ShuviApplicationBackendCompositionError(
      ShuviApplicationBackendCompositionErrorCode.RUNTIME_FACTORY_CONFLICT,
      'Shuvi application backend owns the Runtime factory');
  }
  if (ports.host.mcpClient !== undefined) {
    throw new ShuviApplicationBackendCompositionError(
      ShuviApplicationBackendCompositionErrorCode.RUNTIME_FACTORY_CONFLICT,
      'Shuvi application backend owns the MCP host resource');
  }
  if (ports.adapter === undefined || ports.registry === undefined || ports.mcpManager === undefined ||
    ports.mcpProviders === undefined || ports.mcpPolicies === undefined) {
    throw new ShuviApplicationBackendCompositionError(
      ShuviApplicationBackendCompositionErrorCode.INVALID_CONFIGURATION,
      'Shuvi application backend requires MCP adapter and Tool Registry');
  }
  const value: SingleAgentHostPorts = new SingleAgentHostPorts();
  value.credentialStore = ports.host.credentialStore;
  value.executionStorage = ports.host.executionStorage;
  value.memoryStorage = ports.host.memoryStorage;
  value.mcpClient = new ShuviWebSearchMcpHostResource(
    ports.mcpManager, ports.mcpProviders, ports.mcpPolicies, ports.searchMcp);
  value.runtimeFactory = new ShuviApplicationRuntimeFactory(config, ports);
  return value;
}

/** Concrete product composition root for an Ability-owned Shuvi backend. */
export function createShuviApplicationBackend(config: ShuviApplicationBackendConfig,
  ports: ShuviApplicationBackendPorts): AgentApplicationBackend {
  const identity: AgentApplicationBackendIdentityPort = ports.identity === undefined ?
    new SystemAgentApplicationBackendIdentity() : ports.identity;
  return new AgentApplicationBackend(config.frontend, hostPorts(config, ports), identity);
}
