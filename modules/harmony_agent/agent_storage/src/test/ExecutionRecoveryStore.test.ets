import { describe, expect, it } from '@ohos/hypium';
import {
  AgentTaskSnapshot,
  AuthorizationDecision,
  AuthorizationDecisionType,
  AuthorizationGrant,
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
  BudgetReservationSnapshot,
  BudgetReservationState,
  BudgetScopeKind,
  BudgetScopeSnapshot,
  OperationJournalState
} from '@harmony_agent/agent-core';
import {
  DurableExecutionRecoveryStore,
  DurableSnapshotBackendPort,
  ExecutionRecoveryTransaction,
  ExecutionStoragePayload,
  ExecutionRecoveryStore,
  SnapshotIntegrityPort,
  StorageMigrationPort,
  StorageSnapshotCodec,
  StorageSnapshotEnvelope,
  StorageWriteCode,
  StorageWriteResult,
  StoredOperationIntent,
  StoredRegistryRecord
} from '../../Index';

class FixtureIntegrity implements SnapshotIntegrityPort {
  digest(payloadJson: string): string {
    return 'fixture-digest:' + payloadJson;
  }
}

class FixtureMigration implements StorageMigrationPort {
  integrity: SnapshotIntegrityPort = new FixtureIntegrity();

  migrate(source: StorageSnapshotEnvelope): StorageSnapshotEnvelope {
    const value: StorageSnapshotEnvelope = new StorageSnapshotEnvelope();
    value.schemaVersion = '1.2';
    value.revision = source.revision;
    value.payloadJson = source.payloadJson;
    value.payloadDigest = this.integrity.digest(value.payloadJson);
    return value;
  }
}

class FixtureDurableBackend implements DurableSnapshotBackendPort {
  snapshot?: StorageSnapshotEnvelope;
  failNextWrite: boolean = false;
  compareAndSetCalls: number = 0;

  async initialize(): Promise<void> {
  }

  async load(): Promise<StorageSnapshotEnvelope | undefined> {
    if (this.snapshot === undefined) return undefined;
    return StorageSnapshotCodec.decode(StorageSnapshotCodec.encode(this.snapshot));
  }

  async compareAndSet(expectedRevision: number, next: StorageSnapshotEnvelope): Promise<boolean> {
    this.compareAndSetCalls++;
    if (this.failNextWrite) {
      this.failNextWrite = false;
      return false;
    }
    const currentRevision: number = this.snapshot === undefined ? 0 : this.snapshot.revision;
    if (currentRevision !== expectedRevision || next.revision <= expectedRevision) return false;
    this.snapshot = StorageSnapshotCodec.decode(StorageSnapshotCodec.encode(next));
    return true;
  }
}

class FixtureCheckpointBudgetTransaction implements ExecutionRecoveryTransaction {
  apply(store: ExecutionRecoveryStore): StorageWriteResult {
    const saved: StorageWriteResult = store.saveTask(
      taskSnapshot(), '1.1', checkpointJson(), 0, 100);
    if (!saved.accepted) return saved;
    return store.saveBudgetAuthority('task-1', budgetScopes(), 100);
  }
}

function taskSnapshot(version: number = 1): AgentTaskSnapshot {
  const value: AgentTaskSnapshot = new AgentTaskSnapshot();
  value.requestId = 'request-1';
  value.taskId = 'task-1';
  value.sessionId = 'session-1';
  value.snapshotVersion = version;
  value.lastEventSequence = version;
  value.resultJson = '{"status":"running"}';
  value.updatedAt = '2026-09-29T16:00:00.000Z';
  return value;
}

function checkpointJson(version: number = 1): string {
  return JSON.stringify({
    checkpointVersion: '1.1',
    taskId: 'task-1',
    snapshotVersion: version
  });
}

function intent(): StoredOperationIntent {
  const value: StoredOperationIntent = new StoredOperationIntent();
  value.operationId = 'operation-1';
  value.invocationId = 'invocation-1';
  value.taskId = 'task-1';
  value.stepId = 'step-1';
  value.attemptId = 'attempt-1';
  value.toolId = 'calendar.create';
  value.toolIdentityVersion = 'calendar-v1';
  value.schemaDigest = 'sha256:schema';
  value.argumentsDigest = 'sha256:arguments';
  value.idempotencyKey = 'idem-1';
  value.idempotencyMode = IdempotencyMode.PROVIDER_KEY;
  value.sideEffect = SideEffect.REVERSIBLE;
  value.policyRequestId = 'policy-1';
  value.budgetReservationId = 'reservation-1';
  value.createdAt = '2026-09-29T16:00:00.000Z';
  return value;
}

function budgetLimit(): ExecutionBudget {
  const value: ExecutionBudget = new ExecutionBudget();
  value.maxMonetaryCostMicros = 1000;
  value.maxToolCalls = 10;
  return value;
}

function budgetScopes(reserved: boolean = false, settled: boolean = false): BudgetScopeSnapshot[] {
  const values: BudgetScopeSnapshot[] = [];
  const kinds: BudgetScopeKind[] = [BudgetScopeKind.TASK, BudgetScopeKind.STEP, BudgetScopeKind.PROVIDER];
  const ids: string[] = ['task-1', 'step-1', 'provider-1'];
  for (let i: number = 0; i < kinds.length; i++) {
    const value: BudgetScopeSnapshot = new BudgetScopeSnapshot();
    value.kind = kinds[i];
    value.taskId = 'task-1';
    value.scopeId = ids[i];
    value.limit = budgetLimit();
    if (reserved) {
      value.reserved.toolCalls = 1;
      value.reserved.monetaryCostMicros = 100;
    }
    if (settled) {
      value.consumed.toolCalls = 1;
      value.consumed.monetaryCostMicros = 80;
    }
    values.push(value);
  }
  return values;
}

function reservation(): BudgetReservationSnapshot {
  const value: BudgetReservationSnapshot = new BudgetReservationSnapshot();
  value.reservationId = 'reservation-1';
  value.taskId = 'task-1';
  value.stepId = 'step-1';
  value.providerId = 'provider-1';
  value.requested.toolCalls = 1;
  value.requested.monetaryCostMicros = 100;
  value.state = BudgetReservationState.RESERVED;
  return value;
}

function outcome(status: ToolOutcomeStatus = ToolOutcomeStatus.SUCCEEDED): ToolOutcome {
  const value: ToolOutcome = new ToolOutcome();
  value.invocationId = 'invocation-1';
  value.status = status;
  value.resultJson = '{"eventId":"event-1"}';
  value.resultDigest = 'sha256:result';
  value.providerReceipt = 'receipt-1';
  value.startedAt = '2026-09-29T16:00:01.000Z';
  value.finishedAt = '2026-09-29T16:00:02.000Z';
  return value;
}

function actualBudget(): BudgetAmount {
  const value: BudgetAmount = new BudgetAmount();
  value.toolCalls = 1;
  value.monetaryCostMicros = 80;
  return value;
}

function trace(id: string): TraceEvent {
  const value: TraceEvent = new TraceEvent();
  value.eventId = id;
  value.taskId = 'task-1';
  value.eventType = 'operation.state';
  value.timestamp = '2026-09-29T16:00:00.000Z';
  value.component = 'agent-storage';
  value.componentVersion = '0.1.0';
  value.privacyRedactionVersion = '1';
  return value;
}

function policyRequest(): PolicyRequest {
  const value: PolicyRequest = new PolicyRequest();
  value.requestId = 'policy-1';
  value.userId = 'user-1';
  value.taskId = 'task-1';
  value.stepId = 'step-1';
  value.operationId = 'operation-1';
  value.toolId = 'calendar.create';
  value.toolIdentityVersion = 'calendar-v1';
  value.providerId = 'provider-1';
  value.sideEffect = SideEffect.REVERSIBLE;
  value.schemaDigest = 'sha256:schema';
  value.argumentsDigest = 'sha256:arguments';
  value.estimatedCostMicros = 100;
  value.requestedAt = '2026-09-29T16:00:00.000Z';
  value.expiresAt = '2026-09-29T16:01:00.000Z';
  value.expiresAtMs = 60000;
  return value;
}

function decision(): AuthorizationDecision {
  const value: AuthorizationDecision = new AuthorizationDecision();
  value.commandId = 'decision-1';
  value.policyRequestId = 'policy-1';
  value.userId = 'user-1';
  value.taskId = 'task-1';
  value.decision = AuthorizationDecisionType.APPROVED;
  value.decidedAt = '2026-09-29T16:00:01.000Z';
  value.decidedAtMs = 1000;
  return value;
}

function grant(): AuthorizationGrant {
  const value: AuthorizationGrant = new AuthorizationGrant();
  value.grantId = 'grant-1';
  value.policyRequestId = 'policy-1';
  value.decisionCommandId = 'decision-1';
  value.userId = 'user-1';
  value.taskId = 'task-1';
  value.stepId = 'step-1';
  value.operationId = 'operation-1';
  value.toolId = 'calendar.create';
  value.toolIdentityVersion = 'calendar-v1';
  value.schemaDigest = 'sha256:schema';
  value.argumentsDigest = 'sha256:arguments';
  value.budgetReservationId = 'reservation-1';
  value.policyVersion = 'policy-v1';
  value.issuedAt = '2026-09-29T16:00:01.000Z';
  value.expiresAt = '2026-09-29T16:01:00.000Z';
  value.issuedAtMs = 1000;
  value.expiresAtMs = 60000;
  return value;
}

function preparedStore(): ExecutionRecoveryStore {
  const value: ExecutionRecoveryStore = authorizedStore();
  value.prepareOperation(intent(), reservation(), budgetScopes(true), 100);
  return value;
}

function authorizedStore(): ExecutionRecoveryStore {
  const value: ExecutionRecoveryStore = new ExecutionRecoveryStore();
  value.savePolicyRequest(policyRequest(), 70);
  value.savePolicyDecision('policy-1', decision(), 1, 80);
  value.saveAuthorizationGrant('policy-1', grant(), 2, 90);
  return value;
}

function restored(source: ExecutionRecoveryStore): ExecutionRecoveryStore {
  const integrity: FixtureIntegrity = new FixtureIntegrity();
  const result = ExecutionRecoveryStore.restore(source.checkpoint(integrity), integrity);
  return result.store as ExecutionRecoveryStore;
}

async function openDurable(backend: DurableSnapshotBackendPort): Promise<DurableExecutionRecoveryStore> {
  const result = await DurableExecutionRecoveryStore.open(backend, new FixtureIntegrity());
  if (!result.accepted || result.store === undefined) {
    throw new Error('fixture durable store failed to open: ' + result.code);
  }
  return result.store;
}

async function authorizeDurable(store: DurableExecutionRecoveryStore): Promise<void> {
  await store.savePolicyRequest(policyRequest(), 70);
  await store.savePolicyDecision('policy-1', decision(), 1, 80);
  await store.saveAuthorizationGrant('policy-1', grant(), 2, 90);
}

export default function executionRecoveryStoreTest(): void {
  describe('ExecutionRecoveryStore', () => {
    it('savesOpaqueRuntimeCheckpointsWithCasEnumerationAndCopyIsolation', 0, () => {
      const store: ExecutionRecoveryStore = new ExecutionRecoveryStore();
      const first: AgentTaskSnapshot = taskSnapshot();
      expect(store.saveTask(first, '1.1', checkpointJson(), 0, 100).accepted).assertTrue();
      first.resultJson = '{"mutated":true}';
      expect(store.getTask('task-1')?.snapshot.resultJson).assertEqual('{"status":"running"}');
      expect(store.getTask('task-1')?.checkpointJson).assertEqual(checkpointJson());
      const listed: string[] = store.listTaskIds();
      expect(listed.length).assertEqual(1);
      listed[0] = 'mutated';
      expect(store.listTaskIds()[0]).assertEqual('task-1');
      expect(store.saveTask(taskSnapshot(2), '1.1', checkpointJson(2), 0, 110).code)
        .assertEqual(StorageWriteCode.VERSION_CONFLICT);
      expect(store.saveTask(taskSnapshot(2), '1.1', checkpointJson(2), 1, 110).accepted).assertTrue();
    });

    it('rejectsMalformedOpaqueRuntimeCheckpoint', 0, () => {
      const store: ExecutionRecoveryStore = new ExecutionRecoveryStore();
      expect(store.saveTask(taskSnapshot(), '1.1', '{broken', 0, 100).code)
        .assertEqual(StorageWriteCode.INVALID_INPUT);
      expect(store.listTaskIds().length).assertEqual(0);
      expect(store.saveTask(taskSnapshot(), '1.1', checkpointJson(), 0, 100).accepted).assertTrue();
      const integrity: FixtureIntegrity = new FixtureIntegrity();
      const envelope: StorageSnapshotEnvelope = store.checkpoint(integrity);
      const payload: ExecutionStoragePayload = JSON.parse(envelope.payloadJson) as ExecutionStoragePayload;
      payload.tasks[0].checkpointJson = '{broken';
      envelope.payloadJson = JSON.stringify(payload);
      envelope.payloadDigest = integrity.digest(envelope.payloadJson);
      expect(ExecutionRecoveryStore.restore(envelope, integrity).code)
        .assertEqual(StorageWriteCode.CORRUPT_SNAPSHOT);
    });

    it('atomicallyPreparesOperationAndBudgetBeforeDispatch', 0, () => {
      const store: ExecutionRecoveryStore = authorizedStore();
      const prepared = store.prepareOperation(intent(), reservation(), budgetScopes(true), 100);
      expect(prepared.accepted).assertTrue();
      expect(store.getOperation('operation-1')?.state).assertEqual(OperationJournalState.PREPARED);
      expect(store.getOperation('operation-1')?.intent.policyRequestId).assertEqual('policy-1');
      expect(store.getOperation('operation-1')?.intent.idempotencyMode)
        .assertEqual(IdempotencyMode.PROVIDER_KEY);
      expect(store.getOperation('operation-1')?.intent.sideEffect).assertEqual(SideEffect.REVERSIBLE);
      expect(store.getBudgetReservation('reservation-1')?.snapshot.state)
        .assertEqual(BudgetReservationState.RESERVED);
      const reservations = store.getBudgetReservations('task-1');
      expect(reservations.length).assertEqual(1);
      reservations[0].snapshot.requested.toolCalls = 99;
      expect(store.getBudgetReservations('task-1')[0].snapshot.requested.toolCalls).assertEqual(1);
      expect(store.getBudgetScopes('task-1').length).assertEqual(3);
      expect(store.getBudgetScopes('task-1')[0].snapshot.reserved.toolCalls).assertEqual(1);
      expect(store.markOperationInFlight('operation-1', 'worker-1', 1, 110).code)
        .assertEqual(StorageWriteCode.LEASE_REQUIRED);
    });

    it('persistsCompleteBudgetAuthorityWithCopyIsolation', 0, () => {
      const store: ExecutionRecoveryStore = new ExecutionRecoveryStore();
      const scopes: BudgetScopeSnapshot[] = budgetScopes();
      expect(store.saveBudgetAuthority('task-1', scopes, 100).accepted).assertTrue();
      scopes[0].limit.maxToolCalls = 999;
      const exposed = store.getBudgetScopes('task-1');
      exposed[0].snapshot.limit.maxToolCalls = 888;
      expect(store.getBudgetScopes('task-1')[0].snapshot.limit.maxToolCalls).assertEqual(10);
      expect(restored(store).getBudgetScopes('task-1').length).assertEqual(3);
    });

    it('rejectsPrepareWithoutDurablePolicyOrCompleteAuthority', 0, () => {
      const withoutPolicy: ExecutionRecoveryStore = new ExecutionRecoveryStore();
      expect(withoutPolicy.prepareOperation(intent(), reservation(), budgetScopes(true), 100).code)
        .assertEqual(StorageWriteCode.INVALID_INPUT);
      const incomplete: ExecutionRecoveryStore = authorizedStore();
      const complete: BudgetScopeSnapshot[] = budgetScopes(true);
      const scopes: BudgetScopeSnapshot[] = [complete[0], complete[1]];
      expect(incomplete.prepareOperation(intent(), reservation(), scopes, 100).code)
        .assertEqual(StorageWriteCode.INVALID_INPUT);
      expect(incomplete.getOperation('operation-1') === undefined).assertTrue();
      expect(incomplete.getBudgetReservation('reservation-1') === undefined).assertTrue();
      expect(incomplete.getBudgetScopes('task-1').length).assertEqual(0);
    });

    it('makesPrepareReplayIdempotentAndRejectsPolicyBindingDrift', 0, () => {
      const store: ExecutionRecoveryStore = preparedStore();
      expect(store.prepareOperation(intent(), reservation(), budgetScopes(true), 100).duplicate).assertTrue();
      const changed: StoredOperationIntent = intent();
      changed.argumentsDigest = 'sha256:changed';
      expect(store.prepareOperation(changed, reservation(), budgetScopes(true), 100).code)
        .assertEqual(StorageWriteCode.INVALID_INPUT);
    });

    it('usesExclusiveLeaseAndMonotonicFencingTokens', 0, () => {
      const store: ExecutionRecoveryStore = new ExecutionRecoveryStore();
      const first = store.acquireLease('task-1', 'worker-a', 100, 100);
      expect(first.lease?.fencingToken).assertEqual(1);
      expect(store.acquireLease('task-1', 'worker-b', 100, 150).code)
        .assertEqual(StorageWriteCode.LEASE_HELD);
      const second = store.acquireLease('task-1', 'worker-b', 100, 200);
      expect(second.lease?.fencingToken).assertEqual(2);
      expect(store.renewLease('task-1', 'worker-a', 1, 100, 210).code)
        .assertEqual(StorageWriteCode.STALE_FENCE);
    });

    it('keepsPreparedOperationDispatchableAfterRestart', 0, () => {
      const store: ExecutionRecoveryStore = restored(preparedStore());
      expect(store.getOperation('operation-1')?.state).assertEqual(OperationJournalState.PREPARED);
      expect(store.recoveryCandidates().length).assertEqual(1);
    });

    it('turnsInFlightCrashIntoUnknownAndHoldsBudget', 0, () => {
      const source: ExecutionRecoveryStore = preparedStore();
      const lease = source.acquireLease('task-1', 'worker-a', 1000, 100).lease;
      source.markOperationInFlight('operation-1', 'worker-a', lease?.fencingToken as number, 110);
      const integrity: FixtureIntegrity = new FixtureIntegrity();
      const before: StorageSnapshotEnvelope = source.checkpoint(integrity);
      const store: ExecutionRecoveryStore = ExecutionRecoveryStore.restore(before, integrity).store as
        ExecutionRecoveryStore;
      expect(store.getOperation('operation-1')?.state).assertEqual(OperationJournalState.UNKNOWN_OUTCOME);
      expect(store.getBudgetReservation('reservation-1')?.snapshot.state)
        .assertEqual(BudgetReservationState.UNKNOWN);
      expect(store.checkpoint(integrity).revision).assertEqual(before.revision + 1);
    });

    it('persistsCommittedOutcomeAndProviderReceiptAcrossRestart', 0, () => {
      const source: ExecutionRecoveryStore = preparedStore();
      const token: number = source.acquireLease('task-1', 'worker-a', 1000, 100).lease?.fencingToken as number;
      source.markOperationInFlight('operation-1', 'worker-a', token, 110);
      source.recordOperationOutcome('operation-1', outcome(), actualBudget(), 'worker-a', token, 120);
      const store: ExecutionRecoveryStore = restored(source);
      expect(store.getOperation('operation-1')?.state).assertEqual(OperationJournalState.COMMITTED);
      expect(store.getOperation('operation-1')?.outcome?.providerReceipt).assertEqual('receipt-1');
      expect(store.getBudgetReservation('reservation-1')?.snapshot.actual.monetaryCostMicros).assertEqual(80);
      expect(store.getBudgetScopes('task-1')[0].snapshot.reserved.toolCalls).assertEqual(0);
      expect(store.getBudgetScopes('task-1')[0].snapshot.consumed.monetaryCostMicros).assertEqual(80);
      expect(store.recoveryCandidates().length).assertEqual(0);
    });

    it('treatsResultBeforeCommitCrashAsUnknownInsteadOfRetryableFailure', 0, () => {
      const source: ExecutionRecoveryStore = preparedStore();
      const token: number = source.acquireLease('task-1', 'worker-a', 1000, 100).lease?.fencingToken as number;
      source.markOperationInFlight('operation-1', 'worker-a', token, 110);
      const store: ExecutionRecoveryStore = restored(source);
      expect(store.getOperation('operation-1')?.state).assertEqual(OperationJournalState.UNKNOWN_OUTCOME);
      expect(store.getOperation('operation-1')?.dispatchCount).assertEqual(1);
    });

    it('rejectsStaleExecutorAfterLeaseTakeover', 0, () => {
      const store: ExecutionRecoveryStore = preparedStore();
      const first: number = store.acquireLease('task-1', 'worker-a', 100, 100).lease?.fencingToken as number;
      store.markOperationInFlight('operation-1', 'worker-a', first, 110);
      store.acquireLease('task-1', 'worker-b', 100, 200);
      expect(store.recordOperationOutcome('operation-1', outcome(), actualBudget(), 'worker-a', first, 210).code)
        .assertEqual(StorageWriteCode.STALE_FENCE);
    });

    it('requiresReconciliationBeforeRedispatch', 0, () => {
      const store: ExecutionRecoveryStore = preparedStore();
      const token: number = store.acquireLease('task-1', 'worker-a', 1000, 100).lease?.fencingToken as number;
      store.markOperationInFlight('operation-1', 'worker-a', token, 110);
      store.markOperationUnknown('operation-1', 'worker-a', token, 120);
      expect(store.markOperationInFlight('operation-1', 'worker-a', token, 130).code)
        .assertEqual(StorageWriteCode.STATE_CONFLICT);
      expect(store.reconcileOperation('operation-1', false, undefined, undefined,
        'worker-a', token, 140).accepted)
        .assertTrue();
      expect(store.markOperationInFlight('operation-1', 'worker-a', token, 150).accepted).assertTrue();
      expect(store.getOperation('operation-1')?.dispatchCount).assertEqual(2);
    });

    it('keepsTraceAppendOnlyOrderedAndRetentionScopedToTerminalTasks', 0, () => {
      const store: ExecutionRecoveryStore = new ExecutionRecoveryStore();
      expect(store.appendTrace(trace('trace-1'), 1, 100).accepted).assertTrue();
      expect(store.appendTrace(trace('trace-3'), 3, 120).code).assertEqual(StorageWriteCode.VERSION_CONFLICT);
      expect(store.appendTrace(trace('trace-2'), 2, 110).accepted).assertTrue();
      const exposed = store.listTrace('task-1', 0);
      exposed[0].event.eventType = 'mutated';
      expect(store.listTrace('task-1', 0)[0].event.eventType).assertEqual('operation.state');
      expect(store.pruneTraceBefore(115, []).removedTraceEvents).assertEqual(0);
      expect(store.pruneTraceBefore(115, ['task-1']).removedTraceEvents).assertEqual(2);
      expect(store.appendTrace(trace('trace-3'), 3, 130).accepted).assertTrue();
    });

    it('detectsCorruptUnsupportedAndMalformedSnapshots', 0, () => {
      const integrity: FixtureIntegrity = new FixtureIntegrity();
      const envelope: StorageSnapshotEnvelope = preparedStore().checkpoint(integrity);
      envelope.payloadJson = envelope.payloadJson + ' ';
      expect(ExecutionRecoveryStore.restore(envelope, integrity).code)
        .assertEqual(StorageWriteCode.CORRUPT_SNAPSHOT);
      const unsupported: StorageSnapshotEnvelope = preparedStore().checkpoint(integrity);
      unsupported.schemaVersion = '1.0';
      expect(ExecutionRecoveryStore.restore(unsupported, integrity).code)
        .assertEqual(StorageWriteCode.UNSUPPORTED_SCHEMA);
      expect(StorageSnapshotCodec.decode('{broken') === undefined).assertTrue();
    });

    it('usesExplicitMigrationPortForOlderSnapshot', 0, () => {
      const integrity: FixtureIntegrity = new FixtureIntegrity();
      const envelope: StorageSnapshotEnvelope = preparedStore().checkpoint(integrity);
      envelope.schemaVersion = '0.9';
      const restoredResult = ExecutionRecoveryStore.restore(envelope, integrity, new FixtureMigration());
      expect(restoredResult.accepted).assertTrue();
      expect(restoredResult.store?.getOperation('operation-1')?.intent.operationId)
        .assertEqual('operation-1');
    });

    it('persistsPolicyDecisionAndGrantWithCasBinding', 0, () => {
      const store: ExecutionRecoveryStore = new ExecutionRecoveryStore();
      expect(store.savePolicyRequest(policyRequest(), 100).accepted).assertTrue();
      expect(store.savePolicyDecision('policy-1', decision(), 0, 110).code)
        .assertEqual(StorageWriteCode.VERSION_CONFLICT);
      expect(store.savePolicyDecision('policy-1', decision(), 1, 110).accepted).assertTrue();
      const wrongDecision: AuthorizationGrant = grant();
      wrongDecision.decisionCommandId = 'decision-other';
      expect(store.saveAuthorizationGrant('policy-1', wrongDecision, 2, 120).code)
        .assertEqual(StorageWriteCode.INVALID_INPUT);
      expect(store.saveAuthorizationGrant('policy-1', grant(), 2, 120).accepted).assertTrue();
      expect(store.getPolicyRecord('policy-1')?.version).assertEqual(3);
    });

    it('rejectsCorruptPolicyDecisionBindingDuringRestore', 0, () => {
      const integrity: FixtureIntegrity = new FixtureIntegrity();
      const store: ExecutionRecoveryStore = new ExecutionRecoveryStore();
      store.savePolicyRequest(policyRequest(), 100);
      store.savePolicyDecision('policy-1', decision(), 1, 110);
      store.saveAuthorizationGrant('policy-1', grant(), 2, 120);
      const envelope: StorageSnapshotEnvelope = store.checkpoint(integrity);
      const payload: ExecutionStoragePayload = JSON.parse(envelope.payloadJson) as ExecutionStoragePayload;
      if (payload.policies[0].grant !== undefined) {
        payload.policies[0].grant.decisionCommandId = 'decision-other';
      }
      envelope.payloadJson = JSON.stringify(payload);
      envelope.payloadDigest = integrity.digest(envelope.payloadJson);
      expect(ExecutionRecoveryStore.restore(envelope, integrity).code)
        .assertEqual(StorageWriteCode.CORRUPT_SNAPSHOT);
    });

    it('rejectsCorruptBudgetAuthorityDuringRestore', 0, () => {
      const integrity: FixtureIntegrity = new FixtureIntegrity();
      const envelope: StorageSnapshotEnvelope = preparedStore().checkpoint(integrity);
      const payload: ExecutionStoragePayload = JSON.parse(envelope.payloadJson) as ExecutionStoragePayload;
      payload.budgetScopes[0].snapshot.reserved.toolCalls = 0;
      envelope.payloadJson = JSON.stringify(payload);
      envelope.payloadDigest = integrity.digest(envelope.payloadJson);
      expect(ExecutionRecoveryStore.restore(envelope, integrity).code)
        .assertEqual(StorageWriteCode.CORRUPT_SNAPSHOT);
    });

    it('doesNotPersistGrantAfterDeniedDecision', 0, () => {
      const store: ExecutionRecoveryStore = new ExecutionRecoveryStore();
      store.savePolicyRequest(policyRequest(), 100);
      const denied: AuthorizationDecision = decision();
      denied.decision = AuthorizationDecisionType.DENIED;
      denied.denialReasonCode = 'USER_REJECTED';
      store.savePolicyDecision('policy-1', denied, 1, 110);
      expect(store.saveAuthorizationGrant('policy-1', grant(), 2, 120).code)
        .assertEqual(StorageWriteCode.VERSION_CONFLICT);
    });

    it('keepsRegistryVersionAndDigestConflictsExplicit', 0, () => {
      const store: ExecutionRecoveryStore = new ExecutionRecoveryStore();
      const record: StoredRegistryRecord = new StoredRegistryRecord();
      record.recordId = 'tool:calendar.create';
      record.recordVersion = '1';
      record.recordDigest = 'sha256:registry';
      record.payloadJson = '{"enabled":true}';
      record.updatedAtMs = 100;
      expect(store.saveRegistryRecord(record).accepted).assertTrue();
      const changed: StoredRegistryRecord = new StoredRegistryRecord();
      changed.recordId = record.recordId;
      changed.recordVersion = record.recordVersion;
      changed.recordDigest = 'sha256:changed';
      changed.payloadJson = record.payloadJson;
      changed.updatedAtMs = 100;
      expect(store.saveRegistryRecord(changed).code).assertEqual(StorageWriteCode.VERSION_CONFLICT);
    });

    it('doesNotPublishPreparedIntentWhenDurableCasFails', 0, async () => {
      const backend: FixtureDurableBackend = new FixtureDurableBackend();
      const store: DurableExecutionRecoveryStore = await openDurable(backend);
      await authorizeDurable(store);
      const beforeRevision: number = store.revision();
      backend.failNextWrite = true;
      const result = await store.prepareOperation(intent(), reservation(), budgetScopes(true), 100);
      expect(result.code).assertEqual(StorageWriteCode.VERSION_CONFLICT);
      expect(store.getOperation('operation-1') === undefined).assertTrue();
      expect(store.getBudgetReservation('reservation-1') === undefined).assertTrue();
      expect(store.getBudgetScopes('task-1').length).assertEqual(0);
      expect(store.revision()).assertEqual(beforeRevision);
    });

    it('publishesCheckpointAndAuthorityWithOneDurableCasOrNothing', 0, async () => {
      const backend: FixtureDurableBackend = new FixtureDurableBackend();
      const store: DurableExecutionRecoveryStore = await openDurable(backend);
      backend.failNextWrite = true;
      expect((await store.transact(new FixtureCheckpointBudgetTransaction())).code)
        .assertEqual(StorageWriteCode.VERSION_CONFLICT);
      expect(store.getTask('task-1') === undefined).assertTrue();
      expect(store.getBudgetScopes('task-1').length).assertEqual(0);
      expect(backend.compareAndSetCalls).assertEqual(1);

      expect((await store.transact(new FixtureCheckpointBudgetTransaction())).accepted).assertTrue();
      expect(store.getTask('task-1')?.checkpointVersion).assertEqual('1.1');
      expect(store.getBudgetScopes('task-1').length).assertEqual(3);
      expect(backend.compareAndSetCalls).assertEqual(2);
      expect(store.revision()).assertEqual(2);
    });

    it('keepsOneWinnerAcrossConcurrentDurableSessions', 0, async () => {
      const backend: FixtureDurableBackend = new FixtureDurableBackend();
      const first: DurableExecutionRecoveryStore = await openDurable(backend);
      await authorizeDurable(first);
      const second: DurableExecutionRecoveryStore = await openDurable(backend);
      expect((await first.prepareOperation(intent(), reservation(), budgetScopes(true), 100)).accepted).assertTrue();
      const losing = await second.prepareOperation(intent(), reservation(), budgetScopes(true), 100);
      expect(losing.code).assertEqual(StorageWriteCode.VERSION_CONFLICT);
      expect(second.getOperation('operation-1') === undefined).assertTrue();
      const reopened: DurableExecutionRecoveryStore = await openDurable(backend);
      expect(reopened.getOperation('operation-1')?.state).assertEqual(OperationJournalState.PREPARED);
    });

    it('durablyNormalizesInFlightCrashBeforeRecoveryReturns', 0, async () => {
      const backend: FixtureDurableBackend = new FixtureDurableBackend();
      const store: DurableExecutionRecoveryStore = await openDurable(backend);
      await authorizeDurable(store);
      await store.prepareOperation(intent(), reservation(), budgetScopes(true), 100);
      const lease = await store.acquireLease('task-1', 'owner-a', 1000, 110);
      await store.markOperationInFlight('operation-1', 'owner-a', lease.lease?.fencingToken as number, 120);
      const beforeRestart: number = store.revision();

      const reopened: DurableExecutionRecoveryStore = await openDurable(backend);
      expect(reopened.revision()).assertEqual(beforeRestart + 1);
      expect(reopened.getOperation('operation-1')?.state).assertEqual(OperationJournalState.UNKNOWN_OUTCOME);
      expect(reopened.getBudgetReservation('reservation-1')?.snapshot.state)
        .assertEqual(BudgetReservationState.UNKNOWN);
    });

    it('persistsCommittedOutcomeAndActualBudgetThroughDurableBackend', 0, async () => {
      const backend: FixtureDurableBackend = new FixtureDurableBackend();
      const store: DurableExecutionRecoveryStore = await openDurable(backend);
      await authorizeDurable(store);
      await store.prepareOperation(intent(), reservation(), budgetScopes(true), 100);
      const lease = await store.acquireLease('task-1', 'owner-a', 1000, 110);
      const token: number = lease.lease?.fencingToken as number;
      await store.markOperationInFlight('operation-1', 'owner-a', token, 120);
      expect((await store.recordOperationOutcome(
        'operation-1',
        outcome(),
        actualBudget(),
        'owner-a',
        token,
        130
      )).accepted).assertTrue();

      const reopened: DurableExecutionRecoveryStore = await openDurable(backend);
      expect(reopened.getOperation('operation-1')?.outcome?.providerReceipt).assertEqual('receipt-1');
      expect(reopened.getBudgetReservation('reservation-1')?.snapshot.actual.monetaryCostMicros).assertEqual(80);
      expect(reopened.getBudgetReservation('reservation-1')?.snapshot.state)
        .assertEqual(BudgetReservationState.SETTLED);
      expect(reopened.getBudgetScopes('task-1')[0].snapshot.reserved.monetaryCostMicros).assertEqual(0);
      expect(reopened.getBudgetScopes('task-1')[0].snapshot.consumed.monetaryCostMicros).assertEqual(80);
    });
  });
}
