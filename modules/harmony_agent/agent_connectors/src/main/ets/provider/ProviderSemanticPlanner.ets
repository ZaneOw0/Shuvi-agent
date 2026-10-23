import {
  ClarificationRequest,
  ClarificationResponse,
  ContractValidator,
  IdempotencyMode,
  RiskLevel,
  SideEffect,
  WorkflowGraph,
  WorkflowInputBinding,
  WorkflowStep,
  WorkflowStepKind
} from '@harmony_agent/agent-contracts';
import {
  CollaborationRoleAssignment,
  CollaborationPlanValidator,
  PlanningRequest,
  PlanningResult,
  PlanningStatus,
  PlanningMemoryContextItem,
  PlanningMemoryContextPort,
  PlanningMemoryContextRequest,
  PlanningMemoryContextResult,
  PLANNING_MEMORY_CONTEXT_VERSION,
  RuntimeClockPort,
  RuntimeIdGeneratorPort,
  SemanticPlannerPort
} from '@harmony_agent/agent-runtime';
import { parseJsonObject } from '../mcp/CanonicalJson';
import {
  ModelInvocation,
  ModelMessage,
  ModelProvider,
  ModelProviderResult,
  ProviderCapabilityKind,
  ProviderFinishReason,
  ProviderPriceSnapshot,
  ProviderUsage
} from './ProviderContracts';
import { ModelProviderProfile, RegisteredModelProvider } from './ProviderCatalog';
import { ProviderCancellationSource } from './ProviderLifecycle';

const PROVIDER_SEMANTIC_PLANNER_CONFIG_VERSION: string = '1.0';
const PLANNER_STEP_SCHEMA: string = '{"type":"object","additionalProperties":false,' +
  '"properties":{"stepId":{"type":"string"},"kind":{"type":"string"},"goal":{"type":"string"},' +
  '"dependencies":{"type":"array","items":{"type":"string"}},' +
  '"inputBindings":{"type":"array","items":{"type":"object","additionalProperties":false,' +
  '"properties":{"name":{"type":"string"},"sourceStepId":{"type":"string"},' +
  '"sourceOutputPath":{"type":"string"},"literalJson":{"type":"string"}},"required":["name"]}},' +
  '"expectedOutputSchemaJson":{"type":"string"},' +
  '"capabilityRequirements":{"type":"array","items":{"type":"string"}},' +
  '"sideEffect":{"type":"string"},"riskLevel":{"type":"string"},' +
  '"permissionRequirements":{"type":"array","items":{"type":"string"}},' +
  '"idempotencyMode":{"type":"string"},"timeoutMs":{"type":"integer"},' +
  '"retryPolicyRef":{"type":"string"},"verificationPolicyRef":{"type":"string"}},' +
  '"required":["stepId","kind","goal","dependencies","inputBindings","expectedOutputSchemaJson",' +
  '"capabilityRequirements","sideEffect","riskLevel","permissionRequirements","idempotencyMode",' +
  '"timeoutMs","retryPolicyRef","verificationPolicyRef"]}';
const PLANNER_OUTPUT_SCHEMA: string = '{"type":"object","additionalProperties":false,' +
  '"properties":{"status":{"type":"string","enum":["ready","clarificationRequired","rejected"]},' +
  '"workflow":{"type":"object","additionalProperties":false,' +
  '"properties":{"entryStepIds":{"type":"array","items":{"type":"string"}},' +
  '"steps":{"type":"array","items":' + PLANNER_STEP_SCHEMA + '}},' +
  '"required":["entryStepIds","steps"]},' +
  '"clarification":{"type":"object","additionalProperties":false,' +
  '"properties":{"questionCode":{"type":"string"},"prompt":{"type":"string"},' +
  '"responseSchemaJson":{"type":"string"}},' +
  '"required":["questionCode","prompt","responseSchemaJson"]},' +
  '"rejectionCode":{"type":"string"}},"required":["status"]}';
const PLANNER_SYSTEM_PROMPT: string = 'You are the semantic planning component of a headless agent runtime. ' +
  'Return only JSON matching the responseContract in the user message. Produce a declarative typed workflow, a clarification request, ' +
  'or a stable rejection. Never claim that a tool ran, never request product UI actions, and never include secrets.';

export enum ProviderPlanningPhase {
  PLAN = 'plan',
  RESUME = 'resume',
  REPLAN = 'replan'
}

export enum ProviderSemanticPlannerErrorCode {
  INVALID_CONFIGURATION = 'INVALID_CONFIGURATION',
  PROVIDER_IDENTITY_MISMATCH = 'PROVIDER_IDENTITY_MISMATCH'
}

export class ProviderSemanticPlannerError extends Error {
  readonly code: ProviderSemanticPlannerErrorCode;

  constructor(code: ProviderSemanticPlannerErrorCode, message: string) {
    super(message);
    this.name = 'ProviderSemanticPlannerError';
    this.code = code;
  }
}

export class ProviderSemanticPlannerConfig {
  configVersion: string = PROVIDER_SEMANTIC_PLANNER_CONFIG_VERSION;
  promptVersion: string = 'typed-workflow-v1';
  estimatedInputTokens: number = 0;
  maxOutputTokens: number = 0;
  temperature: number = 0;
  timeoutMs: number = 0;
  clarificationTtlMs: number = 0;
  maxSteps: number = 0;
  maxPromptCharacters: number = 0;
  maxMemoryItems: number = 0;
  maxMemoryCharacters: number = 0;
}

export class ProviderPlannerTrace {
  phase: ProviderPlanningPhase = ProviderPlanningPhase.PLAN;
  taskId: string = '';
  providerRequestId: string = '';
  agentActivationId: string = '';
  roleId: string = '';
  roleVersion: string = '';
  roleRegistryDigest: string = '';
  collaborationDecisionDigest: string = '';
  providerId: string = '';
  modelId: string = '';
  modelVersion: string = '';
  region: string = '';
  priceSnapshotId: string = '';
  finishReason: ProviderFinishReason = ProviderFinishReason.ERROR;
  planningStatus: PlanningStatus = PlanningStatus.REJECTED;
  rejectionCode: string = '';
  usage: ProviderUsage = new ProviderUsage();
}

export interface ProviderSemanticPlannerObserverPort {
  onGenerationCompleted(trace: ProviderPlannerTrace): void;
}

class NoopProviderSemanticPlannerObserver implements ProviderSemanticPlannerObserverPort {
  onGenerationCompleted(_trace: ProviderPlannerTrace): void {
  }
}

class ActiveProviderPlanning {
  taskId: string = '';
  cancellation: ProviderCancellationSource = new ProviderCancellationSource();
}

function validText(value: string): boolean {
  return value.trim().length > 0;
}

function objectRecord(value: Object | undefined): Record<string, Object> | undefined {
  if (value === undefined || value === null || Array.isArray(value) || typeof value !== 'object') {
    return undefined;
  }
  return value as Record<string, Object>;
}

function exactKeys(value: Record<string, Object>, allowed: string[]): boolean {
  const keys: string[] = Object.keys(value);
  for (let index: number = 0; index < keys.length; index++) {
    if (allowed.indexOf(keys[index]) < 0) return false;
  }
  return true;
}

function textField(value: Record<string, Object>, name: string): string | undefined {
  const field: Object | undefined = value[name];
  return typeof field === 'string' && validText(field as string) ? field as string : undefined;
}

function optionalTextField(value: Record<string, Object>, name: string): string | undefined {
  const field: Object | undefined = value[name];
  return typeof field === 'string' ? field as string : undefined;
}

function integerField(value: Record<string, Object>, name: string): number | undefined {
  const field: Object | undefined = value[name];
  return typeof field === 'number' && Number.isSafeInteger(field as number) ? field as number : undefined;
}

function stringArray(value: Object | undefined): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const result: string[] = [];
  for (let index: number = 0; index < value.length; index++) {
    if (typeof value[index] !== 'string' || !validText(value[index] as string)) return undefined;
    result.push(value[index] as string);
  }
  return result;
}

function validCount(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function validEpochMs(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0 && value <= 8640000000000000;
}

function validUsage(value: ProviderUsage): boolean {
  return validCount(value.inputTokens) && validCount(value.outputTokens) && validCount(value.totalTokens) &&
    validCount(value.providerReportedCostMicros) && validCount(value.settledCostMicros) &&
    value.totalTokens === value.inputTokens + value.outputTokens;
}

function jsonObjectText(value: string): boolean {
  try {
    parseJsonObject(value);
    return true;
  } catch (error) {
    return false;
  }
}

function jsonText(value: string): boolean {
  try {
    JSON.parse(value);
    return true;
  } catch (error) {
    return false;
  }
}

function workflowKind(value: string): WorkflowStepKind | undefined {
  if (value === WorkflowStepKind.LLM) return WorkflowStepKind.LLM;
  if (value === WorkflowStepKind.TOOL) return WorkflowStepKind.TOOL;
  if (value === WorkflowStepKind.VERIFY) return WorkflowStepKind.VERIFY;
  if (value === WorkflowStepKind.JOIN) return WorkflowStepKind.JOIN;
  if (value === WorkflowStepKind.USER_CONFIRMATION) return WorkflowStepKind.USER_CONFIRMATION;
  return undefined;
}

function sideEffect(value: string): SideEffect | undefined {
  if (value === SideEffect.NONE) return SideEffect.NONE;
  if (value === SideEffect.REVERSIBLE) return SideEffect.REVERSIBLE;
  if (value === SideEffect.IRREVERSIBLE) return SideEffect.IRREVERSIBLE;
  return undefined;
}

function riskLevel(value: string): RiskLevel | undefined {
  if (value === RiskLevel.LOW) return RiskLevel.LOW;
  if (value === RiskLevel.MEDIUM) return RiskLevel.MEDIUM;
  if (value === RiskLevel.HIGH) return RiskLevel.HIGH;
  if (value === RiskLevel.CRITICAL) return RiskLevel.CRITICAL;
  return undefined;
}

function idempotencyMode(value: string): IdempotencyMode | undefined {
  if (value === IdempotencyMode.NONE) return IdempotencyMode.NONE;
  if (value === IdempotencyMode.PROVIDER_KEY) return IdempotencyMode.PROVIDER_KEY;
  if (value === IdempotencyMode.RECONCILE) return IdempotencyMode.RECONCILE;
  return undefined;
}

function copyUsage(source: ProviderUsage): ProviderUsage {
  const result: ProviderUsage = new ProviderUsage();
  result.inputTokens = source.inputTokens;
  result.outputTokens = source.outputTokens;
  result.totalTokens = source.totalTokens;
  result.providerReportedCostMicros = source.providerReportedCostMicros;
  result.settledCostMicros = source.settledCostMicros;
  return result;
}

export class ProviderSemanticPlanner implements SemanticPlannerPort {
  private readonly provider: ModelProvider;
  private readonly profile: ModelProviderProfile;
  private readonly price: ProviderPriceSnapshot;
  private readonly config: ProviderSemanticPlannerConfig;
  private readonly clock: RuntimeClockPort;
  private readonly ids: RuntimeIdGeneratorPort;
  private readonly observer: ProviderSemanticPlannerObserverPort;
  private readonly memoryContext?: PlanningMemoryContextPort;
  private readonly activePlanning: ActiveProviderPlanning[] = [];

  constructor(registered: RegisteredModelProvider, provider: ModelProvider,
    config: ProviderSemanticPlannerConfig, clock: RuntimeClockPort, ids: RuntimeIdGeneratorPort,
    observer: ProviderSemanticPlannerObserverPort = new NoopProviderSemanticPlannerObserver(),
    memoryContext?: PlanningMemoryContextPort) {
    this.profile = registered.profileSnapshot();
    this.price = registered.priceSnapshot();
    this.validateConfiguration(config, provider, memoryContext);
    this.provider = provider;
    this.config = this.copyConfig(config);
    this.clock = clock;
    this.ids = ids;
    this.observer = observer;
    this.memoryContext = memoryContext;
  }

  async plan(request: PlanningRequest): Promise<PlanningResult> {
    return await this.invoke(ProviderPlanningPhase.PLAN, request);
  }

  async planForRole(request: PlanningRequest,
    role: CollaborationRoleAssignment): Promise<PlanningResult> {
    if (!this.validRoleBinding(request, role)) return this.rejected('PLANNER_ROLE_BINDING_INVALID');
    return await this.invoke(ProviderPlanningPhase.PLAN, request, undefined, role);
  }

  async resume(request: PlanningRequest, response: ClarificationResponse): Promise<PlanningResult> {
    if (response.taskId !== request.envelope.taskId || !jsonText(response.answerJson)) {
      return this.rejected('PLANNER_CLARIFICATION_RESPONSE_INVALID');
    }
    return await this.invoke(ProviderPlanningPhase.RESUME, request, response);
  }

  async resumeForRole(request: PlanningRequest, response: ClarificationResponse,
    role: CollaborationRoleAssignment): Promise<PlanningResult> {
    if (!this.validRoleBinding(request, role)) return this.rejected('PLANNER_ROLE_BINDING_INVALID');
    if (response.taskId !== request.envelope.taskId || !jsonText(response.answerJson)) {
      return this.rejected('PLANNER_CLARIFICATION_RESPONSE_INVALID');
    }
    return await this.invoke(ProviderPlanningPhase.RESUME, request, response, role);
  }

  async replan(request: PlanningRequest): Promise<PlanningResult> {
    if (request.previousWorkflow === undefined || request.affectedStepIds.length === 0) {
      return this.rejected('PLANNER_REPLAN_CONTEXT_REQUIRED');
    }
    return await this.invoke(ProviderPlanningPhase.REPLAN, request);
  }

  async replanForRole(request: PlanningRequest,
    role: CollaborationRoleAssignment): Promise<PlanningResult> {
    if (!this.validRoleBinding(request, role)) return this.rejected('PLANNER_ROLE_BINDING_INVALID');
    if (request.previousWorkflow === undefined || request.affectedStepIds.length === 0) {
      return this.rejected('PLANNER_REPLAN_CONTEXT_REQUIRED');
    }
    return await this.invoke(ProviderPlanningPhase.REPLAN, request, undefined, role);
  }

  interrupt(taskId: string): boolean {
    let interrupted: boolean = false;
    for (let i: number = this.activePlanning.length - 1; i >= 0; i--) {
      if (this.activePlanning[i].taskId === taskId) {
        interrupted = true;
        this.activePlanning[i].cancellation.cancel();
      }
    }
    return interrupted;
  }

  collaborativeBudgetRejectionCode(request: PlanningRequest, activations: number): string {
    if (!Number.isSafeInteger(activations) || activations <= 0 ||
      activations > request.envelope.executionBudget.maxAgentActivations) {
      return 'COLLABORATION_AGENT_BUDGET_EXCEEDED';
    }
    const perActivationInputTokens: number = this.config.estimatedInputTokens +
      this.config.maxMemoryCharacters;
    const inputTokens: number = perActivationInputTokens * activations;
    if (!Number.isSafeInteger(inputTokens) || inputTokens > request.envelope.executionBudget.maxInputTokens) {
      return 'COLLABORATION_INPUT_BUDGET_EXCEEDED';
    }
    const outputTokens: number = this.config.maxOutputTokens * activations;
    if (!Number.isSafeInteger(outputTokens) || outputTokens > request.envelope.executionBudget.maxOutputTokens) {
      return 'COLLABORATION_OUTPUT_BUDGET_EXCEEDED';
    }
    const costMicros: number = this.estimatedCostMicros(
      this.config.maxOutputTokens, perActivationInputTokens) * activations;
    if (!Number.isSafeInteger(costMicros) ||
      costMicros > request.envelope.executionBudget.maxMonetaryCostMicros) {
      return 'COLLABORATION_COST_BUDGET_EXCEEDED';
    }
    return '';
  }

  private validRoleBinding(request: PlanningRequest, role: CollaborationRoleAssignment): boolean {
    const plan = request.collaborationPlan;
    if (plan === undefined || !CollaborationPlanValidator.validate(plan, request.frame,
      request.envelope.executionBudget.maxAgentActivations).valid) return false;
    for (let i: number = 0; i < plan.assignments.length; i++) {
      const candidate: CollaborationRoleAssignment = plan.assignments[i];
      if (candidate.roleId === role.roleId && candidate.roleVersion === role.roleVersion &&
        candidate.roleRegistryDigest === role.roleRegistryDigest) return true;
    }
    return false;
  }

  private async invoke(phase: ProviderPlanningPhase, request: PlanningRequest,
    response?: ClarificationResponse,
    role?: CollaborationRoleAssignment): Promise<PlanningResult> {
    if (this.profile.privacyClasses.indexOf(request.envelope.privacyClass) < 0) {
      return this.rejected('PLANNER_PRIVACY_NOT_SUPPORTED');
    }
    let memory: PlanningMemoryContextResult | undefined = undefined;
    if (this.memoryContext !== undefined) {
      try {
        memory = this.memoryContext.retrieve(this.memoryRequest(request));
      } catch (error) {
        return this.rejected('PLANNER_MEMORY_CONTEXT_FAILED');
      }
      if (!this.validMemoryContext(request, memory)) {
        return this.rejected('PLANNER_MEMORY_CONTEXT_FAILED');
      }
    }
    const estimatedInputTokens: number = this.config.estimatedInputTokens +
      (memory === undefined ? 0 : memory.totalCharacters);
    if (!Number.isSafeInteger(estimatedInputTokens) ||
      estimatedInputTokens > request.envelope.executionBudget.maxInputTokens) {
      return this.rejected('PLANNER_INPUT_BUDGET_EXCEEDED');
    }
    const outputTokens: number = Math.min(this.config.maxOutputTokens,
      request.envelope.executionBudget.maxOutputTokens);
    if (!Number.isSafeInteger(outputTokens) || outputTokens <= 0) {
      return this.rejected('PLANNER_OUTPUT_BUDGET_EXHAUSTED');
    }
    const monetaryLimit: number = request.envelope.executionBudget.maxMonetaryCostMicros;
    if (this.estimatedCostMicros(outputTokens, estimatedInputTokens) > monetaryLimit) {
      return this.rejected('PLANNER_COST_BUDGET_EXCEEDED');
    }
    const prompt: string = this.prompt(phase, request, response, role, memory);
    if (prompt.length > this.config.maxPromptCharacters) {
      return this.rejected('PLANNER_PROMPT_TOO_LARGE');
    }
    const invocation: ModelInvocation = this.invocation(request, prompt, outputTokens);
    if (!validText(invocation.context.requestId) || !validText(invocation.context.operationId)) {
      return this.rejected('PLANNER_RUNTIME_ID_INVALID');
    }
    const activationId: string = role === undefined ? '' :
      this.ids.nextId('agentActivation', request.envelope.requestId);
    if (role !== undefined && !validText(activationId)) {
      return this.rejected('PLANNER_AGENT_ACTIVATION_ID_INVALID');
    }
    const active: ActiveProviderPlanning = new ActiveProviderPlanning();
    active.taskId = request.envelope.taskId;
    this.activePlanning.push(active);
    try {
      const generated: ModelProviderResult = await this.provider.generate(invocation, active.cancellation);
      const result: PlanningResult = this.parseResult(phase, request, invocation, generated);
      this.observe(phase, request, generated, result, role, activationId);
      return result;
    } finally {
      const index: number = this.activePlanning.indexOf(active);
      if (index >= 0) this.activePlanning.splice(index, 1);
    }
  }

  private invocation(request: PlanningRequest, prompt: string, outputTokens: number): ModelInvocation {
    const value: ModelInvocation = new ModelInvocation();
    value.context.requestId = this.ids.nextId('plannerRequest', request.envelope.requestId);
    value.context.taskId = request.envelope.taskId;
    value.context.stepId = 'semantic-planner';
    value.context.operationId = this.ids.nextId('plannerOperation', request.envelope.requestId);
    value.context.providerId = this.profile.providerId;
    value.context.region = this.profile.region;
    value.context.priceSnapshotId = this.price.snapshotId;
    value.context.timeoutMs = Math.min(this.config.timeoutMs,
      request.envelope.executionBudget.maxWallTimeMs);
    if (value.context.timeoutMs <= 0) value.context.timeoutMs = this.config.timeoutMs;
    value.modelId = this.profile.registryModelId;
    value.modelVersion = this.profile.modelVersion;
    const system: ModelMessage = new ModelMessage();
    system.role = 'system';
    system.content = PLANNER_SYSTEM_PROMPT + ' Prompt contract version: ' + this.config.promptVersion + '.';
    value.messages.push(system);
    const user: ModelMessage = new ModelMessage();
    user.role = 'user';
    user.content = prompt;
    value.messages.push(user);
    value.responseSchemaJson = PLANNER_OUTPUT_SCHEMA;
    value.maxOutputTokens = outputTokens;
    value.temperature = this.config.temperature;
    return value;
  }

  private prompt(phase: ProviderPlanningPhase, request: PlanningRequest,
    response?: ClarificationResponse, role?: CollaborationRoleAssignment,
    memory?: PlanningMemoryContextResult): string {
    let value: string = 'phase=' + phase + '\ncollaborationMode=' + request.collaborationMode +
      '\nplanningRequest=' + JSON.stringify(request);
    if (role !== undefined) value += '\nactiveRole=' + JSON.stringify(role);
    if (response !== undefined) value += '\nclarificationResponse=' + JSON.stringify(response);
    if (memory !== undefined) value += '\nmemoryContext=' + JSON.stringify(memory);
    value += '\nresponseContract=' + PLANNER_OUTPUT_SCHEMA +
      '\nReturn exactly one JSON object and no prose or markdown. For ready status, workflow must contain only ' +
      'entryStepIds and steps. The runtime assigns taskId, workflowId, workflowVersion, and createdAt; never return ' +
      'those fields or any other unlisted field. ' +
      'Each step must contain stepId, kind, goal, dependencies, inputBindings, expectedOutputSchemaJson, ' +
      'capabilityRequirements, sideEffect, riskLevel, permissionRequirements, idempotencyMode, timeoutMs, ' +
      'retryPolicyRef, and verificationPolicyRef. For clarificationRequired, clarification must contain ' +
      'questionCode, prompt, and responseSchemaJson.';
    return value;
  }

  private memoryRequest(request: PlanningRequest): PlanningMemoryContextRequest {
    const value: PlanningMemoryContextRequest = new PlanningMemoryContextRequest();
    value.taskId = request.envelope.taskId;
    value.ownerId = request.envelope.userId;
    this.addMemoryTerm(value.queryTerms, request.envelope.userIntent);
    this.addMemoryTerm(value.queryTerms, request.frame.goal);
    for (let index: number = 0; index < request.frame.constraints.length; index++) {
      this.addMemoryTerm(value.queryTerms, request.frame.constraints[index]);
    }
    for (let index: number = 0; index < request.frame.capabilityCategories.length; index++) {
      this.addMemoryTerm(value.queryTerms, request.frame.capabilityCategories[index]);
    }
    value.maxItems = this.config.maxMemoryItems;
    value.maxCharacters = this.config.maxMemoryCharacters;
    return value;
  }

  private addMemoryTerm(terms: string[], value: string): void {
    if (!validText(value) || terms.indexOf(value) >= 0) return;
    terms.push(value);
  }

  private validMemoryContext(request: PlanningRequest, context: PlanningMemoryContextResult): boolean {
    if (context.contextVersion !== PLANNING_MEMORY_CONTEXT_VERSION ||
      context.taskId !== request.envelope.taskId || context.ownerId !== request.envelope.userId ||
      !Number.isSafeInteger(context.totalCharacters) || context.totalCharacters < 0 ||
      context.totalCharacters > this.config.maxMemoryCharacters ||
      context.items.length > this.config.maxMemoryItems) return false;
    let characters: number = 0;
    const chunkIds: string[] = [];
    for (let index: number = 0; index < context.items.length; index++) {
      const item: PlanningMemoryContextItem = context.items[index];
      if (!validText(item.memoryId) || !validText(item.chunkId) ||
        !Number.isSafeInteger(item.memoryVersion) || item.memoryVersion <= 0 || !validText(item.content) ||
        chunkIds.indexOf(item.chunkId) >= 0) return false;
      for (let tagIndex: number = 0; tagIndex < item.tags.length; tagIndex++) {
        if (!validText(item.tags[tagIndex])) return false;
      }
      chunkIds.push(item.chunkId);
      characters += item.content.length;
      if (!Number.isSafeInteger(characters) || characters > this.config.maxMemoryCharacters) return false;
    }
    return characters === context.totalCharacters;
  }

  private parseResult(phase: ProviderPlanningPhase, request: PlanningRequest, invocation: ModelInvocation,
    generated: ModelProviderResult): PlanningResult {
    if (generated.requestId !== invocation.context.requestId ||
      generated.modelId !== this.profile.registryModelId || generated.modelVersion !== this.profile.modelVersion ||
      generated.region !== this.profile.region || generated.priceSnapshotId !== this.price.snapshotId ||
      !validUsage(generated.usage)) {
      return this.rejected('PLANNER_PROVIDER_TRACE_MISMATCH');
    }
    if (generated.finishReason !== ProviderFinishReason.STOP) {
      return this.rejected('PLANNER_PROVIDER_INCOMPLETE');
    }
    const outputJson: string | undefined = generated.outputJson;
    if (outputJson === undefined) return this.rejected('PLANNER_OUTPUT_JSON_REQUIRED');
    let root: Record<string, Object>;
    try {
      root = parseJsonObject(outputJson) as Record<string, Object>;
    } catch (error) {
      return this.rejected('PLANNER_OUTPUT_INVALID');
    }
    if (!exactKeys(root, ['status', 'workflow', 'clarification', 'rejectionCode'])) {
      return this.rejected('PLANNER_OUTPUT_INVALID');
    }
    const status: string | undefined = textField(root, 'status');
    if (status === PlanningStatus.REJECTED) {
      if (root['workflow'] !== undefined || root['clarification'] !== undefined) {
        return this.rejected('PLANNER_OUTPUT_INVALID');
      }
      const code: string | undefined = textField(root, 'rejectionCode');
      return this.rejected(code === undefined ? 'PLANNER_PROVIDER_REJECTED' :
        this.stableProviderRejection(code));
    }
    if (status === PlanningStatus.CLARIFICATION_REQUIRED) {
      if (root['workflow'] !== undefined || root['rejectionCode'] !== undefined) {
        return this.rejected('PLANNER_OUTPUT_INVALID');
      }
      return this.clarification(request, root['clarification']);
    }
    if (status !== PlanningStatus.READY) return this.rejected('PLANNER_OUTPUT_INVALID');
    if (root['clarification'] !== undefined || root['rejectionCode'] !== undefined) {
      return this.rejected('PLANNER_OUTPUT_INVALID');
    }
    const workflow: WorkflowGraph | undefined = this.workflow(phase, request, root['workflow']);
    if (workflow === undefined) return this.rejected('PLANNER_WORKFLOW_INVALID');
    const result: PlanningResult = new PlanningResult();
    result.status = PlanningStatus.READY;
    result.workflow = workflow;
    return result;
  }

  private workflow(phase: ProviderPlanningPhase, request: PlanningRequest,
    value: Object | undefined): WorkflowGraph | undefined {
    const record: Record<string, Object> | undefined = objectRecord(value);
    if (record === undefined || !exactKeys(record, ['entryStepIds', 'steps'])) return undefined;
    const entries: string[] | undefined = stringArray(record['entryStepIds']);
    const rawSteps: Object | undefined = record['steps'];
    if (entries === undefined || !Array.isArray(rawSteps) || rawSteps.length === 0 ||
      rawSteps.length > this.config.maxSteps) return undefined;
    const graph: WorkflowGraph = new WorkflowGraph();
    graph.taskId = request.envelope.taskId;
    graph.entryStepIds = entries;
    for (let index: number = 0; index < rawSteps.length; index++) {
      const parsed: WorkflowStep | undefined = this.step(rawSteps[index]);
      if (parsed === undefined) return undefined;
      graph.steps.push(parsed);
    }
    const previous: WorkflowGraph | undefined = request.previousWorkflow;
    if (phase === ProviderPlanningPhase.REPLAN && previous !== undefined) {
      graph.workflowId = previous.workflowId;
      graph.workflowVersion = this.ids.nextId('workflowVersion', request.envelope.requestId);
    } else {
      graph.workflowId = this.ids.nextId('workflow', request.envelope.requestId);
      graph.workflowVersion = '1';
    }
    const nowMs: number = this.clock.nowMs();
    if (!validEpochMs(nowMs) || !validText(graph.workflowId) || !validText(graph.workflowVersion) ||
      (previous !== undefined && phase === ProviderPlanningPhase.REPLAN &&
        graph.workflowVersion === previous.workflowVersion)) return undefined;
    graph.createdAt = new Date(nowMs).toISOString();
    if (!ContractValidator.validateWorkflowGraphShape(graph).valid || !this.validTopology(graph)) {
      return undefined;
    }
    return graph;
  }

  private step(value: Object): WorkflowStep | undefined {
    const record: Record<string, Object> | undefined = objectRecord(value);
    const allowed: string[] = ['stepId', 'kind', 'goal', 'dependencies', 'inputBindings',
      'expectedOutputSchemaJson', 'capabilityRequirements', 'sideEffect', 'riskLevel',
      'permissionRequirements', 'idempotencyMode', 'timeoutMs', 'retryPolicyRef',
      'verificationPolicyRef'];
    if (record === undefined || !exactKeys(record, allowed)) return undefined;
    const stepId: string | undefined = textField(record, 'stepId');
    const kindText: string | undefined = textField(record, 'kind');
    const goal: string | undefined = textField(record, 'goal');
    const dependencies: string[] | undefined = stringArray(record['dependencies']);
    const capabilityRequirements: string[] | undefined = stringArray(record['capabilityRequirements']);
    const permissions: string[] | undefined = stringArray(record['permissionRequirements']);
    const expected: string | undefined = textField(record, 'expectedOutputSchemaJson');
    const retry: string | undefined = textField(record, 'retryPolicyRef');
    const verification: string | undefined = textField(record, 'verificationPolicyRef');
    const timeoutMs: number | undefined = integerField(record, 'timeoutMs');
    const effectText: string | undefined = textField(record, 'sideEffect');
    const riskText: string | undefined = textField(record, 'riskLevel');
    const idempotencyText: string | undefined = textField(record, 'idempotencyMode');
    if (stepId === undefined || kindText === undefined || goal === undefined || dependencies === undefined ||
      capabilityRequirements === undefined || permissions === undefined || expected === undefined ||
      retry === undefined || verification === undefined || timeoutMs === undefined || effectText === undefined ||
      riskText === undefined || idempotencyText === undefined || !jsonObjectText(expected)) return undefined;
    const kind: WorkflowStepKind | undefined = workflowKind(kindText);
    const effect: SideEffect | undefined = sideEffect(effectText);
    const risk: RiskLevel | undefined = riskLevel(riskText);
    const idempotency: IdempotencyMode | undefined = idempotencyMode(idempotencyText);
    if (kind === undefined || effect === undefined || risk === undefined || idempotency === undefined) return undefined;
    const rawBindings: Object | undefined = record['inputBindings'];
    if (!Array.isArray(rawBindings)) return undefined;
    const step: WorkflowStep = new WorkflowStep();
    step.stepId = stepId;
    step.kind = kind;
    step.goal = goal;
    step.dependencies = dependencies;
    step.expectedOutputSchemaJson = expected;
    step.capabilityRequirements = capabilityRequirements;
    step.sideEffect = effect;
    step.riskLevel = risk;
    step.permissionRequirements = permissions;
    step.idempotencyMode = idempotency;
    step.timeoutMs = timeoutMs;
    step.retryPolicyRef = retry;
    step.verificationPolicyRef = verification;
    for (let index: number = 0; index < rawBindings.length; index++) {
      const binding: WorkflowInputBinding | undefined = this.binding(rawBindings[index]);
      if (binding === undefined || this.bindingIndex(step.inputBindings, binding.name) >= 0) return undefined;
      step.inputBindings.push(binding);
    }
    return step;
  }

  private binding(value: Object): WorkflowInputBinding | undefined {
    const record: Record<string, Object> | undefined = objectRecord(value);
    if (record === undefined || !exactKeys(record,
      ['name', 'sourceStepId', 'sourceOutputPath', 'literalJson'])) return undefined;
    const name: string | undefined = textField(record, 'name');
    const sourceStepId: string | undefined = optionalTextField(record, 'sourceStepId');
    const sourceOutputPath: string | undefined = optionalTextField(record, 'sourceOutputPath');
    const literalJson: string | undefined = optionalTextField(record, 'literalJson');
    const hasSource: boolean = sourceStepId !== undefined;
    const hasPath: boolean = sourceOutputPath !== undefined;
    const hasLiteral: boolean = literalJson !== undefined;
    if (name === undefined || hasSource === hasLiteral || (hasSource &&
      (!validText(sourceStepId as string) || !hasPath || !validText(sourceOutputPath as string))) ||
      (!hasSource && hasPath) || (hasSource && hasLiteral) ||
      (hasLiteral && (!validText(literalJson as string) || !jsonText(literalJson as string)))) return undefined;
    const result: WorkflowInputBinding = new WorkflowInputBinding();
    result.name = name;
    if (hasSource) {
      result.sourceStepId = sourceStepId;
      result.sourceOutputPath = sourceOutputPath;
    } else {
      result.literalJson = literalJson;
    }
    return result;
  }

  private bindingIndex(bindings: WorkflowInputBinding[], name: string): number {
    for (let index: number = 0; index < bindings.length; index++) {
      if (bindings[index].name === name) return index;
    }
    return -1;
  }

  private validTopology(graph: WorkflowGraph): boolean {
    for (let index: number = 0; index < graph.steps.length; index++) {
      const current: WorkflowStep = graph.steps[index];
      if (this.stepIndex(graph, current.stepId) !== index) return false;
      if (current.kind !== WorkflowStepKind.JOIN && current.timeoutMs <= 0) return false;
      if (current.sideEffect !== SideEffect.NONE && current.idempotencyMode === IdempotencyMode.NONE) return false;
      if (current.kind === WorkflowStepKind.TOOL && current.capabilityRequirements.length === 0) return false;
      const zeroDependencyEntry: boolean = graph.entryStepIds.indexOf(current.stepId) >= 0;
      if ((current.dependencies.length === 0) !== zeroDependencyEntry) return false;
      for (let dependencyIndex: number = 0; dependencyIndex < current.dependencies.length; dependencyIndex++) {
        const dependency: string = current.dependencies[dependencyIndex];
        if (dependency === current.stepId || this.stepIndex(graph, dependency) < 0 ||
          current.dependencies.indexOf(dependency) !== dependencyIndex) return false;
      }
      for (let bindingIndex: number = 0; bindingIndex < current.inputBindings.length; bindingIndex++) {
        const source: string | undefined = current.inputBindings[bindingIndex].sourceStepId;
        if (source !== undefined && current.dependencies.indexOf(source) < 0) return false;
      }
    }
    for (let entryIndex: number = 0; entryIndex < graph.entryStepIds.length; entryIndex++) {
      const entry: string = graph.entryStepIds[entryIndex];
      const stepIndex: number = this.stepIndex(graph, entry);
      if (stepIndex < 0 || graph.steps[stepIndex].dependencies.length > 0 ||
        graph.entryStepIds.indexOf(entry) !== entryIndex) return false;
    }
    return this.acyclic(graph);
  }

  private acyclic(graph: WorkflowGraph): boolean {
    const remaining: number[] = [];
    const processed: boolean[] = [];
    for (let index: number = 0; index < graph.steps.length; index++) {
      remaining.push(graph.steps[index].dependencies.length);
      processed.push(false);
    }
    let count: number = 0;
    let advanced: boolean = true;
    while (advanced) {
      advanced = false;
      for (let index: number = 0; index < graph.steps.length; index++) {
        if (!processed[index] && remaining[index] === 0) {
          processed[index] = true;
          count++;
          advanced = true;
          for (let target: number = 0; target < graph.steps.length; target++) {
            if (!processed[target] && graph.steps[target].dependencies.indexOf(graph.steps[index].stepId) >= 0) {
              remaining[target]--;
            }
          }
        }
      }
    }
    return count === graph.steps.length;
  }

  private stepIndex(graph: WorkflowGraph, stepId: string): number {
    for (let index: number = 0; index < graph.steps.length; index++) {
      if (graph.steps[index].stepId === stepId) return index;
    }
    return -1;
  }

  private clarification(request: PlanningRequest, value: Object | undefined): PlanningResult {
    const record: Record<string, Object> | undefined = objectRecord(value);
    if (record === undefined || !exactKeys(record, ['questionCode', 'prompt', 'responseSchemaJson'])) {
      return this.rejected('PLANNER_CLARIFICATION_INVALID');
    }
    const questionCode: string | undefined = textField(record, 'questionCode');
    const prompt: string | undefined = textField(record, 'prompt');
    const responseSchema: string | undefined = textField(record, 'responseSchemaJson');
    if (questionCode === undefined || prompt === undefined || responseSchema === undefined ||
      !jsonObjectText(responseSchema)) return this.rejected('PLANNER_CLARIFICATION_INVALID');
    const nowMs: number = this.clock.nowMs();
    const expiresAtMs: number = nowMs + this.config.clarificationTtlMs;
    if (!validEpochMs(nowMs) || !validEpochMs(expiresAtMs)) {
      return this.rejected('PLANNER_CLOCK_INVALID');
    }
    const clarification: ClarificationRequest = new ClarificationRequest();
    clarification.clarificationId = this.ids.nextId('clarification', request.envelope.requestId);
    if (!validText(clarification.clarificationId)) return this.rejected('PLANNER_RUNTIME_ID_INVALID');
    clarification.taskId = request.envelope.taskId;
    clarification.questionCode = questionCode;
    clarification.prompt = prompt;
    clarification.responseSchemaJson = responseSchema;
    clarification.requestedAt = new Date(nowMs).toISOString();
    clarification.expiresAtMs = expiresAtMs;
    clarification.expiresAt = new Date(expiresAtMs).toISOString();
    const result: PlanningResult = new PlanningResult();
    result.status = PlanningStatus.CLARIFICATION_REQUIRED;
    result.clarification = clarification;
    return result;
  }

  private rejected(code: string): PlanningResult {
    const result: PlanningResult = new PlanningResult();
    result.status = PlanningStatus.REJECTED;
    result.rejectionCode = code;
    return result;
  }

  private stableProviderRejection(value: string): string {
    if (value.length > 64) return 'PLANNER_PROVIDER_REJECTED';
    for (let index: number = 0; index < value.length; index++) {
      const code: number = value.charCodeAt(index);
      const valid: boolean = (code >= 65 && code <= 90) || (code >= 48 && code <= 57) || code === 95;
      if (!valid) return 'PLANNER_PROVIDER_REJECTED';
    }
    return value;
  }

  private estimatedCostMicros(outputTokens: number, inputTokens: number): number {
    return Math.ceil((inputTokens * this.price.inputMicrosPerMillionTokens +
      outputTokens * this.price.outputMicrosPerMillionTokens) / 1000000) + this.price.fixedCostMicros;
  }

  private observe(phase: ProviderPlanningPhase, request: PlanningRequest, generated: ModelProviderResult,
    result: PlanningResult, role?: CollaborationRoleAssignment, activationId: string = ''): void {
    const trace: ProviderPlannerTrace = new ProviderPlannerTrace();
    trace.phase = phase;
    trace.taskId = request.envelope.taskId;
    trace.providerRequestId = generated.requestId;
    trace.agentActivationId = activationId;
    if (role !== undefined) {
      trace.roleId = role.roleId;
      trace.roleVersion = role.roleVersion;
      trace.roleRegistryDigest = role.roleRegistryDigest;
      if (request.collaborationPlan !== undefined) {
        trace.collaborationDecisionDigest = request.collaborationPlan.decisionDigest;
      }
    }
    trace.providerId = this.profile.providerId;
    trace.modelId = generated.modelId;
    trace.modelVersion = generated.modelVersion;
    trace.region = generated.region;
    trace.priceSnapshotId = generated.priceSnapshotId;
    trace.finishReason = generated.finishReason;
    trace.planningStatus = result.status;
    trace.rejectionCode = result.rejectionCode;
    trace.usage = copyUsage(generated.usage);
    try {
      this.observer.onGenerationCompleted(trace);
    } catch (error) {
    }
  }

  private validateConfiguration(config: ProviderSemanticPlannerConfig, provider: ModelProvider,
    memoryContext?: PlanningMemoryContextPort): void {
    const memoryDisabled: boolean = config.maxMemoryItems === 0 && config.maxMemoryCharacters === 0 &&
      memoryContext === undefined;
    const memoryEnabled: boolean = Number.isSafeInteger(config.maxMemoryItems) && config.maxMemoryItems > 0 &&
      config.maxMemoryItems <= 50 && Number.isSafeInteger(config.maxMemoryCharacters) &&
      config.maxMemoryCharacters > 0 && config.maxMemoryCharacters <= 32768 && memoryContext !== undefined;
    const maximumInputTokens: number = config.estimatedInputTokens + config.maxMemoryCharacters;
    const valid: boolean = config.configVersion === PROVIDER_SEMANTIC_PLANNER_CONFIG_VERSION &&
      validText(config.promptVersion) && Number.isSafeInteger(config.estimatedInputTokens) &&
      config.estimatedInputTokens > 0 && Number.isSafeInteger(maximumInputTokens) &&
      maximumInputTokens <= this.profile.maxInputTokens && (memoryDisabled || memoryEnabled) &&
      Number.isSafeInteger(config.maxOutputTokens) &&
      config.maxOutputTokens > 0 && config.maxOutputTokens <= this.profile.maxOutputTokens &&
      Number.isFinite(config.temperature) && config.temperature >= 0 && config.temperature <= 2 &&
      Number.isSafeInteger(config.timeoutMs) && config.timeoutMs > 0 &&
      Number.isSafeInteger(config.clarificationTtlMs) && config.clarificationTtlMs > 0 &&
      Number.isSafeInteger(config.maxSteps) && config.maxSteps > 0 &&
      Number.isSafeInteger(config.maxPromptCharacters) && config.maxPromptCharacters > 0 &&
      this.profile.capabilityKind === ProviderCapabilityKind.MODEL && this.profile.available &&
      this.price.providerId === this.profile.providerId &&
      this.price.capabilityId === this.profile.providerModelId &&
      this.price.capabilityVersion === this.profile.modelVersion && this.price.region === this.profile.region;
    if (!valid) {
      throw new ProviderSemanticPlannerError(ProviderSemanticPlannerErrorCode.INVALID_CONFIGURATION,
        'Provider semantic planner configuration is invalid');
    }
    const registry = provider.registryEntry(maximumInputTokens, config.maxOutputTokens);
    if (registry.modelId !== this.profile.registryModelId || registry.providerId !== this.profile.providerId ||
      registry.modelVersion !== this.profile.modelVersion || registry.registryDigest.length === 0 ||
      registry.regions.length !== 1 || registry.regions[0] !== this.profile.region || !registry.available) {
      throw new ProviderSemanticPlannerError(ProviderSemanticPlannerErrorCode.PROVIDER_IDENTITY_MISMATCH,
        'Model provider does not match the registered planner identity');
    }
  }

  private copyConfig(source: ProviderSemanticPlannerConfig): ProviderSemanticPlannerConfig {
    const result: ProviderSemanticPlannerConfig = new ProviderSemanticPlannerConfig();
    result.configVersion = source.configVersion;
    result.promptVersion = source.promptVersion;
    result.estimatedInputTokens = source.estimatedInputTokens;
    result.maxOutputTokens = source.maxOutputTokens;
    result.temperature = source.temperature;
    result.timeoutMs = source.timeoutMs;
    result.clarificationTtlMs = source.clarificationTtlMs;
    result.maxSteps = source.maxSteps;
    result.maxPromptCharacters = source.maxPromptCharacters;
    result.maxMemoryItems = source.maxMemoryItems;
    result.maxMemoryCharacters = source.maxMemoryCharacters;
    return result;
  }
}
