import { ContractValidator, PolicyRequest, RiskLevel, SideEffect, WorkflowStep } from '@harmony_agent/agent-contracts';
import { AgentApplicationBackend, AgentFrontendAuthorizationDecision, AgentFrontendAuthorizationPrompt,
  AgentFrontendCommandReceipt, PlanningRequest, PreparedToolDispatch, ToolInvocationPreparerPort
} from '@harmony_agent/agent-runtime';
import { ConnectorDigestPort, SHUVI_WEB_SEARCH_SERVER_ID, SHUVI_WEB_SEARCH_TOOL_ID } from '@harmony_agent/agent-connectors';

class SearchArguments { query?: string; maxResults?: number; }

export class SearchAuthorizationPreview {
  requestId: string = '';
  taskId: string = '';
  stepId: string = '';
  operationId: string = '';
  argumentsDigest: string = '';
  query: string = '';
  maxResults: number = 0;
  estimatedCostMicros: number = 0;
  requestedAt: string = '';
  expiresAt: string = '';
  expiresAtMs: number = 0;
}

function copyPreview(source: SearchAuthorizationPreview): SearchAuthorizationPreview {
  const value: SearchAuthorizationPreview = new SearchAuthorizationPreview();
  value.requestId = source.requestId; value.taskId = source.taskId;
  value.stepId = source.stepId; value.operationId = source.operationId;
  value.argumentsDigest = source.argumentsDigest; value.query = source.query;
  value.maxResults = source.maxResults; value.estimatedCostMicros = source.estimatedCostMicros;
  value.requestedAt = source.requestedAt; value.expiresAt = source.expiresAt; value.expiresAtMs = source.expiresAtMs;
  return value;
}

class PreviewEntry {
  signature: string;
  preview: SearchAuthorizationPreview;
  constructor(signature: string, preview: SearchAuthorizationPreview) {
    this.signature = signature; this.preview = preview;
  }
}

// Application-owned, bounded and memory-only. It cannot grant permission or replace Runtime validation.
export class SearchAuthorizationPreviews {
  private entries: PreviewEntry[] = [];

  capture(prepared: PreparedToolDispatch, digest: ConnectorDigestPort, nowMs: number): boolean {
    try {
      if (!Number.isSafeInteger(nowMs) || nowMs < 0) return false;
      this.prune(nowMs);
      const policy: PolicyRequest = prepared.policyRequest;
      const invocation = prepared.invocation;
      if (!ContractValidator.validatePolicyRequest(policy).valid ||
        policy.toolId !== SHUVI_WEB_SEARCH_TOOL_ID || policy.providerId !== SHUVI_WEB_SEARCH_SERVER_ID ||
        policy.riskLevel !== RiskLevel.LOW || policy.sideEffect !== SideEffect.NONE ||
        policy.expiresAtMs <= nowMs || Date.parse(policy.expiresAt) !== policy.expiresAtMs ||
        !Number.isFinite(Date.parse(policy.requestedAt)) || Date.parse(policy.requestedAt) > nowMs ||
        invocation.taskId !== policy.taskId || invocation.stepId !== policy.stepId ||
        invocation.operationId !== policy.operationId || invocation.toolId !== policy.toolId ||
        invocation.toolIdentityVersion !== policy.toolIdentityVersion || invocation.schemaDigest !== policy.schemaDigest ||
        invocation.argumentsDigest !== policy.argumentsDigest ||
        typeof invocation.argumentsJson !== 'string' || invocation.argumentsJson.length > 8192 ||
        digest.digest(invocation.argumentsJson) !== policy.argumentsDigest) return false;
      const args: SearchArguments = JSON.parse(invocation.argumentsJson);
      if (args === null || typeof args !== 'object' || Array.isArray(args) ||
        Object.keys(args).length !== 2 || typeof args.query !== 'string' ||
        args.query.trim().length === 0 || args.query !== args.query.trim() ||
        typeof args.maxResults !== 'number' || !Number.isSafeInteger(args.maxResults) ||
        args.maxResults < 1 || args.maxResults > 10) return false;
      let length: number = 0;
      for (let index: number = 0; index < args.query.length; index++) {
        const code: number = args.query.charCodeAt(index);
        if (code >= 0xD800 && code <= 0xDBFF && index + 1 < args.query.length) {
          const low: number = args.query.charCodeAt(index + 1);
          if (low >= 0xDC00 && low <= 0xDFFF) index++;
        }
        length++;
      }
      if (length > 500) return false;
      const signature: string = digest.digest(JSON.stringify(prepared));
      if (signature.trim().length === 0) return false;
      const existing: PreviewEntry | undefined = this.entries.find((entry: PreviewEntry): boolean =>
        entry.preview.requestId === policy.requestId);
      if (existing !== undefined) {
        if (existing.signature === signature) return true;
        this.forgetTask(existing.preview.taskId);
        return false;
      }
      if (this.entries.length >= 32) return false;
      const preview: SearchAuthorizationPreview = new SearchAuthorizationPreview();
      preview.requestId = policy.requestId; preview.taskId = policy.taskId;
      preview.stepId = policy.stepId; preview.operationId = policy.operationId;
      preview.argumentsDigest = policy.argumentsDigest; preview.query = args.query; preview.maxResults = args.maxResults;
      preview.estimatedCostMicros = policy.estimatedCostMicros; preview.requestedAt = policy.requestedAt;
      preview.expiresAt = policy.expiresAt; preview.expiresAtMs = policy.expiresAtMs;
      this.entries.push(new PreviewEntry(signature, preview));
      return true;
    } catch (error) { return false; }
  }

  resolve(prompt: AgentFrontendAuthorizationPrompt, nowMs: number): SearchAuthorizationPreview | undefined {
    if (!Number.isSafeInteger(nowMs) || nowMs < 0) return undefined;
    this.prune(nowMs);
    const entry: PreviewEntry | undefined = this.entries.find((value: PreviewEntry): boolean =>
      value.preview.requestId === prompt.requestId && value.preview.taskId === prompt.taskId);
    if (entry === undefined || prompt.toolId !== SHUVI_WEB_SEARCH_TOOL_ID ||
      prompt.providerId !== SHUVI_WEB_SEARCH_SERVER_ID || prompt.riskLevel !== RiskLevel.LOW ||
      prompt.estimatedCostMicros !== entry.preview.estimatedCostMicros ||
      prompt.requestedAt !== entry.preview.requestedAt || prompt.expiresAt !== entry.preview.expiresAt) return undefined;
    return copyPreview(entry.preview);
  }

  forgetTask(taskId: string): void {
    this.entries = this.entries.filter((entry: PreviewEntry): boolean => entry.preview.taskId !== taskId);
  }
  clear(): void { this.entries = []; }
  private prune(nowMs: number): void {
    this.entries = this.entries.filter((entry: PreviewEntry): boolean => entry.preview.expiresAtMs > nowMs);
  }
}

export class PreviewingSearchPreparer implements ToolInvocationPreparerPort {
  private readonly delegate: ToolInvocationPreparerPort;
  private readonly previews: SearchAuthorizationPreviews;
  private readonly digest: ConnectorDigestPort;
  constructor(delegate: ToolInvocationPreparerPort, previews: SearchAuthorizationPreviews, digest: ConnectorDigestPort) {
    this.delegate = delegate; this.previews = previews; this.digest = digest;
  }
  prepare(request: PlanningRequest, step: WorkflowStep, nowMs: number): PreparedToolDispatch {
    const prepared: PreparedToolDispatch = this.delegate.prepare(request, step, nowMs);
    if (prepared.policyRequest.taskId !== request.envelope.taskId ||
      prepared.policyRequest.userId !== request.envelope.userId || prepared.policyRequest.stepId !== step.stepId ||
      !this.previews.capture(prepared, this.digest, nowMs)) return new PreparedToolDispatch();
    return prepared;
  }
}

// Call again at the confirmation click; a previously rendered card may already have expired.
export async function decideSearchAuthorization(backend: AgentApplicationBackend,
  previews: SearchAuthorizationPreviews, prompt: AgentFrontendAuthorizationPrompt,
  approved: boolean, nowMs: number): Promise<AgentFrontendCommandReceipt> {
  if (approved && previews.resolve(prompt, nowMs) === undefined) {
    throw new Error('SEARCH_AUTHORIZATION_PREVIEW_UNAVAILABLE');
  }
  const decision: AgentFrontendAuthorizationDecision = new AgentFrontendAuthorizationDecision();
  decision.policyRequestId = prompt.requestId; decision.taskId = prompt.taskId; decision.approved = approved;
  if (!approved) decision.denialReasonCode = 'userDenied';
  const receipt: AgentFrontendCommandReceipt = await backend.authorize(decision);
  if (receipt.accepted) previews.forgetTask(prompt.taskId);
  return receipt;
}
