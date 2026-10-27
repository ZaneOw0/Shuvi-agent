import common from '@ohos.app.ability.common';
import util from '@ohos.util';
import { PrivacyClass, RiskLevel } from '@harmony_agent/agent-contracts';
import {
  AgentApplicationBackend, AgentApplicationBackendConfig, AgentFrontendAuthorizationDecision,
  AgentFrontendAuthorizationPrompt, AgentFrontendCommandReceipt, AgentRuntimeFacade, ProductionAgentRuntimeConfig,
  ProductionAgentRuntimePorts, RuntimeClockPort, RuntimeIdGeneratorPort, SingleAgentCollaborationSelector,
  SingleAgentHostPorts, SingleAgentHostResourcePort, SingleAgentHostRuntimeFactoryPort, ToolRegistry,
  createProductionAgentRuntime
} from '@harmony_agent/agent-runtime';
import { McpClientManager } from '@harmony_agent/mcp-client';
import { KnowledgeAssembly } from '../../knowledge/infra/KnowledgeAssembly';
import { AgentHostDigest } from './AgentHostDigest';
import { AgentRdbOpenPort, NativeAgentRdbOpen } from './AgentRdbResources';
import { KnowledgeExecutionResource } from './KnowledgeExecutionResource';
import {
  KNOWLEDGE_RUNTIME_POLICY, KNOWLEDGE_RUNTIME_PROVIDER, KNOWLEDGE_RUNTIME_TOOL_ID, KnowledgeToolAdapterFactory,
  KnowledgeToolPlanner, KnowledgeToolPreparer, createKnowledgeToolEntry
} from './KnowledgeTaskSupport';
import { SearchAuthorizationPreviews } from './SearchAuthorizationPreview';
import { SessionModelCredentials } from './SessionModelCredentials';
import { SessionModelHttpClient } from './SessionModelHttpClient';
import { ArkTsDeepSeekHttpClient } from './DeepSeekHttpClient';
import {
  ShuviAuthorizationPort, ShuviRuntimeSession, ShuviRuntimeSessionFactory, ShuviRuntimeSessionPort, ShuviSessionResources
} from './ShuviRuntimeSession';

const KNOWLEDGE_OWNER: string = 'shuvi-local-owner-v1';

class KnowledgeClock implements RuntimeClockPort { nowMs(): number { return Date.now(); } }
class KnowledgeIds implements RuntimeIdGeneratorPort {
  nextId(kind: string,_request: string): string { return kind+'-'+util.generateRandomUUID(); }
}
class DisabledKnowledgeMcp implements SingleAgentHostResourcePort {
  async open(): Promise<void> {}
  async close(): Promise<void> {}
}
class LocalKnowledgeCredentials extends SessionModelCredentials {
  configure(value: Uint8Array): void { value.fill(0); }
  open(): Promise<void> { return Promise.resolve(); }
  close(): Promise<void> { return Promise.resolve(); }
}
class KnowledgeResource implements SingleAgentHostResourcePort {
  private readonly assembly: KnowledgeAssembly; private opened: boolean = false; private closing?: Promise<void>;
  constructor(assembly: KnowledgeAssembly) { this.assembly = assembly; }
  async open(): Promise<void> {
    if (this.closing !== undefined) { await this.closing; }
    if (!this.opened) { await this.assembly.acquire(); this.opened = true; }
  }
  close(): Promise<void> {
    if (!this.opened) { return Promise.resolve(); }
    if (this.closing !== undefined) { return this.closing; }
    this.closing = this.assembly.release().then((): void => {
      this.opened = false; this.closing = undefined;
    }, (error: Error): void => {
      this.closing = undefined; throw error;
    });
    return this.closing;
  }
}
class KnowledgeResources implements ShuviSessionResources {
  // This local-only session cannot resolve a DeepSeek credential because no secret is ever configured.
  credentials: SessionModelCredentials = new LocalKnowledgeCredentials();
  memory: KnowledgeResource;
  execution: KnowledgeExecutionResource;
  constructor(opener: AgentRdbOpenPort,assembly: KnowledgeAssembly,digest: AgentHostDigest) {
    this.memory = new KnowledgeResource(assembly);
    this.execution = new KnowledgeExecutionResource(opener,KNOWLEDGE_OWNER,KNOWLEDGE_RUNTIME_POLICY,digest);
  }
}
class KnowledgeBackendFactory implements SingleAgentHostRuntimeFactoryPort {
  private readonly ports: ProductionAgentRuntimePorts;
  constructor(ports: ProductionAgentRuntimePorts) { this.ports = ports; }
  async create(): Promise<AgentRuntimeFacade> {
    const config: ProductionAgentRuntimeConfig = new ProductionAgentRuntimeConfig();
    config.policyVersion = KNOWLEDGE_RUNTIME_POLICY; config.grantTtlMs = 60000;
    return createProductionAgentRuntime(config,this.ports);
  }
}

class LocalKnowledgeAuthorization implements ShuviAuthorizationPort {
  async decide(backend: AgentApplicationBackend,_previews: SearchAuthorizationPreviews,
    prompt: AgentFrontendAuthorizationPrompt,approved: boolean): Promise<AgentFrontendCommandReceipt> {
    const expires: number = Date.parse(prompt.expiresAt);
    if (!approved || prompt.toolId !== KNOWLEDGE_RUNTIME_TOOL_ID || prompt.providerId !== KNOWLEDGE_RUNTIME_PROVIDER ||
      prompt.riskLevel !== RiskLevel.LOW || prompt.estimatedCostMicros !== 0 || !Number.isFinite(expires) || expires <= Date.now()) {
      throw new Error('KNOWLEDGE_AUTHORIZATION_REJECTED');
    }
    const decision: AgentFrontendAuthorizationDecision = new AgentFrontendAuthorizationDecision();
    decision.policyRequestId = prompt.requestId; decision.taskId = prompt.taskId; decision.approved = true;
    return await backend.authorize(decision);
  }
}

export function knowledgeFrontendConfig(): AgentApplicationBackendConfig {
  const config: AgentApplicationBackendConfig = new AgentApplicationBackendConfig();
  config.userId = KNOWLEDGE_OWNER; config.privacyClass = PrivacyClass.PERSONAL;
  config.consentContext.interactiveAllowed = true; config.requestedBudget.maxWallTimeMs = 30000;
  config.requestedBudget.maxToolCalls = 1; config.requestedBudget.maxAgentActivations = 1;
  config.requestedBudget.maxMonetaryCostMicros = 0; return config;
}

export class KnowledgeRuntimeFactory implements ShuviRuntimeSessionFactory {
  private readonly opener: AgentRdbOpenPort; private readonly assembly: KnowledgeAssembly; private readonly debug: boolean;
  private readonly onOutcomeRejected: (taskId: string) => void;
  constructor(opener: AgentRdbOpenPort,assembly: KnowledgeAssembly,debug: boolean,
    onOutcomeRejected: (taskId: string) => void = (_taskId: string): void => {}) {
    this.opener = opener; this.assembly = assembly; this.debug = debug; this.onOutcomeRejected = onOutcomeRejected;
  }
  create(): ShuviRuntimeSessionPort {
    if (!this.debug) { throw new Error('KNOWLEDGE_RUNTIME_DEBUG_ONLY'); }
    const digest: AgentHostDigest = new AgentHostDigest(); const resources: KnowledgeResources = new KnowledgeResources(this.opener,this.assembly,digest);
    resources.execution.onOutcomeRejected = this.onOutcomeRejected;
    const registry: ToolRegistry = new ToolRegistry();
    if (!registry.register(createKnowledgeToolEntry(digest)).accepted) { throw new Error('KNOWLEDGE_TOOL_REGISTRATION_FAILED'); }
    const ids: KnowledgeIds = new KnowledgeIds(); const ports: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
    ports.clock = new KnowledgeClock(); ports.ids = ids; ports.planner = new KnowledgeToolPlanner();
    ports.collaboration = new SingleAgentCollaborationSelector(); ports.persistence = resources.execution;
    ports.toolPreparer = new KnowledgeToolPreparer(registry,digest,ids);
    ports.adapterFactory = new KnowledgeToolAdapterFactory(this.assembly.runtimeSearch,resources.execution,digest);
    const host: SingleAgentHostPorts = new SingleAgentHostPorts(); host.credentialStore = resources.credentials;
    host.executionStorage = resources.execution; host.memoryStorage = resources.memory;
    host.mcpClient = new DisabledKnowledgeMcp(); host.runtimeFactory = new KnowledgeBackendFactory(ports);
    const backend: AgentApplicationBackend = new AgentApplicationBackend(knowledgeFrontendConfig(),host);
    return new ShuviRuntimeSession(backend,resources,new SessionModelHttpClient(new ArkTsDeepSeekHttpClient()),
      new McpClientManager(),new SearchAuthorizationPreviews(),undefined,new LocalKnowledgeAuthorization());
  }
}

export function knowledgeRuntimeFactory(context: common.Context,debug: boolean,
  onOutcomeRejected: (taskId: string) => void = (_taskId: string): void => {}): KnowledgeRuntimeFactory {
  return new KnowledgeRuntimeFactory(new NativeAgentRdbOpen(context),KnowledgeAssembly.forContext(context),debug,onOutcomeRejected);
}
