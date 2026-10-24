import { ArtifactCollaborationPolicy } from '../routing/ArtifactCollaborationPolicy';
import {
  AgentErrorClass,
  AgentRuntimeEvent,
  AgentTaskSnapshot,
  AgentTaskStatus,
  AuthorizationDecision,
  ClarificationRequest,
  ClarificationResponse,
  CommandReceipt,
  ContractCodec,
  ContractValidator,
  PolicyRequest,
  ReconciliationReport,
  TaskControlAction,
  TaskControlCommand,
  TaskHandle,
  TaskSubmission,
  ToolOutcome,
  ToolOutcomeStatus,
  WorkflowInputBinding,
  WorkflowStep
} from '@harmony_agent/agent-contracts';
import { StepExecutionStatus } from '@harmony_agent/agent-core';
import { AgentRuntimeError } from '../api/AgentRuntimeError';
import {
  AgentRuntimeErrorCode,
  AgentRuntimeFacade,
  AgentRuntimeObserver,
  AgentSubscription,
  ShutdownMode,
  SubscriptionRequest
} from '../api/RuntimeApi';
import {
  CoordinatorCommandResult,
  DispatchPersistenceContext,
  OrchestrationAcceptance,
  RuntimeTaskRecoveryCheckpoint,
  StepCompletion,
  StepDispatchReceipt,
  StepDispatchRequest
} from '../orchestration/OrchestrationTypes';
import { RuntimeCoordinator, RuntimeCoordinatorConfig } from '../orchestration/RuntimeCoordinator';
import {
  RuntimeCheckpointValidationResult,
  RuntimeCheckpointValidator
} from '../orchestration/RuntimeCheckpointValidator';
import { RuntimeDurableAuthorityPayload } from '../orchestration/RecoveryAuthorityTypes';
import {
  CollaborationPlanSelectorPort,
  CollaborationSelectorPort,
  RuntimeClockPort,
  RuntimeIdGeneratorPort,
  SemanticPlannerPort,
  RuntimeStateObserverPort,
  StepDispatchPort,
  ToolInvocationPreparerPort
} from '../orchestration/RuntimePorts';
import {
  PRODUCTION_RUNTIME_COMPOSITION_VERSION,
  ProductionAgentRuntimeConfig,
  ProductionRuntimeAdapterFactoryPort,
  ProductionAgentRuntimePorts,
  ProductionRuntimePersistencePort,
  ProductionRuntimeRecoverySourcePort,
  RuntimePersistenceResult,
  RuntimeToolOutcomeSinkPort
} from './ProductionRuntimeTypes';
import { RuntimeRecoveryAuthority } from '../orchestration/RecoveryAuthorityTypes';

function copyPersistenceContext(source: DispatchPersistenceContext | undefined):
  DispatchPersistenceContext | undefined {
  if (source === undefined) return undefined;
  const value: DispatchPersistenceContext = new DispatchPersistenceContext();
  value.contextVersion = source.contextVersion;
  value.operationId = source.operationId;
  value.dispatchId = source.dispatchId;
  value.invocationId = source.invocationId;
  value.attemptId = source.attemptId;
  value.taskId = source.taskId;
  value.stepId = source.stepId;
  value.toolId = source.toolId;
  value.toolIdentityVersion = source.toolIdentityVersion;
  value.schemaDigest = source.schemaDigest;
  value.argumentsDigest = source.argumentsDigest;
  value.idempotencyKey = source.idempotencyKey;
  value.idempotencyMode = source.idempotencyMode;
  value.sideEffect = source.sideEffect;
  value.policyRequestId = source.policyRequestId;
  value.budgetReservationId = source.budgetReservationId;
  value.providerId = source.providerId;
  value.requestedToolCalls = source.requestedToolCalls;
  value.requestedCostMicros = source.requestedCostMicros;
  value.createdAt = source.createdAt;
  return value;
}

function copyWorkflowStep(source: WorkflowStep): WorkflowStep {
  const value: WorkflowStep = new WorkflowStep();
  value.stepId = source.stepId;
  value.kind = source.kind;
  value.goal = source.goal;
  value.dependencies = source.dependencies.slice();
  for (let i: number = 0; i < source.inputBindings.length; i++) {
    const binding: WorkflowInputBinding = new WorkflowInputBinding();
    binding.name = source.inputBindings[i].name;
    binding.sourceStepId = source.inputBindings[i].sourceStepId;
    binding.sourceOutputPath = source.inputBindings[i].sourceOutputPath;
    binding.literalJson = source.inputBindings[i].literalJson;
    value.inputBindings.push(binding);
  }
  value.expectedOutputSchemaJson = source.expectedOutputSchemaJson;
  value.capabilityRequirements = source.capabilityRequirements.slice();
  value.sideEffect = source.sideEffect;
  value.riskLevel = source.riskLevel;
  value.permissionRequirements = source.permissionRequirements.slice();
  value.idempotencyMode = source.idempotencyMode;
  value.timeoutMs = source.timeoutMs;
  value.retryPolicyRef = source.retryPolicyRef;
  value.verificationPolicyRef = source.verificationPolicyRef;
  return value;
}

function copyDispatchRequest(source: StepDispatchRequest): StepDispatchRequest {
  const value: StepDispatchRequest = new StepDispatchRequest();
  value.task = ContractCodec.parseTaskEnvelope(ContractCodec.stringify(source.task));
  value.workflowId = source.workflowId;
  value.workflowVersion = source.workflowVersion;
  value.step = copyWorkflowStep(source.step);
  value.dispatchId = source.dispatchId;
  if (source.toolInvocation !== undefined) {
    value.toolInvocation = ContractCodec.parseToolInvocation(ContractCodec.stringify(source.toolInvocation));
  }
  value.persistenceContext = copyPersistenceContext(source.persistenceContext);
  return value;
}

class PersistedTaskVersion {
  taskId: string = '';
  version: number = 0;
}

class ProductionObserverRegistration {
  request: SubscriptionRequest = new SubscriptionRequest();
  observer?: AgentRuntimeObserver;
  closed: boolean = false;
  lastEventSequence: number = 0;
  lastPolicyRequestId: string = '';
  lastClarificationId: string = '';
}

class ProductionCommandRecord {
  commandId: string = '';
  taskId: string = '';
  fingerprint: string = '';
  receipt: CommandReceipt = new CommandReceipt();
}

class PendingDispatchBinding {
  taskId: string = '';
  stepId: string = '';
  dispatchId: string = '';
  invocationId: string = '';
  active: boolean = false;
  queuedOutcome?: ToolOutcome;
}

class PendingDispatchRegistry {
  private readonly values: PendingDispatchBinding[] = [];

  register(request: StepDispatchRequest): void {
    const value: PendingDispatchBinding = new PendingDispatchBinding();
    value.taskId = request.task.taskId;
    value.stepId = request.step.stepId;
    value.dispatchId = request.dispatchId;
    value.invocationId = request.toolInvocation === undefined ? '' : request.toolInvocation.invocationId;
    this.values.push(value);
  }

  remove(dispatchId: string): void {
    const index: number = this.find(dispatchId);
    if (index >= 0) this.values.splice(index, 1);
  }

  activate(dispatchId: string): void {
    const index: number = this.find(dispatchId);
    if (index >= 0) this.values[index].active = true;
  }

  isActive(dispatchId: string): boolean {
    const index: number = this.find(dispatchId);
    return index >= 0 && this.values[index].active;
  }

  queue(dispatchId: string, outcome: ToolOutcome): void {
    const index: number = this.find(dispatchId);
    if (index >= 0 && this.values[index].queuedOutcome === undefined) {
      this.values[index].queuedOutcome = ContractCodec.parseToolOutcome(ContractCodec.stringify(outcome));
    }
  }

  takeQueued(): PendingAdapterCompletion | undefined {
    for (let i: number = 0; i < this.values.length; i++) {
      if (this.values[i].active && this.values[i].queuedOutcome !== undefined) {
        const completion: PendingAdapterCompletion = new PendingAdapterCompletion();
        completion.taskId = this.values[i].taskId;
        completion.stepId = this.values[i].stepId;
        completion.dispatchId = this.values[i].dispatchId;
        completion.outcome = this.values[i].queuedOutcome as ToolOutcome;
        this.values[i].queuedOutcome = undefined;
        return completion;
      }
    }
    return undefined;
  }

  matches(taskId: string, stepId: string, dispatchId: string, outcome: ToolOutcome): boolean {
    const index: number = this.find(dispatchId);
    if (index < 0) return false;
    const value: PendingDispatchBinding = this.values[index];
    return value.taskId === taskId && value.stepId === stepId &&
      (value.invocationId.length === 0 || value.invocationId === outcome.invocationId);
  }

  takeTaskDispatchIds(taskId: string): string[] {
    const result: string[] = [];
    for (let index: number = this.values.length - 1; index >= 0; index--) {
      if (this.values[index].taskId === taskId) {
        result.unshift(this.values[index].dispatchId);
        this.values.splice(index, 1);
      }
    }
    return result;
  }

  private find(dispatchId: string): number {
    for (let i: number = 0; i < this.values.length; i++) {
      if (this.values[i].dispatchId === dispatchId) return i;
    }
    return -1;
  }
}

class PendingAdapterCompletion {
  taskId: string = '';
  stepId: string = '';
  dispatchId: string = '';
  outcome: ToolOutcome = new ToolOutcome();
}

class PendingAdapterDispatch {
  request: StepDispatchRequest = new StepDispatchRequest();
}

class PendingDispatchQueue {
  private readonly values: PendingAdapterDispatch[] = [];

  enqueue(request: StepDispatchRequest): void {
    const value: PendingAdapterDispatch = new PendingAdapterDispatch();
    value.request = copyDispatchRequest(request);
    this.values.push(value);
  }

  take(): PendingAdapterDispatch | undefined {
    if (this.values.length === 0) return undefined;
    return this.values.shift();
  }

  hasValues(): boolean {
    return this.values.length > 0;
  }

  cancel(dispatchId: string): boolean {
    for (let index: number = 0; index < this.values.length; index++) {
      if (this.values[index].request.dispatchId === dispatchId) {
        this.values.splice(index, 1);
        return true;
      }
    }
    return false;
  }
}

class PendingCheckpointWrite {
  checkpoint: RuntimeTaskRecoveryCheckpoint = new RuntimeTaskRecoveryCheckpoint();
  authority: RuntimeDurableAuthorityPayload = new RuntimeDurableAuthorityPayload();
  event: AgentRuntimeEvent = new AgentRuntimeEvent();
}

function copySnapshot(value: AgentTaskSnapshot): AgentTaskSnapshot {
  return ContractCodec.parseAgentTaskSnapshot(ContractCodec.stringify(value));
}

function copyEvent(value: AgentRuntimeEvent): AgentRuntimeEvent {
  return ContractCodec.parseAgentRuntimeEvent(ContractCodec.stringify(value));
}

function copyPolicy(value: PolicyRequest): PolicyRequest {
  return ContractCodec.parsePolicyRequest(ContractCodec.stringify(value));
}

function copyClarification(value: ClarificationRequest): ClarificationRequest {
  return ContractCodec.parseClarificationRequest(ContractCodec.stringify(value));
}

function copyHandle(value: TaskHandle): TaskHandle {
  return ContractCodec.parseTaskHandle(ContractCodec.stringify(value));
}

function copyReceipt(value: CommandReceipt): CommandReceipt {
  return ContractCodec.parseCommandReceipt(ContractCodec.stringify(value));
}

function copyCheckpoint(value: RuntimeTaskRecoveryCheckpoint): RuntimeTaskRecoveryCheckpoint {
  return JSON.parse(ContractCodec.stringify(value)) as RuntimeTaskRecoveryCheckpoint;
}

function copyAuthority(value: RuntimeDurableAuthorityPayload): RuntimeDurableAuthorityPayload {
  return JSON.parse(ContractCodec.stringify(value)) as RuntimeDurableAuthorityPayload;
}

class BoundSubscription implements AgentSubscription {
  private registration: ProductionObserverRegistration;

  constructor(registration: ProductionObserverRegistration) {
    this.registration = registration;
  }

  close(): void {
    this.registration.closed = true;
  }

  isClosed(): boolean {
    return this.registration.closed;
  }
}

class DeferredStepDispatchPort implements StepDispatchPort {
  private delegate?: StepDispatchPort;

  bind(delegate: StepDispatchPort): void {
    if (this.delegate !== undefined) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT,
        'production adapter already bound');
    }
    this.delegate = delegate;
  }

  dispatch(request: StepDispatchRequest): StepDispatchReceipt {
    if (this.delegate === undefined) {
      const missing: StepDispatchReceipt = new StepDispatchReceipt();
      missing.rejectionCode = 'PRODUCTION_ADAPTER_NOT_BOUND';
      return missing;
    }
    return this.delegate.dispatch(request);
  }

  cancel(dispatchId: string): boolean {
    return this.delegate !== undefined && this.delegate.cancel(dispatchId);
  }
}

class QueuedStepDispatchPort implements StepDispatchPort {
  private readonly queue: PendingDispatchQueue;

  constructor(queue: PendingDispatchQueue) {
    this.queue = queue;
  }

  dispatch(request: StepDispatchRequest): StepDispatchReceipt {
    this.queue.enqueue(request);
    const receipt: StepDispatchReceipt = new StepDispatchReceipt();
    receipt.accepted = true;
    return receipt;
  }

  cancel(dispatchId: string): boolean {
    return this.queue.cancel(dispatchId);
  }
}

class ProductionOutcomeSink implements RuntimeToolOutcomeSinkPort {
  private runtime?: ProductionAgentRuntime;
  private readonly pending: PendingDispatchRegistry;

  constructor(pending: PendingDispatchRegistry) {
    this.pending = pending;
  }

  bind(runtime: ProductionAgentRuntime): void {
    this.runtime = runtime;
  }

  async complete(taskId: string, stepId: string, dispatchId: string, outcome: ToolOutcome): Promise<void> {
    if (this.runtime !== undefined && this.pending.matches(taskId, stepId, dispatchId, outcome)) {
      if (this.pending.isActive(dispatchId)) {
        await this.runtime.completeToolOutcome(taskId, stepId, dispatchId, outcome);
      } else {
        this.pending.queue(dispatchId, outcome);
      }
    }
  }

  async flushQueued(): Promise<void> {
    if (this.runtime === undefined) return;
    let completion: PendingAdapterCompletion | undefined = this.pending.takeQueued();
    while (completion !== undefined) {
      await this.runtime.completeToolOutcome(completion.taskId, completion.stepId,
        completion.dispatchId, completion.outcome, false);
      completion = this.pending.takeQueued();
    }
  }
}

class ProductionAgentRuntime implements AgentRuntimeFacade, RuntimeStateObserverPort {
  private readonly config: ProductionAgentRuntimeConfig;
  private readonly ports: ProductionAgentRuntimePorts;
  private readonly clock: RuntimeClockPort;
  private readonly persistence: ProductionRuntimePersistencePort;
  private readonly coordinator: RuntimeCoordinator;
  private readonly outcomeSink: ProductionOutcomeSink;
  private readonly adapter: StepDispatchPort;
  private readonly registrations: ProductionObserverRegistration[] = [];
  private readonly persistedVersions: PersistedTaskVersion[] = [];
  private readonly commands: ProductionCommandRecord[] = [];
  private readonly pendingDispatches: PendingDispatchRegistry = new PendingDispatchRegistry();
  private readonly pendingAdapterDispatches: PendingDispatchQueue = new PendingDispatchQueue();
  private readonly pendingCheckpoints: PendingCheckpointWrite[] = [];
  private shutdownRequested: boolean = false;
  private persistenceFaulted: boolean = false;
  private flushing: boolean = false;
  private pendingCommandIds: string[] = [];
  private commandTail: Promise<void> = Promise.resolve();

  constructor(config: ProductionAgentRuntimeConfig, ports: ProductionAgentRuntimePorts) {
    validateComposition(config, ports);
    this.config = config;
    this.ports = ports;
    this.clock = ports.clock as RuntimeClockPort;
    this.persistence = ports.persistence as ProductionRuntimePersistencePort;
    const ids: RuntimeIdGeneratorPort = ports.ids as RuntimeIdGeneratorPort;
    const planner: SemanticPlannerPort = ports.planner as SemanticPlannerPort;
    const collaboration: CollaborationSelectorPort = ports.collaboration as CollaborationSelectorPort;
    const collaborationPlan: CollaborationPlanSelectorPort | undefined = ports.collaborationPlan;
    const toolPreparer: ToolInvocationPreparerPort = ports.toolPreparer as ToolInvocationPreparerPort;
    const adapterFactory: ProductionRuntimeAdapterFactoryPort =
      ports.adapterFactory as ProductionRuntimeAdapterFactoryPort;

    const deferred: DeferredStepDispatchPort = new DeferredStepDispatchPort();
    const coordinatorConfig: RuntimeCoordinatorConfig = new RuntimeCoordinatorConfig();
    coordinatorConfig.policyVersion = config.policyVersion;
    coordinatorConfig.grantTtlMs = config.grantTtlMs;
    this.coordinator = new RuntimeCoordinator(
      coordinatorConfig,
      this.clock,
      ids,
      planner,
      collaboration,
      toolPreparer,
      deferred,
      this,
      collaborationPlan,
      ports.collaborationPreparation,
      config.collaborationPreparationTimeoutMs,
      async (): Promise<void> => { await this.flushLifecycle(); }
    );
    this.outcomeSink = new ProductionOutcomeSink(this.pendingDispatches);
    this.outcomeSink.bind(this);
    this.adapter = adapterFactory.create(this.outcomeSink);
    deferred.bind(new QueuedStepDispatchPort(this.pendingAdapterDispatches));
  }

  async recoverPersistedTasks(): Promise<void> {
    const recovery: ProductionRuntimeRecoverySourcePort | undefined = this.ports.recovery;
    if (recovery === undefined) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT,
        'production recovery source is required');
    }
    let taskIds: string[];
    try {
      taskIds = await recovery.listRecoveryTaskIds();
    } catch (error) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'recovery task enumeration failed');
    }
    const seen: string[] = [];
    for (let i: number = 0; i < taskIds.length; i++) {
      const taskId: string = taskIds[i];
      if (taskId.trim().length === 0 || seen.indexOf(taskId) >= 0) {
        throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
          'recovery task enumeration is invalid');
      }
      seen.push(taskId);
    }
    seen.sort();
    for (let i: number = 0; i < seen.length; i++) await this.recoverTask(seen[i], recovery);
  }

  private async recoverTask(taskId: string, recovery: ProductionRuntimeRecoverySourcePort): Promise<void> {
    let checkpoint: RuntimeTaskRecoveryCheckpoint | undefined;
    try {
      checkpoint = await this.persistence.loadCheckpoint(taskId);
    } catch (error) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'recovery checkpoint read failed');
    }
    if (checkpoint === undefined) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'enumerated recovery checkpoint is missing');
    }
    const validation: RuntimeCheckpointValidationResult = RuntimeCheckpointValidator.validate(checkpoint);
    if (!validation.valid || checkpoint.envelope.taskId !== taskId || checkpoint.snapshot.taskId !== taskId) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'enumerated recovery checkpoint is invalid');
    }
    const activeRecovery: boolean = checkpoint.activeInvocation !== undefined ||
      checkpoint.pendingDispatchId.length > 0;
    let authority: RuntimeRecoveryAuthority | undefined;
    if (activeRecovery) authority = await this.readRecoveryAuthority(taskId, recovery);
    this.markPersisted(taskId, checkpoint.snapshot.snapshotVersion);
    const restored: CoordinatorCommandResult = this.coordinator.restoreCheckpoint(checkpoint, authority);
    if (!restored.accepted) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'coordinator recovery rejected: ' + restored.code);
    }
    if (restored.code === 'RESTORED_TERMINAL') return;
    if (activeRecovery && (authority === undefined || authority.operation === undefined ||
      authority.operation.outcome === undefined)) {
      await this.persistRecoveryNormalization(taskId, checkpoint.snapshot.snapshotVersion);
    }
    if (authority === undefined) authority = await this.readRecoveryAuthority(taskId, recovery);
    const hydrated: CoordinatorCommandResult = this.coordinator.hydrateRecoveryAuthority(taskId, authority);
    if (!hydrated.accepted) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'recovery authority rejected: ' + hydrated.code);
    }
    await this.flushLifecycle();
  }

  private async readRecoveryAuthority(taskId: string,
    recovery: ProductionRuntimeRecoverySourcePort): Promise<RuntimeRecoveryAuthority> {
    let authority: RuntimeRecoveryAuthority | undefined;
    try {
      authority = await recovery.loadRecoveryAuthority(taskId);
    } catch (error) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'recovery authority read failed');
    }
    if (authority === undefined) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'recovery authority is missing');
    }
    return authority;
  }

  private async persistRecoveryNormalization(taskId: string, expectedPreviousVersion: number): Promise<void> {
    const write: PendingCheckpointWrite | undefined = this.pendingCheckpoints.shift();
    if (write === undefined || write.checkpoint.snapshot.taskId !== taskId ||
      write.checkpoint.snapshot.snapshotVersion !== expectedPreviousVersion + 1 ||
      write.checkpoint.activeInvocation !== undefined || write.checkpoint.pendingDispatchId.length > 0) {
      this.persistenceFaulted = true;
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'active recovery normalization checkpoint is invalid');
    }
    let saved: RuntimePersistenceResult;
    try {
      saved = await this.persistence.normalizeRecoveredOperation(
        copyCheckpoint(write.checkpoint), expectedPreviousVersion, this.clock.nowMs());
    } catch (error) {
      this.persistenceFaulted = true;
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'active recovery normalization failed');
    }
    if (!saved.accepted) {
      this.persistenceFaulted = true;
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'active recovery normalization rejected: ' + saved.code);
    }
    this.markPersisted(taskId, write.checkpoint.snapshot.snapshotVersion);
  }

  async submitTask(submission: TaskSubmission): Promise<TaskHandle> {
    return await this.serialize(async (): Promise<TaskHandle> => {
      return await this.submitTaskNow(submission);
    });
  }

  private async submitTaskNow(submission: TaskSubmission): Promise<TaskHandle> {
    this.requireActive();
    const accepted: OrchestrationAcceptance = await this.coordinator.acceptTask(submission);
    if (!accepted.duplicate) this.drive(accepted.handle.taskId);
    await this.flushLifecycle();
    const snapshot: AgentTaskSnapshot = this.coordinator.getSnapshot(accepted.handle.taskId);
    const handle: TaskHandle = copyHandle(accepted.handle);
    handle.snapshotVersion = snapshot.snapshotVersion;
    return handle;
  }

  async getTaskSnapshot(taskId: string): Promise<AgentTaskSnapshot> {
    return await this.serialize(async (): Promise<AgentTaskSnapshot> => {
      return await this.getTaskSnapshotNow(taskId);
    });
  }

  private async getTaskSnapshotNow(taskId: string): Promise<AgentTaskSnapshot> {
    this.requireActive();
    try {
      return this.coordinator.getSnapshot(taskId);
    } catch (error) {
      let stored: RuntimeTaskRecoveryCheckpoint | undefined;
      try {
        stored = await this.persistence.loadCheckpoint(taskId);
      } catch (persistenceError) {
        this.persistenceFaulted = true;
        throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
          'task snapshot persistence read failed');
      }
      if (stored !== undefined) {
        const validation: RuntimeCheckpointValidationResult =
          RuntimeCheckpointValidator.validate(stored);
        if (!validation.valid || stored.envelope.taskId !== taskId ||
          stored.snapshot.taskId !== taskId) {
          this.persistenceFaulted = true;
          throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
            'stored runtime checkpoint is invalid');
        }
        return copySnapshot(stored.snapshot);
      }
      throw new AgentRuntimeError(AgentRuntimeErrorCode.TASK_NOT_FOUND, 'task not found: ' + taskId);
    }
  }

  async cancelTask(command: TaskControlCommand): Promise<CommandReceipt> {
    command = ContractCodec.parseTaskControlCommand(ContractCodec.stringify(command));
    if (ContractValidator.validateTaskControlCommand(command).valid && command.action === TaskControlAction.CANCEL &&
      !this.shutdownRequested && !this.persistenceFaulted && this.pendingCommandIds.indexOf(command.commandId) < 0 &&
      !this.commands.some((record: ProductionCommandRecord) => record.commandId === command.commandId)) {
      this.coordinator.interruptPlanning(command.taskId);
    }
    return await this.serializeCommand(command.commandId, async (): Promise<CommandReceipt> => {
      return await this.applyControl(command, TaskControlAction.CANCEL);
    });
  }

  async pauseTask(command: TaskControlCommand): Promise<CommandReceipt> {
    return await this.serializeCommand(command.commandId, async (): Promise<CommandReceipt> => {
      return await this.applyControl(command, TaskControlAction.PAUSE);
    });
  }

  async resumeTask(command: TaskControlCommand): Promise<CommandReceipt> {
    return await this.serializeCommand(command.commandId, async (): Promise<CommandReceipt> => {
      return await this.resumeTaskNow(command);
    });
  }

  private async resumeTaskNow(command: TaskControlCommand): Promise<CommandReceipt> {
    const receipt: CommandReceipt = await this.applyControl(command, TaskControlAction.RESUME);
    if (receipt.accepted && !receipt.duplicate) this.drive(command.taskId);
    await this.flushLifecycle();
    return receipt;
  }

  async provideAuthorization(decision: AuthorizationDecision): Promise<CommandReceipt> {
    return await this.serializeCommand(decision.commandId, async (): Promise<CommandReceipt> => {
      return await this.provideAuthorizationNow(decision);
    });
  }

  private async provideAuthorizationNow(decision: AuthorizationDecision): Promise<CommandReceipt> {
    this.requireActive();
    if (!ContractValidator.validateAuthorizationDecision(decision).valid) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'invalid AuthorizationDecision');
    }
    const fingerprint: string = 'authorization:' + ContractCodec.stringify(decision);
    const replay: CommandReceipt | undefined = await this.replay(
      decision.commandId, decision.taskId, fingerprint);
    if (replay !== undefined) return replay;
    if (!this.activeTaskExists(decision.taskId)) {
      return this.remember(fingerprint,
        await this.rejected(decision.commandId, decision.taskId, 'TASK_NOT_ACTIVE'));
    }
    const result: CoordinatorCommandResult = this.coordinator.provideAuthorization(decision);
    await this.flushLifecycle();
    return this.remember(fingerprint, this.receipt(decision.commandId, decision.taskId, result));
  }

  async provideClarification(response: ClarificationResponse): Promise<CommandReceipt> {
    return await this.serializeCommand(response.commandId, async (): Promise<CommandReceipt> => {
      return await this.provideClarificationNow(response);
    });
  }

  private async provideClarificationNow(response: ClarificationResponse): Promise<CommandReceipt> {
    this.requireActive();
    if (!ContractValidator.validateClarificationResponse(response).valid) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'invalid ClarificationResponse');
    }
    const fingerprint: string = 'clarification:' + ContractCodec.stringify(response);
    const replay: CommandReceipt | undefined = await this.replay(
      response.commandId, response.taskId, fingerprint);
    if (replay !== undefined) return replay;
    if (!this.activeTaskExists(response.taskId)) {
      return this.remember(fingerprint,
        await this.rejected(response.commandId, response.taskId, 'TASK_NOT_ACTIVE'));
    }
    const result: CoordinatorCommandResult = await this.coordinator.provideClarification(response);
    const receipt: CommandReceipt = this.remember(fingerprint,
      this.receipt(response.commandId, response.taskId, result));
    if (receipt.accepted) this.drive(response.taskId);
    await this.flushLifecycle();
    return receipt;
  }

  async provideReconciliation(report: ReconciliationReport): Promise<CommandReceipt> {
    return await this.serializeCommand(report.commandId, async (): Promise<CommandReceipt> => {
      return await this.provideReconciliationNow(report);
    });
  }

  private async provideReconciliationNow(report: ReconciliationReport): Promise<CommandReceipt> {
    this.requireActive();
    if (!ContractValidator.validateReconciliationReport(report).valid) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'invalid ReconciliationReport');
    }
    const fingerprint: string = 'reconciliation:' + ContractCodec.stringify(report);
    const replay: CommandReceipt | undefined = await this.replay(
      report.commandId, report.taskId, fingerprint);
    if (replay !== undefined) return replay;
    if (!this.activeTaskExists(report.taskId)) {
      return this.remember(fingerprint,
        await this.rejected(report.commandId, report.taskId, 'TASK_NOT_ACTIVE'));
    }
    let persisted: RuntimePersistenceResult;
    try {
      persisted = await this.persistence.recordReconciliation(report, this.clock.nowMs());
    } catch (error) {
      this.persistenceFaulted = true;
      return this.remember(fingerprint,
        await this.rejected(report.commandId, report.taskId, 'PERSISTENCE_RECONCILIATION_EXCEPTION'));
    }
    if (!persisted.accepted) {
      return this.remember(fingerprint,
        await this.rejected(report.commandId, report.taskId,
          'PERSISTENCE_RECONCILIATION_' + persisted.code));
    }
    const result: CoordinatorCommandResult = this.coordinator.provideReconciliation(report);
    const receipt: CommandReceipt = this.remember(fingerprint,
      this.receipt(report.commandId, report.taskId, result));
    if (receipt.accepted) this.drive(report.taskId);
    await this.flushLifecycle();
    return receipt;
  }

  async subscribe(request: SubscriptionRequest, observer: AgentRuntimeObserver): Promise<AgentSubscription> {
    return await this.serialize(async (): Promise<AgentSubscription> => {
      return await this.subscribeNow(request, observer);
    });
  }

  private async subscribeNow(request: SubscriptionRequest,
    observer: AgentRuntimeObserver): Promise<AgentSubscription> {
    this.requireActive();
    if (request.subscriptionId.length === 0 || request.taskId.length === 0 ||
      !Number.isSafeInteger(request.afterSequence) || request.afterSequence < 0 ||
      this.findRegistration(request.subscriptionId) >= 0) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.SUBSCRIPTION_CONFLICT, 'invalid subscription');
    }
    const snapshot: AgentTaskSnapshot = await this.getTaskSnapshotNow(request.taskId);
    if (request.afterSequence > snapshot.lastEventSequence) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.SUBSCRIPTION_CONFLICT,
        'afterSequence is ahead of the task');
    }
    const registration: ProductionObserverRegistration = new ProductionObserverRegistration();
    registration.request.subscriptionId = request.subscriptionId;
    registration.request.taskId = request.taskId;
    registration.request.afterSequence = request.afterSequence;
    registration.observer = observer;
    registration.lastEventSequence = request.afterSequence;
    this.registrations.push(registration);
    if (this.activeTaskExists(request.taskId)) {
      const events: AgentRuntimeEvent[] = this.coordinator.getEvents(request.taskId);
      for (let i: number = 0; i < events.length; i++) this.deliverEvent(registration, events[i]);
      this.deliverPending(registration);
    } else if (request.afterSequence < snapshot.lastEventSequence) {
      registration.closed = true;
      throw new AgentRuntimeError(AgentRuntimeErrorCode.SUBSCRIPTION_CONFLICT,
        'persisted event replay is unavailable for an inactive task');
    }
    return new BoundSubscription(registration);
  }

  async shutdown(mode: ShutdownMode): Promise<void> {
    if (mode !== ShutdownMode.GRACEFUL && mode !== ShutdownMode.IMMEDIATE) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'invalid ShutdownMode');
    }
    const interrupted: string[] = this.coordinator.interruptAllPlanning();
    await this.serialize(async (): Promise<void> => {
      for (let i: number = 0; i < interrupted.length; i++) this.coordinator.cancel(interrupted[i]);
      await this.flushLifecycle();
      await this.shutdownNow(mode);
    });
  }

  private async shutdownNow(mode: ShutdownMode): Promise<void> {
    if (this.shutdownRequested) return;
    this.shutdownRequested = true;
    for (let i: number = 0; i < this.registrations.length; i++) {
      this.registrations[i].closed = true;
    }
  }

  onStateChanged(snapshot: AgentTaskSnapshot, event: AgentRuntimeEvent): void {
    const expected: number = this.latestKnownVersion(snapshot.taskId);
    if (snapshot.snapshotVersion !== expected + 1) {
      this.persistenceFaulted = true;
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'non-sequential task snapshot version');
    }
    const checkpoint: RuntimeTaskRecoveryCheckpoint =
      this.coordinator.getRecoveryCheckpoint(snapshot.taskId);
    const validation: RuntimeCheckpointValidationResult =
      RuntimeCheckpointValidator.validate(checkpoint);
    if (!validation.valid) {
      this.persistenceFaulted = true;
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'generated runtime checkpoint is invalid');
    }
    const write: PendingCheckpointWrite = new PendingCheckpointWrite();
    write.checkpoint = copyCheckpoint(checkpoint);
    write.authority = copyAuthority(this.coordinator.getDurableAuthorityPayload(snapshot.taskId));
    if (write.authority.taskId !== checkpoint.snapshot.taskId ||
      write.authority.checkpointSnapshotVersion !== checkpoint.snapshot.snapshotVersion) {
      this.persistenceFaulted = true;
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'generated durable authority binding is invalid');
    }
    write.event = copyEvent(event);
    this.pendingCheckpoints.push(write);
  }

  async completeToolOutcome(taskId: string, stepId: string, dispatchId: string, outcome: ToolOutcome,
    flushAfter: boolean = true): Promise<void> {
    if (!flushAfter) {
      await this.completeToolOutcomeNow(taskId, stepId, dispatchId, outcome, false);
      return;
    }
    await this.serialize(async (): Promise<void> => {
      await this.completeToolOutcomeNow(taskId, stepId, dispatchId, outcome, true);
    });
  }

  private async completeToolOutcomeNow(taskId: string, stepId: string, dispatchId: string,
    outcome: ToolOutcome, flushAfter: boolean): Promise<void> {
    if (this.shutdownRequested || this.persistenceFaulted ||
      !ContractValidator.validateToolOutcome(outcome).valid || !this.activeTaskExists(taskId)) return;
    let recorded: RuntimePersistenceResult;
    try {
      recorded = await this.persistence.recordOutcome(taskId, stepId, dispatchId, outcome,
        this.clock.nowMs());
    } catch (error) {
      this.persistenceFaulted = true;
      return;
    }
    if (!recorded.accepted) {
      this.persistenceFaulted = true;
      return;
    }
    this.pendingDispatches.remove(dispatchId);
    const completion: StepCompletion = new StepCompletion();
    completion.taskId = taskId;
    completion.stepId = stepId;
    completion.dispatchId = dispatchId;
    completion.result.status = this.stepStatus(outcome.status);
    completion.result.outputJson = outcome.resultJson === undefined ? '{}' : outcome.resultJson;
    completion.result.outputDigest = outcome.resultDigest === undefined ? '' : outcome.resultDigest;
    completion.result.errorClass = outcome.errorClass === undefined ? AgentErrorClass.PROVIDER : outcome.errorClass;
    completion.result.errorCode = outcome.errorCode === undefined ? '' : outcome.errorCode;
    const applied: CoordinatorCommandResult = this.coordinator.completeStep(completion);
    if (applied.accepted) this.drive(taskId);
    if (flushAfter) await this.flushLifecycle();
  }

  private serialize<T>(operation: () => Promise<T>): Promise<T> {
    const result: Promise<T> = new Promise<T>((resolve: (value: T) => void,
      reject: (reason: Object) => void): void => {
      const run = async (): Promise<void> => {
        try {
          resolve(await operation());
        } catch (error) {
          reject(error as Object);
        }
      };
      this.commandTail = this.commandTail.then(run, run);
    });
    return result;
  }

  private async serializeCommand(commandId: string, operation: () => Promise<CommandReceipt>): Promise<CommandReceipt> {
    this.pendingCommandIds.push(commandId);
    return await this.serialize(async (): Promise<CommandReceipt> => {
      try { return await operation(); }
      finally {
        const index: number = this.pendingCommandIds.indexOf(commandId);
        if (index >= 0) this.pendingCommandIds.splice(index, 1);
      }
    });
  }

  private async applyControl(command: TaskControlCommand,
    expected: TaskControlAction): Promise<CommandReceipt> {
    this.requireActive();
    if (!ContractValidator.validateTaskControlCommand(command).valid || command.action !== expected) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'invalid TaskControlCommand');
    }
    const fingerprint: string = 'control:' + ContractCodec.stringify(command);
    const replay: CommandReceipt | undefined = await this.replay(
      command.commandId, command.taskId, fingerprint);
    if (replay !== undefined) return replay;
    if (!this.activeTaskExists(command.taskId)) {
      return this.remember(fingerprint,
        await this.rejected(command.commandId, command.taskId, 'TASK_NOT_ACTIVE'));
    }
    let result: CoordinatorCommandResult;
    if (expected === TaskControlAction.CANCEL) result = this.coordinator.cancel(command.taskId);
    else if (expected === TaskControlAction.PAUSE) result = this.coordinator.pause(command.taskId);
    else result = this.coordinator.resume(command.taskId);
    if (expected === TaskControlAction.CANCEL && result.accepted && result.code === 'CANCELLED') {
      const dispatchIds: string[] = this.pendingDispatches.takeTaskDispatchIds(command.taskId);
      for (let index: number = 0; index < dispatchIds.length; index++) {
        this.adapter.cancel(dispatchIds[index]);
      }
    }
    const receipt: CommandReceipt = this.remember(
      fingerprint, this.receipt(command.commandId, command.taskId, result));
    await this.flushLifecycle();
    return receipt;
  }

  private drive(taskId: string): void {
    for (let i: number = 0; i < this.config.autoAdvanceLimit; i++) {
      const snapshot: AgentTaskSnapshot = this.coordinator.getSnapshot(taskId);
      if (snapshot.status !== AgentTaskStatus.RUNNING) return;
      const advanced: CoordinatorCommandResult = this.coordinator.advance(taskId);
      if (!advanced.accepted || advanced.code === 'DISPATCHED' || advanced.code === 'AUTHORIZATION_REQUIRED') return;
    }
  }

  private async flushLifecycle(): Promise<void> {
    if (this.flushing) return;
    this.flushing = true;
    try {
      while (this.pendingCheckpoints.length > 0 || this.pendingAdapterDispatches.hasValues()) {
        const pendingDispatch: PendingAdapterDispatch | undefined = this.pendingAdapterDispatches.take();
        if (pendingDispatch === undefined) {
          const write: PendingCheckpointWrite | undefined = this.pendingCheckpoints.shift();
          if (write !== undefined) await this.persistCheckpoint(write);
          continue;
        }
        const atomicIndex: number = this.findDispatchCheckpoint(
          pendingDispatch.request.task.taskId, pendingDispatch.request.dispatchId);
        if (atomicIndex < 0) {
          this.persistenceFaulted = true;
          throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
            'dispatch checkpoint is unavailable');
        }
        for (let i: number = 0; i < atomicIndex; i++) {
          const earlier: PendingCheckpointWrite | undefined = this.pendingCheckpoints.shift();
          if (earlier !== undefined) await this.persistCheckpoint(earlier);
        }
        const atomic: PendingCheckpointWrite | undefined = this.pendingCheckpoints.shift();
        if (atomic === undefined) {
          this.persistenceFaulted = true;
          throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
            'dispatch checkpoint disappeared');
        }
        await this.persistCheckpoint(atomic, pendingDispatch.request.persistenceContext, true);
        await this.invokeAdapter(pendingDispatch.request);
        await this.outcomeSink.flushQueued();
      }
    } finally {
      this.flushing = false;
    }
  }

  private async persistCheckpoint(write: PendingCheckpointWrite,
    dispatchContext?: DispatchPersistenceContext, dispatchGate: boolean = false): Promise<void> {
    const checkpoint: RuntimeTaskRecoveryCheckpoint = write.checkpoint;
    const expected: number = this.persistedVersion(checkpoint.snapshot.taskId);
    if (checkpoint.snapshot.snapshotVersion !== expected + 1) {
      this.persistenceFaulted = true;
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'non-sequential durable checkpoint version');
    }
    let saved: RuntimePersistenceResult;
    try {
      if (dispatchGate) {
        saved = await this.persistence.beforeDispatch(checkpoint, expected,
          copyPersistenceContext(dispatchContext), copyAuthority(write.authority), this.clock.nowMs());
      } else {
        saved = await this.persistence.saveCheckpoint(checkpoint, expected,
          copyAuthority(write.authority), this.clock.nowMs());
      }
    } catch (error) {
      this.persistenceFaulted = true;
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        !dispatchGate ? 'task checkpoint persistence failed' :
          'dispatch checkpoint persistence failed');
    }
    if (!saved.accepted) {
      this.persistenceFaulted = true;
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        (!dispatchGate ? 'task checkpoint persistence rejected: ' :
          'dispatch checkpoint persistence rejected: ') + saved.code);
    }
    this.markPersisted(checkpoint.snapshot.taskId, checkpoint.snapshot.snapshotVersion);
    for (let i: number = 0; i < this.registrations.length; i++) {
      if (!this.registrations[i].closed &&
        this.registrations[i].request.taskId === checkpoint.snapshot.taskId) {
        this.deliverEvent(this.registrations[i], write.event);
        this.deliverPending(this.registrations[i]);
      }
    }
  }

  private async invokeAdapter(request: StepDispatchRequest): Promise<void> {
    this.pendingDispatches.register(request);
    const receipt: StepDispatchReceipt = this.adapter.dispatch(copyDispatchRequest(request));
    if (receipt.accepted) {
      this.pendingDispatches.activate(request.dispatchId);
      return;
    }
    this.pendingDispatches.remove(request.dispatchId);
    let recorded: RuntimePersistenceResult;
    try {
      recorded = await this.persistence.recordDispatchRejected(
        copyPersistenceContext(request.persistenceContext), request.dispatchId,
        receipt.rejectionCode, this.clock.nowMs());
    } catch (error) {
      this.persistenceFaulted = true;
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'adapter rejection persistence failed');
    }
    if (!recorded.accepted) {
      this.persistenceFaulted = true;
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'adapter rejection persistence rejected: ' + recorded.code);
    }
    const completion: StepCompletion = new StepCompletion();
    completion.taskId = request.task.taskId;
    completion.stepId = request.step.stepId;
    completion.dispatchId = request.dispatchId;
    completion.result.status = StepExecutionStatus.FAILED;
    completion.result.errorClass = AgentErrorClass.PROVIDER;
    completion.result.errorCode = receipt.rejectionCode;
    const applied: CoordinatorCommandResult = this.coordinator.completeStep(completion);
    if (applied.accepted) this.drive(request.task.taskId);
  }

  private findDispatchCheckpoint(taskId: string, dispatchId: string): number {
    let found: number = -1;
    for (let i: number = 0; i < this.pendingCheckpoints.length; i++) {
      const checkpoint: RuntimeTaskRecoveryCheckpoint = this.pendingCheckpoints[i].checkpoint;
      if (checkpoint.snapshot.taskId === taskId && checkpoint.pendingDispatchId === dispatchId) found = i;
    }
    return found;
  }

  private latestKnownVersion(taskId: string): number {
    for (let i: number = this.pendingCheckpoints.length - 1; i >= 0; i--) {
      if (this.pendingCheckpoints[i].checkpoint.snapshot.taskId === taskId) {
        return this.pendingCheckpoints[i].checkpoint.snapshot.snapshotVersion;
      }
    }
    return this.persistedVersion(taskId);
  }

  private persistedVersion(taskId: string): number {
    const index: number = this.findPersistedVersion(taskId);
    return index < 0 ? 0 : this.persistedVersions[index].version;
  }

  private markPersisted(taskId: string, snapshotVersion: number): void {
    const index: number = this.findPersistedVersion(taskId);
    if (index < 0) {
      const version: PersistedTaskVersion = new PersistedTaskVersion();
      version.taskId = taskId;
      version.version = snapshotVersion;
      this.persistedVersions.push(version);
    } else {
      this.persistedVersions[index].version = snapshotVersion;
    }
  }

  private deliverEvent(registration: ProductionObserverRegistration, event: AgentRuntimeEvent): void {
    if (registration.closed || event.sequence <= registration.lastEventSequence ||
      registration.observer === undefined) return;
    try {
      registration.observer.onEvent(copyEvent(event));
      registration.lastEventSequence = event.sequence;
    } catch (error) {
      registration.closed = true;
    }
  }

  private deliverPending(registration: ProductionObserverRegistration): void {
    if (registration.closed || registration.observer === undefined) return;
    const policy: PolicyRequest | undefined = this.coordinator.getPendingPolicyRequest(registration.request.taskId);
    if (policy !== undefined && policy.requestId !== registration.lastPolicyRequestId) {
      try {
        registration.observer.onPolicyRequest(copyPolicy(policy));
        registration.lastPolicyRequestId = policy.requestId;
      } catch (error) {
        registration.closed = true;
        return;
      }
    }
    const clarification: ClarificationRequest | undefined =
      this.coordinator.getPendingClarification(registration.request.taskId);
    if (clarification !== undefined && clarification.clarificationId !== registration.lastClarificationId) {
      try {
        registration.observer.onClarificationRequest(copyClarification(clarification));
        registration.lastClarificationId = clarification.clarificationId;
      } catch (error) {
        registration.closed = true;
      }
    }
  }

  private receipt(commandId: string, taskId: string, result: CoordinatorCommandResult): CommandReceipt {
    const value: CommandReceipt = new CommandReceipt();
    value.commandId = commandId;
    value.taskId = taskId;
    value.accepted = result.accepted;
    value.snapshotVersion = result.snapshotVersion;
    if (!result.accepted) value.rejectionCode = result.code;
    return value;
  }

  private async rejected(commandId: string, taskId: string, code: string): Promise<CommandReceipt> {
    const value: CommandReceipt = new CommandReceipt();
    value.commandId = commandId;
    value.taskId = taskId;
    value.rejectionCode = code;
    let stored: RuntimeTaskRecoveryCheckpoint | undefined;
    try {
      stored = await this.persistence.loadCheckpoint(taskId);
    } catch (error) {
      this.persistenceFaulted = true;
      value.rejectionCode = 'PERSISTENCE_READ_EXCEPTION';
      return value;
    }
    if (stored !== undefined) {
      const validation: RuntimeCheckpointValidationResult =
        RuntimeCheckpointValidator.validate(stored);
      if (!validation.valid || stored.envelope.taskId !== taskId ||
        stored.snapshot.taskId !== taskId) {
        this.persistenceFaulted = true;
        value.rejectionCode = 'PERSISTENCE_CHECKPOINT_INVALID';
        value.snapshotVersion = 0;
        return value;
      }
      value.snapshotVersion = stored.snapshot.snapshotVersion;
    }
    return value;
  }

  private remember(fingerprint: string, receipt: CommandReceipt): CommandReceipt {
    const record: ProductionCommandRecord = new ProductionCommandRecord();
    record.commandId = receipt.commandId;
    record.taskId = receipt.taskId;
    record.fingerprint = fingerprint;
    record.receipt = copyReceipt(receipt);
    this.commands.push(record);
    return copyReceipt(receipt);
  }

  private async replay(commandId: string, taskId: string,
    fingerprint: string): Promise<CommandReceipt | undefined> {
    for (let i: number = 0; i < this.commands.length; i++) {
      if (this.commands[i].commandId === commandId) {
        if (this.commands[i].taskId !== taskId || this.commands[i].fingerprint !== fingerprint) {
          return await this.rejected(commandId, taskId, 'COMMAND_ID_CONFLICT');
        }
        const receipt: CommandReceipt = copyReceipt(this.commands[i].receipt);
        receipt.duplicate = true;
        return receipt;
      }
    }
    return undefined;
  }

  private activeTaskExists(taskId: string): boolean {
    try {
      this.coordinator.getSnapshot(taskId);
      return true;
    } catch (error) {
      return false;
    }
  }

  private findRegistration(subscriptionId: string): number {
    for (let i: number = 0; i < this.registrations.length; i++) {
      if (this.registrations[i].request.subscriptionId === subscriptionId) return i;
    }
    return -1;
  }

  private findPersistedVersion(taskId: string): number {
    for (let i: number = 0; i < this.persistedVersions.length; i++) {
      if (this.persistedVersions[i].taskId === taskId) return i;
    }
    return -1;
  }

  private stepStatus(status: ToolOutcomeStatus): StepExecutionStatus {
    if (status === ToolOutcomeStatus.SUCCEEDED) return StepExecutionStatus.SUCCEEDED;
    if (status === ToolOutcomeStatus.CANCELLED) return StepExecutionStatus.CANCELLED;
    if (status === ToolOutcomeStatus.UNKNOWN_OUTCOME) return StepExecutionStatus.UNKNOWN_OUTCOME;
    return StepExecutionStatus.FAILED;
  }

  private requireActive(): void {
    if (this.shutdownRequested) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.RUNTIME_SHUTDOWN, 'runtime is shut down');
    }
    if (this.persistenceFaulted) {
      throw new AgentRuntimeError(AgentRuntimeErrorCode.PERSISTENCE_FAILURE,
        'runtime persistence is faulted');
    }
  }
}

function validateComposition(config: ProductionAgentRuntimeConfig, ports: ProductionAgentRuntimePorts): void {
  if (ports.collaborationPlan instanceof ArtifactCollaborationPolicy &&
    ports.collaborationPreparation !== ports.collaborationPlan) {
    throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'artifact selector requires preparation');
  }
  if ((ports.collaborationPreparation !== undefined && ports.collaborationPreparation !== ports.collaborationPlan) ||
    !Number.isSafeInteger(config.collaborationPreparationTimeoutMs) || config.collaborationPreparationTimeoutMs <= 0) {
    throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT, 'invalid collaboration preparation binding');
  }
  if (config.compositionVersion !== PRODUCTION_RUNTIME_COMPOSITION_VERSION ||
    config.policyVersion.length === 0 || !Number.isSafeInteger(config.grantTtlMs) || config.grantTtlMs <= 0 ||
    !Number.isSafeInteger(config.autoAdvanceLimit) || config.autoAdvanceLimit <= 0 ||
    ports.clock === undefined || ports.ids === undefined || ports.planner === undefined ||
    ports.collaboration === undefined || ports.toolPreparer === undefined ||
    ports.adapterFactory === undefined || ports.persistence === undefined) {
    throw new AgentRuntimeError(AgentRuntimeErrorCode.INVALID_CONTRACT,
      'invalid production runtime composition');
  }
}

export function createProductionAgentRuntime(config: ProductionAgentRuntimeConfig,
  ports: ProductionAgentRuntimePorts): AgentRuntimeFacade {
  return new ProductionAgentRuntime(config, ports);
}

/** Restores durable tasks before exposing the sole task-control facade. */
export async function createRecoveredProductionAgentRuntime(config: ProductionAgentRuntimeConfig,
  ports: ProductionAgentRuntimePorts): Promise<AgentRuntimeFacade> {
  const runtime: ProductionAgentRuntime = new ProductionAgentRuntime(config, ports);
  await runtime.recoverPersistedTasks();
  return runtime;
}
