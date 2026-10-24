import common from '@ohos.app.ability.common';
import util from '@ohos.util';
import { PrivacyClass, ToolInvocation, ToolOutcome } from '@harmony_agent/agent-contracts';
import { BudgetAmount } from '@harmony_agent/agent-core';
import {
  AgentFrontendAuthorizationPrompt, AgentFrontendCommandReceipt, AgentFrontendEventListener,
  AgentFrontendSubscription, AgentFrontendTaskHandle, AgentFrontendTaskRequest, AgentFrontendTaskState,
  RuntimeClockPort, RuntimeIdGeneratorPort, ToolRegistry
} from '@harmony_agent/agent-runtime';
import { RuntimeExecutionRecoveryBridgeConfig, RuntimeOutcomeAccountingPort, StoredOperation } from '@harmony_agent/agent-storage';
import { McpClientManager, McpManagerOptions } from '@harmony_agent/mcp-client';
import {
  ConnectorClockPort, McpClientManagerToolPort, McpGrantVerification,
  McpGrantVerifierPort, McpInvocationPolicyBridge, McpProviderRegistry, McpReadOnlyToolPolicyRegistry,
  ProviderPriceSnapshot, ShuviWebSearchMcpClientToolPort
} from '@harmony_agent/agent-connectors';
import { DeepSeekProfile } from './DeepSeekProtocol';
import { AgentHostDigest } from './AgentHostDigest';
import { NativeAgentRdbOpen, AgentRdbOpenPort } from './AgentRdbResources';
import { ShuviDeviceHostResources } from './ShuviDeviceHostResources';
import { ShuviModelBackendConfig, ShuviModelBackendPorts } from './ShuviModelBackend';
import { ShuviRuntimeSessionFactory, ShuviRuntimeSessionPort, createShuviRuntimeSession } from './ShuviRuntimeSession';
import { SearchUsageMcpAdapter, SearchUsageReceipts } from './SearchUsageReceipts';

// Startup verification is deliberately read-only. This is not a tool execution grant.
export class StartupDeniedGrants implements McpGrantVerifierPort {
  verify(_invocation: ToolInvocation): McpGrantVerification { return new McpGrantVerification(); }
}

// An absent receipt is unknown usage, never an invented zero-cost settlement.
export class UnsettledSearchAccounting implements RuntimeOutcomeAccountingPort {
  actualForOutcome(_operation: StoredOperation, _outcome: ToolOutcome): BudgetAmount | undefined { return undefined; }
}

class StartupClock implements ConnectorClockPort, RuntimeClockPort {
  nowIso(): string { return new Date().toISOString(); }
  nowMs(): number { return Date.now(); }
}
class StartupIds implements RuntimeIdGeneratorPort {
  nextId(kind: string, _requestId: string): string { return kind + '-' + util.generateRandomUUID(); }
}

export function startupBackendConfig(): ShuviModelBackendConfig {
  const config = new ShuviModelBackendConfig();
  config.frontend.userId = 'shuvi-local-owner-v1';
  config.frontend.privacyClass = PrivacyClass.PUBLIC;
  // All task budgets remain zero: this check cannot submit tasks.
  config.runtime.policyVersion = 'shuvi-startup-check-v1';
  config.runtime.grantTtlMs = 60000;
  config.planner.estimatedInputTokens = 8192;
  config.planner.maxOutputTokens = 2048;
  config.planner.timeoutMs = 30000;
  config.planner.clarificationTtlMs = 60000;
  config.planner.maxSteps = 3;
  config.planner.maxPromptCharacters = 16000;
  config.planner.maxMemoryItems = 5;
  config.planner.maxMemoryCharacters = 2048;
  // Basic search PAYG estimate, not a receipt or a claim about this user's subscription.
  config.search.estimatedCostMicros = 8000;
  return config;
}

export function startupModelProfile(): DeepSeekProfile {
  const profile = new DeepSeekProfile();
  profile.modelId = 'deepseek-flash';
  profile.modelVersion = 'DeepSeek-V4.1-Flash-1017';
  profile.region = 'provider-managed'; // Routing label, not a data-residency guarantee.
  profile.maxInputTokens = 32768; // Application caps, intentionally below the provider limit.
  profile.maxOutputTokens = 2048;
  profile.privacyClasses = [PrivacyClass.PUBLIC];
  profile.available = true;
  return profile;
}

export function startupModelPrice(digest: AgentHostDigest): ProviderPriceSnapshot {
  const price = new ProviderPriceSnapshot();
  price.snapshotId = 'deepseek-flash-2026-10-23-peak-estimate';
  price.providerId = 'deepseek-direct';
  price.capabilityId = 'deepseek-flash';
  price.capabilityVersion = 'DeepSeek-V4.1-Flash-1017';
  price.region = 'provider-managed';
  price.inputMicrosPerMillionTokens = 300000;
  price.outputMicrosPerMillionTokens = 1200000;
  price.effectiveAt = '2026-10-23T00:00:00.000Z'; // Date checked, not the supplier's effective-date claim.
  price.snapshotDigest = digest.digest(JSON.stringify(price));
  return price;
}

/** Prevent even accidental page calls from executing tasks during startup-only acceptance. */
export class StartupOnlySession implements ShuviRuntimeSessionPort {
  private readonly delegate: ShuviRuntimeSessionPort;
  constructor(delegate: ShuviRuntimeSessionPort) { this.delegate = delegate; }
  start(key: Uint8Array): Promise<void> { return this.delegate.start(key); }
  stop(): Promise<void> { return this.delegate.stop(); }
  async submit(_request: AgentFrontendTaskRequest): Promise<AgentFrontendTaskHandle> { throw new Error('STARTUP_CHECK_ONLY'); }
  async authorize(_prompt: AgentFrontendAuthorizationPrompt, _approved: boolean): Promise<AgentFrontendCommandReceipt> {
    throw new Error('STARTUP_CHECK_ONLY');
  }
  async cancel(_taskId: string): Promise<AgentFrontendCommandReceipt> { throw new Error('STARTUP_CHECK_ONLY'); }
  async getTask(_taskId: string): Promise<AgentFrontendTaskState> { throw new Error('STARTUP_CHECK_ONLY'); }
  async subscribe(_taskId: string, _listener: AgentFrontendEventListener,
    _afterSequence: number): Promise<AgentFrontendSubscription> { throw new Error('STARTUP_CHECK_ONLY'); }
}

export class RuntimeStartupFactory implements ShuviRuntimeSessionFactory {
  private readonly opener: AgentRdbOpenPort;
  private readonly debugBuild: boolean;
  constructor(opener: AgentRdbOpenPort, debugBuild: boolean) {
    this.opener = opener; this.debugBuild = debugBuild;
  }

  create(): ShuviRuntimeSessionPort {
    if (!this.debugBuild) throw new Error('STARTUP_CHECK_DEBUG_ONLY');
    const config = startupBackendConfig();
    const recovery = new RuntimeExecutionRecoveryBridgeConfig();
    recovery.ownerId = config.frontend.userId;
    recovery.policyVersion = config.runtime.policyVersion;
    recovery.leaseTtlMs = 60000;
    recovery.outcomeAccounting = new UnsettledSearchAccounting();
    const resources = new ShuviDeviceHostResources(this.opener, recovery);
    const bridge = new McpInvocationPolicyBridge(resources.digest);
    const options: McpManagerOptions = {
      debugBuild: true, invocationPolicy: bridge, clientName: 'shuvi-runtime-startup', clientVersion: '1.0.0'
    };
    const manager = new McpClientManager(options);
    const ports = new ShuviModelBackendPorts();
    ports.manager = manager;
    const providers = new McpProviderRegistry(resources.digest);
    const policies = new McpReadOnlyToolPolicyRegistry();
    ports.providers = providers;
    ports.policies = policies;
    ports.registry = new ToolRegistry();
    ports.runtime.ids = new StartupIds();
    ports.runtime.clock = new StartupClock();
    ports.searchUsage = new SearchUsageReceipts(resources.digest);
    ports.adapter = new SearchUsageMcpAdapter(
      new ShuviWebSearchMcpClientToolPort(new McpClientManagerToolPort(manager)),
      providers, policies, resources.digest, new StartupClock(), new StartupDeniedGrants(), bridge, ports.searchUsage);
    return new StartupOnlySession(createShuviRuntimeSession(config, ports, resources,
      startupModelProfile(), startupModelPrice(resources.digest)));
  }
}

export function runtimeStartupFactory(context: common.Context, debugBuild: boolean): RuntimeStartupFactory {
  return new RuntimeStartupFactory(new NativeAgentRdbOpen(context), debugBuild);
}
