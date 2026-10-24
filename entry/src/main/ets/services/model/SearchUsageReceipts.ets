import { ContractCodec, ContractValidator, ToolInvocation, ToolOutcome, ToolOutcomeStatus } from '@harmony_agent/agent-contracts';
import { StoredOperation } from '@harmony_agent/agent-storage';
import {
  ConnectorClockPort, ConnectorDigestPort, McpAgentAdapter, McpClientToolPort, McpGrantVerifierPort,
  McpInvocationPolicyBridge, McpProviderRegistry, McpReadOnlyToolPolicyRegistry, SHUVI_WEB_SEARCH_TOOL_ID,
  canonicalJson
} from '@harmony_agent/agent-connectors';
import {
  McpAggregateResult, McpCancellationSignal, McpCapabilityRef, McpTool, McpToolResult
} from '@harmony_agent/mcp-client';

/** Supplier-reported units, not a monetary charge or a durable billing receipt. */
export class SearchUsage {
  schemaVersion: string = '1.0';
  requestId: string = '';
  provider: string = 'tavily';
  state: string = 'unknown';
  unit?: string;
  credits?: number;
  providerRequestId?: string;
}
class UsageMeta { shuviSearchUsage?: SearchUsage; }
class RawResult { _meta?: UsageMeta; structuredContent?: Object; }
class SearchResultIdentity { requestId?: string; provider?: string; query?: string; schemaVersion?: string; }
function record(value: Object | undefined): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}
function uuid(value: string | undefined): boolean {
  return typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

/** Parse typed JSON, then validate every consumed field; a type annotation is not validation. */
export function readSearchUsage(result: McpToolResult): SearchUsage | undefined {
  try {
    const structured = result.structuredContent;
    if (result.isError || !record(result.raw) || structured === undefined || !record(structured)) return undefined;
    const encoded = JSON.stringify(result.raw);
    if (encoded.length > 1048576) return undefined;
    const raw: RawResult = JSON.parse(encoded);
    const rawStructured = raw.structuredContent;
    if (!record(raw._meta) || rawStructured === undefined || !record(rawStructured) ||
      canonicalJson(rawStructured) !== canonicalJson(structured)) return undefined;
    const usage = raw._meta?.shuviSearchUsage;
    if (usage === undefined || !record(usage)) return undefined;
    const identity: SearchResultIdentity = JSON.parse(JSON.stringify(structured));
    if (usage.schemaVersion !== '1.0' || usage.provider !== 'tavily' || !uuid(usage.requestId) ||
      usage.requestId !== identity.requestId || identity.provider !== 'tavily' || identity.schemaVersion !== '1.0') return undefined;
    const keys = Object.keys(usage);
    const allowed: string[] = ['schemaVersion', 'requestId', 'provider', 'state', 'unit', 'credits', 'providerRequestId'];
    if (keys.some((key: string): boolean => allowed.indexOf(key) < 0)) return undefined;
    if (usage.state === 'unknown') {
      if (keys.length !== 4) return undefined;
    } else if (usage.state === 'known') {
      if (usage.unit !== 'credits' || typeof usage.credits !== 'number' || !Number.isFinite(usage.credits) ||
        usage.credits < 0 || usage.credits > Number.MAX_SAFE_INTEGER) return undefined;
      if (usage.providerRequestId !== undefined && (typeof usage.providerRequestId !== 'string' ||
        !/^[A-Za-z0-9_-]{1,128}$/.test(usage.providerRequestId))) return undefined;
    } else { return undefined; }
    return usage;
  } catch (error) { return undefined; }
}

class CapturedUsage {
  requestId: string = '';
  argumentsDigest: string = '';
  resultDigest: string = '';
  usage: SearchUsage = new SearchUsage();
  owner: string = '';
  valid: boolean = true;
}
class BoundUsage {
  invocation?: ToolInvocation;
  identity: string = '';
  outcomeDigest: string = '';
  captured?: CapturedUsage;
}

/** Per-session bounded memory. Never evict and reuse IDs; a full/closed ledger yields unknown. */
export class SearchUsageReceipts {
  private readonly digest: ConnectorDigestPort;
  private readonly captured: Map<string, CapturedUsage> = new Map<string, CapturedUsage>();
  private readonly bound: Map<string, BoundUsage> = new Map<string, BoundUsage>();
  private readonly providerRequests: Map<string, CapturedUsage> = new Map<string, CapturedUsage>();
  private closed: boolean = false;
  constructor(digest: ConnectorDigestPort) { this.digest = digest; }

  capture(argumentsValue: Object, result: McpToolResult): void {
    const structured = result.structuredContent;
    if (this.closed || result.isError || structured === undefined || !record(structured)) return;
    try {
      const content: SearchResultIdentity = JSON.parse(JSON.stringify(structured));
      const requestId = content.requestId;
      if (requestId === undefined || !uuid(requestId)) return;
      const previous = this.captured.get(requestId);
      if (previous !== undefined) { previous.valid = false; return; }
      if (this.captured.size >= 128) return;
      const receipt = new CapturedUsage();
      receipt.requestId = requestId;
      receipt.argumentsDigest = this.digest.digest(canonicalJson(argumentsValue));
      receipt.resultDigest = this.digest.digest(canonicalJson(structured));
      const usage = readSearchUsage(result);
      if (usage !== undefined) receipt.usage = usage;
      receipt.usage.requestId = requestId;
      const providerId = receipt.usage.providerRequestId;
      if (providerId !== undefined) {
        const reused = this.providerRequests.get(providerId);
        if (reused !== undefined) { reused.valid = false; receipt.valid = false; }
        else { this.providerRequests.set(providerId, receipt); }
      }
      this.captured.set(requestId, receipt);
    } catch (error) { /* Unparseable data cannot supply a usage receipt. */ }
  }

  bind(invocation: ToolInvocation, outcome: ToolOutcome): void {
    if (this.closed) return;
    try {
      if (!ContractValidator.validateToolInvocation(invocation).valid ||
        !ContractValidator.validateToolOutcome(outcome).valid || invocation.toolId !== SHUVI_WEB_SEARCH_TOOL_ID ||
        invocation.invocationId !== outcome.invocationId) return;
      const identity = this.digest.digest(ContractCodec.stringify(invocation));
      const outcomeDigest = this.digest.digest(ContractCodec.stringify(outcome));
      const existing = this.bound.get(invocation.invocationId);
      if (existing !== undefined) {
        if (existing.identity !== identity || existing.outcomeDigest !== outcomeDigest) {
          if (existing.captured !== undefined) existing.captured.valid = false;
          existing.identity = ''; // A conflicting replay remains unusable for this session.
        }
        return;
      }
      if (this.bound.size >= 128) return;
      const binding = new BoundUsage(); binding.identity = identity; binding.outcomeDigest = outcomeDigest;
      binding.invocation = ContractCodec.parseToolInvocation(ContractCodec.stringify(invocation));
      this.bound.set(invocation.invocationId, binding);
      if (outcome.status !== ToolOutcomeStatus.SUCCEEDED || outcome.resultJson === undefined) return;
      const content: SearchResultIdentity = JSON.parse(outcome.resultJson);
      if (!record(content) || content.requestId === undefined) return;
      const receipt = this.captured.get(content.requestId);
      if (receipt === undefined || !receipt.valid) return;
      if (receipt.owner !== '' && receipt.owner !== identity) { receipt.valid = false; return; }
      if (receipt.argumentsDigest !== invocation.argumentsDigest ||
        this.digest.digest(canonicalJson(JSON.parse(invocation.argumentsJson))) !== invocation.argumentsDigest ||
        receipt.resultDigest !== outcome.resultDigest ||
        this.digest.digest(outcome.resultJson) !== outcome.resultDigest) return;
      receipt.owner = identity;
      binding.captured = receipt;
    } catch (error) { /* Unknown remains unknown; accounting must not invent a zero. */ }
  }

  lookup(invocation: ToolInvocation, outcome: ToolOutcome): SearchUsage | undefined {
    if (this.closed) return undefined;
    const binding = this.bound.get(invocation.invocationId);
    if (binding === undefined || binding.identity !== this.digest.digest(ContractCodec.stringify(invocation)) ||
      binding.outcomeDigest !== this.digest.digest(ContractCodec.stringify(outcome))) return undefined;
    const receipt = binding.captured;
    if (receipt === undefined || !receipt.valid) return undefined;
    const copy: SearchUsage = JSON.parse(JSON.stringify(receipt.usage));
    return copy;
  }

  lookupOperation(operation: StoredOperation, outcome: ToolOutcome): SearchUsage | undefined {
    const intent = operation.intent;
    const invocation = this.bound.get(intent.invocationId)?.invocation;
    if (invocation === undefined || invocation.operationId !== intent.operationId ||
      invocation.taskId !== intent.taskId || invocation.stepId !== intent.stepId || invocation.attemptId !== intent.attemptId ||
      invocation.toolId !== intent.toolId || invocation.toolIdentityVersion !== intent.toolIdentityVersion ||
      invocation.schemaDigest !== intent.schemaDigest || invocation.argumentsDigest !== intent.argumentsDigest ||
      (invocation.idempotencyKey === undefined ? 'attempt:' + invocation.attemptId : invocation.idempotencyKey) !== intent.idempotencyKey) {
      return undefined;
    }
    return this.lookup(invocation, outcome);
  }

  close(): void { this.closed = true; this.captured.clear(); this.bound.clear(); this.providerRequests.clear(); }
}

class UsageCapturingClient implements McpClientToolPort {
  private readonly delegate: McpClientToolPort;
  private readonly receipts: SearchUsageReceipts;
  constructor(delegate: McpClientToolPort, receipts: SearchUsageReceipts) { this.delegate = delegate; this.receipts = receipts; }
  listTools(): Promise<McpAggregateResult<McpTool>> { return this.delegate.listTools(); }
  async callTool(ref: McpCapabilityRef, args: Object, cancellation?: McpCancellationSignal): Promise<McpToolResult> {
    // Per-call snapshot, not a shared current-invocation variable (concurrent calls may finish out of order).
    const snapshot: Object = JSON.parse(JSON.stringify(args));
    const result = await this.delegate.callTool(ref, args, cancellation);
    if (ref.serverId === 'shuvi-web-search' && ref.name === 'web_search') this.receipts.capture(snapshot, result);
    return result;
  }
}

/** Preserve upstream policy/grant checks and catalog; associate only the exact completed outcome. */
export class SearchUsageMcpAdapter extends McpAgentAdapter {
  private readonly receipts: SearchUsageReceipts;
  constructor(client: McpClientToolPort, providers: McpProviderRegistry, policies: McpReadOnlyToolPolicyRegistry,
    digest: ConnectorDigestPort, clock: ConnectorClockPort, grants: McpGrantVerifierPort,
    bridge: McpInvocationPolicyBridge, receipts: SearchUsageReceipts) {
    super(new UsageCapturingClient(client, receipts), providers, policies, digest, clock, grants, bridge);
    this.receipts = receipts;
  }
  async invoke(invocation: ToolInvocation): Promise<ToolOutcome> {
    if (!ContractValidator.validateToolInvocation(invocation).valid) return super.invoke(invocation);
    const snapshot = ContractCodec.parseToolInvocation(ContractCodec.stringify(invocation));
    const outcome = await super.invoke(snapshot);
    this.receipts.bind(snapshot, outcome);
    return outcome;
  }
}
