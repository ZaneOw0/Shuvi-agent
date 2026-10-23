import {
  AgentTaskSnapshot,
  AuthorizationDecision,
  AuthorizationGrant,
  PolicyRequest,
  ToolOutcome,
  TraceEvent
} from '@harmony_agent/agent-contracts';
import { BudgetAmount, BudgetReservationSnapshot, BudgetScopeSnapshot } from '@harmony_agent/agent-core';
import {
  LeaseResult,
  OperationPrepareResult,
  RecoveryLease,
  RetentionResult,
  StorageSnapshotEnvelope,
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

export interface SnapshotIntegrityPort {
  digest(payloadJson: string): string;
}

export interface StorageMigrationPort {
  migrate(source: StorageSnapshotEnvelope): StorageSnapshotEnvelope;
}

export interface TaskRepository {
  saveTask(snapshot: AgentTaskSnapshot, checkpointVersion: string, checkpointJson: string,
    expectedPreviousVersion: number, nowMs: number): StorageWriteResult;
  getTask(taskId: string): StoredTaskSnapshot | undefined;
  listTaskIds(): string[];
}

export interface OperationRepository {
  prepareOperation(intent: StoredOperationIntent, reservation: BudgetReservationSnapshot,
    budgetScopes: BudgetScopeSnapshot[], nowMs: number): OperationPrepareResult;
  markOperationInFlight(operationId: string, ownerId: string, fencingToken: number,
    nowMs: number): StorageWriteResult;
  recordOperationOutcome(operationId: string, outcome: ToolOutcome, actual: BudgetAmount, ownerId: string,
    fencingToken: number, nowMs: number): StorageWriteResult;
  markOperationUnknown(operationId: string, ownerId: string, fencingToken: number,
    nowMs: number): StorageWriteResult;
  reconcileOperation(operationId: string, committed: boolean, outcome: ToolOutcome | undefined,
    actual: BudgetAmount | undefined,
    ownerId: string, fencingToken: number, nowMs: number): StorageWriteResult;
  getOperation(operationId: string): StoredOperation | undefined;
  recoveryCandidates(): StoredOperation[];
}

export interface BudgetRepository {
  saveBudgetAuthority(taskId: string, budgetScopes: BudgetScopeSnapshot[], nowMs: number): StorageWriteResult;
  getBudgetReservation(reservationId: string): StoredBudgetReservation | undefined;
  getBudgetReservations(taskId: string): StoredBudgetReservation[];
  getBudgetScopes(taskId: string): StoredBudgetScope[];
}

export interface TraceRepository {
  appendTrace(event: TraceEvent, sequence: number, timestampMs: number): StorageWriteResult;
  listTrace(taskId: string, afterSequence: number): StoredTraceEvent[];
  pruneTraceBefore(cutoffMs: number, terminalTaskIds: string[]): RetentionResult;
}

export interface RegistryRepository {
  saveRegistryRecord(record: StoredRegistryRecord): StorageWriteResult;
  getRegistryRecord(recordId: string): StoredRegistryRecord | undefined;
}

export interface PolicyRepository {
  savePolicyRequest(request: PolicyRequest, nowMs: number): StorageWriteResult;
  savePolicyDecision(policyRequestId: string, decision: AuthorizationDecision,
    expectedVersion: number, nowMs: number): StorageWriteResult;
  saveAuthorizationGrant(policyRequestId: string, grant: AuthorizationGrant,
    expectedVersion: number, nowMs: number): StorageWriteResult;
  getPolicyRecord(policyRequestId: string): StoredPolicyRecord | undefined;
}

export interface RecoveryLeasePort {
  acquireLease(resourceId: string, ownerId: string, ttlMs: number, nowMs: number): LeaseResult;
  renewLease(resourceId: string, ownerId: string, fencingToken: number,
    ttlMs: number, nowMs: number): LeaseResult;
  releaseLease(resourceId: string, ownerId: string, fencingToken: number): StorageWriteResult;
  getLease(resourceId: string): RecoveryLease | undefined;
}

export interface RecoverySnapshotPort {
  checkpoint(integrity: SnapshotIntegrityPort): StorageSnapshotEnvelope;
}

/**
 * Durable storage boundary for a complete recovery snapshot.
 *
 * The host owns RdbStore creation and lifetime. Implementations must use
 * compare-and-set semantics so two recovery owners cannot both publish from
 * the same durable revision.
 */
export interface DurableSnapshotBackendPort {
  initialize(): Promise<void>;
  load(): Promise<StorageSnapshotEnvelope | undefined>;
  compareAndSet(expectedRevision: number, next: StorageSnapshotEnvelope): Promise<boolean>;
}
