import {
  AgentTaskSnapshot,
  AuthorizationDecision,
  AuthorizationGrant,
  IdempotencyMode,
  PolicyRequest,
  SideEffect,
  ToolOutcome,
  TraceEvent
} from '@harmony_agent/agent-contracts';
import {
  BudgetReservationSnapshot,
  BudgetReservationState,
  BudgetScopeSnapshot,
  OperationJournalState
} from '@harmony_agent/agent-core';

export const AGENT_STORAGE_SCHEMA_VERSION: string = '1.2';

export enum StorageWriteCode {
  CREATED = 'CREATED',
  UPDATED = 'UPDATED',
  UNCHANGED = 'UNCHANGED',
  NOT_FOUND = 'NOT_FOUND',
  INVALID_INPUT = 'INVALID_INPUT',
  VERSION_CONFLICT = 'VERSION_CONFLICT',
  STATE_CONFLICT = 'STATE_CONFLICT',
  LEASE_REQUIRED = 'LEASE_REQUIRED',
  STALE_FENCE = 'STALE_FENCE',
  LEASE_HELD = 'LEASE_HELD',
  CORRUPT_SNAPSHOT = 'CORRUPT_SNAPSHOT',
  UNSUPPORTED_SCHEMA = 'UNSUPPORTED_SCHEMA'
}

export class StorageWriteResult {
  accepted: boolean = false;
  duplicate: boolean = false;
  code: StorageWriteCode = StorageWriteCode.INVALID_INPUT;
}

export class StoredTaskSnapshot {
  taskId: string = '';
  snapshotVersion: number = 0;
  snapshot: AgentTaskSnapshot = new AgentTaskSnapshot();
  checkpointVersion: string = '';
  checkpointJson: string = '';
  updatedAtMs: number = 0;
}

export class StoredOperationIntent {
  operationId: string = '';
  invocationId: string = '';
  taskId: string = '';
  stepId: string = '';
  attemptId: string = '';
  toolId: string = '';
  toolIdentityVersion: string = '';
  schemaDigest: string = '';
  argumentsDigest: string = '';
  idempotencyKey: string = '';
  idempotencyMode: IdempotencyMode = IdempotencyMode.NONE;
  sideEffect: SideEffect = SideEffect.NONE;
  policyRequestId: string = '';
  budgetReservationId: string = '';
  createdAt: string = '';
}

export class StoredOperation {
  intent: StoredOperationIntent = new StoredOperationIntent();
  state: OperationJournalState = OperationJournalState.PREPARED;
  outcome?: ToolOutcome;
  fencingToken: number = 0;
  dispatchCount: number = 0;
  updatedAtMs: number = 0;
}

export class StoredBudgetReservation {
  snapshot: BudgetReservationSnapshot = new BudgetReservationSnapshot();
  updatedAtMs: number = 0;
}

export class StoredBudgetScope {
  snapshot: BudgetScopeSnapshot = new BudgetScopeSnapshot();
  updatedAtMs: number = 0;
}

export class StoredTraceEvent {
  event: TraceEvent = new TraceEvent();
  sequence: number = 0;
  timestampMs: number = 0;
}

export class StoredTraceCursor {
  taskId: string = '';
  lastSequence: number = 0;
}

export class StoredRegistryRecord {
  recordId: string = '';
  recordVersion: string = '';
  recordDigest: string = '';
  payloadJson: string = '{}';
  updatedAtMs: number = 0;
}

export class StoredPolicyRecord {
  policyRequestId: string = '';
  version: number = 0;
  request: PolicyRequest = new PolicyRequest();
  decision?: AuthorizationDecision;
  grant?: AuthorizationGrant;
  updatedAtMs: number = 0;
}

export class RecoveryLease {
  resourceId: string = '';
  ownerId: string = '';
  fencingToken: number = 0;
  expiresAtMs: number = 0;
}

export class LeaseResult extends StorageWriteResult {
  lease?: RecoveryLease;
}

export class RetentionResult {
  removedTraceEvents: number = 0;
}

export class ExecutionStoragePayload {
  tasks: StoredTaskSnapshot[] = [];
  operations: StoredOperation[] = [];
  budgets: StoredBudgetReservation[] = [];
  budgetScopes: StoredBudgetScope[] = [];
  traces: StoredTraceEvent[] = [];
  traceCursors: StoredTraceCursor[] = [];
  registries: StoredRegistryRecord[] = [];
  policies: StoredPolicyRecord[] = [];
  leases: RecoveryLease[] = [];
  nextFencingToken: number = 1;
}

export class StorageSnapshotEnvelope {
  schemaVersion: string = AGENT_STORAGE_SCHEMA_VERSION;
  revision: number = 0;
  payloadJson: string = '';
  payloadDigest: string = '';
}

export class OperationPrepareResult extends StorageWriteResult {
  operation?: StoredOperation;
}

export class OperationRecoveryCandidate {
  operation: StoredOperation = new StoredOperation();
  budgetState: BudgetReservationState = BudgetReservationState.RESERVED;
}
