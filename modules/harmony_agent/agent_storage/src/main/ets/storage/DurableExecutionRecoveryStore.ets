import { VerifiedInvoice } from './InvoiceTypes';
import {
  AgentTaskSnapshot,
  AuthorizationDecision,
  AuthorizationGrant,
  PolicyRequest,
  ToolOutcome,
  TraceEvent
} from '@harmony_agent/agent-contracts';
import { BudgetAmount, BudgetReservationSnapshot, BudgetScopeSnapshot } from '@harmony_agent/agent-core';
import { ExecutionRecoveryStore } from './ExecutionRecoveryStore';
import {
  DurableSnapshotBackendPort,
  SnapshotIntegrityPort,
  StorageMigrationPort
} from './StoragePorts';
import {
  LeaseResult,
  OperationPrepareResult,
  RecoveryLease,
  RetentionResult,
  StorageSnapshotEnvelope,
  StorageWriteCode,
  StorageWriteResult,
  StoredBudgetReservation,
  StoredBudgetScope,
  StoredOperation,
  StoredOperationIntent,
  StoredPolicyRecord,
  StoredRegistryRecord,
  StoredTaskSnapshot,
  StoredTraceEvent
} from './StorageTypes';

export class DurableExecutionStoreOpenResult {
  accepted: boolean = false;
  code: StorageWriteCode = StorageWriteCode.CORRUPT_SNAPSHOT;
  store?: DurableExecutionRecoveryStore;
}

export class DurableRetentionResult extends RetentionResult {
  accepted: boolean = false;
  code: StorageWriteCode = StorageWriteCode.INVALID_INPUT;
}

/**
 * Applies a bounded group of synchronous recovery-store mutations to one
 * isolated candidate. The durable session publishes the complete candidate
 * with one backend CAS only when apply returns an accepted, non-duplicate
 * result. The port carries storage mutations only and cannot control Runtime.
 */
export interface ExecutionRecoveryTransaction {
  apply(store: ExecutionRecoveryStore): StorageWriteResult;
}

function conflictWriteResult(): StorageWriteResult {
  const result: StorageWriteResult = new StorageWriteResult();
  result.code = StorageWriteCode.VERSION_CONFLICT;
  return result;
}

function conflictPrepareResult(): OperationPrepareResult {
  const result: OperationPrepareResult = new OperationPrepareResult();
  result.code = StorageWriteCode.VERSION_CONFLICT;
  return result;
}

function conflictLeaseResult(): LeaseResult {
  const result: LeaseResult = new LeaseResult();
  result.code = StorageWriteCode.VERSION_CONFLICT;
  return result;
}

/**
 * Async durable session over the synchronous protocol store.
 *
 * Every mutation is made on an isolated fork. The fork becomes observable
 * only after the complete snapshot is durably published with CAS. A false CAS
 * result leaves the previous in-memory state untouched and requires the caller
 * to reopen before making execution decisions.
 */
export class DurableExecutionRecoveryStore {
  private readonly backend: DurableSnapshotBackendPort;
  private readonly integrity: SnapshotIntegrityPort;
  private current: ExecutionRecoveryStore;
  private durableRevision: number;
  private invoiceReconciliationOnly: boolean = false;

  private constructor(backend: DurableSnapshotBackendPort, integrity: SnapshotIntegrityPort,
    current: ExecutionRecoveryStore, durableRevision: number) {
    this.backend = backend;
    this.integrity = integrity;
    this.current = current;
    this.durableRevision = durableRevision;
  }

  static async open(backend: DurableSnapshotBackendPort, integrity: SnapshotIntegrityPort,
    migration?: StorageMigrationPort): Promise<DurableExecutionStoreOpenResult> {
    return await DurableExecutionRecoveryStore.openWithMode(backend, integrity, migration, true);
  }

  /**
   * Opens a session without independently normalizing IN_FLIGHT operations.
   * RuntimeExecutionRecoveryBridge uses this mode so operation, budget, lease
   * and Runtime checkpoint recovery can be published by one later CAS.
   */
  static async openForRuntimeRecovery(backend: DurableSnapshotBackendPort, integrity: SnapshotIntegrityPort,
    migration?: StorageMigrationPort): Promise<DurableExecutionStoreOpenResult> {
    return await DurableExecutionRecoveryStore.openWithMode(backend, integrity, migration, false);
  }

  /** Dedicated offline host session: cannot be mounted as a Runtime execution bridge. */
  static async openForInvoiceReconciliation(backend: DurableSnapshotBackendPort, integrity: SnapshotIntegrityPort):
    Promise<DurableExecutionStoreOpenResult> {
    const opened = await DurableExecutionRecoveryStore.openWithMode(backend, integrity, undefined, false);
    if (opened.store !== undefined) opened.store.invoiceReconciliationOnly = true;
    return opened;
  }

  isInvoiceReconciliationOnly(): boolean { return this.invoiceReconciliationOnly; }

  private static async openWithMode(backend: DurableSnapshotBackendPort, integrity: SnapshotIntegrityPort,
    migration: StorageMigrationPort | undefined,
    normalizeInFlight: boolean): Promise<DurableExecutionStoreOpenResult> {
    await backend.initialize();
    const source: StorageSnapshotEnvelope | undefined = await backend.load();
    const result: DurableExecutionStoreOpenResult = new DurableExecutionStoreOpenResult();
    if (source === undefined) {
      result.accepted = true;
      result.code = StorageWriteCode.CREATED;
      result.store = new DurableExecutionRecoveryStore(backend, integrity, new ExecutionRecoveryStore(), 0);
      return result;
    }

    const restored = ExecutionRecoveryStore.restore(source, integrity, migration, normalizeInFlight);
    if (!restored.accepted || restored.store === undefined) {
      result.code = restored.code;
      return result;
    }
    const normalized: StorageSnapshotEnvelope = restored.store.checkpoint(integrity);
    if (normalized.revision > source.revision) {
      const saved: boolean = await backend.compareAndSet(source.revision, normalized);
      if (!saved) {
        result.code = StorageWriteCode.VERSION_CONFLICT;
        return result;
      }
    }
    result.accepted = true;
    result.code = StorageWriteCode.UPDATED;
    result.store = new DurableExecutionRecoveryStore(
      backend,
      integrity,
      restored.store,
      normalized.revision
    );
    return result;
  }

  /** Invoke only from an offline, trusted reconciliation session; reopen Runtime afterwards. */
  async settleInvoice(invoice: VerifiedInvoice, actual: BudgetAmount, nowMs: number): Promise<StorageWriteResult> {
    if (!this.invoiceReconciliationOnly) {
      const rejected: StorageWriteResult = new StorageWriteResult();
      rejected.code = StorageWriteCode.STATE_CONFLICT;
      return rejected;
    }
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    const result: StorageWriteResult = candidate.settleInvoice(invoice, actual, nowMs);
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictWriteResult();
  }

  revision(): number {
    return this.durableRevision;
  }

  getTask(taskId: string): StoredTaskSnapshot | undefined {
    return this.current.getTask(taskId);
  }

  listTaskIds(): string[] {
    return this.current.listTaskIds();
  }

  getOperation(operationId: string): StoredOperation | undefined {
    return this.current.getOperation(operationId);
  }

  recoveryCandidates(): StoredOperation[] {
    return this.current.recoveryCandidates();
  }

  getBudgetReservation(reservationId: string): StoredBudgetReservation | undefined {
    return this.current.getBudgetReservation(reservationId);
  }

  getBudgetReservations(taskId: string): StoredBudgetReservation[] {
    return this.current.getBudgetReservations(taskId);
  }

  getBudgetScopes(taskId: string): StoredBudgetScope[] {
    return this.current.getBudgetScopes(taskId);
  }

  listTrace(taskId: string, afterSequence: number): StoredTraceEvent[] {
    return this.current.listTrace(taskId, afterSequence);
  }

  getRegistryRecord(recordId: string): StoredRegistryRecord | undefined {
    return this.current.getRegistryRecord(recordId);
  }

  getPolicyRecord(policyRequestId: string): StoredPolicyRecord | undefined {
    return this.current.getPolicyRecord(policyRequestId);
  }

  getLease(resourceId: string): RecoveryLease | undefined {
    return this.current.getLease(resourceId);
  }

  async saveTask(snapshot: AgentTaskSnapshot, checkpointVersion: string, checkpointJson: string,
    expectedPreviousVersion: number, nowMs: number): Promise<StorageWriteResult> {
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    const result: StorageWriteResult = candidate.saveTask(
      snapshot, checkpointVersion, checkpointJson, expectedPreviousVersion, nowMs);
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictWriteResult();
  }

  async transact(transaction: ExecutionRecoveryTransaction): Promise<StorageWriteResult> {
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    let result: StorageWriteResult;
    try {
      result = transaction.apply(candidate);
    } catch (error) {
      const rejected: StorageWriteResult = new StorageWriteResult();
      rejected.code = StorageWriteCode.INVALID_INPUT;
      return rejected;
    }
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictWriteResult();
  }

  async saveBudgetAuthority(taskId: string, budgetScopes: BudgetScopeSnapshot[],
    nowMs: number): Promise<StorageWriteResult> {
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    const result: StorageWriteResult = candidate.saveBudgetAuthority(taskId, budgetScopes, nowMs);
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictWriteResult();
  }

  async prepareOperation(intent: StoredOperationIntent, reservation: BudgetReservationSnapshot,
    budgetScopes: BudgetScopeSnapshot[], nowMs: number): Promise<OperationPrepareResult> {
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    const result: OperationPrepareResult = candidate.prepareOperation(intent, reservation, budgetScopes, nowMs);
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictPrepareResult();
  }

  async markOperationInFlight(operationId: string, ownerId: string, fencingToken: number,
    nowMs: number): Promise<StorageWriteResult> {
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    const result: StorageWriteResult = candidate.markOperationInFlight(operationId, ownerId, fencingToken, nowMs);
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictWriteResult();
  }

  async recordOperationOutcome(operationId: string, outcome: ToolOutcome, actual: BudgetAmount,
    ownerId: string, fencingToken: number, nowMs: number): Promise<StorageWriteResult> {
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    const result: StorageWriteResult = candidate.recordOperationOutcome(
      operationId,
      outcome,
      actual,
      ownerId,
      fencingToken,
      nowMs
    );
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictWriteResult();
  }

  async markOperationUnknown(operationId: string, ownerId: string, fencingToken: number,
    nowMs: number): Promise<StorageWriteResult> {
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    const result: StorageWriteResult = candidate.markOperationUnknown(operationId, ownerId, fencingToken, nowMs);
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictWriteResult();
  }

  async reconcileOperation(operationId: string, committed: boolean, outcome: ToolOutcome | undefined,
    actual: BudgetAmount | undefined, ownerId: string, fencingToken: number,
    nowMs: number): Promise<StorageWriteResult> {
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    const result: StorageWriteResult = candidate.reconcileOperation(
      operationId,
      committed,
      outcome,
      actual,
      ownerId,
      fencingToken,
      nowMs
    );
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictWriteResult();
  }

  async appendTrace(event: TraceEvent, sequence: number, timestampMs: number): Promise<StorageWriteResult> {
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    const result: StorageWriteResult = candidate.appendTrace(event, sequence, timestampMs);
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictWriteResult();
  }

  async pruneTraceBefore(cutoffMs: number, terminalTaskIds: string[]): Promise<DurableRetentionResult> {
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    const removed: RetentionResult = candidate.pruneTraceBefore(cutoffMs, terminalTaskIds);
    const result: DurableRetentionResult = new DurableRetentionResult();
    result.removedTraceEvents = removed.removedTraceEvents;
    if (removed.removedTraceEvents === 0) {
      result.accepted = true;
      result.code = StorageWriteCode.UNCHANGED;
      return result;
    }
    result.accepted = await this.commit(candidate);
    result.code = result.accepted ? StorageWriteCode.UPDATED : StorageWriteCode.VERSION_CONFLICT;
    if (!result.accepted) result.removedTraceEvents = 0;
    return result;
  }

  async saveRegistryRecord(record: StoredRegistryRecord): Promise<StorageWriteResult> {
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    const result: StorageWriteResult = candidate.saveRegistryRecord(record);
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictWriteResult();
  }

  async savePolicyRequest(request: PolicyRequest, nowMs: number): Promise<StorageWriteResult> {
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    const result: StorageWriteResult = candidate.savePolicyRequest(request, nowMs);
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictWriteResult();
  }

  async savePolicyDecision(policyRequestId: string, decision: AuthorizationDecision,
    expectedVersion: number, nowMs: number): Promise<StorageWriteResult> {
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    const result: StorageWriteResult = candidate.savePolicyDecision(
      policyRequestId,
      decision,
      expectedVersion,
      nowMs
    );
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictWriteResult();
  }

  async saveAuthorizationGrant(policyRequestId: string, grant: AuthorizationGrant,
    expectedVersion: number, nowMs: number): Promise<StorageWriteResult> {
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    const result: StorageWriteResult = candidate.saveAuthorizationGrant(
      policyRequestId,
      grant,
      expectedVersion,
      nowMs
    );
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictWriteResult();
  }

  async acquireLease(resourceId: string, ownerId: string, ttlMs: number,
    nowMs: number): Promise<LeaseResult> {
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    const result: LeaseResult = candidate.acquireLease(resourceId, ownerId, ttlMs, nowMs);
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictLeaseResult();
  }

  async renewLease(resourceId: string, ownerId: string, fencingToken: number, ttlMs: number,
    nowMs: number): Promise<LeaseResult> {
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    const result: LeaseResult = candidate.renewLease(resourceId, ownerId, fencingToken, ttlMs, nowMs);
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictLeaseResult();
  }

  async releaseLease(resourceId: string, ownerId: string, fencingToken: number): Promise<StorageWriteResult> {
    const candidate: ExecutionRecoveryStore = this.current.forkForTransaction();
    const result: StorageWriteResult = candidate.releaseLease(resourceId, ownerId, fencingToken);
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictWriteResult();
  }

  private async commit(candidate: ExecutionRecoveryStore): Promise<boolean> {
    const next: StorageSnapshotEnvelope = candidate.checkpoint(this.integrity);
    const accepted: boolean = await this.backend.compareAndSet(this.durableRevision, next);
    if (accepted) {
      this.current = candidate;
      this.durableRevision = next.revision;
    }
    return accepted;
  }
}
