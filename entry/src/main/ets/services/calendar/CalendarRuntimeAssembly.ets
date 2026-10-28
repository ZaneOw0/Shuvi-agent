import util from '@ohos.util';
import { PrivacyClass, ToolOutcome } from '@harmony_agent/agent-contracts';
import { BudgetAmount } from '@harmony_agent/agent-core';
import { AgentApplicationBackend, AgentApplicationBackendConfig, AgentApplicationBackendState,
  AgentFrontendAuthorizationDecision, AgentFrontendAuthorizationPrompt, AgentFrontendCommandReceipt,
  AgentFrontendEventListener, AgentFrontendSubscription, AgentFrontendTaskHandle, AgentFrontendTaskRequest, AgentFrontendTaskState,
  AgentRuntimeFacade, ProductionAgentRuntimeConfig, ProductionAgentRuntimePorts, ProductionRuntimeAdapterFactoryPort,
  RuntimeClockPort, RuntimeIdGeneratorPort, RuntimeToolOutcomeSinkPort, ShutdownMode, SingleAgentCollaborationSelector,
  SingleAgentHostPorts, SingleAgentHostResourcePort, SingleAgentHostRuntimeFactoryPort, StepDispatchPort, ToolRegistry,
  createProductionAgentRuntime } from '@harmony_agent/agent-runtime';
import { RuntimeExecutionRecoveryBridgeConfig, RuntimeOutcomeAccountingPort, StoredOperation } from '@harmony_agent/agent-storage';
import { AgentRdbOpenPort } from '../model/AgentRdbResources';
import { AgentHostDigest } from '../model/AgentHostDigest';
import { ShuviRuntimeSessionFactory, ShuviRuntimeSessionPort } from '../model/ShuviRuntimeSession';
import { CalendarExecutionResource } from './CalendarExecutionResource';
import { CalendarNativeToolPort, CalendarToolAdapter } from './CalendarToolAdapter';
import { CALENDAR_OWNER, CALENDAR_POLICY, CalendarToolPreviews, CalendarToolResult, parseCalendarToolResult, registerCalendarTool } from './CalendarToolContract';
import { CalendarToolPlanner } from './CalendarToolPlanner';

class LocalResource implements SingleAgentHostResourcePort { async open(): Promise<void> {} async close(): Promise<void> {} }
class CalendarClock implements RuntimeClockPort { nowMs(): number { return Date.now(); } }
class CalendarIds implements RuntimeIdGeneratorPort { nextId(kind: string, _request: string): string { return kind + '-' + util.generateRandomUUID(); } }
class CalendarAccounting implements RuntimeOutcomeAccountingPort {
  actualForOutcome(_operation: StoredOperation, _outcome: ToolOutcome): BudgetAmount {
    // Native CalendarKit has no supplier charge. Model billing stays in the separate model task.
    const value = new BudgetAmount(); value.toolCalls = 1; return value;
  }
}
class CalendarAdapters implements ProductionRuntimeAdapterFactoryPort {
  private readonly native: CalendarNativeToolPort; private readonly execution: CalendarExecutionResource; private readonly digest: AgentHostDigest;
  private readonly resultSink: (taskId: string, result: CalendarToolResult) => void;
  constructor(native: CalendarNativeToolPort, execution: CalendarExecutionResource, digest: AgentHostDigest,
    resultSink: (taskId: string, result: CalendarToolResult) => void) {
    this.native = native; this.execution = execution; this.digest = digest; this.resultSink = resultSink;
  }
  create(sink: RuntimeToolOutcomeSinkPort): StepDispatchPort { return new CalendarToolAdapter(this.native, this.execution, this.digest, sink, this.resultSink); }
}
class CalendarBackendFactory implements SingleAgentHostRuntimeFactoryPort {
  private readonly ports: ProductionAgentRuntimePorts;
  constructor(ports: ProductionAgentRuntimePorts) { this.ports = ports; }
  async create(): Promise<AgentRuntimeFacade> {
    const config = new ProductionAgentRuntimeConfig(); config.policyVersion = CALENDAR_POLICY; config.grantTtlMs = 60000;
    return createProductionAgentRuntime(config, this.ports);
  }
}
class CalendarRuntimeSession implements ShuviRuntimeSessionPort {
  private readonly backend: AgentApplicationBackend; private readonly execution: CalendarExecutionResource;
  private readonly previews: CalendarToolPreviews; private readonly native: CalendarNativeToolPort;
  private starting?: Promise<void>; private stopping?: Promise<void>; private stopped: boolean = false; private ready: boolean = false;
  private taskId: string = '';
  constructor(backend: AgentApplicationBackend, execution: CalendarExecutionResource, previews: CalendarToolPreviews, native: CalendarNativeToolPort) {
    this.backend = backend; this.execution = execution; this.previews = previews; this.native = native;
  }
  async start(key: Uint8Array): Promise<void> {
    key.fill(0);
    if (this.stopped || this.starting !== undefined) throw new Error('CALENDAR_SESSION_USED');
    this.starting = this.backend.onCreate(); await this.starting;
    if (this.stopped) throw new Error('CALENDAR_START_INTERRUPTED'); this.ready = true;
  }
  stop(): Promise<void> {
    if (this.stopping !== undefined) return this.stopping;
    this.stopped = true; this.ready = false; this.previews.clear(); this.native.cancel();
    this.stopping = this.close(); return this.stopping;
  }
  private async close(): Promise<void> {
    if (this.starting !== undefined) { try { await this.starting; } catch {} }
    let failed = false;
    if (this.backend.lifecycleState() !== AgentApplicationBackendState.NEW && this.backend.lifecycleState() !== AgentApplicationBackendState.FAILED) {
      try { await this.backend.onDestroy(ShutdownMode.IMMEDIATE); } catch { failed = true; }
    }
    try { await this.execution.close(); } catch { failed = true; }
    if (failed) throw new Error('CALENDAR_CLOSE_FAILED');
  }
  private assertReady(): void { if (!this.ready || this.stopped) throw new Error('CALENDAR_NOT_READY'); }
  async submit(request: AgentFrontendTaskRequest): Promise<AgentFrontendTaskHandle> {
    this.assertReady(); if (!this.execution.available()) throw new Error('CALENDAR_JOURNAL_FULL');
    const handle = await this.backend.submitTask(request); this.taskId = handle.taskId; return handle;
  }
  async authorize(prompt: AgentFrontendAuthorizationPrompt, approved: boolean): Promise<AgentFrontendCommandReceipt> {
    this.assertReady(); if (this.previews.resolve(prompt) === undefined) throw new Error('CALENDAR_PREVIEW_EXPIRED');
    const decision = new AgentFrontendAuthorizationDecision(); decision.taskId = prompt.taskId;
    decision.policyRequestId = prompt.requestId; decision.approved = approved;
    if (!approved) decision.denialReasonCode = 'USER_DECLINED';
    return this.backend.authorize(decision);
  }
  async cancel(taskId: string): Promise<AgentFrontendCommandReceipt> {
    this.assertReady();
    // Runtime defers cancellation of side-effecting steps for reconciliation. The native host can
    // still stop BEFORE addEvent, or retain a late ID after addEvent; it must not promise rollback.
    if (taskId === this.taskId) this.native.cancel();
    return this.backend.cancelTask(taskId);
  }
  async getTask(taskId: string): Promise<AgentFrontendTaskState> { this.assertReady(); return this.backend.getTaskState(taskId); }
  async subscribe(taskId: string, listener: AgentFrontendEventListener, afterSequence: number): Promise<AgentFrontendSubscription> {
    this.assertReady(); return this.backend.subscribe(taskId, listener, afterSequence);
  }
}
export class CalendarRuntimeFactory implements ShuviRuntimeSessionFactory {
  readonly previews: CalendarToolPreviews = new CalendarToolPreviews();
  onOutcomeRejected: (taskId: string) => void = (_taskId: string): void => {};
  private readonly opener: AgentRdbOpenPort; private readonly native: CalendarNativeToolPort; private readonly debug: boolean;
  private resultTask: string = '';
  private result?: CalendarToolResult;
  constructor(opener: AgentRdbOpenPort, native: CalendarNativeToolPort, debug: boolean) { this.opener = opener; this.native = native; this.debug = debug; }
  resultFor(taskId: string): CalendarToolResult | undefined {
    return this.resultTask === taskId && this.result !== undefined ? parseCalendarToolResult(JSON.stringify(this.result)) : undefined;
  }
  create(): ShuviRuntimeSessionPort {
    if (!this.debug) throw new Error('CALENDAR_RUNTIME_DEBUG_ONLY');
    this.previews.clear(); const digest = new AgentHostDigest(); const registry = new ToolRegistry(); registerCalendarTool(registry, digest);
    const recovery = new RuntimeExecutionRecoveryBridgeConfig(); recovery.ownerId = CALENDAR_OWNER;
    recovery.policyVersion = CALENDAR_POLICY; recovery.leaseTtlMs = 60000; recovery.outcomeAccounting = new CalendarAccounting();
    const execution = new CalendarExecutionResource(this.opener, recovery, digest);
    execution.onOutcomeRejected = (id: string): void => this.onOutcomeRejected(id);
    const ports = new ProductionAgentRuntimePorts(); ports.ids = new CalendarIds(); ports.clock = new CalendarClock();
    const planner = new CalendarToolPlanner(registry, digest, ports.ids, this.previews);
    ports.planner = planner; ports.toolPreparer = planner; ports.collaboration = new SingleAgentCollaborationSelector();
    ports.persistence = execution; ports.adapterFactory = new CalendarAdapters(this.native, execution, digest,
      (taskId: string, result: CalendarToolResult): void => { this.resultTask = taskId; this.result = parseCalendarToolResult(JSON.stringify(result)); });
    const host = new SingleAgentHostPorts(); host.credentialStore = new LocalResource(); host.memoryStorage = new LocalResource();
    host.mcpClient = new LocalResource(); host.executionStorage = execution; host.runtimeFactory = new CalendarBackendFactory(ports);
    const config = new AgentApplicationBackendConfig(); config.userId = CALENDAR_OWNER; config.privacyClass = PrivacyClass.PERSONAL;
    config.consentContext.interactiveAllowed = true; config.requestedBudget.maxWallTimeMs = 180000;
    config.requestedBudget.maxToolCalls = 1; config.requestedBudget.maxAgentActivations = 1;
    return new CalendarRuntimeSession(new AgentApplicationBackend(config, host), execution, this.previews, this.native);
  }
}
