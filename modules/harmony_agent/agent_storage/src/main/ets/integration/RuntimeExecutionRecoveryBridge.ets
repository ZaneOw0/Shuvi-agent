import {
  AgentTaskStatus,
  ContractCodec,
  ContractValidator,
  ReconciliationReport,
  ReconciliationStatus,
  ToolOutcome,
  ToolOutcomeStatus,
  ToolInvocation
} from '@harmony_agent/agent-contracts';
import {
  BudgetAmount,
  BudgetReservationSnapshot,
  OperationJournalState
} from '@harmony_agent/agent-core';
import {
  DispatchPersistenceContext,
  ProductionRuntimePersistencePort,
  ProductionRuntimeRecoverySourcePort,
  RuntimeDurableAuthorityPayload,
  RuntimePersistenceCode,
  RuntimePersistenceResult,
  RuntimeRecoveryAuthority,
  RuntimeRecoveryOperationAuthority,
  RuntimeRecoveryPolicyAuthority,
  RuntimeRecoveryAuthorityValidator,
  RuntimeCheckpointValidator,
  RuntimeTaskRecoveryCheckpoint
} from '@harmony_agent/agent-runtime';
import {
  DurableExecutionRecoveryStore,
  ExecutionRecoveryTransaction
} from '../storage/DurableExecutionRecoveryStore';
import { ExecutionRecoveryStore } from '../storage/ExecutionRecoveryStore';
import {
  RecoveryLease,
  StorageWriteCode,
  StorageWriteResult,
  StoredOperation,
  StoredOperationIntent,
  StoredPolicyRecord
} from '../storage/StorageTypes';

/** Resolves provider usage that is deliberately absent from ToolOutcome. */
export interface RuntimeOutcomeAccountingPort {
  actualForOutcome(operation: StoredOperation, outcome: ToolOutcome): BudgetAmount | undefined;
}

/** Concrete settlement required for a confirmed reconciliation report. */
export class RuntimeReconciliationSettlement {
  outcome: ToolOutcome = new ToolOutcome();
  actual: BudgetAmount = new BudgetAmount();
}

/** Resolves evidence into a concrete outcome and usage without giving storage task-control authority. */
export interface RuntimeReconciliationSettlementPort {
  resolve(report: ReconciliationReport,
    operation: StoredOperation): RuntimeReconciliationSettlement | undefined;
}

export class RuntimeExecutionRecoveryBridgeConfig {
  ownerId: string = '';
  leaseTtlMs: number = 0;
  policyVersion: string = '';
  outcomeAccounting?: RuntimeOutcomeAccountingPort;
  reconciliationSettlement?: RuntimeReconciliationSettlementPort;
}

class MutationTracker {
  mutated: boolean = false;

  observe(result: StorageWriteResult): StorageWriteResult | undefined {
    if (!result.accepted) return result;
    if (!result.duplicate) this.mutated = true;
    return undefined;
  }

  complete(): StorageWriteResult {
    const value: StorageWriteResult = new StorageWriteResult();
    value.accepted = true;
    value.duplicate = !this.mutated;
    value.code = this.mutated ? StorageWriteCode.UPDATED : StorageWriteCode.UNCHANGED;
    return value;
  }
}

class DispatchBinding {
  dispatchId: string = '';
  operationId: string = '';
  taskId: string = '';
  stepId: string = '';
  ownerId: string = '';
  fencingToken: number = 0;
}

function rejectedWrite(code: StorageWriteCode = StorageWriteCode.INVALID_INPUT): StorageWriteResult {
  const value: StorageWriteResult = new StorageWriteResult();
  value.code = code;
  return value;
}

function runtimeResult(accepted: boolean, duplicate: boolean,
  code: RuntimePersistenceCode): RuntimePersistenceResult {
  const value: RuntimePersistenceResult = new RuntimePersistenceResult();
  value.accepted = accepted;
  value.duplicate = duplicate;
  value.code = code;
  return value;
}

function mapWrite(result: StorageWriteResult): RuntimePersistenceResult {
  if (result.accepted) {
    return runtimeResult(true, result.duplicate,
      result.duplicate ? RuntimePersistenceCode.UNCHANGED : RuntimePersistenceCode.SAVED);
  }
  if (result.code === StorageWriteCode.NOT_FOUND) {
    return runtimeResult(false, false, RuntimePersistenceCode.NOT_FOUND);
  }
  if (result.code === StorageWriteCode.VERSION_CONFLICT) {
    return runtimeResult(false, false, RuntimePersistenceCode.VERSION_CONFLICT);
  }
  return runtimeResult(false, false, RuntimePersistenceCode.REJECTED);
}

function copyCheckpoint(value: RuntimeTaskRecoveryCheckpoint): RuntimeTaskRecoveryCheckpoint {
  return JSON.parse(ContractCodec.stringify(value)) as RuntimeTaskRecoveryCheckpoint;
}

function copyOutcome(value: ToolOutcome): ToolOutcome {
  return ContractCodec.parseToolOutcome(ContractCodec.stringify(value));
}

function copyBudget(value: BudgetAmount): BudgetAmount {
  return JSON.parse(JSON.stringify(value)) as BudgetAmount;
}

function copyReport(value: ReconciliationReport): ReconciliationReport {
  return ContractCodec.parseReconciliationReport(ContractCodec.stringify(value));
}

function applyPolicy(store: ExecutionRecoveryStore, authority: RuntimeDurableAuthorityPayload,
  nowMs: number, tracker: MutationTracker): StorageWriteResult | undefined {
  const policy = authority.policy;
  if (policy === undefined) return undefined;
  let rejected: StorageWriteResult | undefined = tracker.observe(store.savePolicyRequest(policy.request, nowMs));
  if (rejected !== undefined) return rejected;
  if (policy.version === 1 && policy.decision === undefined && policy.grant === undefined) {
    return store.getPolicyRecord(policy.request.requestId)?.version === 1 ?
      undefined : rejectedWrite(StorageWriteCode.STATE_CONFLICT);
  }
  if (policy.version !== 3 || policy.decision === undefined || policy.grant === undefined) {
    return rejectedWrite();
  }
  rejected = tracker.observe(store.savePolicyDecision(policy.request.requestId, policy.decision, 1, nowMs));
  if (rejected !== undefined) return rejected;
  rejected = tracker.observe(store.saveAuthorizationGrant(policy.request.requestId, policy.grant, 2, nowMs));
  if (rejected !== undefined) return rejected;
  return store.getPolicyRecord(policy.request.requestId)?.version === 3 ?
    undefined : rejectedWrite(StorageWriteCode.STATE_CONFLICT);
}

function findReservation(authority: RuntimeDurableAuthorityPayload,
  reservationId: string): BudgetReservationSnapshot | undefined {
  for (let i: number = 0; i < authority.budgetReservations.length; i++) {
    if (authority.budgetReservations[i].reservationId === reservationId) {
      return authority.budgetReservations[i];
    }
  }
  return undefined;
}

function intentFrom(context: DispatchPersistenceContext): StoredOperationIntent {
  const value: StoredOperationIntent = new StoredOperationIntent();
  value.operationId = context.operationId;
  value.invocationId = context.invocationId;
  value.taskId = context.taskId;
  value.stepId = context.stepId;
  value.attemptId = context.attemptId;
  value.toolId = context.toolId;
  value.toolIdentityVersion = context.toolIdentityVersion;
  value.schemaDigest = context.schemaDigest;
  value.argumentsDigest = context.argumentsDigest;
  value.idempotencyKey = context.idempotencyKey;
  value.idempotencyMode = context.idempotencyMode;
  value.sideEffect = context.sideEffect;
  value.policyRequestId = context.policyRequestId;
  value.budgetReservationId = context.budgetReservationId;
  value.createdAt = context.createdAt;
  return value;
}

function contextMatchesAuthority(context: DispatchPersistenceContext,
  authority: RuntimeDurableAuthorityPayload): boolean {
  const operation = authority.operation;
  if (operation === undefined) return false;
  return context.operationId === operation.operationId && context.invocationId === operation.invocationId &&
    context.taskId === operation.taskId && context.stepId === operation.stepId &&
    context.attemptId === operation.attemptId && context.toolId === operation.toolId &&
    context.toolIdentityVersion === operation.toolIdentityVersion &&
    context.schemaDigest === operation.schemaDigest && context.argumentsDigest === operation.argumentsDigest &&
    context.idempotencyKey === operation.idempotencyKey && context.idempotencyMode === operation.idempotencyMode &&
    context.sideEffect === operation.sideEffect && context.policyRequestId === operation.policyRequestId &&
    context.budgetReservationId === operation.budgetReservationId;
}

function sameStoredOperation(operation: StoredOperation, context: DispatchPersistenceContext): boolean {
  const intent: StoredOperationIntent = operation.intent;
  return intent.operationId === context.operationId && intent.invocationId === context.invocationId &&
    intent.taskId === context.taskId && intent.stepId === context.stepId &&
    intent.attemptId === context.attemptId && intent.toolId === context.toolId &&
    intent.toolIdentityVersion === context.toolIdentityVersion && intent.schemaDigest === context.schemaDigest &&
    intent.argumentsDigest === context.argumentsDigest && intent.idempotencyKey === context.idempotencyKey &&
    intent.policyRequestId === context.policyRequestId &&
    intent.budgetReservationId === context.budgetReservationId;
}

function operationMatchesInvocation(operation: StoredOperation, invocation: ToolInvocation): boolean {
  const intent: StoredOperationIntent = operation.intent;
  const expectedKey: string = invocation.idempotencyKey === undefined ?
    'attempt:' + invocation.attemptId : invocation.idempotencyKey as string;
  return intent.operationId === invocation.operationId && intent.invocationId === invocation.invocationId &&
    intent.taskId === invocation.taskId && intent.stepId === invocation.stepId &&
    intent.attemptId === invocation.attemptId && intent.toolId === invocation.toolId &&
    intent.toolIdentityVersion === invocation.toolIdentityVersion &&
    intent.schemaDigest === invocation.schemaDigest && intent.argumentsDigest === invocation.argumentsDigest &&
    intent.idempotencyKey === expectedKey;
}

function validRecoveryNormalization(source: RuntimeTaskRecoveryCheckpoint,
  normalized: RuntimeTaskRecoveryCheckpoint, operation: StoredOperation): boolean {
  const active: ToolInvocation | undefined = source.activeInvocation;
  if (!RuntimeCheckpointValidator.validate(source).valid ||
    !RuntimeCheckpointValidator.validate(normalized).valid || active === undefined ||
    source.pendingDispatchId.length === 0 || source.pendingOperationId.length === 0 ||
    normalized.activeInvocation !== undefined || normalized.pendingDispatchId.length > 0 ||
    normalized.pendingInvocation !== undefined || normalized.pendingPolicyRequest !== undefined ||
    normalized.snapshot.status !== AgentTaskStatus.WAITING_RECONCILIATION ||
    normalized.snapshot.snapshotVersion !== source.snapshot.snapshotVersion + 1 ||
    normalized.snapshot.taskId !== source.snapshot.taskId ||
    normalized.envelope.taskId !== source.envelope.taskId ||
    normalized.pendingStepId !== source.pendingStepId ||
    normalized.pendingOperationId !== source.pendingOperationId || normalized.paused ||
    normalized.events.length !== source.events.length + 1 ||
    normalized.snapshot.lastEventSequence !== source.snapshot.lastEventSequence + 1 ||
    !operationMatchesInvocation(operation, active) ||
    operation.intent.operationId !== source.pendingOperationId || operation.outcome !== undefined ||
    (operation.state !== OperationJournalState.IN_FLIGHT &&
      operation.state !== OperationJournalState.UNKNOWN_OUTCOME) ||
    operation.fencingToken <= 0 || operation.dispatchCount <= 0) return false;
  for (let i: number = 0; i < source.events.length; i++) {
    if (ContractCodec.stringify(source.events[i]) !== ContractCodec.stringify(normalized.events[i])) return false;
  }
  return true;
}

function saveTask(store: ExecutionRecoveryStore, checkpoint: RuntimeTaskRecoveryCheckpoint,
  expectedPreviousVersion: number, nowMs: number, tracker: MutationTracker): StorageWriteResult | undefined {
  return tracker.observe(store.saveTask(checkpoint.snapshot, checkpoint.checkpointVersion,
    ContractCodec.stringify(checkpoint), expectedPreviousVersion, nowMs));
}

class SaveCheckpointTransaction implements ExecutionRecoveryTransaction {
  private readonly checkpoint: RuntimeTaskRecoveryCheckpoint;
  private readonly expectedPreviousVersion: number;
  private readonly authority: RuntimeDurableAuthorityPayload;
  private readonly nowMs: number;

  constructor(checkpoint: RuntimeTaskRecoveryCheckpoint, expectedPreviousVersion: number,
    authority: RuntimeDurableAuthorityPayload, nowMs: number) {
    this.checkpoint = checkpoint;
    this.expectedPreviousVersion = expectedPreviousVersion;
    this.authority = authority;
    this.nowMs = nowMs;
  }

  apply(store: ExecutionRecoveryStore): StorageWriteResult {
    const tracker: MutationTracker = new MutationTracker();
    let rejected: StorageWriteResult | undefined = saveTask(store, this.checkpoint,
      this.expectedPreviousVersion, this.nowMs, tracker);
    if (rejected !== undefined) return rejected;
    rejected = applyPolicy(store, this.authority, this.nowMs, tracker);
    if (rejected !== undefined) return rejected;
    if (this.authority.budgetReservations.length === 0) {
      rejected = tracker.observe(store.saveBudgetAuthority(this.authority.taskId,
        this.authority.budgetScopes, this.nowMs));
      if (rejected !== undefined) return rejected;
    }
    return tracker.complete();
  }
}

class BeforeDispatchTransaction implements ExecutionRecoveryTransaction {
  private readonly checkpoint: RuntimeTaskRecoveryCheckpoint;
  private readonly expectedPreviousVersion: number;
  private readonly context: DispatchPersistenceContext;
  private readonly authority: RuntimeDurableAuthorityPayload;
  private readonly ownerId: string;
  private readonly leaseTtlMs: number;
  private readonly nowMs: number;
  fencingToken: number = 0;

  constructor(checkpoint: RuntimeTaskRecoveryCheckpoint, expectedPreviousVersion: number,
    context: DispatchPersistenceContext, authority: RuntimeDurableAuthorityPayload,
    ownerId: string, leaseTtlMs: number, nowMs: number) {
    this.checkpoint = checkpoint;
    this.expectedPreviousVersion = expectedPreviousVersion;
    this.context = context;
    this.authority = authority;
    this.ownerId = ownerId;
    this.leaseTtlMs = leaseTtlMs;
    this.nowMs = nowMs;
  }

  apply(store: ExecutionRecoveryStore): StorageWriteResult {
    const tracker: MutationTracker = new MutationTracker();
    let rejected: StorageWriteResult | undefined = saveTask(store, this.checkpoint,
      this.expectedPreviousVersion, this.nowMs, tracker);
    if (rejected !== undefined) return rejected;
    rejected = applyPolicy(store, this.authority, this.nowMs, tracker);
    if (rejected !== undefined) return rejected;
    const reservation: BudgetReservationSnapshot | undefined =
      findReservation(this.authority, this.context.budgetReservationId);
    if (reservation === undefined) return rejectedWrite();
    rejected = tracker.observe(store.prepareOperation(intentFrom(this.context), reservation,
      this.authority.budgetScopes, this.nowMs));
    if (rejected !== undefined) return rejected;

    const operation: StoredOperation | undefined = store.getOperation(this.context.operationId);
    const existingLease: RecoveryLease | undefined = store.getLease(this.context.taskId);
    if (operation !== undefined && operation.state === OperationJournalState.IN_FLIGHT) {
      if (tracker.mutated || existingLease === undefined || existingLease.ownerId !== this.ownerId ||
        existingLease.expiresAtMs <= this.nowMs || operation.fencingToken !== existingLease.fencingToken ||
        !sameStoredOperation(operation, this.context)) return rejectedWrite(StorageWriteCode.STATE_CONFLICT);
      this.fencingToken = existingLease.fencingToken;
      return tracker.complete();
    }
    if (operation === undefined || operation.state !== OperationJournalState.PREPARED) {
      return rejectedWrite(StorageWriteCode.STATE_CONFLICT);
    }
    const lease = store.acquireLease(this.context.taskId, this.ownerId, this.leaseTtlMs, this.nowMs);
    rejected = tracker.observe(lease);
    if (rejected !== undefined || lease.lease === undefined) return rejected === undefined ? rejectedWrite() : rejected;
    this.fencingToken = lease.lease.fencingToken;
    rejected = tracker.observe(store.markOperationInFlight(this.context.operationId,
      this.ownerId, this.fencingToken, this.nowMs));
    return rejected === undefined ? tracker.complete() : rejected;
  }
}

class RecoveryNormalizationTransaction implements ExecutionRecoveryTransaction {
  private readonly checkpoint: RuntimeTaskRecoveryCheckpoint;
  private readonly expectedPreviousVersion: number;
  private readonly ownerId: string;
  private readonly leaseTtlMs: number;
  private readonly nowMs: number;

  constructor(checkpoint: RuntimeTaskRecoveryCheckpoint, expectedPreviousVersion: number,
    ownerId: string, leaseTtlMs: number, nowMs: number) {
    this.checkpoint = checkpoint;
    this.expectedPreviousVersion = expectedPreviousVersion;
    this.ownerId = ownerId;
    this.leaseTtlMs = leaseTtlMs;
    this.nowMs = nowMs;
  }

  apply(store: ExecutionRecoveryStore): StorageWriteResult {
    const storedTask = store.getTask(this.checkpoint.snapshot.taskId);
    if (storedTask === undefined || storedTask.snapshotVersion !== this.expectedPreviousVersion) {
      return rejectedWrite(StorageWriteCode.VERSION_CONFLICT);
    }
    let source: RuntimeTaskRecoveryCheckpoint;
    try {
      source = JSON.parse(storedTask.checkpointJson) as RuntimeTaskRecoveryCheckpoint;
    } catch (error) {
      return rejectedWrite();
    }
    const operation: StoredOperation | undefined = store.getOperation(source.pendingOperationId);
    if (operation === undefined || !validRecoveryNormalization(source, this.checkpoint, operation)) {
      return rejectedWrite(StorageWriteCode.STATE_CONFLICT);
    }

    const tracker: MutationTracker = new MutationTracker();
    const oldLease: RecoveryLease | undefined = store.getLease(source.snapshot.taskId);
    if (operation.state === OperationJournalState.IN_FLIGHT && oldLease === undefined) {
      return rejectedWrite(StorageWriteCode.STATE_CONFLICT);
    }
    if (oldLease !== undefined) {
      if (oldLease.fencingToken !== operation.fencingToken) {
        return rejectedWrite(StorageWriteCode.STALE_FENCE);
      }
      let rejected: StorageWriteResult | undefined = tracker.observe(store.releaseLease(
        oldLease.resourceId, oldLease.ownerId, oldLease.fencingToken));
      if (rejected !== undefined) return rejected;
    }

    const takeover = store.acquireLease(source.snapshot.taskId, this.ownerId, this.leaseTtlMs, this.nowMs);
    let rejected: StorageWriteResult | undefined = tracker.observe(takeover);
    if (rejected !== undefined || takeover.lease === undefined) {
      return rejected === undefined ? rejectedWrite() : rejected;
    }
    rejected = tracker.observe(store.normalizeOperationForRecovery(
      operation.intent.operationId, takeover.lease.fencingToken, this.nowMs));
    if (rejected !== undefined) return rejected;
    rejected = tracker.observe(store.releaseLease(
      source.snapshot.taskId, this.ownerId, takeover.lease.fencingToken));
    if (rejected !== undefined) return rejected;
    rejected = saveTask(store, this.checkpoint, this.expectedPreviousVersion, this.nowMs, tracker);
    return rejected === undefined ? tracker.complete() : rejected;
  }
}

function releaseBoundLease(store: ExecutionRecoveryStore, binding: DispatchBinding,
  tracker: MutationTracker): StorageWriteResult | undefined {
  const lease: RecoveryLease | undefined = store.getLease(binding.taskId);
  if (lease === undefined) return undefined;
  if (lease.ownerId !== binding.ownerId || lease.fencingToken !== binding.fencingToken) {
    return rejectedWrite(StorageWriteCode.STALE_FENCE);
  }
  return tracker.observe(store.releaseLease(binding.taskId, binding.ownerId, binding.fencingToken));
}

class OutcomeTransaction implements ExecutionRecoveryTransaction {
  private readonly binding: DispatchBinding;
  private readonly outcome: ToolOutcome;
  private readonly actual?: BudgetAmount;
  private readonly nowMs: number;

  constructor(binding: DispatchBinding, outcome: ToolOutcome, actual: BudgetAmount | undefined, nowMs: number) {
    this.binding = binding;
    this.outcome = outcome;
    this.actual = actual;
    this.nowMs = nowMs;
  }

  apply(store: ExecutionRecoveryStore): StorageWriteResult {
    const tracker: MutationTracker = new MutationTracker();
    const operation: StoredOperation | undefined = store.getOperation(this.binding.operationId);
    if (operation === undefined) return rejectedWrite(StorageWriteCode.NOT_FOUND);
    if (operation.intent.taskId !== this.binding.taskId || operation.intent.stepId !== this.binding.stepId ||
      operation.intent.invocationId !== this.outcome.invocationId) return rejectedWrite();
    let rejected: StorageWriteResult | undefined;
    if (this.outcome.status === ToolOutcomeStatus.UNKNOWN_OUTCOME) {
      if (operation.state === OperationJournalState.IN_FLIGHT) {
        rejected = tracker.observe(store.markOperationUnknown(this.binding.operationId,
          this.binding.ownerId, this.binding.fencingToken, this.nowMs));
        if (rejected !== undefined) return rejected;
      } else if (operation.state !== OperationJournalState.UNKNOWN_OUTCOME) {
        return rejectedWrite(StorageWriteCode.STATE_CONFLICT);
      }
    } else {
      if (this.actual === undefined) return rejectedWrite();
      rejected = tracker.observe(store.recordOperationOutcome(this.binding.operationId, this.outcome,
        this.actual, this.binding.ownerId, this.binding.fencingToken, this.nowMs));
      if (rejected !== undefined) return rejected;
    }
    rejected = releaseBoundLease(store, this.binding, tracker);
    return rejected === undefined ? tracker.complete() : rejected;
  }
}

class DispatchRejectedTransaction implements ExecutionRecoveryTransaction {
  private readonly binding: DispatchBinding;
  private readonly nowMs: number;

  constructor(binding: DispatchBinding, nowMs: number) {
    this.binding = binding;
    this.nowMs = nowMs;
  }

  apply(store: ExecutionRecoveryStore): StorageWriteResult {
    const tracker: MutationTracker = new MutationTracker();
    let operation: StoredOperation | undefined = store.getOperation(this.binding.operationId);
    if (operation === undefined) return rejectedWrite(StorageWriteCode.NOT_FOUND);
    let rejected: StorageWriteResult | undefined;
    if (operation.state === OperationJournalState.IN_FLIGHT) {
      rejected = tracker.observe(store.markOperationUnknown(this.binding.operationId,
        this.binding.ownerId, this.binding.fencingToken, this.nowMs));
      if (rejected !== undefined) return rejected;
      operation = store.getOperation(this.binding.operationId);
    }
    if (operation !== undefined && operation.state === OperationJournalState.UNKNOWN_OUTCOME) {
      rejected = tracker.observe(store.reconcileOperation(this.binding.operationId, false, undefined, undefined,
        this.binding.ownerId, this.binding.fencingToken, this.nowMs));
      if (rejected !== undefined) return rejected;
    } else if (operation === undefined || operation.state !== OperationJournalState.PREPARED) {
      return rejectedWrite(StorageWriteCode.STATE_CONFLICT);
    }
    rejected = releaseBoundLease(store, this.binding, tracker);
    return rejected === undefined ? tracker.complete() : rejected;
  }
}

class ReconciliationTransaction implements ExecutionRecoveryTransaction {
  private readonly report: ReconciliationReport;
  private readonly settlement?: RuntimeReconciliationSettlement;
  private readonly ownerId: string;
  private readonly leaseTtlMs: number;
  private readonly nowMs: number;

  constructor(report: ReconciliationReport, settlement: RuntimeReconciliationSettlement | undefined,
    ownerId: string, leaseTtlMs: number, nowMs: number) {
    this.report = report;
    this.settlement = settlement;
    this.ownerId = ownerId;
    this.leaseTtlMs = leaseTtlMs;
    this.nowMs = nowMs;
  }

  apply(store: ExecutionRecoveryStore): StorageWriteResult {
    const tracker: MutationTracker = new MutationTracker();
    const operation: StoredOperation | undefined = store.getOperation(this.report.operationId);
    if (operation === undefined) return rejectedWrite(StorageWriteCode.NOT_FOUND);
    if (operation.intent.taskId !== this.report.taskId || operation.intent.stepId !== this.report.stepId) {
      return rejectedWrite();
    }
    if (this.report.status === ReconciliationStatus.NOT_EXECUTED &&
      operation.state === OperationJournalState.PREPARED && operation.dispatchCount > 0) {
      return tracker.complete();
    }
    if (operation.state === OperationJournalState.COMMITTED && this.settlement !== undefined &&
      operation.outcome !== undefined &&
      ContractCodec.stringify(operation.outcome) === ContractCodec.stringify(this.settlement.outcome)) {
      return tracker.complete();
    }
    if (operation.state !== OperationJournalState.UNKNOWN_OUTCOME) {
      return rejectedWrite(StorageWriteCode.STATE_CONFLICT);
    }

    let token: number = 0;
    const existing: RecoveryLease | undefined = store.getLease(this.report.taskId);
    if (existing !== undefined && existing.expiresAtMs > this.nowMs) {
      if (existing.ownerId !== this.ownerId) return rejectedWrite(StorageWriteCode.LEASE_HELD);
      token = existing.fencingToken;
    } else {
      const lease = store.acquireLease(this.report.taskId, this.ownerId, this.leaseTtlMs, this.nowMs);
      const leaseRejected: StorageWriteResult | undefined = tracker.observe(lease);
      if (leaseRejected !== undefined || lease.lease === undefined) {
        return leaseRejected === undefined ? rejectedWrite() : leaseRejected;
      }
      token = lease.lease.fencingToken;
    }

    let rejected: StorageWriteResult | undefined;
    if (this.report.status === ReconciliationStatus.NOT_EXECUTED) {
      rejected = tracker.observe(store.reconcileOperation(this.report.operationId, false, undefined, undefined,
        this.ownerId, token, this.nowMs));
    } else {
      if (this.settlement === undefined) return rejectedWrite();
      rejected = tracker.observe(store.reconcileOperation(this.report.operationId, true,
        this.settlement.outcome, this.settlement.actual, this.ownerId, token, this.nowMs));
    }
    if (rejected !== undefined) return rejected;
    const binding: DispatchBinding = new DispatchBinding();
    binding.taskId = this.report.taskId;
    binding.ownerId = this.ownerId;
    binding.fencingToken = token;
    rejected = releaseBoundLease(store, binding, tracker);
    return rejected === undefined ? tracker.complete() : rejected;
  }
}

/**
 * Host-side adapter from the production Runtime persistence boundary to the
 * durable execution store. It exposes no task-control method; callers still
 * control work exclusively through AgentRuntimeFacade.
 *
 * beforeDispatch conservatively commits IN_FLIGHT before the adapter call.
 * A process crash in that narrow interval therefore requires reconciliation
 * instead of risking a duplicate side effect.
 */
export class RuntimeExecutionRecoveryBridge implements ProductionRuntimePersistencePort,
  ProductionRuntimeRecoverySourcePort {
  private readonly store: DurableExecutionRecoveryStore;
  private readonly config: RuntimeExecutionRecoveryBridgeConfig;
  private bindings: DispatchBinding[] = [];

  constructor(store: DurableExecutionRecoveryStore, config: RuntimeExecutionRecoveryBridgeConfig) {
    if (config.ownerId.trim().length === 0 || config.policyVersion.trim().length === 0 ||
      !Number.isSafeInteger(config.leaseTtlMs) ||
      config.leaseTtlMs <= 0) throw new Error('invalid runtime execution recovery bridge config');
    this.store = store;
    const stable: RuntimeExecutionRecoveryBridgeConfig = new RuntimeExecutionRecoveryBridgeConfig();
    stable.ownerId = config.ownerId;
    stable.leaseTtlMs = config.leaseTtlMs;
    stable.policyVersion = config.policyVersion;
    stable.outcomeAccounting = config.outcomeAccounting;
    stable.reconciliationSettlement = config.reconciliationSettlement;
    this.config = stable;
  }

  async saveCheckpoint(checkpoint: RuntimeTaskRecoveryCheckpoint, expectedPreviousVersion: number,
    authority: RuntimeDurableAuthorityPayload, nowMs: number): Promise<RuntimePersistenceResult> {
    if (!this.validWriteBinding(checkpoint, authority)) {
      return runtimeResult(false, false, RuntimePersistenceCode.REJECTED);
    }
    return mapWrite(await this.store.transact(new SaveCheckpointTransaction(
      copyCheckpoint(checkpoint), expectedPreviousVersion,
      JSON.parse(ContractCodec.stringify(authority)) as RuntimeDurableAuthorityPayload, nowMs)));
  }

  async loadCheckpoint(taskId: string): Promise<RuntimeTaskRecoveryCheckpoint | undefined> {
    const stored = this.store.getTask(taskId);
    if (stored === undefined) return undefined;
    return JSON.parse(stored.checkpointJson) as RuntimeTaskRecoveryCheckpoint;
  }

  async normalizeRecoveredOperation(checkpoint: RuntimeTaskRecoveryCheckpoint,
    expectedPreviousVersion: number, nowMs: number): Promise<RuntimePersistenceResult> {
    if (!RuntimeCheckpointValidator.validate(checkpoint).valid ||
      checkpoint.activeInvocation !== undefined || checkpoint.pendingDispatchId.length > 0) {
      return runtimeResult(false, false, RuntimePersistenceCode.REJECTED);
    }
    return mapWrite(await this.store.transact(new RecoveryNormalizationTransaction(
      copyCheckpoint(checkpoint), expectedPreviousVersion,
      this.config.ownerId, this.config.leaseTtlMs, nowMs)));
  }

  async listRecoveryTaskIds(): Promise<string[]> {
    const values: string[] = this.store.listTaskIds();
    values.sort();
    return values;
  }

  async loadRecoveryAuthority(taskId: string): Promise<RuntimeRecoveryAuthority | undefined> {
    const checkpoint: RuntimeTaskRecoveryCheckpoint | undefined = await this.loadCheckpoint(taskId);
    if (checkpoint === undefined || checkpoint.snapshot.taskId !== taskId || this.store.revision() <= 0) {
      return undefined;
    }
    const value: RuntimeRecoveryAuthority = new RuntimeRecoveryAuthority();
    value.taskId = taskId;
    value.checkpointSnapshotVersion = checkpoint.snapshot.snapshotVersion;
    value.policyVersion = this.config.policyVersion;
    value.storageRevision = this.store.revision();
    const scopes = this.store.getBudgetScopes(taskId);
    for (let i: number = 0; i < scopes.length; i++) {
      value.budgetScopes.push(JSON.parse(JSON.stringify(scopes[i].snapshot)));
    }
    const reservations = this.store.getBudgetReservations(taskId);
    for (let i: number = 0; i < reservations.length; i++) {
      value.budgetReservations.push(JSON.parse(JSON.stringify(reservations[i].snapshot)));
    }

    if (checkpoint.pendingPolicyRequest !== undefined) {
      const storedPolicy: StoredPolicyRecord | undefined =
        this.store.getPolicyRecord(checkpoint.pendingPolicyRequest.requestId);
      if (storedPolicy === undefined || storedPolicy.version !== 1) return undefined;
      value.policy = this.policyAuthority(storedPolicy);
    } else if (checkpoint.activeInvocation !== undefined) {
      const storedOperation: StoredOperation | undefined = this.store.getOperation(checkpoint.pendingOperationId);
      if (storedOperation === undefined) return undefined;
      const storedPolicy: StoredPolicyRecord | undefined =
        this.store.getPolicyRecord(storedOperation.intent.policyRequestId);
      if (storedPolicy === undefined || storedPolicy.version !== 3) return undefined;
      value.policy = this.policyAuthority(storedPolicy);
      value.operation = this.operationAuthority(storedOperation);
    }
    if (!RuntimeRecoveryAuthorityValidator.validate(checkpoint, value).valid) return undefined;
    return JSON.parse(ContractCodec.stringify(value)) as RuntimeRecoveryAuthority;
  }

  async beforeDispatch(checkpoint: RuntimeTaskRecoveryCheckpoint, expectedPreviousVersion: number,
    context: DispatchPersistenceContext | undefined, authority: RuntimeDurableAuthorityPayload,
    nowMs: number): Promise<RuntimePersistenceResult> {
    if (!this.validWriteBinding(checkpoint, authority)) {
      return runtimeResult(false, false, RuntimePersistenceCode.REJECTED);
    }
    if (context === undefined) {
      return await this.saveCheckpoint(checkpoint, expectedPreviousVersion, authority, nowMs);
    }
    if (!contextMatchesAuthority(context, authority)) {
      return runtimeResult(false, false, RuntimePersistenceCode.REJECTED);
    }
    const durable: RuntimeRecoveryAuthority =
      JSON.parse(ContractCodec.stringify(authority)) as RuntimeRecoveryAuthority;
    durable.storageRevision = this.store.revision() + 1;
    if (!RuntimeRecoveryAuthorityValidator.validate(checkpoint, durable).valid) {
      return runtimeResult(false, false, RuntimePersistenceCode.REJECTED);
    }
    const transaction: BeforeDispatchTransaction = new BeforeDispatchTransaction(
      copyCheckpoint(checkpoint), expectedPreviousVersion,
      JSON.parse(ContractCodec.stringify(context)) as DispatchPersistenceContext,
      JSON.parse(ContractCodec.stringify(authority)) as RuntimeDurableAuthorityPayload,
      this.config.ownerId, this.config.leaseTtlMs, nowMs);
    const stored: StorageWriteResult = await this.store.transact(transaction);
    if (!stored.accepted) return mapWrite(stored);
    const operation: StoredOperation | undefined = this.store.getOperation(context.operationId);
    const lease: RecoveryLease | undefined = this.store.getLease(context.taskId);
    if (operation === undefined || lease === undefined || operation.state !== OperationJournalState.IN_FLIGHT ||
      lease.ownerId !== this.config.ownerId || operation.fencingToken !== lease.fencingToken) {
      return runtimeResult(false, false, RuntimePersistenceCode.REJECTED);
    }
    this.rememberBinding(context, lease.fencingToken);
    return mapWrite(stored);
  }

  async recordDispatchRejected(context: DispatchPersistenceContext | undefined, dispatchId: string,
    rejectionCode: string, nowMs: number): Promise<RuntimePersistenceResult> {
    if (context === undefined || dispatchId !== context.dispatchId || rejectionCode.trim().length === 0) {
      return runtimeResult(false, false, RuntimePersistenceCode.REJECTED);
    }
    const operation: StoredOperation | undefined = this.store.getOperation(context.operationId);
    if (operation === undefined || !sameStoredOperation(operation, context)) {
      return runtimeResult(false, false, RuntimePersistenceCode.REJECTED);
    }
    let binding: DispatchBinding | undefined = this.findBinding(dispatchId);
    if (binding === undefined) binding = this.bindingFromContext(context);
    return mapWrite(await this.store.transact(new DispatchRejectedTransaction(binding, nowMs)));
  }

  async recordOutcome(taskId: string, stepId: string, dispatchId: string, outcome: ToolOutcome,
    nowMs: number): Promise<RuntimePersistenceResult> {
    const binding: DispatchBinding | undefined = this.findBinding(dispatchId);
    if (binding === undefined || binding.taskId !== taskId || binding.stepId !== stepId ||
      !ContractValidator.validateToolOutcome(outcome).valid) {
      return runtimeResult(false, false, RuntimePersistenceCode.NOT_FOUND);
    }
    let actual: BudgetAmount | undefined;
    if (outcome.status !== ToolOutcomeStatus.UNKNOWN_OUTCOME) {
      const accounting: RuntimeOutcomeAccountingPort | undefined = this.config.outcomeAccounting;
      const operation: StoredOperation | undefined = this.store.getOperation(binding.operationId);
      if (accounting === undefined || operation === undefined) {
        return runtimeResult(false, false, RuntimePersistenceCode.REJECTED);
      }
      actual = accounting.actualForOutcome(operation, copyOutcome(outcome));
      if (actual === undefined) return runtimeResult(false, false, RuntimePersistenceCode.REJECTED);
      actual = copyBudget(actual);
    }
    return mapWrite(await this.store.transact(new OutcomeTransaction(binding, copyOutcome(outcome), actual, nowMs)));
  }

  async recordReconciliation(report: ReconciliationReport, nowMs: number): Promise<RuntimePersistenceResult> {
    if (!ContractValidator.validateReconciliationReport(report).valid) {
      return runtimeResult(false, false, RuntimePersistenceCode.REJECTED);
    }
    if (report.status === ReconciliationStatus.STILL_UNKNOWN) {
      const operation: StoredOperation | undefined = this.store.getOperation(report.operationId);
      if (operation === undefined || operation.intent.taskId !== report.taskId ||
        operation.intent.stepId !== report.stepId || operation.state !== OperationJournalState.UNKNOWN_OUTCOME) {
        return runtimeResult(false, false, RuntimePersistenceCode.REJECTED);
      }
      return runtimeResult(true, true, RuntimePersistenceCode.UNCHANGED);
    }
    let settlement: RuntimeReconciliationSettlement | undefined;
    if (report.status === ReconciliationStatus.CONFIRMED_SUCCEEDED ||
      report.status === ReconciliationStatus.CONFIRMED_FAILED) {
      const resolver: RuntimeReconciliationSettlementPort | undefined = this.config.reconciliationSettlement;
      const operation: StoredOperation | undefined = this.store.getOperation(report.operationId);
      if (resolver === undefined || operation === undefined) {
        return runtimeResult(false, false, RuntimePersistenceCode.REJECTED);
      }
      const resolved: RuntimeReconciliationSettlement | undefined = resolver.resolve(copyReport(report), operation);
      if (resolved === undefined ||
        (report.status === ReconciliationStatus.CONFIRMED_SUCCEEDED &&
          resolved.outcome.status !== ToolOutcomeStatus.SUCCEEDED) ||
        (report.status === ReconciliationStatus.CONFIRMED_FAILED &&
          (resolved.outcome.status === ToolOutcomeStatus.SUCCEEDED ||
            resolved.outcome.status === ToolOutcomeStatus.UNKNOWN_OUTCOME)) ||
        resolved.outcome.invocationId !== operation.intent.invocationId ||
        (report.providerReceipt !== undefined &&
          resolved.outcome.providerReceipt !== report.providerReceipt)) {
        return runtimeResult(false, false, RuntimePersistenceCode.REJECTED);
      }
      settlement = new RuntimeReconciliationSettlement();
      settlement.outcome = copyOutcome(resolved.outcome);
      settlement.actual = copyBudget(resolved.actual);
    }
    return mapWrite(await this.store.transact(new ReconciliationTransaction(copyReport(report), settlement,
      this.config.ownerId, this.config.leaseTtlMs, nowMs)));
  }

  private validWriteBinding(checkpoint: RuntimeTaskRecoveryCheckpoint,
    authority: RuntimeDurableAuthorityPayload): boolean {
    return RuntimeCheckpointValidator.validate(checkpoint).valid &&
      authority.taskId === checkpoint.snapshot.taskId &&
      authority.checkpointSnapshotVersion === checkpoint.snapshot.snapshotVersion &&
      authority.policyVersion.trim().length > 0;
  }

  private policyAuthority(source: StoredPolicyRecord): RuntimeRecoveryPolicyAuthority {
    const value: RuntimeRecoveryPolicyAuthority = new RuntimeRecoveryPolicyAuthority();
    value.version = source.version;
    value.request = ContractCodec.parsePolicyRequest(ContractCodec.stringify(source.request));
    if (source.decision !== undefined) {
      value.decision = ContractCodec.parseAuthorizationDecision(ContractCodec.stringify(source.decision));
    }
    if (source.grant !== undefined) {
      value.grant = ContractCodec.parseAuthorizationGrant(ContractCodec.stringify(source.grant));
    }
    return value;
  }

  private operationAuthority(source: StoredOperation): RuntimeRecoveryOperationAuthority {
    const intent: StoredOperationIntent = source.intent;
    const value: RuntimeRecoveryOperationAuthority = new RuntimeRecoveryOperationAuthority();
    value.operationId = intent.operationId;
    value.invocationId = intent.invocationId;
    value.taskId = intent.taskId;
    value.stepId = intent.stepId;
    value.attemptId = intent.attemptId;
    value.toolId = intent.toolId;
    value.toolIdentityVersion = intent.toolIdentityVersion;
    value.schemaDigest = intent.schemaDigest;
    value.argumentsDigest = intent.argumentsDigest;
    value.idempotencyKey = intent.idempotencyKey;
    value.idempotencyMode = intent.idempotencyMode;
    value.sideEffect = intent.sideEffect;
    value.policyRequestId = intent.policyRequestId;
    value.budgetReservationId = intent.budgetReservationId;
    value.state = source.state;
    value.fencingToken = source.fencingToken;
    value.dispatchCount = source.dispatchCount;
    if (source.outcome !== undefined) value.outcome = copyOutcome(source.outcome);
    return value;
  }

  private rememberBinding(context: DispatchPersistenceContext, fencingToken: number): void {
    const value: DispatchBinding = this.bindingFromContext(context);
    value.fencingToken = fencingToken;
    const next: DispatchBinding[] = [];
    for (let i: number = 0; i < this.bindings.length; i++) {
      if (this.bindings[i].dispatchId !== context.dispatchId) next.push(this.bindings[i]);
    }
    next.push(value);
    this.bindings = next;
  }

  private bindingFromContext(context: DispatchPersistenceContext): DispatchBinding {
    const value: DispatchBinding = new DispatchBinding();
    value.dispatchId = context.dispatchId;
    value.operationId = context.operationId;
    value.taskId = context.taskId;
    value.stepId = context.stepId;
    value.ownerId = this.config.ownerId;
    const lease: RecoveryLease | undefined = this.store.getLease(context.taskId);
    if (lease !== undefined && lease.ownerId === this.config.ownerId) value.fencingToken = lease.fencingToken;
    return value;
  }

  private findBinding(dispatchId: string): DispatchBinding | undefined {
    for (let i: number = 0; i < this.bindings.length; i++) {
      if (this.bindings[i].dispatchId === dispatchId) return this.bindings[i];
    }
    return undefined;
  }
}
