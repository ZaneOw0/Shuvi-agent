import {
  DataBoundary,
  IdempotencyMode,
  RiskLevel,
  SideEffect,
  ToolInvocation,
  ToolOutcome
} from '@harmony_agent/agent-contracts';
import { ToolRegistryEntry } from '@harmony_agent/agent-runtime';
import {
  McpAggregateResult,
  McpCancellationSignal,
  McpCapabilityRef,
  McpServerFailure,
  McpServerProfile,
  McpTool,
  McpToolResult
} from '@harmony_agent/mcp-client';

export interface ConnectorDigestPort {
  digest(value: string): string;
}

export interface ConnectorClockPort {
  nowIso(): string;
}

export interface McpGrantVerifierPort {
  verify(invocation: ToolInvocation): McpGrantVerification;
}

export class McpGrantVerification {
  allowed: boolean = false;
  code: string = 'GRANT_DENIED';
}

export interface McpClientToolPort {
  listTools(): Promise<McpAggregateResult<McpTool>>;
  callTool(ref: McpCapabilityRef, argumentsValue: Object,
    cancellation?: McpCancellationSignal): Promise<McpToolResult>;
}

export class McpProviderRegistration {
  profile: McpServerProfile = { id: '', endpoint: '' };
  profileVersion: string = '';
  profileDigest: string = '';
}

export class McpToolPolicy {
  serverId: string = '';
  toolName: string = '';
  capabilityTags: string[] = [];
  permissionRequirements: string[] = [];
  riskLevel: RiskLevel = RiskLevel.LOW;
  dataBoundary: DataBoundary = DataBoundary.REMOTE_ALLOWED;
  latencyClass: string = 'network';
  costClass: string = 'provider';
  estimatedCostMicros: number = 0;
  sideEffect: SideEffect = SideEffect.NONE;
  idempotencyMode: IdempotencyMode = IdempotencyMode.NONE;
  /** Controlled top-level argument names. Values must already be covered by argumentsDigest. */
  idempotencyKeyArgument?: string;
  operationIdArgument?: string;
  /** Top-level structuredContent field containing the provider's durable operation receipt. */
  receiptField?: string;
}

/** Compatibility policy; McpReadOnlyToolPolicyRegistry still rejects all side effects. */
export class McpReadOnlyToolPolicy extends McpToolPolicy {}

export class McpCatalogRefreshResult {
  entries: ToolRegistryEntry[] = [];
  invalidatedToolIds: string[] = [];
  failures: McpServerFailure[] = [];
}

export interface McpToolOutcomeSinkPort {
  complete(taskId: string, stepId: string, dispatchId: string, outcome: ToolOutcome): void;
}
