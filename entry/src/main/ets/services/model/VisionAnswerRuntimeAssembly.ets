import common from '@ohos.app.ability.common';
import util from '@ohos.util';
import { PrivacyClass } from '@harmony_agent/agent-contracts';
import {
  AgentApplicationBackend, AgentApplicationBackendConfig, AgentRuntimeFacade, ProductionAgentRuntimeConfig,
  ProductionAgentRuntimePorts, RuntimeClockPort, RuntimeIdGeneratorPort, SingleAgentCollaborationSelector,
  SingleAgentHostPorts, SingleAgentHostResourcePort, SingleAgentHostRuntimeFactoryPort, createProductionAgentRuntime
} from '@harmony_agent/agent-runtime';
import { McpClientManager } from '@harmony_agent/mcp-client';
import { AgentHostDigest } from './AgentHostDigest';
import { AgentRdbOpenPort, NativeAgentRdbOpen } from './AgentRdbResources';
import {
  AnswerExecutionPolicy, KnowledgeAnswerExecutionResource
} from './KnowledgeAnswerExecutionStore';
import { VisionAnswerContext, VisionAnswerAdapterFactory, VisionAnswerPlanner, VISION_ANSWER_POLICY, VISION_ANSWER_STEP_ID } from './VisionAnswerTaskSupport';
import { VisionChatTransportPort } from './VisionChatProtocol';
import { ArkTsVisionChatTransport } from './VisionChatTransport';
import { ArkTsDeepSeekHttpClient } from './DeepSeekHttpClient';
import { SessionModelCredentials } from './SessionModelCredentials';
import { SessionModelHttpClient } from './SessionModelHttpClient';
import { startupModelProfile } from './RuntimeStartupAssembly';
import { SearchAuthorizationPreviews } from './SearchAuthorizationPreview';
import { ShuviRuntimeSession, ShuviRuntimeSessionFactory, ShuviRuntimeSessionPort, ShuviSessionResources } from './ShuviRuntimeSession';

const VISION_ANSWER_OWNER: string = 'shuvi-local-owner-v1';
const VISION_ANSWER_SCHEMA: string = 'shuvi-vision-answer-1.0';
const VISION_ANSWER_STORE: string = 'shuvi_vision_answer_v1.db';
const VISION_ANSWER_MEMORY_STORE: string = 'shuvi_vision_answer_unused_memory_v1.db';

function visionAnswerExecutionPolicy(): AnswerExecutionPolicy {
  const policy: AnswerExecutionPolicy = new AnswerExecutionPolicy();
  policy.owner = VISION_ANSWER_OWNER; policy.schema = VISION_ANSWER_SCHEMA;
  policy.storeName = VISION_ANSWER_STORE; policy.memoryStoreName = VISION_ANSWER_MEMORY_STORE;
  policy.stepId = VISION_ANSWER_STEP_ID; return policy;
}

class VisionAnswerClock implements RuntimeClockPort { nowMs(): number { return Date.now(); } }
class VisionAnswerIds implements RuntimeIdGeneratorPort {
  nextId(kind: string, _request: string): string { return kind + '-' + util.generateRandomUUID(); }
}
class DisabledVisionAnswerResource implements SingleAgentHostResourcePort {
  async open(): Promise<void> {}
  async close(): Promise<void> {}
}
class VisionAnswerResources implements ShuviSessionResources {
  credentials: SessionModelCredentials = new SessionModelCredentials();
  memory: SingleAgentHostResourcePort = new DisabledVisionAnswerResource();
  execution: KnowledgeAnswerExecutionResource;
  constructor(opener: AgentRdbOpenPort, digest: AgentHostDigest) {
    this.execution = new KnowledgeAnswerExecutionResource(opener, digest, visionAnswerExecutionPolicy());
  }
}
class VisionAnswerBackendFactory implements SingleAgentHostRuntimeFactoryPort {
  private readonly ports: ProductionAgentRuntimePorts;
  constructor(ports: ProductionAgentRuntimePorts) { this.ports = ports; }
  async create(): Promise<AgentRuntimeFacade> {
    const config: ProductionAgentRuntimeConfig = new ProductionAgentRuntimeConfig();
    config.policyVersion = VISION_ANSWER_POLICY; config.grantTtlMs = 60000;
    return createProductionAgentRuntime(config, this.ports);
  }
}

/** A distinct PERSONAL profile; the ordinary PUBLIC chat path is never widened. */
export function visionAnswerFrontendConfig(): AgentApplicationBackendConfig {
  const config: AgentApplicationBackendConfig = new AgentApplicationBackendConfig();
  config.userId = VISION_ANSWER_OWNER; config.privacyClass = PrivacyClass.PERSONAL;
  config.consentContext.interactiveAllowed = true;
  config.requestedBudget.maxWallTimeMs = 60000;
  config.requestedBudget.maxInputTokens = 8192;
  config.requestedBudget.maxOutputTokens = 1024;
  config.requestedBudget.maxMonetaryCostMicros = 10000;
  config.requestedBudget.maxAgentActivations = 1;
  config.requestedBudget.maxToolCalls = 0;
  config.requestedBudget.maxRetries = 0;
  config.requestedBudget.maxReplans = 0;
  return config;
}

/** Direct session-key vision task; no tools, MCP, memory query, retry or public-chat widening. */
export class VisionAnswerRuntimeFactory implements ShuviRuntimeSessionFactory {
  private readonly opener: AgentRdbOpenPort;
  private readonly debug: boolean;
  private readonly context: VisionAnswerContext;
  private readonly modelId: string;
  private readonly onOutcomeRejected: (taskId: string) => void;
  private readonly injectedTransport?: VisionChatTransportPort;
  constructor(opener: AgentRdbOpenPort, debug: boolean, context: VisionAnswerContext, modelId: string,
    onOutcomeRejected: (taskId: string) => void = (_taskId: string): void => {},
    injectedTransport?: VisionChatTransportPort) {
    this.opener = opener; this.debug = debug; this.context = context; this.modelId = modelId;
    this.onOutcomeRejected = onOutcomeRejected; this.injectedTransport = injectedTransport;
  }
  create(): ShuviRuntimeSessionPort {
    if (!this.debug) { throw new Error('VISION_ANSWER_DEBUG_ONLY'); }
    if (this.modelId.length < 1 || this.modelId.length > 128 || !/^[a-zA-Z0-9._-]+$/.test(this.modelId)) {
      throw new Error('VISION_ANSWER_MODEL_INVALID');
    }
    const digest: AgentHostDigest = new AgentHostDigest();
    const resources: VisionAnswerResources = new VisionAnswerResources(this.opener, digest);
    resources.execution.onOutcomeRejected = this.onOutcomeRejected;
    const http: SessionModelHttpClient = new SessionModelHttpClient(new ArkTsDeepSeekHttpClient());
    const transport: VisionChatTransportPort = this.injectedTransport !== undefined ? this.injectedTransport :
      new ArkTsVisionChatTransport(http, resources.credentials);
    const ports: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
    const planner: VisionAnswerPlanner = new VisionAnswerPlanner();
    ports.clock = new VisionAnswerClock(); ports.ids = new VisionAnswerIds();
    ports.planner = planner; ports.toolPreparer = planner;
    ports.collaboration = new SingleAgentCollaborationSelector(); ports.persistence = resources.execution;
    ports.adapterFactory = new VisionAnswerAdapterFactory(transport, digest, this.context, this.modelId);
    const host: SingleAgentHostPorts = new SingleAgentHostPorts();
    host.credentialStore = resources.credentials; host.executionStorage = resources.execution;
    host.memoryStorage = resources.memory; host.mcpClient = new DisabledVisionAnswerResource();
    host.runtimeFactory = new VisionAnswerBackendFactory(ports);
    return new ShuviRuntimeSession(new AgentApplicationBackend(visionAnswerFrontendConfig(), host), resources, http,
      new McpClientManager(), new SearchAuthorizationPreviews());
  }
}

export function visionAnswerRuntimeFactory(context: common.Context, debug: boolean,
  answerContext: VisionAnswerContext,
  onOutcomeRejected: (taskId: string) => void = (_taskId: string): void => {}): VisionAnswerRuntimeFactory {
  return new VisionAnswerRuntimeFactory(new NativeAgentRdbOpen(context), debug, answerContext,
    startupModelProfile().modelId, onOutcomeRejected);
}
