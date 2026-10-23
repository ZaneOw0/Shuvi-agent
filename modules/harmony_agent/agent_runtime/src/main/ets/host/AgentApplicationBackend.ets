import {
  AgentRuntimeEvent,
  AgentTaskSnapshot,
  AgentTaskStatus,
  AuthorizationDecision,
  AuthorizationDecisionType,
  ClarificationRequest,
  CommandReceipt,
  ConsentContext,
  ExecutionBudget,
  PolicyRequest,
  PrivacyClass,
  TaskControlAction,
  TaskControlCommand,
  TaskHandle,
  TaskSubmission
} from '@harmony_agent/agent-contracts';
import {
  AgentRuntimeFacade,
  AgentRuntimeObserver,
  AgentSubscription,
  ShutdownMode,
  SubscriptionRequest
} from '../api/RuntimeApi';
import {
  SINGLE_AGENT_HOST_COMPOSITION_VERSION,
  SingleAgentHostPorts,
  createSingleAgentHostRuntime
} from './SingleAgentHostRuntime';

export const AGENT_APPLICATION_BACKEND_API_VERSION: string = '1.0';

export enum AgentApplicationBackendState {
  NEW = 'new',
  STARTING = 'starting',
  READY = 'ready',
  BACKGROUND = 'background',
  FAILED = 'failed',
  STOPPING = 'stopping',
  STOPPED = 'stopped'
}

export enum AgentApplicationBackendErrorCode {
  INVALID_CONFIGURATION = 'INVALID_CONFIGURATION',
  NOT_READY = 'NOT_READY',
  INVALID_REQUEST = 'INVALID_REQUEST',
  START_FAILED = 'START_FAILED',
  SHUTDOWN_FAILED = 'SHUTDOWN_FAILED'
}

export class AgentApplicationBackendError extends Error {
  readonly code: AgentApplicationBackendErrorCode;

  constructor(code: AgentApplicationBackendErrorCode, message: string) {
    super(message);
    this.name = 'AgentApplicationBackendError';
    this.code = code;
  }
}

/** Host-only defaults. Pages never receive credentials, MCP profiles, Runtime ports or Registry objects. */
export class AgentApplicationBackendConfig {
  apiVersion: string = AGENT_APPLICATION_BACKEND_API_VERSION;
  userId: string = '';
  locale: string = 'zh-CN';
  timeZone: string = 'Asia/Shanghai';
  privacyClass: PrivacyClass = PrivacyClass.PERSONAL;
  requestedBudget: ExecutionBudget = new ExecutionBudget();
  consentContext: ConsentContext = new ConsentContext();
}

export interface AgentApplicationBackendIdentityPort {
  nextId(scope: string): string;
  nowMs(): number;
}

export class SystemAgentApplicationBackendIdentity implements AgentApplicationBackendIdentityPort {
  private sequence: number = 0;

  nextId(scope: string): string {
    this.sequence++;
    return scope + '-' + Date.now().toString() + '-' + this.sequence.toString();
  }

  nowMs(): number {
    return Date.now();
  }
}

export class AgentFrontendTaskRequest {
  requestId?: string;
  conversationId?: string;
  intent: string = '';
}

export class AgentFrontendTaskHandle {
  requestId: string = '';
  taskId: string = '';
  acceptedAt: string = '';
}

export class AgentFrontendAuthorizationDecision {
  policyRequestId: string = '';
  taskId: string = '';
  approved: boolean = false;
  denialReasonCode?: string;
}

export class AgentFrontendCommandReceipt {
  commandId: string = '';
  taskId: string = '';
  accepted: boolean = false;
  duplicate: boolean = false;
  rejectionCode?: string;
}

export class AgentFrontendSearchSource {
  title: string = '';
  url: string = '';
  snippet: string = '';
}

export class AgentFrontendTaskState {
  taskId: string = '';
  status: AgentTaskStatus = AgentTaskStatus.RECEIVED;
  snapshotVersion: number = 0;
  lastEventSequence: number = 0;
  updatedAt: string = '';
  resultJson: string = '{}';
  searchSources: AgentFrontendSearchSource[] = [];
}

export class AgentFrontendEvent {
  eventId: string = '';
  taskId: string = '';
  sequence: number = 0;
  snapshotVersion: number = 0;
  eventType: string = '';
  timestamp: string = '';
  payloadJson: string = '{}';
  searchSources: AgentFrontendSearchSource[] = [];
}

export class AgentFrontendAuthorizationPrompt {
  requestId: string = '';
  taskId: string = '';
  toolId: string = '';
  providerId: string = '';
  riskLevel: string = '';
  estimatedCostMicros: number = 0;
  requestedAt: string = '';
  expiresAt: string = '';
}

export class AgentFrontendClarificationPrompt {
  clarificationId: string = '';
  taskId: string = '';
  questionCode: string = '';
  prompt: string = '';
  responseSchemaJson: string = '{}';
  expiresAt: string = '';
}

export interface AgentFrontendEventListener {
  onEvent(event: AgentFrontendEvent): void;
  onAuthorizationRequired(request: AgentFrontendAuthorizationPrompt): void;
  onClarificationRequired(request: AgentFrontendClarificationPrompt): void;
}

export interface AgentFrontendSubscription {
  close(): void;
  isClosed(): boolean;
}

function asRecord(value: Object | undefined): Record<string, Object> | undefined {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) return undefined;
  return value as Record<string, Object>;
}

function searchSources(json: string): AgentFrontendSearchSource[] {
  let parsed: Object;
  try {
    parsed = JSON.parse(json) as Object;
  } catch (_error) {
    return [];
  }
  const envelope: Record<string, Object> | undefined = asRecord(parsed);
  if (envelope === undefined || envelope['schemaVersion'] !== '1.0' || envelope['provider'] !== 'tavily' ||
    !Array.isArray(envelope['results'])) return [];
  const results: Object[] = envelope['results'] as Object[];
  const sources: AgentFrontendSearchSource[] = [];
  for (let index: number = 0; index < results.length; index++) {
    const source: Record<string, Object> | undefined = asRecord(results[index]);
    if (source === undefined || typeof source['title'] !== 'string' || typeof source['url'] !== 'string' ||
      typeof source['snippet'] !== 'string') continue;
    const item: AgentFrontendSearchSource = new AgentFrontendSearchSource();
    item.title = source['title'] as string;
    item.url = source['url'] as string;
    item.snippet = source['snippet'] as string;
    sources.push(item);
  }
  return sources;
}

function copyBudget(source: ExecutionBudget): ExecutionBudget {
  const value: ExecutionBudget = new ExecutionBudget();
  value.maxWallTimeMs = source.maxWallTimeMs;
  value.maxInputTokens = source.maxInputTokens;
  value.maxOutputTokens = source.maxOutputTokens;
  value.maxMonetaryCostMicros = source.maxMonetaryCostMicros;
  value.maxToolCalls = source.maxToolCalls;
  value.maxAgentActivations = source.maxAgentActivations;
  value.maxRetries = source.maxRetries;
  value.maxReplans = source.maxReplans;
  value.deadlineAt = source.deadlineAt;
  return value;
}

function copyConsent(source: ConsentContext): ConsentContext {
  const value: ConsentContext = new ConsentContext();
  value.interactiveAllowed = source.interactiveAllowed;
  value.grantedPolicyIds = source.grantedPolicyIds.slice();
  return value;
}

class FrontendObserverBridge implements AgentRuntimeObserver {
  private readonly listener: AgentFrontendEventListener;

  constructor(listener: AgentFrontendEventListener) {
    this.listener = listener;
  }

  onEvent(event: AgentRuntimeEvent): void {
    const value: AgentFrontendEvent = new AgentFrontendEvent();
    value.eventId = event.eventId;
    value.taskId = event.taskId;
    value.sequence = event.sequence;
    value.snapshotVersion = event.snapshotVersion;
    value.eventType = event.eventType;
    value.timestamp = event.timestamp;
    value.payloadJson = event.payloadJson;
    value.searchSources = searchSources(event.payloadJson);
    this.listener.onEvent(value);
  }

  onPolicyRequest(request: PolicyRequest): void {
    const value: AgentFrontendAuthorizationPrompt = new AgentFrontendAuthorizationPrompt();
    value.requestId = request.requestId;
    value.taskId = request.taskId;
    value.toolId = request.toolId;
    value.providerId = request.providerId;
    value.riskLevel = request.riskLevel;
    value.estimatedCostMicros = request.estimatedCostMicros;
    value.requestedAt = request.requestedAt;
    value.expiresAt = request.expiresAt;
    this.listener.onAuthorizationRequired(value);
  }

  onClarificationRequest(request: ClarificationRequest): void {
    const value: AgentFrontendClarificationPrompt = new AgentFrontendClarificationPrompt();
    value.clarificationId = request.clarificationId;
    value.taskId = request.taskId;
    value.questionCode = request.questionCode;
    value.prompt = request.prompt;
    value.responseSchemaJson = request.responseSchemaJson;
    value.expiresAt = request.expiresAt;
    this.listener.onClarificationRequired(value);
  }
}

class FrontendSubscriptionBridge implements AgentFrontendSubscription {
  private readonly delegate: AgentSubscription;

  constructor(delegate: AgentSubscription) {
    this.delegate = delegate;
  }

  close(): void { this.delegate.close(); }

  isClosed(): boolean { return this.delegate.isClosed(); }
}

/** Ability-owned backend. The UI sees only this DTO surface. */
export class AgentApplicationBackend {
  private readonly config: AgentApplicationBackendConfig;
  private readonly ports: SingleAgentHostPorts;
  private readonly identity: AgentApplicationBackendIdentityPort;
  private runtime?: AgentRuntimeFacade;
  private state: AgentApplicationBackendState = AgentApplicationBackendState.NEW;
  private startPromise?: Promise<void>;
  private stopPromise?: Promise<void>;

  constructor(config: AgentApplicationBackendConfig, ports: SingleAgentHostPorts,
    identity: AgentApplicationBackendIdentityPort = new SystemAgentApplicationBackendIdentity()) {
    if (config.apiVersion !== AGENT_APPLICATION_BACKEND_API_VERSION || config.userId.trim().length === 0 ||
      config.locale.trim().length === 0 || config.timeZone.trim().length === 0) {
      throw new AgentApplicationBackendError(AgentApplicationBackendErrorCode.INVALID_CONFIGURATION,
        'Agent application backend configuration is invalid');
    }
    this.config = config;
    this.ports = ports;
    this.identity = identity;
  }

  lifecycleState(): AgentApplicationBackendState { return this.state; }

  async onCreate(): Promise<void> { await this.start(); }

  async onForeground(): Promise<void> {
    if (this.state === AgentApplicationBackendState.BACKGROUND) {
      this.state = AgentApplicationBackendState.READY;
      return;
    }
    await this.start();
  }

  onBackground(): void {
    if (this.state === AgentApplicationBackendState.READY) this.state = AgentApplicationBackendState.BACKGROUND;
  }

  async onDestroy(mode: ShutdownMode = ShutdownMode.GRACEFUL): Promise<void> {
    if (this.stopPromise === undefined) this.stopPromise = this.stopOnce(mode);
    await this.stopPromise;
  }

  async submitTask(request: AgentFrontendTaskRequest): Promise<AgentFrontendTaskHandle> {
    if (request.intent.trim().length === 0) {
      throw new AgentApplicationBackendError(AgentApplicationBackendErrorCode.INVALID_REQUEST,
        'Task intent is required');
    }
    const now: number = this.identity.nowMs();
    const submission: TaskSubmission = new TaskSubmission();
    submission.requestId = request.requestId === undefined ? this.identity.nextId('request') : request.requestId;
    submission.conversationId = request.conversationId;
    submission.userId = this.config.userId;
    submission.userIntent = request.intent.trim();
    submission.locale = this.config.locale;
    submission.timeZone = this.config.timeZone;
    submission.referenceTime = new Date(now).toISOString();
    submission.privacyClass = this.config.privacyClass;
    submission.requestedBudget = copyBudget(this.config.requestedBudget);
    submission.consentContext = copyConsent(this.config.consentContext);
    submission.submittedAt = new Date(now).toISOString();
    const handle: TaskHandle = await this.requireRuntime().submitTask(submission);
    const result: AgentFrontendTaskHandle = new AgentFrontendTaskHandle();
    result.requestId = handle.requestId;
    result.taskId = handle.taskId;
    result.acceptedAt = handle.acceptedAt;
    return result;
  }

  async authorize(request: AgentFrontendAuthorizationDecision): Promise<AgentFrontendCommandReceipt> {
    if (request.policyRequestId.trim().length === 0 || request.taskId.trim().length === 0 ||
      (!request.approved && (request.denialReasonCode === undefined ||
        request.denialReasonCode.trim().length === 0))) {
      throw new AgentApplicationBackendError(AgentApplicationBackendErrorCode.INVALID_REQUEST,
        'Authorization decision is invalid');
    }
    const now: number = this.identity.nowMs();
    const decision: AuthorizationDecision = new AuthorizationDecision();
    decision.commandId = this.identity.nextId('authorize');
    decision.policyRequestId = request.policyRequestId;
    decision.userId = this.config.userId;
    decision.taskId = request.taskId;
    decision.decision = request.approved ? AuthorizationDecisionType.APPROVED : AuthorizationDecisionType.DENIED;
    decision.denialReasonCode = request.approved ? undefined : request.denialReasonCode;
    decision.decidedAt = new Date(now).toISOString();
    decision.decidedAtMs = now;
    return this.frontendReceipt(await this.requireRuntime().provideAuthorization(decision));
  }

  async cancelTask(taskId: string, reasonCode: string = 'userRequested'): Promise<AgentFrontendCommandReceipt> {
    if (taskId.trim().length === 0 || reasonCode.trim().length === 0) {
      throw new AgentApplicationBackendError(AgentApplicationBackendErrorCode.INVALID_REQUEST,
        'Cancel request is invalid');
    }
    const command: TaskControlCommand = new TaskControlCommand();
    command.commandId = this.identity.nextId('cancel');
    command.taskId = taskId;
    command.action = TaskControlAction.CANCEL;
    command.reasonCode = reasonCode;
    command.requestedAt = new Date(this.identity.nowMs()).toISOString();
    return this.frontendReceipt(await this.requireRuntime().cancelTask(command));
  }

  async getTaskState(taskId: string): Promise<AgentFrontendTaskState> {
    if (taskId.trim().length === 0) {
      throw new AgentApplicationBackendError(AgentApplicationBackendErrorCode.INVALID_REQUEST,
        'Task ID is required');
    }
    return this.frontendState(await this.requireRuntime().getTaskSnapshot(taskId));
  }

  async subscribe(taskId: string, listener: AgentFrontendEventListener,
    afterSequence: number = 0): Promise<AgentFrontendSubscription> {
    if (taskId.trim().length === 0 || !Number.isSafeInteger(afterSequence) || afterSequence < 0) {
      throw new AgentApplicationBackendError(AgentApplicationBackendErrorCode.INVALID_REQUEST,
        'Subscription request is invalid');
    }
    const request: SubscriptionRequest = new SubscriptionRequest();
    request.subscriptionId = this.identity.nextId('subscription');
    request.taskId = taskId;
    request.afterSequence = afterSequence;
    const subscription: AgentSubscription = await this.requireRuntime().subscribe(
      request, new FrontendObserverBridge(listener));
    return new FrontendSubscriptionBridge(subscription);
  }

  private async start(): Promise<void> {
    if (this.state === AgentApplicationBackendState.READY ||
      this.state === AgentApplicationBackendState.BACKGROUND) return;
    if (this.state === AgentApplicationBackendState.STOPPING ||
      this.state === AgentApplicationBackendState.STOPPED) {
      throw new AgentApplicationBackendError(AgentApplicationBackendErrorCode.NOT_READY,
        'Agent application backend is stopping or stopped');
    }
    if (this.startPromise === undefined) this.startPromise = this.startOnce();
    await this.startPromise;
  }

  private async startOnce(): Promise<void> {
    this.state = AgentApplicationBackendState.STARTING;
    try {
      this.runtime = await createSingleAgentHostRuntime(SINGLE_AGENT_HOST_COMPOSITION_VERSION, this.ports);
      this.state = AgentApplicationBackendState.READY;
    } catch (error) {
      this.state = AgentApplicationBackendState.FAILED;
      this.startPromise = undefined;
      throw new AgentApplicationBackendError(AgentApplicationBackendErrorCode.START_FAILED,
        'Agent application backend failed to start');
    }
  }

  private async stopOnce(mode: ShutdownMode): Promise<void> {
    this.state = AgentApplicationBackendState.STOPPING;
    try {
      const pending: Promise<void> | undefined = this.startPromise;
      if (pending !== undefined) await pending;
      const runtime: AgentRuntimeFacade | undefined = this.runtime;
      if (runtime !== undefined) await runtime.shutdown(mode);
      this.runtime = undefined;
      this.state = AgentApplicationBackendState.STOPPED;
    } catch (error) {
      this.runtime = undefined;
      this.state = AgentApplicationBackendState.STOPPED;
      throw new AgentApplicationBackendError(AgentApplicationBackendErrorCode.SHUTDOWN_FAILED,
        'Agent application backend failed to shut down cleanly');
    }
  }

  private requireRuntime(): AgentRuntimeFacade {
    const runtime: AgentRuntimeFacade | undefined = this.runtime;
    if (runtime === undefined || (this.state !== AgentApplicationBackendState.READY &&
      this.state !== AgentApplicationBackendState.BACKGROUND)) {
      throw new AgentApplicationBackendError(AgentApplicationBackendErrorCode.NOT_READY,
        'Agent application backend is not ready');
    }
    return runtime;
  }

  private frontendReceipt(source: CommandReceipt): AgentFrontendCommandReceipt {
    const value: AgentFrontendCommandReceipt = new AgentFrontendCommandReceipt();
    value.commandId = source.commandId;
    value.taskId = source.taskId;
    value.accepted = source.accepted;
    value.duplicate = source.duplicate;
    value.rejectionCode = source.rejectionCode;
    return value;
  }

  private frontendState(source: AgentTaskSnapshot): AgentFrontendTaskState {
    const value: AgentFrontendTaskState = new AgentFrontendTaskState();
    value.taskId = source.taskId;
    value.status = source.status;
    value.snapshotVersion = source.snapshotVersion;
    value.lastEventSequence = source.lastEventSequence;
    value.updatedAt = source.updatedAt;
    value.resultJson = source.resultJson;
    value.searchSources = searchSources(source.resultJson);
    return value;
  }
}
