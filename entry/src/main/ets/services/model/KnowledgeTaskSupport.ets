import {
  AgentErrorClass, ClarificationResponse, ContractValidator, DataBoundary, IdempotencyMode, PolicyRequest,
  PrivacyClass, RiskLevel, SideEffect, ToolDescriptor, ToolInvocation, ToolOutcome, ToolOutcomeStatus,
  ToolSourceType, WorkflowGraph, WorkflowInputBinding, WorkflowStep, WorkflowStepKind
} from '@harmony_agent/agent-contracts';
import {
  PlanningRequest, PlanningResult, PlanningStatus, PreparedToolDispatch, ProductionRuntimeAdapterFactoryPort,
  RuntimeIdGeneratorPort, RuntimeToolOutcomeSinkPort, SemanticPlannerPort, StepDispatchPort, StepDispatchReceipt,
  StepDispatchRequest, ToolInvocationPreparerPort, ToolRegistry, ToolRegistryEntry
} from '@harmony_agent/agent-runtime';
import { ParsedCancellation } from '../../knowledge/domain/ParsedDocumentModels';
import {
  KnowledgeRuntimeCitation, KnowledgeRuntimeSearchPort, KnowledgeRuntimeSearchRequest, KnowledgeRuntimeSearchResult
} from '../../knowledge/domain/KnowledgeRuntimePorts';
import { AgentHostDigest } from './AgentHostDigest';
import { KnowledgeExecutionResource } from './KnowledgeExecutionResource';

export const KNOWLEDGE_RUNTIME_POLICY: string = 'shuvi-local-knowledge-v1';
export const KNOWLEDGE_RUNTIME_TOOL_ID: string = 'native://shuvi/knowledge.search.local';
export const KNOWLEDGE_RUNTIME_PROVIDER: string = 'shuvi-local-knowledge';
const KNOWLEDGE_TOOL_VERSION: string = '1.0.0';
const KNOWLEDGE_MAX_RESULTS: number = 5;
const KNOWLEDGE_MAX_TOTAL_EXCERPT: number = 3200;

export class KnowledgeToolArguments {
  query: string = '';
  maxResults: number = KNOWLEDGE_MAX_RESULTS;
}

export function parseKnowledgeToolResult(json: string, query: string): KnowledgeRuntimeSearchResult | undefined {
  try {
    if (json.length > 24000) { return undefined; }
    const value: KnowledgeRuntimeSearchResult = JSON.parse(json);
    if (value === null || typeof value !== 'object' || Array.isArray(value) || value.schemaVersion !== '1.0' ||
      value.provider !== KNOWLEDGE_RUNTIME_PROVIDER || value.route !== 'local-direct' || value.query !== query ||
      !Array.isArray(value.citations) || value.citations.length > KNOWLEDGE_MAX_RESULTS) { return undefined; }
    const ids: string[] = []; let total: number = 0;
    for (let index: number = 0; index < value.citations.length; index++) {
      const citation: KnowledgeRuntimeCitation = value.citations[index];
      if (citation === null || typeof citation !== 'object' || Array.isArray(citation) || citation.citationId !== index+1 ||
        typeof citation.evidenceId !== 'string' || citation.evidenceId.length < 1 || citation.evidenceId.length > 512 ||
        ids.indexOf(citation.evidenceId) >= 0 || typeof citation.documentId !== 'string' || citation.documentId.length < 1 ||
        typeof citation.generation !== 'string' || citation.generation.length < 1 || typeof citation.title !== 'string' ||
        citation.title.length > 256 || typeof citation.excerpt !== 'string' || citation.excerpt.length < 1 || citation.excerpt.length > 800 ||
        typeof citation.kind !== 'string' || citation.kind.length < 1 || typeof citation.evidence !== 'string' ||
        citation.evidence.length < 1 || citation.evidence === 'Tag') { return undefined; }
      total += citation.excerpt.length;
      if (total > KNOWLEDGE_MAX_TOTAL_EXCERPT) { return undefined; }
      ids.push(citation.evidenceId);
    }
    return value;
  } catch { return undefined; }
}

/** Deterministic local retrieval. The model never decides whether the personal library is searched. */
export class KnowledgeToolPlanner implements SemanticPlannerPort {
  async plan(request: PlanningRequest): Promise<PlanningResult> {
    const result: PlanningResult = new PlanningResult(); const query: string = request.envelope.userIntent;
    if (!query.trim() || query !== query.trim() || query.length > 500 || request.envelope.privacyClass !== PrivacyClass.PERSONAL) {
      result.rejectionCode = 'KNOWLEDGE_INPUT_REJECTED'; return result;
    }
    const step: WorkflowStep = new WorkflowStep(); step.stepId = 'knowledge-search'; step.kind = WorkflowStepKind.TOOL;
    step.goal = '检索本机个人知识库的当前有效正文证据'; step.timeoutMs = 20000;
    step.capabilityRequirements = ['knowledge.local.search']; step.permissionRequirements = [];
    step.riskLevel = RiskLevel.LOW; step.sideEffect = SideEffect.NONE; step.idempotencyMode = IdempotencyMode.NONE;
    step.retryPolicyRef = 'no-retry'; step.verificationPolicyRef = KNOWLEDGE_RUNTIME_POLICY;
    step.expectedOutputSchemaJson = '{"type":"object"}';
    const queryBinding: WorkflowInputBinding = new WorkflowInputBinding(); queryBinding.name = 'query'; queryBinding.literalJson = JSON.stringify(query);
    const countBinding: WorkflowInputBinding = new WorkflowInputBinding(); countBinding.name = 'maxResults'; countBinding.literalJson = KNOWLEDGE_MAX_RESULTS.toString();
    step.inputBindings = [queryBinding,countBinding];
    const graph: WorkflowGraph = new WorkflowGraph(); graph.taskId = request.envelope.taskId;
    graph.workflowId = 'knowledge-'+request.envelope.taskId; graph.workflowVersion = '1'; graph.createdAt = new Date().toISOString();
    graph.steps = [step]; graph.entryStepIds = [step.stepId]; result.status = PlanningStatus.READY; result.workflow = graph; return result;
  }
  async resume(_request: PlanningRequest,_response: ClarificationResponse): Promise<PlanningResult> { return new PlanningResult(); }
  async replan(_request: PlanningRequest): Promise<PlanningResult> { return new PlanningResult(); }
  interrupt(_taskId: string): boolean { return false; }
}

export function createKnowledgeToolEntry(digest: AgentHostDigest): ToolRegistryEntry {
  const descriptor: ToolDescriptor = new ToolDescriptor(); descriptor.toolId = KNOWLEDGE_RUNTIME_TOOL_ID;
  descriptor.sourceType = ToolSourceType.NATIVE; descriptor.providerId = KNOWLEDGE_RUNTIME_PROVIDER;
  descriptor.capabilityName = 'knowledge.search.local'; descriptor.capabilityVersion = KNOWLEDGE_TOOL_VERSION;
  descriptor.displayName = '检索本机个人知识库'; descriptor.description = '只读检索当前有效且未归档的本机知识库正文证据。';
  descriptor.inputSchemaJson = '{"additionalProperties":false,"properties":{"maxResults":{"maximum":5,"minimum":1,"type":"integer"},"query":{"maxLength":500,"minLength":1,"type":"string"}},"required":["query","maxResults"],"type":"object"}';
  descriptor.outputSchemaJson = '{"type":"object"}';
  descriptor.schemaDigest = digest.digest('knowledge-tool-schema-v1|'+descriptor.inputSchemaJson+'|'+descriptor.outputSchemaJson);
  descriptor.toolIdentityVersion = digest.digest('knowledge-tool-identity-v1|'+descriptor.toolId+'|'+descriptor.capabilityVersion+'|'+descriptor.schemaDigest);
  descriptor.capabilityTags = ['knowledge.local.search','read-only']; descriptor.riskLevel = RiskLevel.LOW;
  descriptor.sideEffect = SideEffect.NONE; descriptor.permissionRequirements = []; descriptor.dataBoundary = DataBoundary.APP_SANDBOX;
  descriptor.availability = 'available'; descriptor.latencyClass = 'local-async'; descriptor.costClass = 'zero';
  descriptor.idempotencyMode = IdempotencyMode.NONE; descriptor.adapterRef = 'native:shuvi-knowledge';
  const entry: ToolRegistryEntry = new ToolRegistryEntry(); entry.descriptor = descriptor;
  entry.registryVersion = descriptor.toolIdentityVersion; entry.descriptionDigest = digest.digest(descriptor.description);
  entry.registryDigest = digest.digest('knowledge-tool-registry-v1|'+descriptor.toolIdentityVersion+'|'+entry.descriptionDigest);
  entry.retrievalRelationVersion = descriptor.toolIdentityVersion; entry.estimatedCostMicros = 0;
  entry.requiresNetwork = false; entry.enabled = true; return entry;
}

export class KnowledgeToolPreparer implements ToolInvocationPreparerPort {
  private readonly registry: ToolRegistry; private readonly digest: AgentHostDigest; private readonly ids: RuntimeIdGeneratorPort;
  constructor(registry: ToolRegistry,digest: AgentHostDigest,ids: RuntimeIdGeneratorPort) {
    this.registry = registry; this.digest = digest; this.ids = ids;
  }
  prepare(request: PlanningRequest,step: WorkflowStep,now: number): PreparedToolDispatch {
    try {
      const entry: ToolRegistryEntry | undefined = this.registry.activeEntries().find((item: ToolRegistryEntry): boolean =>
        item.descriptor.toolId === KNOWLEDGE_RUNTIME_TOOL_ID);
      const query: string = request.envelope.userIntent;
      if (entry === undefined || !Number.isSafeInteger(now) || now < 0 || now > 8640000000000000-60000 ||
        request.envelope.privacyClass !== PrivacyClass.PERSONAL || query.trim() !== query || query.length < 1 || query.length > 500 ||
        step.kind !== WorkflowStepKind.TOOL || step.stepId !== 'knowledge-search' || step.riskLevel !== RiskLevel.LOW ||
        step.sideEffect !== SideEffect.NONE || step.idempotencyMode !== IdempotencyMode.NONE || step.timeoutMs !== 20000 ||
        step.capabilityRequirements.length !== 1 || step.capabilityRequirements[0] !== 'knowledge.local.search' ||
        step.permissionRequirements.length !== 0 || step.inputBindings.length !== 2 ||
        step.inputBindings[0].name !== 'query' || step.inputBindings[0].literalJson !== JSON.stringify(query) ||
        step.inputBindings[1].name !== 'maxResults' || step.inputBindings[1].literalJson !== KNOWLEDGE_MAX_RESULTS.toString()) {
        return new PreparedToolDispatch();
      }
      const argumentsValue: KnowledgeToolArguments = new KnowledgeToolArguments(); argumentsValue.query = query;
      const argumentsJson: string = JSON.stringify(argumentsValue); const argumentsDigest: string = this.digest.digest(argumentsJson);
      const identity: string = request.envelope.requestId+':'+step.stepId; const expires: number = now+60000;
      const operation: string = this.ids.nextId('operation',identity); const policyId: string = this.ids.nextId('policyRequest',identity);
      const invocationId: string = this.ids.nextId('invocation',identity); const attempt: string = this.ids.nextId('attempt',identity);
      const policy: PolicyRequest = new PolicyRequest(); policy.requestId = policyId; policy.userId = request.envelope.userId;
      policy.taskId = request.envelope.taskId; policy.stepId = step.stepId; policy.operationId = operation;
      policy.toolId = entry.descriptor.toolId; policy.toolIdentityVersion = entry.descriptor.toolIdentityVersion;
      policy.providerId = entry.descriptor.providerId; policy.schemaDigest = entry.descriptor.schemaDigest;
      policy.argumentsDigest = argumentsDigest; policy.riskLevel = entry.descriptor.riskLevel; policy.sideEffect = entry.descriptor.sideEffect;
      policy.estimatedCostMicros = 0; policy.requestedAt = new Date(now).toISOString(); policy.expiresAtMs = expires;
      policy.expiresAt = new Date(expires).toISOString();
      const invocation: ToolInvocation = new ToolInvocation(); invocation.invocationId = invocationId;
      invocation.taskId = request.envelope.taskId; invocation.stepId = step.stepId; invocation.operationId = operation;
      invocation.attemptId = attempt; invocation.toolId = entry.descriptor.toolId;
      invocation.toolIdentityVersion = entry.descriptor.toolIdentityVersion; invocation.schemaDigest = entry.descriptor.schemaDigest;
      invocation.argumentsJson = argumentsJson; invocation.argumentsDigest = argumentsDigest; invocation.authorizationGrantId = '';
      invocation.timeoutMs = step.timeoutMs; invocation.createdAt = policy.requestedAt;
      const prepared: PreparedToolDispatch = new PreparedToolDispatch(); prepared.policyRequest = policy; prepared.invocation = invocation;
      return prepared;
    } catch { return new PreparedToolDispatch(); }
  }
}

class KnowledgeDispatchCancellation {
  readonly token: ParsedCancellation = new ParsedCancellation();
  cancel(): void { this.token.invalid = true; }
}

export class KnowledgeToolDispatcher implements StepDispatchPort {
  private readonly search: KnowledgeRuntimeSearchPort; private readonly execution: KnowledgeExecutionResource;
  private readonly digest: AgentHostDigest; private readonly sink: RuntimeToolOutcomeSinkPort;
  private readonly active: Map<string,KnowledgeDispatchCancellation> = new Map<string,KnowledgeDispatchCancellation>();
  constructor(search: KnowledgeRuntimeSearchPort,execution: KnowledgeExecutionResource,digest: AgentHostDigest,sink: RuntimeToolOutcomeSinkPort) {
    this.search = search; this.execution = execution; this.digest = digest; this.sink = sink;
  }
  dispatch(request: StepDispatchRequest): StepDispatchReceipt {
    const receipt: StepDispatchReceipt = new StepDispatchReceipt(); const invocation: ToolInvocation | undefined = request.toolInvocation;
    if (invocation === undefined || request.step.kind !== WorkflowStepKind.TOOL || request.step.stepId !== 'knowledge-search' ||
      invocation.toolId !== KNOWLEDGE_RUNTIME_TOOL_ID || this.active.size > 0) {
      receipt.rejectionCode = 'KNOWLEDGE_DISPATCH_REJECTED'; return receipt;
    }
    const cancellation: KnowledgeDispatchCancellation = new KnowledgeDispatchCancellation();
    this.active.set(request.dispatchId,cancellation); receipt.accepted = true;
    void this.execute(request,invocation,cancellation).catch((): void => {}); return receipt;
  }
  cancel(dispatchId: string): boolean {
    const cancellation: KnowledgeDispatchCancellation | undefined = this.active.get(dispatchId);
    if (cancellation === undefined) { return false; } cancellation.cancel(); return true;
  }
  private async execute(request: StepDispatchRequest,invocation: ToolInvocation,cancellation: KnowledgeDispatchCancellation): Promise<void> {
    const outcome: ToolOutcome = new ToolOutcome(); outcome.invocationId = invocation.invocationId;
    outcome.startedAt = new Date().toISOString();
    try {
      const args: KnowledgeToolArguments = JSON.parse(invocation.argumentsJson);
      if (!ContractValidator.validateToolInvocation(invocation).valid || invocation.schemaDigest.length < 1 ||
        args === null || typeof args !== 'object' || Array.isArray(args) || Object.keys(args).length !== 2 ||
        args.query.trim() !== args.query || args.query.length < 1 || args.query.length > 500 ||
        args.maxResults !== KNOWLEDGE_MAX_RESULTS || this.digest.digest(JSON.stringify(args)) !== invocation.argumentsDigest ||
        !this.execution.verify(invocation)) { throw new Error('KNOWLEDGE_INVOCATION_DENIED'); }
      const searchRequest: KnowledgeRuntimeSearchRequest = new KnowledgeRuntimeSearchRequest();
      searchRequest.query = args.query; searchRequest.maxResults = args.maxResults;
      const result: KnowledgeRuntimeSearchResult = await this.search.search(searchRequest,cancellation.token);
      cancellation.token.check(); const json: string = JSON.stringify(result);
      if (parseKnowledgeToolResult(json,args.query) === undefined) { throw new Error('KNOWLEDGE_RESULT_INVALID'); }
      outcome.status = ToolOutcomeStatus.SUCCEEDED; outcome.resultJson = json; outcome.resultDigest = this.digest.digest(json);
    } catch (error) {
      outcome.status = cancellation.token.invalid ? ToolOutcomeStatus.CANCELLED : ToolOutcomeStatus.FAILED;
      outcome.errorClass = cancellation.token.invalid ? AgentErrorClass.CANCELLED : AgentErrorClass.PROVIDER;
      outcome.errorCode = cancellation.token.invalid ? 'KNOWLEDGE_CANCELLED' : 'KNOWLEDGE_READ_FAILED';
    }
    outcome.finishedAt = new Date().toISOString(); this.active.delete(request.dispatchId);
    if (cancellation.token.invalid) { return; }
    await this.sink.complete(request.task.taskId,request.step.stepId,request.dispatchId,outcome);
  }
}

export class KnowledgeToolAdapterFactory implements ProductionRuntimeAdapterFactoryPort {
  private readonly search: KnowledgeRuntimeSearchPort; private readonly execution: KnowledgeExecutionResource; private readonly digest: AgentHostDigest;
  constructor(search: KnowledgeRuntimeSearchPort,execution: KnowledgeExecutionResource,digest: AgentHostDigest) {
    this.search = search; this.execution = execution; this.digest = digest;
  }
  create(sink: RuntimeToolOutcomeSinkPort): StepDispatchPort {
    return new KnowledgeToolDispatcher(this.search,this.execution,this.digest,sink);
  }
}
