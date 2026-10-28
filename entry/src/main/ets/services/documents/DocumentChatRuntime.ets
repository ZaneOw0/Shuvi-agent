import common from '@ohos.app.ability.common';
import util from '@ohos.util';
import {
  AgentRuntimeEvent, AgentTaskStatus, AuthorizationDecision, AuthorizationDecisionType, ClarificationRequest,
  ClarificationResponse, PolicyRequest, PrivacyClass, SideEffect, TaskSubmission, ToolOutcome, ToolOutcomeStatus,
  WorkflowGraph, WorkflowStep, WorkflowStepKind
} from '@harmony_agent/agent-contracts';
import { BudgetAmount } from '@harmony_agent/agent-core';
import {
  AgentRuntimeFacade, AgentRuntimeObserver, PlanningRequest, PlanningResult, PlanningStatus, PreparedToolDispatch,
  ProductionAgentRuntimeConfig, ProductionAgentRuntimePorts, RuntimeClockPort, RuntimeIdGeneratorPort, SemanticPlannerPort,
  ShutdownMode, SubscriptionRequest, ToolInvocationPreparerPort, ToolRegistry, ToolRegistryEntry, createProductionAgentRuntime,
  SingleAgentCollaborationSelector
} from '@harmony_agent/agent-runtime';
import { RuntimeExecutionRecoveryBridgeConfig, RuntimeOutcomeAccountingPort, StoredOperation } from '@harmony_agent/agent-storage';
import {
  LocalDocumentResult, NativeCancellationResolverPort, NativeCancellationSignalPort,
  NativeExecutionEnvironmentPort, NativePermissionState, OhosNativeDocumentToolSet, RdbDocumentCatalog,
  SystemNativeDocumentDigest, nativeCanonicalJson
} from '@harmony_agent/native-tools';
import { AgentHostDigest } from '../model/AgentHostDigest';
import { NativeAgentRdbOpen } from '../model/AgentRdbResources';
import { DocumentExecutionResource } from './DocumentExecutionResource';
import { DocumentChatCommand, DocumentChatPort, DocumentChatResult } from './DocumentToolContracts';
import { createDownloadDocumentTools, DownloadDocumentStore, DownloadLocation } from './DownloadDocumentStore';

const OWNER: string = 'shuvi-local-owner-v1';
const SCOPE: string = 'shuvi-local-documents-v1';
const POLICY: string = 'shuvi-document-chat-download-v2';

class DocumentClock implements RuntimeClockPort { nowMs(): number { return Date.now(); } }
class DocumentIds implements RuntimeIdGeneratorPort {
  nextId(kind: string, _request: string): string { return kind + '-' + util.generateRandomUUID(); }
}
class DocumentSignal implements NativeCancellationResolverPort, NativeCancellationSignalPort {
  cancelled: boolean = false;
  isCancellationRequested(): boolean { return this.cancelled; }
  resolve(_task: string, _step: string, _dispatch: string, _invocation: string): NativeCancellationSignalPort { return this; }
}
class DocumentEnvironment implements NativeExecutionEnvironmentPort {
  private readonly foreground: () => boolean;
  constructor(foreground: () => boolean) { this.foreground = foreground; }
  permissionState(_permission: string): NativePermissionState { return NativePermissionState.NOT_DECLARED; }
  isBackgroundExecutionAllowed(_tool: string): boolean { return this.foreground(); }
}
class DocumentAccounting implements RuntimeOutcomeAccountingPort {
  actualForOutcome(operation: StoredOperation, outcome: ToolOutcome): BudgetAmount | undefined {
    if (!operation.intent.toolId.startsWith('native://documents/' + SCOPE + '/') ||
      outcome.status === ToolOutcomeStatus.UNKNOWN_OUTCOME) return undefined;
    // This implementation performs only local file/RDB I/O and has no provider billing.
    const amount: BudgetAmount = new BudgetAmount(); amount.toolCalls = 1;
    amount.wallTimeMs = Math.max(0, Date.parse(outcome.finishedAt) - Date.parse(outcome.startedAt));
    return amount;
  }
}

class DocumentPlan implements SemanticPlannerPort, ToolInvocationPreparerPort {
  private readonly registry: ToolRegistry;
  private readonly digest: SystemNativeDocumentDigest;
  private action: string = '';
  private argumentsJson: string = '{}';
  prepared?: PreparedToolDispatch;
  constructor(registry: ToolRegistry, digest: SystemNativeDocumentDigest) { this.registry = registry; this.digest = digest; }
  bind(command: DocumentChatCommand): void {
    this.action = command.action; this.prepared = undefined;
    const args: Record<string, Object> = {};
    if (command.action === 'create') args['fileName'] = command.fileName;
    else args['documentId'] = command.documentId;
    if (command.action === 'update') args['expectedVersion'] = command.expectedVersion;
    if (command.action !== 'read') args['content'] = command.content;
    this.argumentsJson = nativeCanonicalJson(args);
  }
  private entry(): ToolRegistryEntry {
    const entry: ToolRegistryEntry | undefined = this.registry.activeEntries().find((item: ToolRegistryEntry): boolean =>
      item.descriptor.capabilityName === 'document.' + this.action);
    if (entry === undefined) throw new Error('DOCUMENT_TOOL_UNAVAILABLE'); return entry;
  }
  async plan(request: PlanningRequest): Promise<PlanningResult> {
    if (request.envelope.privacyClass !== PrivacyClass.PERSONAL || request.envelope.userIntent !== 'document.' + this.action) {
      throw new Error('DOCUMENT_INTENT_CHANGED');
    }
    const entry: ToolRegistryEntry = this.entry(); const step: WorkflowStep = new WorkflowStep();
    step.stepId = 'local-document'; step.kind = WorkflowStepKind.TOOL; step.goal = request.envelope.userIntent;
    const schema: string | undefined = entry.descriptor.outputSchemaJson;
    if (schema === undefined) throw new Error('DOCUMENT_SCHEMA_UNAVAILABLE');
    step.capabilityRequirements = [entry.descriptor.capabilityName]; step.expectedOutputSchemaJson = schema;
    step.riskLevel = entry.descriptor.riskLevel; step.sideEffect = entry.descriptor.sideEffect;
    step.idempotencyMode = entry.descriptor.idempotencyMode; step.permissionRequirements = entry.descriptor.permissionRequirements.slice();
    step.timeoutMs = 10000; step.retryPolicyRef = 'no-retry'; step.verificationPolicyRef = 'durable-document-receipt-v1';
    const graph: WorkflowGraph = new WorkflowGraph(); graph.workflowId = 'document-' + request.envelope.taskId;
    graph.taskId = request.envelope.taskId; graph.workflowVersion = '1'; graph.createdAt = new Date().toISOString();
    graph.steps = [step]; graph.entryStepIds = [step.stepId];
    const result: PlanningResult = new PlanningResult(); result.status = PlanningStatus.READY; result.workflow = graph; return result;
  }
  async resume(_request: PlanningRequest, _response: ClarificationResponse): Promise<PlanningResult> { return new PlanningResult(); }
  async replan(_request: PlanningRequest): Promise<PlanningResult> { return new PlanningResult(); }
  interrupt(_task: string): boolean { return false; }
  prepare(request: PlanningRequest, step: WorkflowStep, now: number): PreparedToolDispatch {
    const entry: ToolRegistryEntry = this.entry(); const value: PreparedToolDispatch = new PreparedToolDispatch();
    const policy = value.policyRequest;
    policy.requestId = 'policy-' + request.envelope.taskId; policy.userId = request.envelope.userId;
    policy.taskId = request.envelope.taskId; policy.stepId = step.stepId; policy.operationId = 'operation-' + policy.taskId;
    policy.toolId = entry.descriptor.toolId; policy.toolIdentityVersion = entry.descriptor.toolIdentityVersion;
    policy.providerId = entry.descriptor.providerId; policy.schemaDigest = entry.descriptor.schemaDigest;
    policy.riskLevel = step.riskLevel; policy.sideEffect = step.sideEffect; policy.estimatedCostMicros = 0;
    policy.requestedAt = new Date(now).toISOString(); policy.expiresAtMs = now + 60000;
    policy.expiresAt = new Date(policy.expiresAtMs).toISOString(); policy.argumentsDigest = this.digest.digest(this.argumentsJson);
    const invocation = value.invocation;
    invocation.invocationId = 'invocation-' + policy.taskId; invocation.taskId = policy.taskId; invocation.stepId = step.stepId;
    invocation.operationId = policy.operationId; invocation.attemptId = 'attempt-1'; invocation.toolId = policy.toolId;
    invocation.toolIdentityVersion = policy.toolIdentityVersion; invocation.schemaDigest = policy.schemaDigest;
    invocation.argumentsJson = this.argumentsJson; invocation.argumentsDigest = policy.argumentsDigest;
    if (step.sideEffect !== SideEffect.NONE) invocation.idempotencyKey = 'key-' + policy.operationId;
    invocation.timeoutMs = step.timeoutMs; invocation.createdAt = policy.requestedAt;
    this.prepared = value; return value;
  }
}
class DocumentObserver implements AgentRuntimeObserver {
  requests: PolicyRequest[] = [];
  onEvent(_event: AgentRuntimeEvent): void {}
  onPolicyRequest(request: PolicyRequest): void { this.requests.push(request); }
  onClarificationRequest(_request: ClarificationRequest): void { throw new Error('DOCUMENT_CLARIFICATION_UNEXPECTED'); }
}

/** Personal offline tool Runtime, called only by the explicitly enabled model-tool session. */
export class DocumentChatRuntime implements DocumentChatPort {
  private readonly context: common.Context;
  private readonly foreground: () => boolean;
  private readonly digest: SystemNativeDocumentDigest = new SystemNativeDocumentDigest();
  private readonly signal: DocumentSignal = new DocumentSignal();
  private readonly resource: DocumentExecutionResource;
  private tools?: OhosNativeDocumentToolSet;
  private catalog?: RdbDocumentCatalog;
  private runtime?: AgentRuntimeFacade;
  private plan?: DocumentPlan;
  private opening?: Promise<void>;
  private flight?: Promise<DocumentChatResult>;
  private stopping?: Promise<void>;
  private closed: boolean = false;
  constructor(context: common.Context, foreground: () => boolean) {
    this.context = context; this.foreground = foreground;
    const recovery: RuntimeExecutionRecoveryBridgeConfig = new RuntimeExecutionRecoveryBridgeConfig();
    recovery.ownerId = OWNER; recovery.policyVersion = POLICY; recovery.leaseTtlMs = 60000;
    recovery.outcomeAccounting = new DocumentAccounting();
    this.resource = new DocumentExecutionResource(new NativeAgentRdbOpen(context), recovery, new AgentHostDigest());
  }
  private async ensure(): Promise<void> {
    if (this.closed || !this.foreground()) throw new Error('DOCUMENT_SESSION_CLOSED');
    if (this.opening === undefined) this.opening = this.open();
    await this.opening;
    if (this.closed || !this.foreground()) throw new Error('DOCUMENT_SESSION_CLOSED');
  }
  private async open(): Promise<void> {
    try {
      await this.resource.open(); const database = this.resource.database;
      if (database === undefined || this.closed) throw new Error('DOCUMENT_SESSION_CLOSED');
      this.tools = await createDownloadDocumentTools(this.context, SCOPE, database, this.resource,
        new DocumentEnvironment(this.foreground), this.signal);
      this.catalog = new RdbDocumentCatalog(database, SCOPE, this.digest);
      const registry: ToolRegistry = new ToolRegistry();
      for (const entry of this.tools.tools.entries()) if (!registry.register(entry).accepted) throw new Error('DOCUMENT_TOOL_UNAVAILABLE');
      this.plan = new DocumentPlan(registry, this.digest);
      const ports: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
      ports.clock = new DocumentClock(); ports.ids = new DocumentIds(); ports.planner = this.plan; ports.toolPreparer = this.plan;
      ports.collaboration = new SingleAgentCollaborationSelector();
      ports.adapterFactory = this.tools.tools; ports.persistence = this.resource;
      const config: ProductionAgentRuntimeConfig = new ProductionAgentRuntimeConfig(); config.policyVersion = POLICY; config.grantTtlMs = 60000;
      this.runtime = createProductionAgentRuntime(config, ports);
    } catch (error) { await this.resource.close(); throw error as Error; }
  }
  async resolve(target: string): Promise<DocumentChatResult | undefined> {
    await this.ensure(); let id: string = target;
    if (!/^doc-[a-f0-9]{64}$/.test(target)) {
      const snapshot = await (this.catalog as RdbDocumentCatalog).load();
      const matches = snapshot?.documents.filter((item): boolean => item.fileName === target) ?? [];
      if (matches.length > 1) throw new Error('DOCUMENT_AMBIGUOUS_NAME');
      if (matches.length === 0) return undefined; id = matches[0].documentId;
    }
    const value: LocalDocumentResult = await (this.tools as OhosNativeDocumentToolSet).store.read(id, this.signal);
    return this.project(value);
  }
  execute(source: DocumentChatCommand): Promise<DocumentChatResult> {
    if (this.flight !== undefined) return Promise.reject(new Error('DOCUMENT_SESSION_BUSY'));
    const command: DocumentChatCommand = JSON.parse(JSON.stringify(source)) as DocumentChatCommand;
    const result: Promise<DocumentChatResult> = this.executeOnce(command); this.flight = result;
    return result.finally((): void => { this.flight = undefined; });
  }
  private async executeOnce(command: DocumentChatCommand): Promise<DocumentChatResult> {
    await this.ensure(); const runtime: AgentRuntimeFacade = this.runtime as AgentRuntimeFacade;
    const plan: DocumentPlan = this.plan as DocumentPlan; plan.bind(command); this.resource.beginOperation();
    const request: TaskSubmission = new TaskSubmission();
    request.requestId = 'document-' + util.generateRandomUUID(); request.userId = OWNER; request.userIntent = 'document.' + command.action;
    request.locale = 'zh-CN'; request.timeZone = 'Asia/Shanghai'; request.privacyClass = PrivacyClass.PERSONAL;
    request.referenceTime = new Date().toISOString(); request.submittedAt = request.referenceTime;
    request.requestedBudget.maxWallTimeMs = 15000; request.requestedBudget.maxToolCalls = 1;
    request.requestedBudget.maxAgentActivations = 1; request.consentContext.interactiveAllowed = true;
    const handle = await runtime.submitTask(request);
    const observer: DocumentObserver = new DocumentObserver(); const subscription: SubscriptionRequest = new SubscriptionRequest();
    subscription.subscriptionId = 'document-subscription-' + handle.taskId; subscription.taskId = handle.taskId;
    const active = await runtime.subscribe(subscription, observer);
    try {
      for (let i: number = 0; i < 300; i++) {
        const state = await runtime.getTaskSnapshot(handle.taskId);
        if (state.status === AgentTaskStatus.WAITING_AUTHORIZATION) {
          const policy = observer.requests.shift(); const prepared = plan.prepared;
          if (!this.foreground() || this.closed || policy === undefined || prepared === undefined ||
            nativeCanonicalJson(policy) !== nativeCanonicalJson(prepared.policyRequest)) throw new Error('DOCUMENT_CONSENT_CHANGED');
          const decision: AuthorizationDecision = new AuthorizationDecision(); decision.commandId = 'approve-' + policy.requestId;
          decision.policyRequestId = policy.requestId; decision.taskId = handle.taskId; decision.userId = OWNER;
          decision.decision = AuthorizationDecisionType.APPROVED; decision.decidedAtMs = Date.now();
          decision.decidedAt = new Date(decision.decidedAtMs).toISOString();
          if (!(await runtime.provideAuthorization(decision)).accepted) throw new Error('DOCUMENT_CONSENT_REJECTED');
        } else if (state.status === AgentTaskStatus.COMPLETED) {
          const outcome: ToolOutcome | undefined = this.resource.outcome();
          if (outcome === undefined || outcome.status !== ToolOutcomeStatus.SUCCEEDED) throw new Error('DOCUMENT_OUTCOME_NOT_DURABLE');
          const json: string | undefined = outcome.resultJson;
          if (json === undefined) throw new Error('DOCUMENT_RESULT_INVALID');
          return await this.project(JSON.parse(json) as LocalDocumentResult);
        } else if (state.status === AgentTaskStatus.WAITING_RECONCILIATION) {
          throw new Error(this.resource.outcome()?.errorCode ?? 'DOCUMENT_RESULT_UNCERTAIN');
        }
        else if (state.status === AgentTaskStatus.FAILED || state.status === AgentTaskStatus.CANCELLED) {
          throw new Error(this.resource.outcome()?.errorCode ?? 'DOCUMENT_OPERATION_FAILED');
        }
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 50); });
      }
      this.signal.cancelled = true; throw new Error('DOCUMENT_RESULT_UNCERTAIN');
    } catch (error) {
      const outcome: ToolOutcome | undefined = this.resource.outcome();
      if (command.action !== 'read' && this.resource.activeDispatchCommitted &&
        (outcome === undefined || outcome.status === ToolOutcomeStatus.SUCCEEDED)) throw new Error('DOCUMENT_RESULT_UNCERTAIN');
      throw error as Error;
    } finally { active.close(); }
  }
  private async project(value: LocalDocumentResult): Promise<DocumentChatResult> {
    if (!/^doc-[a-f0-9]{64}$/.test(value.documentId) || !Number.isSafeInteger(value.version) || value.version < 1 ||
      typeof value.fileName !== 'string') throw new Error('DOCUMENT_RESULT_INVALID');
    const result: DocumentChatResult = new DocumentChatResult(); result.documentId = value.documentId;
    result.fileName = value.fileName; result.version = value.version; result.content = value.content ?? ''; result.receipt = value.receipt ?? '';
    const location: DownloadLocation = await ((this.tools as OhosNativeDocumentToolSet).store as DownloadDocumentStore).location(value);
    result.savedToDownloads = location.savedToDownloads;
    result.storageLocation = location.storageLocation; result.fileUri = location.fileUri;
    return result;
  }
  stop(): Promise<void> {
    if (this.stopping !== undefined) return this.stopping;
    this.closed = true; this.signal.cancelled = true; this.stopping = this.close(); return this.stopping;
  }
  private async close(): Promise<void> {
    if (this.opening !== undefined) { try { await this.opening; } catch { /* open() releases acquired storage. */ } }
    if (this.flight !== undefined) { try { await this.flight; } catch { /* Preserve durable evidence of interrupted operations. */ } }
    if (this.resource.activeDispatchCommitted && this.resource.outcome() === undefined) throw new Error('DOCUMENT_SHUTDOWN_UNCONFIRMED');
    try { if (this.runtime !== undefined) await this.runtime.shutdown(ShutdownMode.GRACEFUL); }
    finally { await this.resource.close(); }
  }
}
