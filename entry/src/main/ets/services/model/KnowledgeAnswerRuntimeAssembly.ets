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
import { KnowledgeAnswerExecutionResource } from './KnowledgeAnswerExecutionStore';
import {
  KNOWLEDGE_ANSWER_POLICY, KnowledgeAnswerAdapterFactory, KnowledgeAnswerContext, KnowledgeAnswerPlanner
} from './KnowledgeAnswerTaskSupport';
import { DeepSeekProfile } from './DeepSeekProtocol';
import { createDeepSeekProvider } from './DeepSeekProvider';
import { startupModelPrice, startupModelProfile } from './RuntimeStartupAssembly';
import { SearchAuthorizationPreviews } from './SearchAuthorizationPreview';
import { SessionModelCredentials } from './SessionModelCredentials';
import { SessionModelHttpClient } from './SessionModelHttpClient';
import { ArkTsDeepSeekHttpClient } from './DeepSeekHttpClient';
import { ShuviRuntimeSession, ShuviRuntimeSessionFactory, ShuviRuntimeSessionPort, ShuviSessionResources } from './ShuviRuntimeSession';

const KNOWLEDGE_ANSWER_OWNER: string = 'shuvi-local-owner-v1';

class KnowledgeAnswerClock implements RuntimeClockPort { nowMs(): number { return Date.now(); } }
class KnowledgeAnswerIds implements RuntimeIdGeneratorPort {
  nextId(kind: string, _request: string): string { return kind + '-' + util.generateRandomUUID(); }
}
class DisabledKnowledgeAnswerResource implements SingleAgentHostResourcePort {
  async open(): Promise<void> {}
  async close(): Promise<void> {}
}
class KnowledgeAnswerResources implements ShuviSessionResources {
  credentials: SessionModelCredentials = new SessionModelCredentials();
  memory: SingleAgentHostResourcePort = new DisabledKnowledgeAnswerResource();
  execution: KnowledgeAnswerExecutionResource;
  constructor(opener: AgentRdbOpenPort, digest: AgentHostDigest) {
    this.execution = new KnowledgeAnswerExecutionResource(opener, digest);
  }
}
class KnowledgeAnswerBackendFactory implements SingleAgentHostRuntimeFactoryPort {
  private readonly ports: ProductionAgentRuntimePorts;
  constructor(ports: ProductionAgentRuntimePorts) { this.ports = ports; }
  async create(): Promise<AgentRuntimeFacade> {
    const config: ProductionAgentRuntimeConfig = new ProductionAgentRuntimeConfig();
    config.policyVersion = KNOWLEDGE_ANSWER_POLICY; config.grantTtlMs = 60000;
    return createProductionAgentRuntime(config, this.ports);
  }
}

/** A distinct PERSONAL profile; the ordinary PUBLIC chat profile is never widened. */
export function knowledgeAnswerProfile(): DeepSeekProfile {
  const profile: DeepSeekProfile = startupModelProfile();
  profile.privacyClasses = [PrivacyClass.PERSONAL];
  return profile;
}

export function knowledgeAnswerFrontendConfig(): AgentApplicationBackendConfig {
  const config: AgentApplicationBackendConfig = new AgentApplicationBackendConfig();
  config.userId = KNOWLEDGE_ANSWER_OWNER; config.privacyClass = PrivacyClass.PERSONAL;
  config.consentContext.interactiveAllowed = true;
  config.requestedBudget.maxWallTimeMs = 45000;
  config.requestedBudget.maxInputTokens = 8192;
  config.requestedBudget.maxOutputTokens = 1024;
  config.requestedBudget.maxMonetaryCostMicros = 10000;
  config.requestedBudget.maxAgentActivations = 1;
  config.requestedBudget.maxToolCalls = 0;
  config.requestedBudget.maxRetries = 0;
  config.requestedBudget.maxReplans = 0;
  return config;
}

/** Independent PERSONAL model task; no MCP, tools, memory query or automatic retry. */
export class KnowledgeAnswerRuntimeFactory implements ShuviRuntimeSessionFactory {
  private readonly opener: AgentRdbOpenPort;
  private readonly debug: boolean;
  private readonly context: KnowledgeAnswerContext;
  private readonly onOutcomeRejected: (taskId: string) => void;
  constructor(opener: AgentRdbOpenPort, debug: boolean, context: KnowledgeAnswerContext,
    onOutcomeRejected: (taskId: string) => void = (_taskId: string): void => {}) {
    this.opener = opener; this.debug = debug; this.context = context; this.onOutcomeRejected = onOutcomeRejected;
  }
  create(): ShuviRuntimeSessionPort {
    if (!this.debug) { throw new Error('KNOWLEDGE_ANSWER_DEBUG_ONLY'); }
    const digest: AgentHostDigest = new AgentHostDigest();
    const resources: KnowledgeAnswerResources = new KnowledgeAnswerResources(this.opener, digest);
    resources.execution.onOutcomeRejected = this.onOutcomeRejected;
    const http: SessionModelHttpClient = new SessionModelHttpClient(new ArkTsDeepSeekHttpClient());
    const model = createDeepSeekProvider(knowledgeAnswerProfile(), startupModelPrice(digest), digest, resources.credentials, http);
    const ports: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
    const planner: KnowledgeAnswerPlanner = new KnowledgeAnswerPlanner();
    ports.clock = new KnowledgeAnswerClock(); ports.ids = new KnowledgeAnswerIds();
    ports.planner = planner; ports.toolPreparer = planner;
    ports.collaboration = new SingleAgentCollaborationSelector(); ports.persistence = resources.execution;
    ports.adapterFactory = new KnowledgeAnswerAdapterFactory(model.provider, model.registered, digest, this.context);
    const host: SingleAgentHostPorts = new SingleAgentHostPorts();
    host.credentialStore = resources.credentials; host.executionStorage = resources.execution;
    host.memoryStorage = resources.memory; host.mcpClient = new DisabledKnowledgeAnswerResource();
    host.runtimeFactory = new KnowledgeAnswerBackendFactory(ports);
    return new ShuviRuntimeSession(new AgentApplicationBackend(knowledgeAnswerFrontendConfig(), host), resources, http,
      new McpClientManager(), new SearchAuthorizationPreviews());
  }
}

export function knowledgeAnswerRuntimeFactory(context: common.Context, debug: boolean,
  answerContext: KnowledgeAnswerContext,
  onOutcomeRejected: (taskId: string) => void = (_taskId: string): void => {}): KnowledgeAnswerRuntimeFactory {
  return new KnowledgeAnswerRuntimeFactory(new NativeAgentRdbOpen(context), debug, answerContext, onOutcomeRejected);
}
