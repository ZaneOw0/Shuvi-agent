import common from '@ohos.app.ability.common';
import util from '@ohos.util';
import { AgentErrorClass, ClarificationResponse, PrivacyClass, ToolOutcome, ToolOutcomeStatus,
  WorkflowGraph, WorkflowStep, WorkflowStepKind } from '@harmony_agent/agent-contracts';
import { AgentApplicationBackend, AgentApplicationBackendConfig, AgentRuntimeFacade, PlanningRequest,
  PlanningResult, PlanningStatus, PreparedToolDispatch, ProductionAgentRuntimeConfig, ProductionAgentRuntimePorts,
  ProductionRuntimeAdapterFactoryPort, RuntimeToolOutcomeSinkPort, SemanticPlannerPort,
  RuntimeClockPort, RuntimeIdGeneratorPort, SingleAgentCollaborationSelector, SingleAgentHostPorts, SingleAgentHostResourcePort, SingleAgentHostRuntimeFactoryPort,
  StepDispatchPort, StepDispatchReceipt, StepDispatchRequest, ToolInvocationPreparerPort, createProductionAgentRuntime
} from '@harmony_agent/agent-runtime';
import { ModelInvocation, ModelMessage, ModelProvider, ProviderCancellationSource, ProviderFinishReason,
  ProviderTransportError, RegisteredModelProvider } from '@harmony_agent/agent-connectors';
import { McpClientManager } from '@harmony_agent/mcp-client';
import { AgentRdbOpenPort, NativeAgentRdbOpen } from './AgentRdbResources';
import { AgentHostDigest } from './AgentHostDigest';
import { ChatExecutionResource } from './ChatExecutionStore';
import { SessionModelCredentials } from './SessionModelCredentials';
import { SessionModelHttpClient } from './SessionModelHttpClient';
import { ArkTsDeepSeekHttpClient } from './DeepSeekHttpClient';
import { createDeepSeekProvider } from './DeepSeekProvider';
import { DeepSeekToolTransport, ModelTurnPort, ToolTurnLimits } from './DeepSeekToolTransport';
import { ModelDocumentToolsPort } from '../documents/DocumentToolContracts';
import { ModelLoopToolsPort } from './ModelLoopTools';
import { startupModelProfile, startupModelPrice } from './RuntimeStartupAssembly';
import { SearchAuthorizationPreviews } from './SearchAuthorizationPreview';
import { ShuviRuntimeSession, ShuviRuntimeSessionFactory, ShuviRuntimeSessionPort, ShuviSessionResources } from './ShuviRuntimeSession';

export const CHAT_POLICY: string = 'shuvi-model-only-v1';
/** User turns per enable, for every chat purpose. */
export const CHAT_MAX_REQUESTS: number = 10;
// One tool-capable assistant turn may chain several model requests; these caps bound the whole turn.
export const TOOL_TURN_TIMEOUT_MS: number = 90000;
export const TOOL_TURN_WALL_MS: number = 90000;
export const TOOL_TURN_MAX_INPUT_TOKENS: number = 32768;
export const TOOL_TURN_MAX_OUTPUT_TOKENS: number = 2048;
export const TOOL_TURN_MAX_COST_MICROS: number = 20000;
/** Model HTTP requests one tool-capable assistant session may send across all of its turns. */
export const ASSISTANT_MAX_MODEL_REQUESTS: number = 10;
// App-owned composition scope; the default public-chat/search scope remains unchanged.
export enum ChatPurpose { PUBLIC_CHAT, CALENDAR_DRAFT, ASSISTANT }
function chatPrivacy(purpose: ChatPurpose): PrivacyClass {
  return purpose === ChatPurpose.PUBLIC_CHAT ? PrivacyClass.PUBLIC : PrivacyClass.PERSONAL;
}
export interface ChatContextPort {
  systemPrompt(): string;
  promptFor(intent: string): string | undefined;
}
/**
 * Tools for the PERSONAL assistant: document tools run inside the model loop as authorized Runtime tasks; the turn
 * port supplies proposal tools (calendar) that end the loop and hand off to the confirmed native chain.
 */
export class ChatToolKit {
  readonly documents: () => ModelDocumentToolsPort;
  readonly turn: ModelTurnPort;
  readonly extra?: ModelLoopToolsPort;
  constructor(documents: () => ModelDocumentToolsPort, turn: ModelTurnPort, extra?: ModelLoopToolsPort) {
    this.documents = documents; this.turn = turn; this.extra = extra;
  }
}
export function assistantToolLimits(): ToolTurnLimits {
  const limits: ToolTurnLimits = new ToolTurnLimits();
  limits.maxUserChars = 2000; limits.maxOutputTokens = TOOL_TURN_MAX_OUTPUT_TOKENS;
  limits.maxInputTokens = TOOL_TURN_MAX_INPUT_TOKENS; limits.maxAttempts = ASSISTANT_MAX_MODEL_REQUESTS;
  limits.historyChars = 12000;
  return limits;
}
export class ChatAnswer {
  schemaVersion: string = '1.0';
  kind: string = 'modelAnswer';
  text: string = '';
  inputTokens: number = 0;
  outputTokens: number = 0;
}
export function parseChatAnswer(json: string): ChatAnswer | undefined {
  try {
    if (typeof json !== 'string' || json.length > 24000) return undefined;
    const value: ChatAnswer = JSON.parse(json);
    if (value === null || typeof value !== 'object' || Array.isArray(value) || value.schemaVersion !== '1.0' ||
      value.kind !== 'modelAnswer' || typeof value.text !== 'string' || !value.text.trim() || value.text.length > 16000 ||
      !Number.isSafeInteger(value.inputTokens) || value.inputTokens < 0 || value.inputTokens > TOOL_TURN_MAX_INPUT_TOKENS ||
      !Number.isSafeInteger(value.outputTokens) || value.outputTokens < 0 || value.outputTokens > TOOL_TURN_MAX_OUTPUT_TOKENS) return undefined;
    return value;
  } catch { return undefined; }
}

// Deterministic routing for the explicitly selected single-turn chat feature, not a mock answer/planner.
export class ChatPlanner implements SemanticPlannerPort, ToolInvocationPreparerPort {
  private readonly purpose: ChatPurpose;
  private readonly tools: boolean;
  constructor(purpose: ChatPurpose = ChatPurpose.PUBLIC_CHAT, tools: boolean = false) { this.purpose = purpose; this.tools = tools; }
  async plan(request: PlanningRequest): Promise<PlanningResult> {
    const result = new PlanningResult();
    if (!request.envelope.userIntent.trim() || request.envelope.userIntent.length > 500 ||
      request.envelope.privacyClass !== chatPrivacy(this.purpose)) { result.rejectionCode = 'CHAT_INPUT_REJECTED'; return result; }
    const step = new WorkflowStep(); step.stepId = 'chat-answer'; step.kind = WorkflowStepKind.LLM;
    step.goal = this.tools ? '理解用户意图；按需调用本地文档工具或提议待确认日程，并使用真实执行结果回答' :
      this.purpose === ChatPurpose.PUBLIC_CHAT ? '回答本次公开问题，不调用工具' : '识别用户意图并提议日程草稿或回答，不直接调用工具';
    step.timeoutMs = this.tools ? TOOL_TURN_TIMEOUT_MS : 30000;
    step.expectedOutputSchemaJson = '{"type":"object"}'; step.retryPolicyRef = 'no-retry'; step.verificationPolicyRef = 'validated-model-answer-v1';
    const graph = new WorkflowGraph(); graph.taskId = request.envelope.taskId;
    graph.workflowId = 'chat-' + request.envelope.taskId; graph.workflowVersion = '1';
    graph.createdAt = new Date().toISOString(); graph.steps = [step]; graph.entryStepIds = [step.stepId];
    result.status = PlanningStatus.READY; result.workflow = graph; return result;
  }
  async resume(_request: PlanningRequest, _response: ClarificationResponse): Promise<PlanningResult> { return new PlanningResult(); }
  async replan(_request: PlanningRequest): Promise<PlanningResult> { return new PlanningResult(); }
  interrupt(_taskId: string): boolean { return false; }
  prepare(_request: PlanningRequest, _step: WorkflowStep, _now: number): PreparedToolDispatch { throw new Error('CHAT_TOOLS_DISABLED'); }
}

export class ChatModelAdapter implements StepDispatchPort {
  private readonly provider: ModelProvider;
  private readonly model: RegisteredModelProvider;
  private readonly sink: RuntimeToolOutcomeSinkPort;
  private readonly digest: AgentHostDigest;
  private readonly active: Map<string, ProviderCancellationSource> = new Map<string, ProviderCancellationSource>();
  private calls: number = 0;
  private readonly purpose: ChatPurpose;
  private readonly context?: ChatContextPort;
  private readonly tools: boolean;
  constructor(provider: ModelProvider, model: RegisteredModelProvider, sink: RuntimeToolOutcomeSinkPort, digest: AgentHostDigest,
    context?: ChatContextPort, purpose: ChatPurpose = ChatPurpose.PUBLIC_CHAT, tools: boolean = false) {
    this.provider = provider; this.model = model; this.sink = sink; this.digest = digest;
    this.context = context; this.purpose = purpose; this.tools = tools;
  }
  dispatch(request: StepDispatchRequest): StepDispatchReceipt {
    const receipt = new StepDispatchReceipt();
    const budget = request.task.executionBudget;
    const maxInput = this.tools ? TOOL_TURN_MAX_INPUT_TOKENS : 8192;
    const maxOutput = this.tools ? TOOL_TURN_MAX_OUTPUT_TOKENS : 1024;
    const estimate = Math.ceil((maxInput * this.model.priceSnapshot().inputMicrosPerMillionTokens +
      maxOutput * this.model.priceSnapshot().outputMicrosPerMillionTokens) / 1000000) + this.model.priceSnapshot().fixedCostMicros;
    if (request.toolInvocation !== undefined || request.step.kind !== WorkflowStepKind.LLM || request.step.stepId !== 'chat-answer' ||
      !request.task.userIntent.trim() || request.task.userIntent.length > 500 || request.task.privacyClass !== chatPrivacy(this.purpose) ||
      (this.purpose !== ChatPurpose.PUBLIC_CHAT && this.context === undefined) ||
      this.active.size > 0 || this.calls >= CHAT_MAX_REQUESTS || budget.maxInputTokens < maxInput || budget.maxOutputTokens < maxOutput ||
      budget.maxMonetaryCostMicros < estimate || budget.maxWallTimeMs < (this.tools ? TOOL_TURN_WALL_MS : 30000)) {
      receipt.rejectionCode = 'CHAT_SCOPE_OR_BUDGET_REJECTED'; return receipt;
    }
    const cancel = new ProviderCancellationSource(); this.active.set(request.dispatchId, cancel); this.calls++;
    receipt.accepted = true;
    void this.execute(request, cancel).catch((): void => { /* No raw provider errors or user input in logs. UI watchdog stops the session. */ });
    return receipt;
  }
  cancel(dispatchId: string): boolean {
    const cancellation = this.active.get(dispatchId); if (cancellation === undefined) return false;
    cancellation.cancel(); return true;
  }
  private async execute(request: StepDispatchRequest, cancellation: ProviderCancellationSource): Promise<void> {
    const outcome = new ToolOutcome(); outcome.invocationId = request.dispatchId; outcome.startedAt = new Date().toISOString();
    try {
      const invocation = new ModelInvocation(); const profile = this.model.profileSnapshot();
      invocation.context.requestId = request.dispatchId; invocation.context.taskId = request.task.taskId;
      invocation.context.stepId = request.step.stepId; invocation.context.operationId = request.dispatchId;
      invocation.context.providerId = profile.providerId; invocation.context.region = profile.region;
      invocation.context.priceSnapshotId = this.model.priceSnapshot().snapshotId;
      invocation.context.timeoutMs = this.tools ? TOOL_TURN_TIMEOUT_MS : 30000;
      invocation.modelId = profile.registryModelId; invocation.modelVersion = profile.modelVersion;
      invocation.maxOutputTokens = this.tools ? TOOL_TURN_MAX_OUTPUT_TOKENS : 1024; invocation.responseSchemaJson = '{}';
      const system = new ModelMessage(); system.role = 'system';
      system.content = '你是 Shuvi。仅回答当前问题。本次未联网搜索、未读取知识库，也没有日历等工具；不要声称执行了任何操作。不确定的信息明确说明。';
      const user = new ModelMessage(); user.role = 'user'; user.content = request.task.userIntent;
      if (this.context !== undefined) {
        const prompt = this.context.promptFor(request.task.userIntent);
        if (prompt === undefined || prompt.length > 1800) throw new Error('SEARCH_ANSWER_CONTEXT_REQUIRED');
        system.content = this.context.systemPrompt(); user.content = prompt;
      }
      invocation.messages = [system, user];
      const result = await this.provider.generate(invocation, cancellation);
      if (cancellation.isCancellationRequested()) throw new Error('CHAT_CANCELLED');
      if (result.finishReason !== ProviderFinishReason.STOP || result.requestId !== request.dispatchId ||
        result.modelId !== profile.registryModelId || result.modelVersion !== profile.modelVersion ||
        result.region !== profile.region || result.priceSnapshotId !== this.model.priceSnapshot().snapshotId) throw new Error('CHAT_RESPONSE_INVALID');
      const answer = new ChatAnswer(); answer.text = result.outputText;
      answer.inputTokens = result.usage.inputTokens; answer.outputTokens = result.usage.outputTokens;
      const json = JSON.stringify(answer); if (parseChatAnswer(json) === undefined) throw new Error('CHAT_RESPONSE_INVALID');
      outcome.status = ToolOutcomeStatus.SUCCEEDED; outcome.resultJson = json; outcome.resultDigest = this.digest.digest(json);
    } catch (error) {
      outcome.status = cancellation.isCancellationRequested() ? ToolOutcomeStatus.CANCELLED : ToolOutcomeStatus.FAILED;
      outcome.errorClass = error instanceof ProviderTransportError ? error.errorClass : AgentErrorClass.PROVIDER;
      outcome.errorCode = error instanceof ProviderTransportError ? error.code : 'CHAT_RESPONSE_INVALID';
    }
    outcome.finishedAt = new Date().toISOString(); this.active.delete(request.dispatchId);
    // Runtime owns the cancelled terminal state. Do not submit a late completion against its cleared dispatch.
    if (cancellation.isCancellationRequested()) return;
    await this.sink.complete(request.task.taskId, request.step.stepId, request.dispatchId, outcome);
  }
}

class ChatAdapterFactory implements ProductionRuntimeAdapterFactoryPort {
  private readonly provider: ModelProvider; private readonly model: RegisteredModelProvider; private readonly digest: AgentHostDigest;
  private readonly context?: ChatContextPort;
  private readonly purpose: ChatPurpose;
  private readonly tools: boolean;
  constructor(provider: ModelProvider, model: RegisteredModelProvider, digest: AgentHostDigest, context?: ChatContextPort,
    purpose: ChatPurpose = ChatPurpose.PUBLIC_CHAT, tools: boolean = false) {
    this.provider = provider; this.model = model; this.digest = digest; this.context = context; this.purpose = purpose; this.tools = tools;
  }
  create(sink: RuntimeToolOutcomeSinkPort): StepDispatchPort {
    return new ChatModelAdapter(this.provider, this.model, sink, this.digest, this.context, this.purpose, this.tools);
  }
}
// Explicitly disabled host capabilities: no memory query and no MCP connections exist in this composition.
class DisabledChatResource implements SingleAgentHostResourcePort {
  async open(): Promise<void> {}
  async close(): Promise<void> {}
}
class ChatResources implements ShuviSessionResources {
  credentials: SessionModelCredentials = new SessionModelCredentials();
  memory: SingleAgentHostResourcePort = new DisabledChatResource();
  execution: ChatExecutionResource;
  constructor(opener: AgentRdbOpenPort, digest: AgentHostDigest, calendar: boolean, assistant: boolean) {
    this.execution = new ChatExecutionResource(opener, digest, calendar, assistant);
  }
}
class ChatClock implements RuntimeClockPort { nowMs(): number { return Date.now(); } }
class ChatIds implements RuntimeIdGeneratorPort { nextId(kind: string, _request: string): string { return kind + '-' + util.generateRandomUUID(); } }
class ChatBackendFactory implements SingleAgentHostRuntimeFactoryPort {
  private readonly ports: ProductionAgentRuntimePorts;
  constructor(ports: ProductionAgentRuntimePorts) { this.ports = ports; }
  async create(): Promise<AgentRuntimeFacade> {
    const config = new ProductionAgentRuntimeConfig(); config.policyVersion = CHAT_POLICY; config.grantTtlMs = 60000;
    return createProductionAgentRuntime(config, this.ports);
  }
}
export function chatFrontendConfig(purpose: ChatPurpose = ChatPurpose.PUBLIC_CHAT, tools: boolean = false): AgentApplicationBackendConfig {
  const config = new AgentApplicationBackendConfig(); config.userId = 'shuvi-local-owner-v1'; config.privacyClass = chatPrivacy(purpose);
  config.requestedBudget.maxWallTimeMs = 45000; config.requestedBudget.maxInputTokens = 8192;
  config.requestedBudget.maxOutputTokens = 1024; config.requestedBudget.maxMonetaryCostMicros = 10000;
  config.requestedBudget.maxAgentActivations = 1; // One model step per turn; no Runtime tool calls, retries or replans.
  if (tools) {
    // The model step chains up to six requests and six document tool calls inside the tool transport.
    config.requestedBudget.maxWallTimeMs = TOOL_TURN_WALL_MS; config.requestedBudget.maxInputTokens = TOOL_TURN_MAX_INPUT_TOKENS;
    config.requestedBudget.maxOutputTokens = TOOL_TURN_MAX_OUTPUT_TOKENS; config.requestedBudget.maxMonetaryCostMicros = TOOL_TURN_MAX_COST_MICROS;
    config.requestedBudget.maxToolCalls = 6;
  }
  return config;
}
export class ChatRuntimeFactory implements ShuviRuntimeSessionFactory {
  private readonly opener: AgentRdbOpenPort; private readonly debugBuild: boolean;
  private readonly context?: ChatContextPort;
  private readonly purpose: ChatPurpose;
  private readonly tools?: ChatToolKit;
  /** True when the assistant session runs the tool loop (documents in the loop, calendar as a confirmed proposal). */
  readonly documentToolsEnabled: boolean;
  constructor(opener: AgentRdbOpenPort, debugBuild: boolean, context?: ChatContextPort,
    purpose: ChatPurpose = ChatPurpose.PUBLIC_CHAT, tools?: ChatToolKit) {
    this.opener = opener; this.debugBuild = debugBuild; this.context = context; this.purpose = purpose; this.tools = tools;
    this.documentToolsEnabled = purpose === ChatPurpose.ASSISTANT && tools !== undefined;
  }
  create(): ShuviRuntimeSessionPort {
    if (!this.debugBuild) throw new Error('CHAT_DEBUG_ONLY');
    if (this.purpose !== ChatPurpose.PUBLIC_CHAT && this.context === undefined) throw new Error('CALENDAR_CONTEXT_REQUIRED');
    if (this.tools !== undefined && this.purpose !== ChatPurpose.ASSISTANT) throw new Error('CHAT_TOOLS_SCOPE_REJECTED');
    const digest = new AgentHostDigest(); const resources = new ChatResources(this.opener, digest,
      this.purpose === ChatPurpose.CALENDAR_DRAFT, this.purpose === ChatPurpose.ASSISTANT);
    const http = new SessionModelHttpClient(new ArkTsDeepSeekHttpClient());
    const profile = startupModelProfile(); profile.privacyClasses = [chatPrivacy(this.purpose)];
    const kit: ChatToolKit | undefined = this.tools;
    const transport: DeepSeekToolTransport | undefined = kit === undefined ? undefined :
      new DeepSeekToolTransport(profile, http, kit.documents(), kit.turn, assistantToolLimits(), kit.extra);
    // The tool transport owns the conversation turns and the document tools; the session closes it with its resources.
    if (transport !== undefined) resources.memory = transport;
    const model = createDeepSeekProvider(profile, startupModelPrice(digest), digest, resources.credentials, http, undefined, transport);
    const tools = transport !== undefined;
    const ports = new ProductionAgentRuntimePorts(); const planner = new ChatPlanner(this.purpose, tools);
    ports.clock = new ChatClock(); ports.ids = new ChatIds(); ports.planner = planner; ports.toolPreparer = planner;
    ports.collaboration = new SingleAgentCollaborationSelector(); ports.persistence = resources.execution;
    ports.adapterFactory = new ChatAdapterFactory(model.provider, model.registered, digest, this.context, this.purpose, tools);
    const host = new SingleAgentHostPorts(); host.credentialStore = resources.credentials; host.executionStorage = resources.execution;
    host.memoryStorage = resources.memory; host.mcpClient = new DisabledChatResource(); host.runtimeFactory = new ChatBackendFactory(ports);
    return new ShuviRuntimeSession(new AgentApplicationBackend(chatFrontendConfig(this.purpose, tools), host), resources, http,
      new McpClientManager(), new SearchAuthorizationPreviews());
  }
}
export function chatRuntimeFactory(context: common.Context, debugBuild: boolean): ChatRuntimeFactory {
  return new ChatRuntimeFactory(new NativeAgentRdbOpen(context), debugBuild);
}
