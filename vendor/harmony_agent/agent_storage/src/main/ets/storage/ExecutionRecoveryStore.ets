import {
  AgentTaskSnapshot,
  AuthorizationDecision,
  AuthorizationDecisionType,
  AuthorizationGrant,
  ContractCodec,
  ContractValidator,
  ExecutionBudget,
  IdempotencyMode,
  PolicyRequest,
  SideEffect,
  ToolOutcome,
  ToolOutcomeStatus,
  TraceEvent
} from '@harmony_agent/agent-contracts';
import {
  BudgetAmount,
  BudgetLedger,
  BudgetReservationSnapshot,
  BudgetReservationState,
  BudgetScopeKind,
  BudgetScopeSnapshot,
  OperationJournalState
} from '@harmony_agent/agent-core';
import {
  BudgetRepository,
  OperationRepository,
  PolicyRepository,
  RecoveryLeasePort,
  RecoverySnapshotPort,
  RegistryRepository,
  SnapshotIntegrityPort,
  StorageMigrationPort,
  TaskRepository,
  TraceRepository
} from './StoragePorts';
import {
  AGENT_STORAGE_SCHEMA_VERSION,
  ExecutionStoragePayload,
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
  StoredTraceCursor,
  StoredTraceEvent
} from './StorageTypes';

export class ExecutionStoreRestoreResult {
  accepted: boolean = false;
  code: StorageWriteCode = StorageWriteCode.CORRUPT_SNAPSHOT;
  store?: ExecutionRecoveryStore;
}

function writeResult(accepted: boolean, duplicate: boolean, code: StorageWriteCode): StorageWriteResult {
  const value: StorageWriteResult = new StorageWriteResult();
  value.accepted = accepted;
  value.duplicate = duplicate;
  value.code = code;
  return value;
}

function leaseResult(accepted: boolean, duplicate: boolean, code: StorageWriteCode,
  lease?: RecoveryLease): LeaseResult {
  const value: LeaseResult = new LeaseResult();
  value.accepted = accepted;
  value.duplicate = duplicate;
  value.code = code;
  value.lease = lease;
  return value;
}

function validText(value: string): boolean {
  return value.trim().length > 0;
}

function validJson(value: string): boolean {
  if (!validText(value)) return false;
  try {
    const parsed: Object = JSON.parse(value) as Object;
    return parsed !== undefined && parsed !== null;
  } catch (error) {
    return false;
  }
}

function validCount(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function validPositiveCount(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

function validBudgetAmount(value: BudgetAmount): boolean {
  return validCount(value.wallTimeMs) && validCount(value.inputTokens) && validCount(value.outputTokens) &&
    validCount(value.monetaryCostMicros) && validCount(value.toolCalls) &&
    validCount(value.agentActivations) && validCount(value.retries) && validCount(value.replans);
}

function copyBudgetAmount(source: BudgetAmount): BudgetAmount {
  const value: BudgetAmount = new BudgetAmount();
  value.wallTimeMs = source.wallTimeMs;
  value.inputTokens = source.inputTokens;
  value.outputTokens = source.outputTokens;
  value.monetaryCostMicros = source.monetaryCostMicros;
  value.toolCalls = source.toolCalls;
  value.agentActivations = source.agentActivations;
  value.retries = source.retries;
  value.replans = source.replans;
  return value;
}

function canSubtractBudget(left: BudgetAmount, right: BudgetAmount): boolean {
  return left.wallTimeMs >= right.wallTimeMs && left.inputTokens >= right.inputTokens &&
    left.outputTokens >= right.outputTokens && left.monetaryCostMicros >= right.monetaryCostMicros &&
    left.toolCalls >= right.toolCalls && left.agentActivations >= right.agentActivations &&
    left.retries >= right.retries && left.replans >= right.replans;
}

function subtractBudget(left: BudgetAmount, right: BudgetAmount): void {
  left.wallTimeMs -= right.wallTimeMs;
  left.inputTokens -= right.inputTokens;
  left.outputTokens -= right.outputTokens;
  left.monetaryCostMicros -= right.monetaryCostMicros;
  left.toolCalls -= right.toolCalls;
  left.agentActivations -= right.agentActivations;
  left.retries -= right.retries;
  left.replans -= right.replans;
}

function addBudget(left: BudgetAmount, right: BudgetAmount): void {
  left.wallTimeMs += right.wallTimeMs;
  left.inputTokens += right.inputTokens;
  left.outputTokens += right.outputTokens;
  left.monetaryCostMicros += right.monetaryCostMicros;
  left.toolCalls += right.toolCalls;
  left.agentActivations += right.agentActivations;
  left.retries += right.retries;
  left.replans += right.replans;
}

function copyBudgetSnapshot(source: BudgetReservationSnapshot): BudgetReservationSnapshot {
  const value: BudgetReservationSnapshot = new BudgetReservationSnapshot();
  value.reservationId = source.reservationId;
  value.taskId = source.taskId;
  value.stepId = source.stepId;
  value.providerId = source.providerId;
  value.requested = copyBudgetAmount(source.requested);
  value.actual = copyBudgetAmount(source.actual);
  value.state = source.state;
  return value;
}

function copyExecutionBudget(source: ExecutionBudget): ExecutionBudget {
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

function copyBudgetScopeSnapshot(source: BudgetScopeSnapshot): BudgetScopeSnapshot {
  const value: BudgetScopeSnapshot = new BudgetScopeSnapshot();
  value.kind = source.kind;
  value.taskId = source.taskId;
  value.scopeId = source.scopeId;
  value.limit = copyExecutionBudget(source.limit);
  value.consumed = copyBudgetAmount(source.consumed);
  value.reserved = copyBudgetAmount(source.reserved);
  return value;
}

function copyIntent(source: StoredOperationIntent): StoredOperationIntent {
  const value: StoredOperationIntent = new StoredOperationIntent();
  value.operationId = source.operationId;
  value.invocationId = source.invocationId;
  value.taskId = source.taskId;
  value.stepId = source.stepId;
  value.attemptId = source.attemptId;
  value.toolId = source.toolId;
  value.toolIdentityVersion = source.toolIdentityVersion;
  value.schemaDigest = source.schemaDigest;
  value.argumentsDigest = source.argumentsDigest;
  value.idempotencyKey = source.idempotencyKey;
  value.idempotencyMode = source.idempotencyMode;
  value.sideEffect = source.sideEffect;
  value.policyRequestId = source.policyRequestId;
  value.budgetReservationId = source.budgetReservationId;
  value.createdAt = source.createdAt;
  return value;
}

function copyOperation(source: StoredOperation): StoredOperation {
  const value: StoredOperation = new StoredOperation();
  value.intent = copyIntent(source.intent);
  value.state = source.state;
  value.outcome = source.outcome === undefined ? undefined :
    ContractCodec.parseToolOutcome(ContractCodec.stringify(source.outcome));
  value.fencingToken = source.fencingToken;
  value.dispatchCount = source.dispatchCount;
  value.updatedAtMs = source.updatedAtMs;
  return value;
}

function copyStoredBudget(source: StoredBudgetReservation): StoredBudgetReservation {
  const value: StoredBudgetReservation = new StoredBudgetReservation();
  value.snapshot = copyBudgetSnapshot(source.snapshot);
  value.updatedAtMs = source.updatedAtMs;
  return value;
}

function copyStoredBudgetScope(source: StoredBudgetScope): StoredBudgetScope {
  const value: StoredBudgetScope = new StoredBudgetScope();
  value.snapshot = copyBudgetScopeSnapshot(source.snapshot);
  value.updatedAtMs = source.updatedAtMs;
  return value;
}

function copyLease(source: RecoveryLease): RecoveryLease {
  const value: RecoveryLease = new RecoveryLease();
  value.resourceId = source.resourceId;
  value.ownerId = source.ownerId;
  value.fencingToken = source.fencingToken;
  value.expiresAtMs = source.expiresAtMs;
  return value;
}

function copyTask(source: StoredTaskSnapshot): StoredTaskSnapshot {
  const value: StoredTaskSnapshot = new StoredTaskSnapshot();
  value.taskId = source.taskId;
  value.snapshotVersion = source.snapshotVersion;
  value.snapshot = ContractCodec.parseAgentTaskSnapshot(ContractCodec.stringify(source.snapshot));
  value.checkpointVersion = source.checkpointVersion;
  value.checkpointJson = source.checkpointJson;
  value.updatedAtMs = source.updatedAtMs;
  return value;
}

function copyTrace(source: StoredTraceEvent): StoredTraceEvent {
  const value: StoredTraceEvent = new StoredTraceEvent();
  value.event = ContractCodec.parseTraceEvent(ContractCodec.stringify(source.event));
  value.sequence = source.sequence;
  value.timestampMs = source.timestampMs;
  return value;
}

function copyTraceCursor(source: StoredTraceCursor): StoredTraceCursor {
  const value: StoredTraceCursor = new StoredTraceCursor();
  value.taskId = source.taskId;
  value.lastSequence = source.lastSequence;
  return value;
}

function copyRegistry(source: StoredRegistryRecord): StoredRegistryRecord {
  const value: StoredRegistryRecord = new StoredRegistryRecord();
  value.recordId = source.recordId;
  value.recordVersion = source.recordVersion;
  value.recordDigest = source.recordDigest;
  value.payloadJson = source.payloadJson;
  value.updatedAtMs = source.updatedAtMs;
  return value;
}

function copyPolicy(source: StoredPolicyRecord): StoredPolicyRecord {
  const value: StoredPolicyRecord = new StoredPolicyRecord();
  value.policyRequestId = source.policyRequestId;
  value.version = source.version;
  value.request = ContractCodec.parsePolicyRequest(ContractCodec.stringify(source.request));
  value.decision = source.decision === undefined ? undefined :
    ContractCodec.parseAuthorizationDecision(ContractCodec.stringify(source.decision));
  value.grant = source.grant === undefined ? undefined :
    ContractCodec.parseAuthorizationGrant(ContractCodec.stringify(source.grant));
  value.updatedAtMs = source.updatedAtMs;
  return value;
}

function validIntent(value: StoredOperationIntent): boolean {
  return validText(value.operationId) && validText(value.invocationId) && validText(value.taskId) &&
    validText(value.stepId) && validText(value.attemptId) && validText(value.toolId) &&
    validText(value.toolIdentityVersion) && validText(value.schemaDigest) &&
    validText(value.argumentsDigest) && validText(value.idempotencyKey) && validText(value.policyRequestId) &&
    validText(value.budgetReservationId) && validText(value.createdAt) &&
    (value.idempotencyMode === IdempotencyMode.NONE || value.idempotencyMode === IdempotencyMode.PROVIDER_KEY ||
    value.idempotencyMode === IdempotencyMode.RECONCILE) &&
    (value.sideEffect === SideEffect.NONE || value.sideEffect === SideEffect.REVERSIBLE ||
    value.sideEffect === SideEffect.IRREVERSIBLE) &&
    (value.sideEffect === SideEffect.NONE || value.idempotencyMode !== IdempotencyMode.NONE);
}

function validReservation(value: BudgetReservationSnapshot): boolean {
  return validText(value.reservationId) && validText(value.taskId) && validText(value.stepId) &&
    validText(value.providerId) && validBudgetAmount(value.requested) && validBudgetAmount(value.actual);
}

function validExecutionBudget(value: ExecutionBudget): boolean {
  return validCount(value.maxWallTimeMs) && validCount(value.maxInputTokens) &&
    validCount(value.maxOutputTokens) && validCount(value.maxMonetaryCostMicros) &&
    validCount(value.maxToolCalls) && validCount(value.maxAgentActivations) &&
    validCount(value.maxRetries) && validCount(value.maxReplans);
}

function validBudgetScope(value: BudgetScopeSnapshot): boolean {
  return validText(value.taskId) && validText(value.scopeId) && validExecutionBudget(value.limit) &&
    validBudgetAmount(value.consumed) && validBudgetAmount(value.reserved) &&
    (value.kind === BudgetScopeKind.TASK || value.kind === BudgetScopeKind.STEP ||
    value.kind === BudgetScopeKind.PROVIDER);
}

function sameScopeIdentity(left: BudgetScopeSnapshot, right: BudgetScopeSnapshot): boolean {
  return left.kind === right.kind && left.taskId === right.taskId && left.scopeId === right.scopeId;
}

function sameScopeDefinition(left: BudgetScopeSnapshot, right: BudgetScopeSnapshot): boolean {
  return sameScopeIdentity(left, right) && JSON.stringify(left.limit) === JSON.stringify(right.limit);
}

function validBudgetAuthority(taskId: string, scopes: BudgetScopeSnapshot[],
  reservations: BudgetReservationSnapshot[]): boolean {
  if (!validText(taskId) || scopes.length === 0) return false;
  let taskScope: BudgetScopeSnapshot | undefined;
  for (let i: number = 0; i < scopes.length; i++) {
    if (!validBudgetScope(scopes[i]) || scopes[i].taskId !== taskId) return false;
    if (scopes[i].kind === BudgetScopeKind.TASK) {
      if (taskScope !== undefined || scopes[i].scopeId !== taskId) return false;
      taskScope = scopes[i];
    }
  }
  if (taskScope === undefined) return false;
  try {
    const ledger: BudgetLedger = new BudgetLedger();
    ledger.registerTask(taskId, taskScope.limit);
    for (let i: number = 0; i < scopes.length; i++) {
      if (scopes[i].kind === BudgetScopeKind.STEP) {
        ledger.registerStep(taskId, scopes[i].scopeId, scopes[i].limit);
      } else if (scopes[i].kind === BudgetScopeKind.PROVIDER) {
        ledger.registerProvider(taskId, scopes[i].scopeId, scopes[i].limit);
      }
    }
    return ledger.hydrateTask(taskId, scopes, reservations);
  } catch (error) {
    return false;
  }
}

function validOperationPolicyBinding(intent: StoredOperationIntent, reservation: BudgetReservationSnapshot,
  policy: StoredPolicyRecord | undefined): boolean {
  if (policy === undefined || policy.version !== 3 || policy.grant === undefined || policy.decision === undefined ||
    policy.policyRequestId !== intent.policyRequestId || policy.request.requestId !== intent.policyRequestId ||
    policy.request.taskId !== intent.taskId || policy.request.stepId !== intent.stepId ||
    policy.request.operationId !== intent.operationId || policy.request.toolId !== intent.toolId ||
    policy.request.toolIdentityVersion !== intent.toolIdentityVersion ||
    policy.request.schemaDigest !== intent.schemaDigest || policy.request.argumentsDigest !== intent.argumentsDigest ||
    policy.request.sideEffect !== intent.sideEffect || policy.request.providerId !== reservation.providerId ||
    policy.grant.policyRequestId !== intent.policyRequestId || policy.grant.taskId !== intent.taskId ||
    policy.grant.stepId !== intent.stepId || policy.grant.operationId !== intent.operationId ||
    policy.grant.toolId !== intent.toolId || policy.grant.toolIdentityVersion !== intent.toolIdentityVersion ||
    policy.grant.schemaDigest !== intent.schemaDigest || policy.grant.argumentsDigest !== intent.argumentsDigest ||
    policy.grant.budgetReservationId !== reservation.reservationId) return false;
  return true;
}

export class StorageSnapshotCodec {
  static encode(value: StorageSnapshotEnvelope): string {
    return JSON.stringify(value);
  }

  static decode(json: string): StorageSnapshotEnvelope | undefined {
    try {
      const parsed: StorageSnapshotEnvelope = JSON.parse(json) as StorageSnapshotEnvelope;
      if (!validText(parsed.schemaVersion) || !validCount(parsed.revision) ||
        !validText(parsed.payloadJson) || !validText(parsed.payloadDigest)) {
        return undefined;
      }
      const value: StorageSnapshotEnvelope = new StorageSnapshotEnvelope();
      value.schemaVersion = parsed.schemaVersion;
      value.revision = parsed.revision;
      value.payloadJson = parsed.payloadJson;
      value.payloadDigest = parsed.payloadDigest;
      return value;
    } catch (error) {
      return undefined;
    }
  }
}

export class ExecutionRecoveryStore implements TaskRepository, OperationRepository, BudgetRepository,
  TraceRepository, RegistryRepository, PolicyRepository, RecoveryLeasePort, RecoverySnapshotPort {
  private tasks: StoredTaskSnapshot[] = [];
  private operations: StoredOperation[] = [];
  private budgets: StoredBudgetReservation[] = [];
  private budgetScopes: StoredBudgetScope[] = [];
  private traces: StoredTraceEvent[] = [];
  private traceCursors: StoredTraceCursor[] = [];
  private registries: StoredRegistryRecord[] = [];
  private policies: StoredPolicyRecord[] = [];
  private leases: RecoveryLease[] = [];
  private nextFencingToken: number = 1;
  private revision: number = 0;

  saveTask(snapshot: AgentTaskSnapshot, checkpointVersion: string, checkpointJson: string,
    expectedPreviousVersion: number, nowMs: number): StorageWriteResult {
    if (!ContractValidator.validateAgentTaskSnapshot(snapshot).valid || !validCount(expectedPreviousVersion) ||
      !validCount(nowMs) || !validText(checkpointVersion) || !validJson(checkpointJson)) {
      return writeResult(false, false, StorageWriteCode.INVALID_INPUT);
    }
    const index: number = this.findTask(snapshot.taskId);
    if (index < 0 && (expectedPreviousVersion !== 0 || snapshot.snapshotVersion !== 1)) {
      return writeResult(false, false, StorageWriteCode.VERSION_CONFLICT);
    }
    if (index >= 0) {
      const current: StoredTaskSnapshot = this.tasks[index];
      if (current.snapshotVersion === snapshot.snapshotVersion &&
        ContractCodec.stringify(current.snapshot) === ContractCodec.stringify(snapshot) &&
        current.checkpointVersion === checkpointVersion && current.checkpointJson === checkpointJson) {
        return writeResult(true, true, StorageWriteCode.UNCHANGED);
      }
      if (current.snapshotVersion !== expectedPreviousVersion ||
        snapshot.snapshotVersion !== expectedPreviousVersion + 1) {
        return writeResult(false, false, StorageWriteCode.VERSION_CONFLICT);
      }
    }
    const value: StoredTaskSnapshot = new StoredTaskSnapshot();
    value.taskId = snapshot.taskId;
    value.snapshotVersion = snapshot.snapshotVersion;
    value.snapshot = ContractCodec.parseAgentTaskSnapshot(ContractCodec.stringify(snapshot));
    value.checkpointVersion = checkpointVersion;
    value.checkpointJson = checkpointJson;
    value.updatedAtMs = nowMs;
    const next: StoredTaskSnapshot[] = this.tasks.slice();
    if (index < 0) next.push(value); else next[index] = value;
    this.tasks = next;
    this.revision++;
    return writeResult(true, false, index < 0 ? StorageWriteCode.CREATED : StorageWriteCode.UPDATED);
  }

  getTask(taskId: string): StoredTaskSnapshot | undefined {
    const index: number = this.findTask(taskId);
    return index < 0 ? undefined : copyTask(this.tasks[index]);
  }

  listTaskIds(): string[] {
    const values: string[] = [];
    for (let i: number = 0; i < this.tasks.length; i++) values.push(this.tasks[i].taskId);
    return values;
  }

  saveBudgetAuthority(taskId: string, budgetScopes: BudgetScopeSnapshot[], nowMs: number): StorageWriteResult {
    if (!validCount(nowMs)) return writeResult(false, false, StorageWriteCode.INVALID_INPUT);
    const reservations: BudgetReservationSnapshot[] = this.budgetSnapshotsForTask(taskId);
    if (!validBudgetAuthority(taskId, budgetScopes, reservations) ||
      !this.preservesBudgetScopeDefinitions(taskId, budgetScopes)) {
      return writeResult(false, false, StorageWriteCode.INVALID_INPUT);
    }
    const current: BudgetScopeSnapshot[] = this.budgetScopeSnapshotsForTask(taskId);
    if (JSON.stringify(current) === JSON.stringify(budgetScopes)) {
      return writeResult(true, true, StorageWriteCode.UNCHANGED);
    }
    this.budgetScopes = this.replacedBudgetScopes(taskId, budgetScopes, nowMs);
    this.revision++;
    return writeResult(true, false, current.length === 0 ? StorageWriteCode.CREATED : StorageWriteCode.UPDATED);
  }

  prepareOperation(intent: StoredOperationIntent, reservation: BudgetReservationSnapshot,
    budgetScopes: BudgetScopeSnapshot[], nowMs: number): OperationPrepareResult {
    const result: OperationPrepareResult = new OperationPrepareResult();
    if (!validIntent(intent) || !validReservation(reservation) || !validCount(nowMs) ||
      reservation.state !== BudgetReservationState.RESERVED ||
      reservation.reservationId !== intent.budgetReservationId || reservation.taskId !== intent.taskId ||
      reservation.stepId !== intent.stepId ||
      !validOperationPolicyBinding(intent, reservation, this.policyFor(intent.policyRequestId))) {
      result.code = StorageWriteCode.INVALID_INPUT;
      return result;
    }
    const operationIndex: number = this.findOperation(intent.operationId);
    const budgetIndex: number = this.findBudget(reservation.reservationId);
    if (operationIndex >= 0 || budgetIndex >= 0) {
      if (operationIndex >= 0 && budgetIndex >= 0 &&
        ContractCodec.stringify(this.operations[operationIndex].intent) === ContractCodec.stringify(intent) &&
        ContractCodec.stringify(this.budgets[budgetIndex].snapshot) === ContractCodec.stringify(reservation) &&
        JSON.stringify(this.budgetScopeSnapshotsForTask(intent.taskId)) === JSON.stringify(budgetScopes)) {
        result.accepted = true;
        result.duplicate = true;
        result.code = StorageWriteCode.UNCHANGED;
        result.operation = copyOperation(this.operations[operationIndex]);
        return result;
      }
      result.code = StorageWriteCode.VERSION_CONFLICT;
      return result;
    }
    const authorityReservations: BudgetReservationSnapshot[] = this.budgetSnapshotsForTask(intent.taskId);
    authorityReservations.push(copyBudgetSnapshot(reservation));
    if (!validBudgetAuthority(intent.taskId, budgetScopes, authorityReservations) ||
      !this.preservesBudgetScopeDefinitions(intent.taskId, budgetScopes)) {
      result.code = StorageWriteCode.INVALID_INPUT;
      return result;
    }
    const operation: StoredOperation = new StoredOperation();
    operation.intent = copyIntent(intent);
    operation.state = OperationJournalState.PREPARED;
    operation.updatedAtMs = nowMs;
    const storedBudget: StoredBudgetReservation = new StoredBudgetReservation();
    storedBudget.snapshot = copyBudgetSnapshot(reservation);
    storedBudget.updatedAtMs = nowMs;
    const nextOperations: StoredOperation[] = this.operations.slice();
    const nextBudgets: StoredBudgetReservation[] = this.budgets.slice();
    nextOperations.push(operation);
    nextBudgets.push(storedBudget);
    this.operations = nextOperations;
    this.budgets = nextBudgets;
    this.budgetScopes = this.replacedBudgetScopes(intent.taskId, budgetScopes, nowMs);
    this.revision++;
    result.accepted = true;
    result.code = StorageWriteCode.CREATED;
    result.operation = copyOperation(operation);
    return result;
  }

  markOperationInFlight(operationId: string, ownerId: string, fencingToken: number,
    nowMs: number): StorageWriteResult {
    const index: number = this.findOperation(operationId);
    if (index < 0) return writeResult(false, false, StorageWriteCode.NOT_FOUND);
    const operation: StoredOperation = this.operations[index];
    const leaseCode: StorageWriteCode = this.validateLease(operation.intent.taskId, ownerId, fencingToken, nowMs);
    if (leaseCode !== StorageWriteCode.UNCHANGED) return writeResult(false, false, leaseCode);
    if (operation.state !== OperationJournalState.PREPARED) {
      return writeResult(false, false, StorageWriteCode.STATE_CONFLICT);
    }
    operation.state = OperationJournalState.IN_FLIGHT;
    operation.fencingToken = fencingToken;
    operation.dispatchCount++;
    operation.updatedAtMs = nowMs;
    this.revision++;
    return writeResult(true, false, StorageWriteCode.UPDATED);
  }

  recordOperationOutcome(operationId: string, outcome: ToolOutcome, actual: BudgetAmount, ownerId: string,
    fencingToken: number, nowMs: number): StorageWriteResult {
    const index: number = this.findOperation(operationId);
    if (index < 0) return writeResult(false, false, StorageWriteCode.NOT_FOUND);
    const operation: StoredOperation = this.operations[index];
    if (operation.state === OperationJournalState.COMMITTED && operation.outcome !== undefined &&
      ContractCodec.stringify(operation.outcome) === ContractCodec.stringify(outcome)) {
      return writeResult(true, true, StorageWriteCode.UNCHANGED);
    }
    const leaseCode: StorageWriteCode = this.validateLease(operation.intent.taskId, ownerId, fencingToken, nowMs);
    if (leaseCode !== StorageWriteCode.UNCHANGED) return writeResult(false, false, leaseCode);
    if (operation.state !== OperationJournalState.IN_FLIGHT ||
      !ContractValidator.validateToolOutcome(outcome).valid ||
      !validBudgetAmount(actual) ||
      outcome.invocationId !== operation.intent.invocationId ||
      outcome.status === ToolOutcomeStatus.UNKNOWN_OUTCOME) {
      return writeResult(false, false, StorageWriteCode.STATE_CONFLICT);
    }
    const budget: StoredBudgetReservation = this.requireBudget(operation.intent.budgetReservationId);
    if (!this.settleBudgetAuthority(budget.snapshot, actual, nowMs)) {
      return writeResult(false, false, StorageWriteCode.STATE_CONFLICT);
    }
    operation.state = OperationJournalState.COMMITTED;
    operation.outcome = ContractCodec.parseToolOutcome(ContractCodec.stringify(outcome));
    operation.updatedAtMs = nowMs;
    budget.snapshot.actual = copyBudgetAmount(actual);
    budget.snapshot.state = BudgetReservationState.SETTLED;
    budget.updatedAtMs = nowMs;
    this.revision++;
    return writeResult(true, false, StorageWriteCode.UPDATED);
  }

  markOperationUnknown(operationId: string, ownerId: string, fencingToken: number,
    nowMs: number): StorageWriteResult {
    const index: number = this.findOperation(operationId);
    if (index < 0) return writeResult(false, false, StorageWriteCode.NOT_FOUND);
    const operation: StoredOperation = this.operations[index];
    const leaseCode: StorageWriteCode = this.validateLease(operation.intent.taskId, ownerId, fencingToken, nowMs);
    if (leaseCode !== StorageWriteCode.UNCHANGED) return writeResult(false, false, leaseCode);
    if (operation.state !== OperationJournalState.IN_FLIGHT) {
      return writeResult(false, false, StorageWriteCode.STATE_CONFLICT);
    }
    operation.state = OperationJournalState.UNKNOWN_OUTCOME;
    operation.updatedAtMs = nowMs;
    const budget: StoredBudgetReservation = this.requireBudget(operation.intent.budgetReservationId);
    budget.snapshot.state = BudgetReservationState.UNKNOWN;
    budget.updatedAtMs = nowMs;
    this.revision++;
    return writeResult(true, false, StorageWriteCode.UPDATED);
  }

  /**
   * Normalizes a persisted active operation during startup recovery. The
   * enclosing durable transaction must validate the checkpoint and lease
   * binding before calling this method; backend CAS provides the final fence.
   */
  normalizeOperationForRecovery(operationId: string, fencingToken: number,
    nowMs: number): StorageWriteResult {
    const index: number = this.findOperation(operationId);
    if (index < 0) return writeResult(false, false, StorageWriteCode.NOT_FOUND);
    if (!validPositiveCount(fencingToken) || !validCount(nowMs)) {
      return writeResult(false, false, StorageWriteCode.INVALID_INPUT);
    }
    const operation: StoredOperation = this.operations[index];
    const budget: StoredBudgetReservation = this.requireBudget(operation.intent.budgetReservationId);
    if (operation.state === OperationJournalState.UNKNOWN_OUTCOME &&
      operation.fencingToken === fencingToken && budget.snapshot.state === BudgetReservationState.UNKNOWN) {
      return writeResult(true, true, StorageWriteCode.UNCHANGED);
    }
    if ((operation.state !== OperationJournalState.IN_FLIGHT &&
      operation.state !== OperationJournalState.UNKNOWN_OUTCOME) ||
      (budget.snapshot.state !== BudgetReservationState.RESERVED &&
        budget.snapshot.state !== BudgetReservationState.UNKNOWN)) {
      return writeResult(false, false, StorageWriteCode.STATE_CONFLICT);
    }
    operation.state = OperationJournalState.UNKNOWN_OUTCOME;
    operation.fencingToken = fencingToken;
    operation.updatedAtMs = nowMs;
    budget.snapshot.state = BudgetReservationState.UNKNOWN;
    budget.updatedAtMs = nowMs;
    this.revision++;
    return writeResult(true, false, StorageWriteCode.UPDATED);
  }

  reconcileOperation(operationId: string, committed: boolean, outcome: ToolOutcome | undefined,
    actual: BudgetAmount | undefined,
    ownerId: string, fencingToken: number, nowMs: number): StorageWriteResult {
    const index: number = this.findOperation(operationId);
    if (index < 0) return writeResult(false, false, StorageWriteCode.NOT_FOUND);
    const operation: StoredOperation = this.operations[index];
    const leaseCode: StorageWriteCode = this.validateLease(operation.intent.taskId, ownerId, fencingToken, nowMs);
    if (leaseCode !== StorageWriteCode.UNCHANGED) return writeResult(false, false, leaseCode);
    if (operation.state !== OperationJournalState.UNKNOWN_OUTCOME ||
      (committed && (outcome === undefined || outcome.invocationId !== operation.intent.invocationId ||
        actual === undefined || !validBudgetAmount(actual) ||
        !ContractValidator.validateToolOutcome(outcome).valid || outcome.status === ToolOutcomeStatus.UNKNOWN_OUTCOME)) ||
      (!committed && (outcome !== undefined || actual !== undefined))) {
      return writeResult(false, false, StorageWriteCode.STATE_CONFLICT);
    }
    const budget: StoredBudgetReservation = this.requireBudget(operation.intent.budgetReservationId);
    if (committed) {
      if (!this.settleBudgetAuthority(budget.snapshot, actual as BudgetAmount, nowMs)) {
        return writeResult(false, false, StorageWriteCode.STATE_CONFLICT);
      }
      operation.state = OperationJournalState.COMMITTED;
      operation.outcome = ContractCodec.parseToolOutcome(ContractCodec.stringify(outcome as ToolOutcome));
      budget.snapshot.actual = copyBudgetAmount(actual as BudgetAmount);
      budget.snapshot.state = BudgetReservationState.SETTLED;
    } else {
      operation.state = OperationJournalState.PREPARED;
      operation.outcome = undefined;
      operation.fencingToken = 0;
      budget.snapshot.state = BudgetReservationState.RESERVED;
      budget.snapshot.actual = new BudgetAmount();
    }
    operation.updatedAtMs = nowMs;
    budget.updatedAtMs = nowMs;
    this.revision++;
    return writeResult(true, false, StorageWriteCode.UPDATED);
  }

  getOperation(operationId: string): StoredOperation | undefined {
    const index: number = this.findOperation(operationId);
    return index < 0 ? undefined : copyOperation(this.operations[index]);
  }

  recoveryCandidates(): StoredOperation[] {
    const values: StoredOperation[] = [];
    for (let i: number = 0; i < this.operations.length; i++) {
      if (this.operations[i].state === OperationJournalState.PREPARED ||
        this.operations[i].state === OperationJournalState.UNKNOWN_OUTCOME) {
        values.push(copyOperation(this.operations[i]));
      }
    }
    return values;
  }

  getBudgetReservation(reservationId: string): StoredBudgetReservation | undefined {
    const index: number = this.findBudget(reservationId);
    return index < 0 ? undefined : copyStoredBudget(this.budgets[index]);
  }

  getBudgetReservations(taskId: string): StoredBudgetReservation[] {
    const values: StoredBudgetReservation[] = [];
    for (let i: number = 0; i < this.budgets.length; i++) {
      if (this.budgets[i].snapshot.taskId === taskId) {
        values.push(copyStoredBudget(this.budgets[i]));
      }
    }
    return values;
  }

  getBudgetScopes(taskId: string): StoredBudgetScope[] {
    const values: StoredBudgetScope[] = [];
    for (let i: number = 0; i < this.budgetScopes.length; i++) {
      if (this.budgetScopes[i].snapshot.taskId === taskId) {
        values.push(copyStoredBudgetScope(this.budgetScopes[i]));
      }
    }
    return values;
  }

  appendTrace(event: TraceEvent, sequence: number, timestampMs: number): StorageWriteResult {
    if (!ContractValidator.validateTraceEvent(event).valid || !validPositiveCount(sequence) ||
      !validCount(timestampMs)) {
      return writeResult(false, false, StorageWriteCode.INVALID_INPUT);
    }
    for (let i: number = 0; i < this.traces.length; i++) {
      if (this.traces[i].event.eventId === event.eventId) {
        if (this.traces[i].sequence === sequence &&
          ContractCodec.stringify(this.traces[i].event) === ContractCodec.stringify(event)) {
          return writeResult(true, true, StorageWriteCode.UNCHANGED);
        }
        return writeResult(false, false, StorageWriteCode.VERSION_CONFLICT);
      }
    }
    const cursorIndex: number = this.findTraceCursor(event.taskId);
    const expected: number = cursorIndex < 0 ? 1 : this.traceCursors[cursorIndex].lastSequence + 1;
    if (sequence !== expected) return writeResult(false, false, StorageWriteCode.VERSION_CONFLICT);
    const stored: StoredTraceEvent = new StoredTraceEvent();
    stored.event = ContractCodec.parseTraceEvent(ContractCodec.stringify(event));
    stored.sequence = sequence;
    stored.timestampMs = timestampMs;
    const next: StoredTraceEvent[] = this.traces.slice();
    next.push(stored);
    this.traces = next;
    if (cursorIndex < 0) {
      const cursor: StoredTraceCursor = new StoredTraceCursor();
      cursor.taskId = event.taskId;
      cursor.lastSequence = sequence;
      const cursors: StoredTraceCursor[] = this.traceCursors.slice();
      cursors.push(cursor);
      this.traceCursors = cursors;
    } else {
      this.traceCursors[cursorIndex].lastSequence = sequence;
    }
    this.revision++;
    return writeResult(true, false, StorageWriteCode.CREATED);
  }

  listTrace(taskId: string, afterSequence: number): StoredTraceEvent[] {
    const values: StoredTraceEvent[] = [];
    for (let i: number = 0; i < this.traces.length; i++) {
      if (this.traces[i].event.taskId === taskId && this.traces[i].sequence > afterSequence) {
        values.push(copyTrace(this.traces[i]));
      }
    }
    return values;
  }

  pruneTraceBefore(cutoffMs: number, terminalTaskIds: string[]): RetentionResult {
    const result: RetentionResult = new RetentionResult();
    if (!validCount(cutoffMs)) return result;
    const kept: StoredTraceEvent[] = [];
    for (let i: number = 0; i < this.traces.length; i++) {
      if (this.traces[i].timestampMs < cutoffMs && includesText(terminalTaskIds, this.traces[i].event.taskId)) {
        result.removedTraceEvents++;
      } else {
        kept.push(this.traces[i]);
      }
    }
    if (result.removedTraceEvents > 0) {
      this.traces = kept;
      this.revision++;
    }
    return result;
  }

  saveRegistryRecord(record: StoredRegistryRecord): StorageWriteResult {
    if (!validText(record.recordId) || !validText(record.recordVersion) || !validText(record.recordDigest) ||
      !validText(record.payloadJson) || !validCount(record.updatedAtMs)) {
      return writeResult(false, false, StorageWriteCode.INVALID_INPUT);
    }
    const index: number = this.findRegistry(record.recordId);
    if (index >= 0 && this.registries[index].recordVersion === record.recordVersion) {
      if (this.registries[index].recordDigest === record.recordDigest &&
        this.registries[index].payloadJson === record.payloadJson) {
        return writeResult(true, true, StorageWriteCode.UNCHANGED);
      }
      return writeResult(false, false, StorageWriteCode.VERSION_CONFLICT);
    }
    const next: StoredRegistryRecord[] = this.registries.slice();
    if (index < 0) next.push(copyRegistry(record)); else next[index] = copyRegistry(record);
    this.registries = next;
    this.revision++;
    return writeResult(true, false, index < 0 ? StorageWriteCode.CREATED : StorageWriteCode.UPDATED);
  }

  getRegistryRecord(recordId: string): StoredRegistryRecord | undefined {
    const index: number = this.findRegistry(recordId);
    return index < 0 ? undefined : copyRegistry(this.registries[index]);
  }

  savePolicyRequest(request: PolicyRequest, nowMs: number): StorageWriteResult {
    if (!ContractValidator.validatePolicyRequest(request).valid || !validCount(nowMs)) {
      return writeResult(false, false, StorageWriteCode.INVALID_INPUT);
    }
    const index: number = this.findPolicy(request.requestId);
    if (index >= 0) {
      if (ContractCodec.stringify(this.policies[index].request) === ContractCodec.stringify(request)) {
        return writeResult(true, true, StorageWriteCode.UNCHANGED);
      }
      return writeResult(false, false, StorageWriteCode.VERSION_CONFLICT);
    }
    const value: StoredPolicyRecord = new StoredPolicyRecord();
    value.policyRequestId = request.requestId;
    value.version = 1;
    value.request = ContractCodec.parsePolicyRequest(ContractCodec.stringify(request));
    value.updatedAtMs = nowMs;
    const next: StoredPolicyRecord[] = this.policies.slice();
    next.push(value);
    this.policies = next;
    this.revision++;
    return writeResult(true, false, StorageWriteCode.CREATED);
  }

  savePolicyDecision(policyRequestId: string, decision: AuthorizationDecision,
    expectedVersion: number, nowMs: number): StorageWriteResult {
    const index: number = this.findPolicy(policyRequestId);
    if (index < 0) return writeResult(false, false, StorageWriteCode.NOT_FOUND);
    const value: StoredPolicyRecord = this.policies[index];
    if (!ContractValidator.validateAuthorizationDecision(decision).valid || !validCount(nowMs) ||
      value.request.taskId !== decision.taskId || value.request.userId !== decision.userId ||
      value.request.requestId !== decision.policyRequestId) {
      return writeResult(false, false, StorageWriteCode.INVALID_INPUT);
    }
    if (value.decision !== undefined && ContractCodec.stringify(value.decision) === ContractCodec.stringify(decision)) {
      return writeResult(true, true, StorageWriteCode.UNCHANGED);
    }
    if (value.version !== expectedVersion || value.decision !== undefined) {
      return writeResult(false, false, StorageWriteCode.VERSION_CONFLICT);
    }
    value.decision = ContractCodec.parseAuthorizationDecision(ContractCodec.stringify(decision));
    value.version++;
    value.updatedAtMs = nowMs;
    this.revision++;
    return writeResult(true, false, StorageWriteCode.UPDATED);
  }

  saveAuthorizationGrant(policyRequestId: string, grant: AuthorizationGrant,
    expectedVersion: number, nowMs: number): StorageWriteResult {
    const index: number = this.findPolicy(policyRequestId);
    if (index < 0) return writeResult(false, false, StorageWriteCode.NOT_FOUND);
    const value: StoredPolicyRecord = this.policies[index];
    if (!ContractValidator.validateAuthorizationGrant(grant).valid || !validCount(nowMs) ||
      grant.policyRequestId !== policyRequestId || grant.taskId !== value.request.taskId ||
      grant.userId !== value.request.userId || grant.stepId !== value.request.stepId ||
      grant.operationId !== value.request.operationId || grant.toolId !== value.request.toolId ||
      grant.toolIdentityVersion !== value.request.toolIdentityVersion ||
      grant.argumentsDigest !== value.request.argumentsDigest || grant.schemaDigest !== value.request.schemaDigest) {
      return writeResult(false, false, StorageWriteCode.INVALID_INPUT);
    }
    if (value.grant !== undefined && ContractCodec.stringify(value.grant) === ContractCodec.stringify(grant)) {
      return writeResult(true, true, StorageWriteCode.UNCHANGED);
    }
    if (value.version !== expectedVersion || value.decision === undefined ||
      value.decision.decision !== AuthorizationDecisionType.APPROVED || value.grant !== undefined) {
      return writeResult(false, false, StorageWriteCode.VERSION_CONFLICT);
    }
    if (grant.decisionCommandId !== value.decision.commandId) {
      return writeResult(false, false, StorageWriteCode.INVALID_INPUT);
    }
    value.grant = ContractCodec.parseAuthorizationGrant(ContractCodec.stringify(grant));
    value.version++;
    value.updatedAtMs = nowMs;
    this.revision++;
    return writeResult(true, false, StorageWriteCode.UPDATED);
  }

  getPolicyRecord(policyRequestId: string): StoredPolicyRecord | undefined {
    const index: number = this.findPolicy(policyRequestId);
    return index < 0 ? undefined : copyPolicy(this.policies[index]);
  }

  acquireLease(resourceId: string, ownerId: string, ttlMs: number, nowMs: number): LeaseResult {
    if (!validText(resourceId) || !validText(ownerId) || !validPositiveCount(ttlMs) || !validCount(nowMs) ||
      !Number.isSafeInteger(nowMs + ttlMs) || !validPositiveCount(this.nextFencingToken) ||
      !Number.isSafeInteger(this.nextFencingToken + 1)) {
      return leaseResult(false, false, StorageWriteCode.INVALID_INPUT);
    }
    const index: number = this.findLease(resourceId);
    if (index >= 0 && this.leases[index].expiresAtMs > nowMs) {
      return leaseResult(false, false, StorageWriteCode.LEASE_HELD, copyLease(this.leases[index]));
    }
    const lease: RecoveryLease = new RecoveryLease();
    lease.resourceId = resourceId;
    lease.ownerId = ownerId;
    lease.fencingToken = this.nextFencingToken;
    lease.expiresAtMs = nowMs + ttlMs;
    this.nextFencingToken++;
    const next: RecoveryLease[] = this.leases.slice();
    if (index < 0) next.push(lease); else next[index] = lease;
    this.leases = next;
    this.revision++;
    return leaseResult(true, false, index < 0 ? StorageWriteCode.CREATED : StorageWriteCode.UPDATED,
      copyLease(lease));
  }

  renewLease(resourceId: string, ownerId: string, fencingToken: number,
    ttlMs: number, nowMs: number): LeaseResult {
    const index: number = this.findLease(resourceId);
    if (index < 0) return leaseResult(false, false, StorageWriteCode.NOT_FOUND);
    const lease: RecoveryLease = this.leases[index];
    if (!validPositiveCount(ttlMs) || !validCount(nowMs) || !Number.isSafeInteger(nowMs + ttlMs) ||
      lease.ownerId !== ownerId || lease.fencingToken !== fencingToken || lease.expiresAtMs <= nowMs) {
      return leaseResult(false, false, StorageWriteCode.STALE_FENCE);
    }
    lease.expiresAtMs = nowMs + ttlMs;
    this.revision++;
    return leaseResult(true, false, StorageWriteCode.UPDATED, copyLease(lease));
  }

  releaseLease(resourceId: string, ownerId: string, fencingToken: number): StorageWriteResult {
    const index: number = this.findLease(resourceId);
    if (index < 0) return writeResult(false, false, StorageWriteCode.NOT_FOUND);
    if (this.leases[index].ownerId !== ownerId || this.leases[index].fencingToken !== fencingToken) {
      return writeResult(false, false, StorageWriteCode.STALE_FENCE);
    }
    const next: RecoveryLease[] = [];
    for (let i: number = 0; i < this.leases.length; i++) {
      if (i !== index) next.push(this.leases[i]);
    }
    this.leases = next;
    this.revision++;
    return writeResult(true, false, StorageWriteCode.UPDATED);
  }

  getLease(resourceId: string): RecoveryLease | undefined {
    const index: number = this.findLease(resourceId);
    return index < 0 ? undefined : copyLease(this.leases[index]);
  }

  checkpoint(integrity: SnapshotIntegrityPort): StorageSnapshotEnvelope {
    const payload: ExecutionStoragePayload = new ExecutionStoragePayload();
    payload.tasks = this.tasks;
    payload.operations = this.operations;
    payload.budgets = this.budgets;
    payload.budgetScopes = this.budgetScopes;
    payload.traces = this.traces;
    payload.traceCursors = this.traceCursors;
    payload.registries = this.registries;
    payload.policies = this.policies;
    payload.leases = this.leases;
    payload.nextFencingToken = this.nextFencingToken;
    const envelope: StorageSnapshotEnvelope = new StorageSnapshotEnvelope();
    envelope.revision = this.revision;
    envelope.payloadJson = JSON.stringify(payload);
    envelope.payloadDigest = integrity.digest(envelope.payloadJson);
    return envelope;
  }

  /**
   * Creates an isolated transaction candidate without applying restart
   * normalization. The durable session publishes this fork only after its
   * snapshot compare-and-set succeeds.
   */
  forkForTransaction(): ExecutionRecoveryStore {
    const store: ExecutionRecoveryStore = new ExecutionRecoveryStore();
    store.revision = this.revision;
    store.nextFencingToken = this.nextFencingToken;
    for (let i: number = 0; i < this.tasks.length; i++) store.tasks.push(copyTask(this.tasks[i]));
    for (let i: number = 0; i < this.operations.length; i++) {
      store.operations.push(copyOperation(this.operations[i]));
    }
    for (let i: number = 0; i < this.budgets.length; i++) {
      store.budgets.push(copyStoredBudget(this.budgets[i]));
    }
    for (let i: number = 0; i < this.budgetScopes.length; i++) {
      store.budgetScopes.push(copyStoredBudgetScope(this.budgetScopes[i]));
    }
    for (let i: number = 0; i < this.traces.length; i++) store.traces.push(copyTrace(this.traces[i]));
    for (let i: number = 0; i < this.traceCursors.length; i++) {
      store.traceCursors.push(copyTraceCursor(this.traceCursors[i]));
    }
    for (let i: number = 0; i < this.registries.length; i++) {
      store.registries.push(copyRegistry(this.registries[i]));
    }
    for (let i: number = 0; i < this.policies.length; i++) store.policies.push(copyPolicy(this.policies[i]));
    for (let i: number = 0; i < this.leases.length; i++) store.leases.push(copyLease(this.leases[i]));
    return store;
  }

  static restore(source: StorageSnapshotEnvelope, integrity: SnapshotIntegrityPort,
    migration?: StorageMigrationPort, normalizeInFlight: boolean = true): ExecutionStoreRestoreResult {
    const result: ExecutionStoreRestoreResult = new ExecutionStoreRestoreResult();
    let envelope: StorageSnapshotEnvelope = source;
    if (envelope.schemaVersion !== AGENT_STORAGE_SCHEMA_VERSION) {
      if (migration === undefined) {
        result.code = StorageWriteCode.UNSUPPORTED_SCHEMA;
        return result;
      }
      envelope = migration.migrate(source);
    }
    if (envelope.schemaVersion !== AGENT_STORAGE_SCHEMA_VERSION || !validCount(envelope.revision) ||
      !validText(envelope.payloadJson) || !validText(envelope.payloadDigest) ||
      integrity.digest(envelope.payloadJson) !== envelope.payloadDigest) {
      result.code = StorageWriteCode.CORRUPT_SNAPSHOT;
      return result;
    }
    try {
      const payload: ExecutionStoragePayload = JSON.parse(envelope.payloadJson) as ExecutionStoragePayload;
      if (!ExecutionRecoveryStore.validatePayload(payload)) {
        result.code = StorageWriteCode.CORRUPT_SNAPSHOT;
        return result;
      }
      const store: ExecutionRecoveryStore = new ExecutionRecoveryStore();
      store.revision = envelope.revision;
      store.nextFencingToken = payload.nextFencingToken;
      let normalizedInFlight: boolean = false;
      for (let i: number = 0; i < payload.tasks.length; i++) store.tasks.push(copyTask(payload.tasks[i]));
      for (let i: number = 0; i < payload.operations.length; i++) {
        const operation: StoredOperation = copyOperation(payload.operations[i]);
        if (normalizeInFlight && operation.state === OperationJournalState.IN_FLIGHT) {
          operation.state = OperationJournalState.UNKNOWN_OUTCOME;
          const budgetIndex: number = store.findBudgetIn(payload.budgets, operation.intent.budgetReservationId);
          payload.budgets[budgetIndex].snapshot.state = BudgetReservationState.UNKNOWN;
          normalizedInFlight = true;
        }
        store.operations.push(operation);
      }
      for (let i: number = 0; i < payload.budgets.length; i++) {
        store.budgets.push(copyStoredBudget(payload.budgets[i]));
      }
      for (let i: number = 0; i < payload.budgetScopes.length; i++) {
        store.budgetScopes.push(copyStoredBudgetScope(payload.budgetScopes[i]));
      }
      for (let i: number = 0; i < payload.traces.length; i++) store.traces.push(copyTrace(payload.traces[i]));
      for (let i: number = 0; i < payload.traceCursors.length; i++) {
        store.traceCursors.push(copyTraceCursor(payload.traceCursors[i]));
      }
      for (let i: number = 0; i < payload.registries.length; i++) {
        store.registries.push(copyRegistry(payload.registries[i]));
      }
      for (let i: number = 0; i < payload.policies.length; i++) store.policies.push(copyPolicy(payload.policies[i]));
      for (let i: number = 0; i < payload.leases.length; i++) store.leases.push(copyLease(payload.leases[i]));
      if (normalizedInFlight) {
        if (!Number.isSafeInteger(store.revision + 1)) {
          result.code = StorageWriteCode.CORRUPT_SNAPSHOT;
          return result;
        }
        store.revision++;
      }
      result.accepted = true;
      result.code = StorageWriteCode.UPDATED;
      result.store = store;
      return result;
    } catch (error) {
      result.code = StorageWriteCode.CORRUPT_SNAPSHOT;
      return result;
    }
  }

  private budgetSnapshotsForTask(taskId: string): BudgetReservationSnapshot[] {
    const values: BudgetReservationSnapshot[] = [];
    for (let i: number = 0; i < this.budgets.length; i++) {
      if (this.budgets[i].snapshot.taskId === taskId) {
        values.push(copyBudgetSnapshot(this.budgets[i].snapshot));
      }
    }
    return values;
  }

  private budgetScopeSnapshotsForTask(taskId: string): BudgetScopeSnapshot[] {
    const values: BudgetScopeSnapshot[] = [];
    for (let i: number = 0; i < this.budgetScopes.length; i++) {
      if (this.budgetScopes[i].snapshot.taskId === taskId) {
        values.push(copyBudgetScopeSnapshot(this.budgetScopes[i].snapshot));
      }
    }
    return values;
  }

  private preservesBudgetScopeDefinitions(taskId: string, next: BudgetScopeSnapshot[]): boolean {
    for (let i: number = 0; i < this.budgetScopes.length; i++) {
      const current: BudgetScopeSnapshot = this.budgetScopes[i].snapshot;
      if (current.taskId !== taskId) continue;
      let matched: boolean = false;
      for (let j: number = 0; j < next.length; j++) {
        if (sameScopeDefinition(current, next[j])) {
          matched = true;
          break;
        }
      }
      if (!matched) return false;
    }
    return true;
  }

  private replacedBudgetScopes(taskId: string, next: BudgetScopeSnapshot[], nowMs: number): StoredBudgetScope[] {
    const values: StoredBudgetScope[] = [];
    for (let i: number = 0; i < this.budgetScopes.length; i++) {
      if (this.budgetScopes[i].snapshot.taskId !== taskId) {
        values.push(copyStoredBudgetScope(this.budgetScopes[i]));
      }
    }
    for (let i: number = 0; i < next.length; i++) {
      const value: StoredBudgetScope = new StoredBudgetScope();
      value.snapshot = copyBudgetScopeSnapshot(next[i]);
      value.updatedAtMs = nowMs;
      values.push(value);
    }
    return values;
  }

  private policyFor(policyRequestId: string): StoredPolicyRecord | undefined {
    const index: number = this.findPolicy(policyRequestId);
    return index < 0 ? undefined : this.policies[index];
  }

  private settleBudgetAuthority(reservation: BudgetReservationSnapshot, actual: BudgetAmount,
    nowMs: number): boolean {
    const indexes: number[] = [];
    for (let i: number = 0; i < this.budgetScopes.length; i++) {
      const scope: BudgetScopeSnapshot = this.budgetScopes[i].snapshot;
      if (scope.taskId !== reservation.taskId) continue;
      if ((scope.kind === BudgetScopeKind.TASK && scope.scopeId === reservation.taskId) ||
        (scope.kind === BudgetScopeKind.STEP && scope.scopeId === reservation.stepId) ||
        (scope.kind === BudgetScopeKind.PROVIDER && scope.scopeId === reservation.providerId)) {
        if (!canSubtractBudget(scope.reserved, reservation.requested)) return false;
        indexes.push(i);
      }
    }
    if (indexes.length !== 3) return false;
    for (let i: number = 0; i < indexes.length; i++) {
      const scope: StoredBudgetScope = this.budgetScopes[indexes[i]];
      subtractBudget(scope.snapshot.reserved, reservation.requested);
      addBudget(scope.snapshot.consumed, actual);
      scope.updatedAtMs = nowMs;
    }
    return true;
  }

  private validateLease(resourceId: string, ownerId: string, fencingToken: number,
    nowMs: number): StorageWriteCode {
    const index: number = this.findLease(resourceId);
    if (index < 0) return StorageWriteCode.LEASE_REQUIRED;
    const lease: RecoveryLease = this.leases[index];
    if (lease.ownerId !== ownerId || lease.fencingToken !== fencingToken || lease.expiresAtMs <= nowMs) {
      return StorageWriteCode.STALE_FENCE;
    }
    return StorageWriteCode.UNCHANGED;
  }

  private requireBudget(reservationId: string): StoredBudgetReservation {
    return this.budgets[this.findBudget(reservationId)];
  }

  private findTask(taskId: string): number {
    for (let i: number = 0; i < this.tasks.length; i++) if (this.tasks[i].taskId === taskId) return i;
    return -1;
  }

  private findOperation(operationId: string): number {
    for (let i: number = 0; i < this.operations.length; i++) {
      if (this.operations[i].intent.operationId === operationId) return i;
    }
    return -1;
  }

  private findBudget(reservationId: string): number {
    return this.findBudgetIn(this.budgets, reservationId);
  }

  private findBudgetIn(values: StoredBudgetReservation[], reservationId: string): number {
    for (let i: number = 0; i < values.length; i++) {
      if (values[i].snapshot.reservationId === reservationId) return i;
    }
    return -1;
  }

  private findRegistry(recordId: string): number {
    for (let i: number = 0; i < this.registries.length; i++) if (this.registries[i].recordId === recordId) return i;
    return -1;
  }

  private findTraceCursor(taskId: string): number {
    for (let i: number = 0; i < this.traceCursors.length; i++) {
      if (this.traceCursors[i].taskId === taskId) return i;
    }
    return -1;
  }

  private findPolicy(requestId: string): number {
    for (let i: number = 0; i < this.policies.length; i++) {
      if (this.policies[i].policyRequestId === requestId) return i;
    }
    return -1;
  }

  private findLease(resourceId: string): number {
    for (let i: number = 0; i < this.leases.length; i++) if (this.leases[i].resourceId === resourceId) return i;
    return -1;
  }

  private static validatePayload(payload: ExecutionStoragePayload): boolean {
    if (payload === undefined || !validPositiveCount(payload.nextFencingToken) || payload.tasks === undefined ||
      payload.operations === undefined || payload.budgets === undefined || payload.budgetScopes === undefined ||
      payload.traces === undefined ||
      payload.traceCursors === undefined || payload.registries === undefined ||
      payload.policies === undefined || payload.leases === undefined) return false;
    const ids: string[] = [];
    for (let i: number = 0; i < payload.operations.length; i++) {
      const operation: StoredOperation = payload.operations[i];
      if (!validIntent(operation.intent) || includesText(ids, operation.intent.operationId) ||
        !validCount(operation.fencingToken) || !validCount(operation.dispatchCount) ||
        !validCount(operation.updatedAtMs)) return false;
      ids.push(operation.intent.operationId);
      const linkedBudget: number = findBudgetSnapshot(payload.budgets, operation.intent.budgetReservationId);
      const linkedPolicy: number = findPolicySnapshot(payload.policies, operation.intent.policyRequestId);
      if (linkedBudget < 0 || linkedPolicy < 0 ||
        !operationStateMatchesBudget(operation, payload.budgets[linkedBudget]) ||
        !validOperationPolicyBinding(operation.intent, payload.budgets[linkedBudget].snapshot,
          payload.policies[linkedPolicy])) return false;
    }
    const budgetIds: string[] = [];
    for (let i: number = 0; i < payload.budgets.length; i++) {
      if (!validReservation(payload.budgets[i].snapshot) || !validCount(payload.budgets[i].updatedAtMs) ||
        !validBudgetAmount(payload.budgets[i].snapshot.actual) ||
        includesText(budgetIds, payload.budgets[i].snapshot.reservationId)) return false;
      let linkedOperations: number = 0;
      for (let j: number = 0; j < payload.operations.length; j++) {
        if (payload.operations[j].intent.budgetReservationId === payload.budgets[i].snapshot.reservationId) {
          linkedOperations++;
        }
      }
      if (linkedOperations !== 1) return false;
      budgetIds.push(payload.budgets[i].snapshot.reservationId);
    }
    const scopeKeys: string[] = [];
    const scopeTasks: string[] = [];
    for (let i: number = 0; i < payload.budgetScopes.length; i++) {
      const stored: StoredBudgetScope = payload.budgetScopes[i];
      const key: string = stored.snapshot.taskId + ':' + stored.snapshot.kind.toString() + ':' +
        stored.snapshot.scopeId;
      if (!validBudgetScope(stored.snapshot) || !validCount(stored.updatedAtMs) ||
        includesText(scopeKeys, key)) return false;
      scopeKeys.push(key);
      if (!includesText(scopeTasks, stored.snapshot.taskId)) scopeTasks.push(stored.snapshot.taskId);
    }
    for (let i: number = 0; i < scopeTasks.length; i++) {
      const scopes: BudgetScopeSnapshot[] = [];
      const reservations: BudgetReservationSnapshot[] = [];
      for (let j: number = 0; j < payload.budgetScopes.length; j++) {
        if (payload.budgetScopes[j].snapshot.taskId === scopeTasks[i]) {
          scopes.push(payload.budgetScopes[j].snapshot);
        }
      }
      for (let j: number = 0; j < payload.budgets.length; j++) {
        if (payload.budgets[j].snapshot.taskId === scopeTasks[i]) {
          reservations.push(payload.budgets[j].snapshot);
        }
      }
      if (!validBudgetAuthority(scopeTasks[i], scopes, reservations)) return false;
    }
    for (let i: number = 0; i < payload.budgets.length; i++) {
      if (!includesText(scopeTasks, payload.budgets[i].snapshot.taskId)) return false;
    }
    const taskIds: string[] = [];
    for (let i: number = 0; i < payload.tasks.length; i++) {
      if (!ContractValidator.validateAgentTaskSnapshot(payload.tasks[i].snapshot).valid ||
        payload.tasks[i].taskId !== payload.tasks[i].snapshot.taskId ||
        payload.tasks[i].snapshotVersion !== payload.tasks[i].snapshot.snapshotVersion ||
        !validText(payload.tasks[i].checkpointVersion) || !validJson(payload.tasks[i].checkpointJson) ||
        includesText(taskIds, payload.tasks[i].taskId) || !validCount(payload.tasks[i].updatedAtMs)) return false;
      taskIds.push(payload.tasks[i].taskId);
    }
    const traceIds: string[] = [];
    const traceSequences: string[] = [];
    for (let i: number = 0; i < payload.traces.length; i++) {
      const traceSequence: string = payload.traces[i].event.taskId + ':' + payload.traces[i].sequence.toString();
      if (!ContractValidator.validateTraceEvent(payload.traces[i].event).valid ||
        !validPositiveCount(payload.traces[i].sequence) || !validCount(payload.traces[i].timestampMs) ||
        includesText(traceIds, payload.traces[i].event.eventId) || includesText(traceSequences, traceSequence) ||
        findTraceCursorSnapshot(payload.traceCursors, payload.traces[i].event.taskId,
          payload.traces[i].sequence) < 0) return false;
      traceIds.push(payload.traces[i].event.eventId);
      traceSequences.push(traceSequence);
    }
    const cursorTasks: string[] = [];
    for (let i: number = 0; i < payload.traceCursors.length; i++) {
      if (!validText(payload.traceCursors[i].taskId) || !validPositiveCount(payload.traceCursors[i].lastSequence) ||
        includesText(cursorTasks, payload.traceCursors[i].taskId)) return false;
      cursorTasks.push(payload.traceCursors[i].taskId);
    }
    const registryIds: string[] = [];
    for (let i: number = 0; i < payload.registries.length; i++) {
      const registry: StoredRegistryRecord = payload.registries[i];
      if (!validText(registry.recordId) || !validText(registry.recordVersion) ||
        !validText(registry.recordDigest) || !validText(registry.payloadJson) ||
        !validCount(registry.updatedAtMs) || includesText(registryIds, registry.recordId)) return false;
      registryIds.push(registry.recordId);
    }
    const policyIds: string[] = [];
    for (let i: number = 0; i < payload.policies.length; i++) {
      const policy: StoredPolicyRecord = payload.policies[i];
      if (!validText(policy.policyRequestId) || !validPositiveCount(policy.version) ||
        !validCount(policy.updatedAtMs) || includesText(policyIds, policy.policyRequestId) ||
        !ContractValidator.validatePolicyRequest(policy.request).valid ||
        policy.policyRequestId !== policy.request.requestId || !validStoredPolicyRecord(policy)) return false;
      policyIds.push(policy.policyRequestId);
    }
    const leaseResources: string[] = [];
    const leaseTokens: string[] = [];
    for (let i: number = 0; i < payload.leases.length; i++) {
      const lease: RecoveryLease = payload.leases[i];
      const tokenText: string = lease.fencingToken.toString();
      if (!validText(lease.resourceId) || !validText(lease.ownerId) ||
        !validPositiveCount(lease.fencingToken) || !validPositiveCount(lease.expiresAtMs) ||
        lease.fencingToken >= payload.nextFencingToken || includesText(leaseResources, lease.resourceId) ||
        includesText(leaseTokens, tokenText)) return false;
      leaseResources.push(lease.resourceId);
      leaseTokens.push(tokenText);
    }
    return true;
  }
}

function includesText(values: string[], value: string): boolean {
  for (let i: number = 0; i < values.length; i++) if (values[i] === value) return true;
  return false;
}

function findBudgetSnapshot(values: StoredBudgetReservation[], reservationId: string): number {
  for (let i: number = 0; i < values.length; i++) {
    if (values[i].snapshot.reservationId === reservationId) return i;
  }
  return -1;
}

function findPolicySnapshot(values: StoredPolicyRecord[], policyRequestId: string): number {
  for (let i: number = 0; i < values.length; i++) {
    if (values[i].policyRequestId === policyRequestId) return i;
  }
  return -1;
}

function findTraceCursorSnapshot(values: StoredTraceCursor[], taskId: string, sequence: number): number {
  for (let i: number = 0; i < values.length; i++) {
    if (values[i].taskId === taskId && values[i].lastSequence >= sequence) return i;
  }
  return -1;
}

function operationStateMatchesBudget(operation: StoredOperation, budget: StoredBudgetReservation): boolean {
  if (operation.state === OperationJournalState.PREPARED) {
    return operation.outcome === undefined && operation.fencingToken === 0 &&
      budget.snapshot.state === BudgetReservationState.RESERVED && zeroBudgetAmount(budget.snapshot.actual);
  }
  if (operation.state === OperationJournalState.IN_FLIGHT) {
    return operation.outcome === undefined && operation.fencingToken > 0 && operation.dispatchCount > 0 &&
      budget.snapshot.state === BudgetReservationState.RESERVED && zeroBudgetAmount(budget.snapshot.actual);
  }
  if (operation.state === OperationJournalState.UNKNOWN_OUTCOME) {
    return operation.outcome === undefined && operation.fencingToken > 0 && operation.dispatchCount > 0 &&
      budget.snapshot.state === BudgetReservationState.UNKNOWN && zeroBudgetAmount(budget.snapshot.actual);
  }
  if (operation.state === OperationJournalState.COMMITTED) {
    const outcome: ToolOutcome | undefined = operation.outcome;
    return outcome !== undefined && ContractValidator.validateToolOutcome(outcome).valid &&
      outcome.invocationId === operation.intent.invocationId && outcome.status !== ToolOutcomeStatus.UNKNOWN_OUTCOME &&
      operation.fencingToken > 0 && operation.dispatchCount > 0 &&
      budget.snapshot.state === BudgetReservationState.SETTLED;
  }
  return false;
}

function zeroBudgetAmount(value: BudgetAmount): boolean {
  return value.wallTimeMs === 0 && value.inputTokens === 0 && value.outputTokens === 0 &&
    value.monetaryCostMicros === 0 && value.toolCalls === 0 && value.agentActivations === 0 &&
    value.retries === 0 && value.replans === 0;
}

function validStoredPolicyRecord(policy: StoredPolicyRecord): boolean {
  if (policy.decision === undefined) {
    return policy.version === 1 && policy.grant === undefined;
  }
  const decision: AuthorizationDecision = policy.decision;
  if (policy.version < 2 || !ContractValidator.validateAuthorizationDecision(decision).valid ||
    decision.policyRequestId !== policy.policyRequestId || decision.taskId !== policy.request.taskId ||
    decision.userId !== policy.request.userId) return false;
  if (policy.grant === undefined) return policy.version === 2;

  const grant: AuthorizationGrant = policy.grant;
  return policy.version === 3 && decision.decision === AuthorizationDecisionType.APPROVED &&
    ContractValidator.validateAuthorizationGrant(grant).valid &&
    grant.policyRequestId === policy.policyRequestId && grant.decisionCommandId === decision.commandId &&
    grant.userId === policy.request.userId && grant.taskId === policy.request.taskId &&
    grant.stepId === policy.request.stepId && grant.operationId === policy.request.operationId &&
    grant.toolId === policy.request.toolId && grant.toolIdentityVersion === policy.request.toolIdentityVersion &&
    grant.schemaDigest === policy.request.schemaDigest && grant.argumentsDigest === policy.request.argumentsDigest;
}
