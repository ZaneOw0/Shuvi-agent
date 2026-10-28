import {
  AgentErrorClass,
  ContractCodec,
  ContractValidator,
  SideEffect,
  ToolDescriptor,
  ToolInvocation,
  ToolOutcome,
  ToolOutcomeStatus,
  ToolSourceType
} from '@harmony_agent/agent-contracts';
import { ToolRegistryEntry } from '@harmony_agent/agent-runtime';
import {
  McpCapabilityKind,
  McpCapabilityRef,
  McpCancellationSource,
  McpClientError,
  McpErrorCode,
  McpTool,
  McpToolResult
} from '@harmony_agent/mcp-client';
import { canonicalJson, parseJsonObject } from './CanonicalJson';
import {
  ConnectorClockPort,
  ConnectorDigestPort,
  McpCatalogRefreshResult,
  McpClientToolPort,
  McpGrantVerification,
  McpGrantVerifierPort,
  McpProviderRegistration,
  McpToolPolicy
} from './McpConnectorTypes';
import { McpInvocationPolicyBridge } from './McpPolicyBridge';
import { McpProviderRegistry } from './McpProviderRegistry';
import { McpToolPolicyRegistry } from './McpToolPolicyRegistry';

function toolId(serverId: string, name: string): string {
  return 'mcp://' + encodeURIComponent(serverId) + '/tool/' + encodeURIComponent(name);
}

function copyEntry(source: ToolRegistryEntry): ToolRegistryEntry {
  const result: ToolRegistryEntry = new ToolRegistryEntry();
  result.descriptor = ContractCodec.parseToolDescriptor(ContractCodec.stringify(source.descriptor));
  result.registryVersion = source.registryVersion;
  result.registryDigest = source.registryDigest;
  result.descriptionDigest = source.descriptionDigest;
  result.retrievalRelationVersion = source.retrievalRelationVersion;
  result.estimatedCostMicros = source.estimatedCostMicros;
  result.requiresNetwork = source.requiresNetwork;
  result.enabled = source.enabled;
  return result;
}

function copyFailures<T>(source: T[]): T[] {
  return source.slice();
}

class McpToolErrorProjection {
  status: ToolOutcomeStatus = ToolOutcomeStatus.FAILED;
  errorClass: AgentErrorClass = AgentErrorClass.PROVIDER;
  code: string = 'MCP_TOOL_ERROR';
  message: string = 'MCP server reported a tool error';
}

function asRecord(value: Object | undefined): Record<string, Object> | undefined {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) return undefined;
  return value as Record<string, Object>;
}

function projectStructuredToolError(value: Object | undefined): McpToolErrorProjection {
  const result: McpToolErrorProjection = new McpToolErrorProjection();
  const envelope: Record<string, Object> | undefined = asRecord(value);
  if (envelope === undefined) return result;
  const schemaVersion: Object = envelope['schemaVersion'];
  const requestId: Object = envelope['requestId'];
  const error: Record<string, Object> | undefined = asRecord(envelope['error']);
  if (schemaVersion !== '1.0' || typeof requestId !== 'string' || requestId.trim().length === 0 ||
    error === undefined) return result;
  const codeValue: Object = error['code'];
  const messageValue: Object = error['message'];
  if (typeof codeValue !== 'string' || typeof messageValue !== 'string' || messageValue.trim().length === 0) {
    return result;
  }
  switch (codeValue) {
    case 'INVALID_ARGUMENT':
      result.errorClass = AgentErrorClass.INVALID_INPUT;
      result.code = codeValue;
      result.message = 'MCP tool rejected its arguments';
      return result;
    case 'CONFIGURATION':
      result.errorClass = AgentErrorClass.CONFIGURATION;
      result.code = codeValue;
      result.message = 'MCP tool is not configured';
      return result;
    case 'AUTHENTICATION':
      result.errorClass = AgentErrorClass.AUTHENTICATION;
      result.code = codeValue;
      result.message = 'MCP tool authentication failed';
      return result;
    case 'RATE_LIMITED':
      result.code = codeValue;
      result.message = 'MCP tool rate limit exceeded';
      return result;
    case 'QUOTA_EXCEEDED':
      result.errorClass = AgentErrorClass.BUDGET_EXHAUSTED;
      result.code = codeValue;
      result.message = 'MCP tool quota exhausted';
      return result;
    case 'NETWORK':
      result.errorClass = AgentErrorClass.NETWORK;
      result.code = codeValue;
      result.message = 'MCP tool upstream network failed';
      return result;
    case 'TIMEOUT':
      result.errorClass = AgentErrorClass.TIMEOUT;
      result.code = codeValue;
      result.message = 'MCP tool timed out';
      return result;
    case 'CANCELLED':
      result.status = ToolOutcomeStatus.CANCELLED;
      result.errorClass = AgentErrorClass.CANCELLED;
      result.code = codeValue;
      result.message = 'MCP tool was cancelled';
      return result;
    case 'INVALID_RESPONSE':
      result.errorClass = AgentErrorClass.SCHEMA_MISMATCH;
      result.code = codeValue;
      result.message = 'MCP tool returned an invalid upstream response';
      return result;
    case 'RESPONSE_TOO_LARGE':
      result.code = codeValue;
      result.message = 'MCP tool response exceeded its limit';
      return result;
    case 'UPSTREAM':
      result.code = codeValue;
      result.message = 'MCP tool upstream failed';
      return result;
    default:
      return result;
  }
}

export class McpAgentAdapter {
  private readonly client: McpClientToolPort;
  private readonly providers: McpProviderRegistry;
  private readonly policies: McpToolPolicyRegistry;
  private readonly digestPort: ConnectorDigestPort;
  private readonly clock: ConnectorClockPort;
  private readonly grantVerifier: McpGrantVerifierPort;
  private readonly policyBridge: McpInvocationPolicyBridge;
  private readonly activeCancellations: Map<string, McpCancellationSource> =
    new Map<string, McpCancellationSource>();
  private catalog: ToolRegistryEntry[] = [];

  constructor(client: McpClientToolPort, providers: McpProviderRegistry,
    policies: McpToolPolicyRegistry, digestPort: ConnectorDigestPort,
    clock: ConnectorClockPort, grantVerifier: McpGrantVerifierPort,
    policyBridge: McpInvocationPolicyBridge) {
    this.client = client;
    this.providers = providers;
    this.policies = policies;
    this.digestPort = digestPort;
    this.clock = clock;
    this.grantVerifier = grantVerifier;
    this.policyBridge = policyBridge;
  }

  async refreshCatalog(): Promise<McpCatalogRefreshResult> {
    const discovered = await this.client.listTools();
    const next: ToolRegistryEntry[] = [];
    for (let index: number = 0; index < discovered.items.length; index++) {
      const mapped: ToolRegistryEntry | undefined = this.mapTool(discovered.items[index]);
      if (mapped !== undefined) next.push(mapped);
    }
    next.sort((left: ToolRegistryEntry, right: ToolRegistryEntry): number => {
      if (left.descriptor.toolId < right.descriptor.toolId) return -1;
      if (left.descriptor.toolId > right.descriptor.toolId) return 1;
      return 0;
    });
    const result: McpCatalogRefreshResult = new McpCatalogRefreshResult();
    result.failures = copyFailures(discovered.errors);
    for (let index: number = 0; index < this.catalog.length; index++) {
      const replacement: ToolRegistryEntry | undefined = this.findEntry(next, this.catalog[index].descriptor.toolId);
      if (replacement === undefined ||
        replacement.descriptor.toolIdentityVersion !== this.catalog[index].descriptor.toolIdentityVersion) {
        result.invalidatedToolIds.push(this.catalog[index].descriptor.toolId);
      }
    }
    this.catalog = next;
    for (let index: number = 0; index < next.length; index++) result.entries.push(copyEntry(next[index]));
    return result;
  }

  getTool(toolIdValue: string): ToolRegistryEntry | undefined {
    const value: ToolRegistryEntry | undefined = this.findEntry(this.catalog, toolIdValue);
    return value === undefined ? undefined : copyEntry(value);
  }

  async invoke(invocation: ToolInvocation): Promise<ToolOutcome> {
    const startedAt: string = this.safeNow(invocation.createdAt);
    try {
      return await this.invokeChecked(invocation, startedAt);
    } catch (error) {
      return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.FAILED,
        AgentErrorClass.CONFIGURATION, 'MCP_ADAPTER_PORT_FAILURE', 'Required connector port failed');
    }
  }

  cancel(invocationId: string): boolean {
    const source: McpCancellationSource | undefined = this.activeCancellations.get(invocationId);
    if (source === undefined) return false;
    source.cancel();
    return true;
  }

  private async invokeChecked(invocation: ToolInvocation, startedAt: string): Promise<ToolOutcome> {
    if (!ContractValidator.validateToolInvocation(invocation).valid) {
      return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.FAILED,
        AgentErrorClass.INVALID_INPUT, 'INVALID_TOOL_INVOCATION', 'Tool invocation contract is invalid');
    }
    const entry: ToolRegistryEntry | undefined = this.findEntry(this.catalog, invocation.toolId);
    if (entry === undefined) {
      return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.FAILED,
        AgentErrorClass.CONFIGURATION, 'MCP_TOOL_NOT_REGISTERED', 'MCP tool is not in the current catalog');
    }
    const policy: McpToolPolicy | undefined = this.policies.get(entry.descriptor.providerId,
      entry.descriptor.capabilityName);
    const provider: McpProviderRegistration | undefined = this.providers.get(entry.descriptor.providerId);
    if (policy === undefined || provider === undefined ||
      this.identityVersion(provider, policy, entry.descriptor.schemaDigest) !== entry.descriptor.toolIdentityVersion) {
      return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED,
        AgentErrorClass.POLICY_DENIED, 'MCP_TOOL_IDENTITY_STALE', 'Controlled MCP profile or policy changed');
    }
    if (entry.descriptor.toolIdentityVersion !== invocation.toolIdentityVersion ||
      entry.descriptor.schemaDigest !== invocation.schemaDigest) {
      return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED,
        AgentErrorClass.POLICY_DENIED, 'MCP_TOOL_IDENTITY_STALE', 'MCP tool identity or schema changed');
    }
    let argumentsValue: Object;
    try {
      argumentsValue = parseJsonObject(invocation.argumentsJson);
    } catch (error) {
      return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.FAILED,
        AgentErrorClass.INVALID_INPUT, 'MCP_ARGUMENTS_INVALID', error instanceof Error ? error.message : String(error));
    }
    if (this.digestPort.digest(canonicalJson(argumentsValue)) !== invocation.argumentsDigest) {
      return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED,
        AgentErrorClass.POLICY_DENIED, 'MCP_ARGUMENTS_DIGEST_MISMATCH', 'Tool arguments changed after authorization');
    }
    if (policy.sideEffect !== SideEffect.NONE) {
      if (provider.profile.retryToolCallOnExpiredSession === true) {
        return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED,
          AgentErrorClass.CONFIGURATION, 'MCP_WRITE_SESSION_REPLAY_ENABLED',
          'Write tools require expired-session replay to be disabled in the server profile');
      }
      const args: Record<string, Object> = argumentsValue as Record<string, Object>;
      if (invocation.idempotencyKey === undefined || invocation.idempotencyKey.trim().length === 0 ||
        (policy.idempotencyKeyArgument !== undefined &&
          args[policy.idempotencyKeyArgument] !== invocation.idempotencyKey) ||
        (policy.operationIdArgument !== undefined && args[policy.operationIdArgument] !== invocation.operationId)) {
        return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED,
          AgentErrorClass.INVALID_INPUT, 'MCP_WRITE_BINDING_INVALID',
          'Write invocation must bind its idempotency key and operation to authorized arguments');
      }
    }
    let grant: McpGrantVerification;
    try {
      grant = this.grantVerifier.verify(invocation);
    } catch (error) {
      return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED,
        AgentErrorClass.POLICY_DENIED, 'MCP_GRANT_VERIFIER_FAILED', 'Runtime grant verifier failed closed');
    }
    if (!grant.allowed) {
      return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED,
        AgentErrorClass.POLICY_DENIED, grant.code, 'Runtime authorization grant was rejected');
    }
    const ref: McpCapabilityRef = {
      serverId: entry.descriptor.providerId,
      kind: McpCapabilityKind.TOOL,
      name: entry.descriptor.capabilityName
    };
    if (!this.policyBridge.arm(invocation, ref, argumentsValue, provider.profileDigest)) {
      return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.DENIED,
        AgentErrorClass.POLICY_DENIED, 'MCP_POLICY_BRIDGE_REJECTED', 'MCP policy ticket could not be created');
    }
    if (this.activeCancellations.has(invocation.invocationId)) {
      this.policyBridge.disarm(invocation.invocationId);
      return this.failure(invocation.invocationId, startedAt, ToolOutcomeStatus.FAILED,
        AgentErrorClass.CONFIGURATION, 'MCP_INVOCATION_ALREADY_ACTIVE', 'MCP invocation is already active');
    }
    const cancellation: McpCancellationSource = new McpCancellationSource();
    this.activeCancellations.set(invocation.invocationId, cancellation);
    try {
      const result: McpToolResult = await this.client.callTool(ref, argumentsValue, cancellation);
      this.policyBridge.disarm(invocation.invocationId);
      return this.success(invocation.invocationId, startedAt, result, policy);
    } catch (error) {
      this.policyBridge.disarm(invocation.invocationId);
      const outcome: ToolOutcome = this.clientFailure(invocation.invocationId, startedAt, error);
      if (policy.sideEffect !== SideEffect.NONE &&
        !(error instanceof McpClientError && error.requestDispatched === false) &&
        !(error instanceof McpClientError && error.code === McpErrorCode.POLICY_DENIED &&
          error.requestDispatched !== true)) {
        outcome.status = ToolOutcomeStatus.UNKNOWN_OUTCOME;
      }
      return outcome;
    } finally {
      this.activeCancellations.delete(invocation.invocationId);
    }
  }

  private mapTool(tool: McpTool): ToolRegistryEntry | undefined {
    if (tool.ref.kind !== McpCapabilityKind.TOOL || tool.ref.name !== tool.name) return undefined;
    const provider: McpProviderRegistration | undefined = this.providers.get(tool.ref.serverId);
    const policy: McpToolPolicy | undefined = this.policies.get(tool.ref.serverId, tool.name);
    if (provider === undefined || policy === undefined) return undefined;
    const inputSchemaJson: string = canonicalJson(tool.inputSchema);
    const outputSchemaJson: string | undefined = tool.outputSchema === undefined ? undefined :
      canonicalJson(tool.outputSchema);
    const schemaDigest: string = this.digestPort.digest('mcp-schema-v1|' + inputSchemaJson + '|' +
      (outputSchemaJson === undefined ? '' : outputSchemaJson));
    const identityVersion: string = this.identityVersion(provider, policy, schemaDigest);
    const descriptor: ToolDescriptor = new ToolDescriptor();
    descriptor.toolId = toolId(tool.ref.serverId, tool.name);
    descriptor.sourceType = ToolSourceType.MCP;
    descriptor.providerId = tool.ref.serverId;
    descriptor.capabilityName = tool.name;
    descriptor.capabilityVersion = provider.profileVersion;
    descriptor.toolIdentityVersion = identityVersion;
    descriptor.displayName = tool.title === undefined ? tool.name : tool.title;
    descriptor.description = tool.description === undefined ? '' : tool.description;
    descriptor.inputSchemaJson = inputSchemaJson;
    descriptor.outputSchemaJson = outputSchemaJson;
    descriptor.schemaDigest = schemaDigest;
    descriptor.capabilityTags = policy.capabilityTags.slice();
    descriptor.riskLevel = policy.riskLevel;
    descriptor.sideEffect = policy.sideEffect;
    descriptor.permissionRequirements = policy.permissionRequirements.slice();
    descriptor.dataBoundary = policy.dataBoundary;
    descriptor.availability = 'available';
    descriptor.latencyClass = policy.latencyClass;
    descriptor.costClass = policy.costClass;
    descriptor.idempotencyMode = policy.idempotencyMode;
    descriptor.adapterRef = 'mcp:' + tool.ref.serverId;
    const entry: ToolRegistryEntry = new ToolRegistryEntry();
    entry.descriptor = descriptor;
    entry.registryVersion = identityVersion;
    entry.descriptionDigest = this.digestPort.digest(descriptor.description);
    entry.registryDigest = this.digestPort.digest('mcp-tool-registry-v1|' + identityVersion + '|' +
      entry.descriptionDigest + '|' + policy.capabilityTags.join(','));
    entry.retrievalRelationVersion = identityVersion;
    entry.estimatedCostMicros = policy.estimatedCostMicros;
    entry.requiresNetwork = true;
    entry.enabled = true;
    return entry;
  }

  private identityVersion(provider: McpProviderRegistration, policy: McpToolPolicy, schemaDigest: string): string {
    return this.digestPort.digest('mcp-tool-identity-v2|' + provider.profile.id + '|tool|' + policy.toolName +
      '|' + provider.profileVersion + '|' + provider.profileDigest + '|' + schemaDigest + '|' +
      canonicalJson(policy as Object));
  }

  private success(invocationId: string, startedAt: string, result: McpToolResult,
    policy: McpToolPolicy): ToolOutcome {
    if (result.isError) {
      const projection: McpToolErrorProjection = projectStructuredToolError(result.structuredContent);
      return this.failure(invocationId, startedAt, policy.sideEffect === SideEffect.NONE ? projection.status : ToolOutcomeStatus.UNKNOWN_OUTCOME,
        projection.errorClass, projection.code, projection.message);
    }
    let receipt: string | undefined = undefined;
    if (policy.sideEffect !== SideEffect.NONE) {
      const content: Object | undefined = result.structuredContent;
      const field: string | undefined = policy.receiptField;
      const value: Object | undefined = content === undefined || content === null || Array.isArray(content) ||
        typeof content !== 'object' || field === undefined ? undefined : (content as Record<string, Object>)[field];
      if (typeof value !== 'string' || value.trim().length === 0) {
        return this.failure(invocationId, startedAt, ToolOutcomeStatus.UNKNOWN_OUTCOME,
          AgentErrorClass.PROVIDER, 'MCP_WRITE_RECEIPT_MISSING', 'Write result has no controlled operation receipt');
      }
      receipt = value;
    }
    const outcome: ToolOutcome = new ToolOutcome();
    outcome.invocationId = invocationId;
    outcome.status = ToolOutcomeStatus.SUCCEEDED;
    outcome.startedAt = startedAt;
    outcome.finishedAt = this.safeNow(startedAt);
    const payload: Object = result.structuredContent === undefined ? result.content as Object :
      result.structuredContent;
    outcome.resultJson = canonicalJson(payload);
    outcome.resultDigest = this.digestPort.digest(outcome.resultJson);
    outcome.providerReceipt = receipt;
    return outcome;
  }

  private clientFailure(invocationId: string, startedAt: string, error: Object): ToolOutcome {
    if (!(error instanceof McpClientError)) {
      return this.failure(invocationId, startedAt, ToolOutcomeStatus.FAILED,
        AgentErrorClass.UNKNOWN, 'MCP_UNEXPECTED_ERROR', error instanceof Error ? error.message : String(error));
    }
    if (error.code === McpErrorCode.POLICY_DENIED) {
      return this.failure(invocationId, startedAt, ToolOutcomeStatus.DENIED,
        AgentErrorClass.POLICY_DENIED, error.code, error.message);
    }
    if (error.code === McpErrorCode.AUTHENTICATION) {
      return this.failure(invocationId, startedAt, ToolOutcomeStatus.FAILED,
        AgentErrorClass.AUTHENTICATION, error.code, error.message);
    }
    if (error.code === McpErrorCode.FORBIDDEN) {
      return this.failure(invocationId, startedAt, ToolOutcomeStatus.FAILED,
        AgentErrorClass.PERMISSION_DENIED, error.code, error.message);
    }
    if (error.code === McpErrorCode.NETWORK) {
      return this.failure(invocationId, startedAt, ToolOutcomeStatus.FAILED,
        AgentErrorClass.NETWORK, error.code, error.message);
    }
    if (error.code === McpErrorCode.TIMEOUT) {
      return this.failure(invocationId, startedAt, ToolOutcomeStatus.FAILED,
        AgentErrorClass.TIMEOUT, error.code, error.message);
    }
    if (error.code === McpErrorCode.CANCELLED) {
      return this.failure(invocationId, startedAt, ToolOutcomeStatus.CANCELLED,
        AgentErrorClass.CANCELLED, error.code, error.message);
    }
    if (error.code === McpErrorCode.INVALID_ARGUMENT) {
      return this.failure(invocationId, startedAt, ToolOutcomeStatus.FAILED,
        AgentErrorClass.INVALID_INPUT, error.code, error.message);
    }
    if (error.code === McpErrorCode.SCHEMA_MISMATCH) {
      return this.failure(invocationId, startedAt, ToolOutcomeStatus.FAILED,
        AgentErrorClass.SCHEMA_MISMATCH, error.code, error.message);
    }
    if (error.code === McpErrorCode.CONFIGURATION) {
      return this.failure(invocationId, startedAt, ToolOutcomeStatus.FAILED,
        AgentErrorClass.CONFIGURATION, error.code, error.message);
    }
    return this.failure(invocationId, startedAt, ToolOutcomeStatus.FAILED,
      AgentErrorClass.PROVIDER, error.code, error.message);
  }

  private failure(invocationId: string, startedAt: string, status: ToolOutcomeStatus,
    errorClass: AgentErrorClass, code: string, message: string): ToolOutcome {
    const outcome: ToolOutcome = new ToolOutcome();
    outcome.invocationId = invocationId;
    outcome.status = status;
    outcome.errorClass = errorClass;
    outcome.errorCode = code;
    outcome.errorMessage = message;
    outcome.startedAt = startedAt;
    outcome.finishedAt = this.safeNow(startedAt);
    return outcome;
  }

  private safeNow(fallback: string): string {
    try {
      return this.clock.nowIso();
    } catch (error) {
      return fallback.trim().length > 0 ? fallback : '1970-01-01T00:00:00.000Z';
    }
  }

  private findEntry(entries: ToolRegistryEntry[], toolIdValue: string): ToolRegistryEntry | undefined {
    for (let index: number = 0; index < entries.length; index++) {
      if (entries[index].descriptor.toolId === toolIdValue) return entries[index];
    }
    return undefined;
  }
}
