import {
  AgentRuntimeFacade,
  PlanningMemoryContextPort,
  ProductionAgentRuntimeConfig,
  ProductionAgentRuntimePorts,
  ToolRegistry
} from '@harmony_agent/agent-runtime';
import { McpAgentAdapter } from '../mcp/McpAgentAdapter';
import {
  McpRuntimeToolExtension,
  createProviderMcpProductionAgentRuntime,
  createRecoveredProviderMcpProductionAgentRuntime
} from '../mcp/McpProductionRuntime';
import { ConnectorDigestPort } from '../mcp/McpConnectorTypes';
import {
  ProviderCredentialPort,
  ProviderPriceSnapshot,
  ProviderTimerPort
} from './ProviderContracts';
import { GenericModelProvider } from './GenericProviders';
import {
  ArkTsLocalAIGatewayHttpClient,
  createLocalAIGatewayModelProfile,
  LocalAIGatewayHttpClientPort,
  LocalAIGatewayModelTransport,
  LocalAIGatewayTransportProfile
} from './LocalAIGatewayTransport';
import { ProviderCatalog, RegisteredModelProvider } from './ProviderCatalog';
import { SystemProviderTimer } from './ProviderLifecycle';
import { ProviderOperationRunner } from './ProviderOperationRunner';
import {
  ProviderSemanticPlannerConfig,
  ProviderSemanticPlannerObserverPort
} from './ProviderSemanticPlanner';

export enum LocalAIGatewayRuntimeCompositionErrorCode {
  DIGEST_REQUIRED = 'DIGEST_REQUIRED',
  CREDENTIALS_REQUIRED = 'CREDENTIALS_REQUIRED',
  MODEL_REGISTRATION_REJECTED = 'MODEL_REGISTRATION_REJECTED',
  MODEL_REGISTRATION_MISSING = 'MODEL_REGISTRATION_MISSING'
}

export class LocalAIGatewayRuntimeCompositionError extends Error {
  readonly code: LocalAIGatewayRuntimeCompositionErrorCode;

  constructor(code: LocalAIGatewayRuntimeCompositionErrorCode, message: string) {
    super(message);
    this.name = 'LocalAIGatewayRuntimeCompositionError';
    this.code = code;
  }
}

export class LocalAIGatewayMcpRuntimeConfig {
  runtimeConfig: ProductionAgentRuntimeConfig = new ProductionAgentRuntimeConfig();
  plannerConfig: ProviderSemanticPlannerConfig = new ProviderSemanticPlannerConfig();
  transportProfile: LocalAIGatewayTransportProfile = new LocalAIGatewayTransportProfile();
  priceSnapshot: ProviderPriceSnapshot = new ProviderPriceSnapshot();
}

export class LocalAIGatewayMcpRuntimePorts {
  runtimePorts: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
  digest?: ConnectorDigestPort;
  credentials?: ProviderCredentialPort;
  timer?: ProviderTimerPort;
  httpClient?: LocalAIGatewayHttpClientPort;
  plannerObserver?: ProviderSemanticPlannerObserverPort;
  memoryContext?: PlanningMemoryContextPort;
  toolExtensions: McpRuntimeToolExtension[] = [];
}

class LocalAIGatewayProviderAssembly {
  registered: RegisteredModelProvider;
  provider: GenericModelProvider;

  constructor(registered: RegisteredModelProvider, provider: GenericModelProvider) {
    this.registered = registered;
    this.provider = provider;
  }
}

function assembleProvider(config: LocalAIGatewayMcpRuntimeConfig,
  ports: LocalAIGatewayMcpRuntimePorts): LocalAIGatewayProviderAssembly {
  if (ports.digest === undefined) {
    throw new LocalAIGatewayRuntimeCompositionError(LocalAIGatewayRuntimeCompositionErrorCode.DIGEST_REQUIRED,
      'Local AI Gateway production composition requires a digest port');
  }
  if (ports.credentials === undefined) {
    throw new LocalAIGatewayRuntimeCompositionError(LocalAIGatewayRuntimeCompositionErrorCode.CREDENTIALS_REQUIRED,
      'Local AI Gateway production composition requires a credential port');
  }
  const catalog: ProviderCatalog = new ProviderCatalog(ports.digest);
  if (!catalog.registerModel(createLocalAIGatewayModelProfile(config.transportProfile), config.priceSnapshot)) {
    throw new LocalAIGatewayRuntimeCompositionError(
      LocalAIGatewayRuntimeCompositionErrorCode.MODEL_REGISTRATION_REJECTED,
      'Local AI Gateway model and price snapshot registration was rejected');
  }
  const registered: RegisteredModelProvider | undefined = catalog.getModel(config.transportProfile.registryModelId);
  if (registered === undefined) {
    throw new LocalAIGatewayRuntimeCompositionError(
      LocalAIGatewayRuntimeCompositionErrorCode.MODEL_REGISTRATION_MISSING,
      'Local AI Gateway registered model is unavailable');
  }
  const timer: ProviderTimerPort = ports.timer === undefined ? new SystemProviderTimer() : ports.timer;
  const client: LocalAIGatewayHttpClientPort = ports.httpClient === undefined ?
    new ArkTsLocalAIGatewayHttpClient() : ports.httpClient;
  const transport: LocalAIGatewayModelTransport =
    new LocalAIGatewayModelTransport(config.transportProfile, client);
  const provider: GenericModelProvider = new GenericModelProvider(registered, transport,
    new ProviderOperationRunner(ports.credentials, timer));
  return new LocalAIGatewayProviderAssembly(registered, provider);
}

/** Builds the concrete Local AI Gateway Provider chain and returns only the production Agent Facade. */
export async function createLocalAIGatewayMcpProductionAgentRuntime(config: LocalAIGatewayMcpRuntimeConfig,
  ports: LocalAIGatewayMcpRuntimePorts, adapter: McpAgentAdapter,
  registry: ToolRegistry, requiredToolIds: string[] = []): Promise<AgentRuntimeFacade> {
  const assembly: LocalAIGatewayProviderAssembly = assembleProvider(config, ports);
  return await createProviderMcpProductionAgentRuntime(config.runtimeConfig, ports.runtimePorts, adapter, registry,
    assembly.registered, assembly.provider, config.plannerConfig, ports.plannerObserver, ports.memoryContext,
    requiredToolIds, ports.toolExtensions);
}

/** Restores durable tasks through the same concrete Local AI Gateway Provider chain. */
export async function createRecoveredLocalAIGatewayMcpProductionAgentRuntime(
  config: LocalAIGatewayMcpRuntimeConfig, ports: LocalAIGatewayMcpRuntimePorts, adapter: McpAgentAdapter,
  registry: ToolRegistry, requiredToolIds: string[] = []): Promise<AgentRuntimeFacade> {
  const assembly: LocalAIGatewayProviderAssembly = assembleProvider(config, ports);
  return await createRecoveredProviderMcpProductionAgentRuntime(config.runtimeConfig, ports.runtimePorts,
    adapter, registry, assembly.registered, assembly.provider, config.plannerConfig,
    ports.plannerObserver, ports.memoryContext, requiredToolIds, ports.toolExtensions);
}
