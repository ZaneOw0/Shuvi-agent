import { describe, expect, it } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import common from '@ohos.app.ability.common';
import relationalStore from '@ohos.data.relationalStore';
import {
  AuthorizationDecision,
  AuthorizationDecisionType,
  AuthorizationGrant,
  AgentTaskSnapshot,
  ExecutionBudget,
  IdempotencyMode,
  PolicyRequest,
  SideEffect,
  ToolOutcome,
  ToolOutcomeStatus
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
  AGENT_STORAGE_VERSION,
  DurableExecutionRecoveryStore,
  DurableSnapshotBackendPort,
  RdbSnapshotBackend,
  SnapshotIntegrityPort,
  StorageWriteCode,
  StoredOperationIntent
} from '@harmony_agent/agent-storage';

class DeviceTestIntegrity implements SnapshotIntegrityPort {
  digest(payloadJson: string): string {
    return 'device-test-digest:' + payloadJson;
  }
}

async function appContext(): Promise<common.UIAbilityContext> {
  try {
    const ability = await abilityDelegatorRegistry.getAbilityDelegator().getCurrentTopAbility();
    return ability.context;
  } catch (error) {
    throw error as Error;
  }
}

function storeConfig(name: string): relationalStore.StoreConfig {
  return {
    name: name,
    securityLevel: relationalStore.SecurityLevel.S1
  };
}

async function removeDatabase(context: common.Context, config: relationalStore.StoreConfig): Promise<void> {
  try {
    await relationalStore.deleteRdbStore(context, config);
  } catch (error) {
    throw error as Error;
  }
}

function closeStore(store: relationalStore.RdbStore | undefined): void {
  if (store === undefined) return;
  try {
    store.close();
  } catch (error) {
    throw error as Error;
  }
}

async function closeAndRemoveDatabase(store: relationalStore.RdbStore | undefined,
  context: common.Context, config: relationalStore.StoreConfig): Promise<void> {
  try {
    closeStore(store);
  } finally {
    await removeDatabase(context, config);
  }
}

async function openRecoveryStore(store: relationalStore.RdbStore): Promise<DurableExecutionRecoveryStore> {
  const backend: DurableSnapshotBackendPort = new RdbSnapshotBackend(store);
  const opened = await DurableExecutionRecoveryStore.open(backend, new DeviceTestIntegrity());
  if (!opened.accepted || opened.store === undefined) {
    throw new Error('durable recovery store failed to open: ' + opened.code);
  }
  return opened.store;
}

function operationIntent(operationId: string): StoredOperationIntent {
  const value: StoredOperationIntent = new StoredOperationIntent();
  value.operationId = operationId;
  value.invocationId = 'invocation-' + operationId;
  value.taskId = 'task-' + operationId;
  value.stepId = 'step-' + operationId;
  value.attemptId = 'attempt-1';
  value.toolId = 'calendar.create';
  value.toolIdentityVersion = 'calendar-v1';
  value.schemaDigest = 'sha256:schema-device';
  value.argumentsDigest = 'sha256:arguments-' + operationId;
  value.idempotencyKey = 'idempotency-' + operationId;
  value.idempotencyMode = IdempotencyMode.PROVIDER_KEY;
  value.sideEffect = SideEffect.REVERSIBLE;
  value.policyRequestId = 'policy-' + operationId;
  value.budgetReservationId = 'reservation-' + operationId;
  value.createdAt = '2026-09-30T00:00:00.000Z';
  return value;
}

function runtimeSnapshot(taskId: string): AgentTaskSnapshot {
  const value: AgentTaskSnapshot = new AgentTaskSnapshot();
  value.requestId = 'request-' + taskId;
  value.taskId = taskId;
  value.sessionId = 'session-' + taskId;
  value.snapshotVersion = 1;
  value.lastEventSequence = 1;
  value.resultJson = '{"status":"running"}';
  value.updatedAt = '2026-10-08T15:00:00.000Z';
  return value;
}

function budgetLimit(): ExecutionBudget {
  const value: ExecutionBudget = new ExecutionBudget();
  value.maxMonetaryCostMicros = 1000;
  value.maxToolCalls = 10;
  return value;
}

function budgetScopes(operationId: string): BudgetScopeSnapshot[] {
  const values: BudgetScopeSnapshot[] = [];
  const kinds: BudgetScopeKind[] = [BudgetScopeKind.TASK, BudgetScopeKind.STEP, BudgetScopeKind.PROVIDER];
  const ids: string[] = ['task-' + operationId, 'step-' + operationId, 'provider-device'];
  for (let i: number = 0; i < kinds.length; i++) {
    const value: BudgetScopeSnapshot = new BudgetScopeSnapshot();
    value.kind = kinds[i];
    value.taskId = 'task-' + operationId;
    value.scopeId = ids[i];
    value.limit = budgetLimit();
    value.reserved.toolCalls = 1;
    value.reserved.monetaryCostMicros = 100;
    values.push(value);
  }
  return values;
}

function policyRequest(operationId: string): PolicyRequest {
  const value: PolicyRequest = new PolicyRequest();
  value.requestId = 'policy-' + operationId;
  value.userId = 'device-user';
  value.taskId = 'task-' + operationId;
  value.stepId = 'step-' + operationId;
  value.operationId = operationId;
  value.toolId = 'calendar.create';
  value.toolIdentityVersion = 'calendar-v1';
  value.providerId = 'provider-device';
  value.sideEffect = SideEffect.REVERSIBLE;
  value.schemaDigest = 'sha256:schema-device';
  value.argumentsDigest = 'sha256:arguments-' + operationId;
  value.estimatedCostMicros = 100;
  value.requestedAt = '2026-09-30T00:00:00.000Z';
  value.expiresAt = '2026-09-30T00:01:00.000Z';
  value.expiresAtMs = 60000;
  return value;
}

function policyDecision(operationId: string): AuthorizationDecision {
  const value: AuthorizationDecision = new AuthorizationDecision();
  value.commandId = 'decision-' + operationId;
  value.policyRequestId = 'policy-' + operationId;
  value.userId = 'device-user';
  value.taskId = 'task-' + operationId;
  value.decision = AuthorizationDecisionType.APPROVED;
  value.decidedAt = '2026-09-30T00:00:01.000Z';
  value.decidedAtMs = 1000;
  return value;
}

function authorizationGrant(operationId: string): AuthorizationGrant {
  const value: AuthorizationGrant = new AuthorizationGrant();
  value.grantId = 'grant-' + operationId;
  value.policyRequestId = 'policy-' + operationId;
  value.decisionCommandId = 'decision-' + operationId;
  value.userId = 'device-user';
  value.taskId = 'task-' + operationId;
  value.stepId = 'step-' + operationId;
  value.operationId = operationId;
  value.toolId = 'calendar.create';
  value.toolIdentityVersion = 'calendar-v1';
  value.schemaDigest = 'sha256:schema-device';
  value.argumentsDigest = 'sha256:arguments-' + operationId;
  value.budgetReservationId = 'reservation-' + operationId;
  value.policyVersion = 'policy-v1';
  value.issuedAt = '2026-09-30T00:00:01.000Z';
  value.expiresAt = '2026-09-30T00:01:00.000Z';
  value.issuedAtMs = 1000;
  value.expiresAtMs = 60000;
  return value;
}

async function authorize(store: DurableExecutionRecoveryStore, operationId: string): Promise<void> {
  await store.savePolicyRequest(policyRequest(operationId), 70);
  await store.savePolicyDecision('policy-' + operationId, policyDecision(operationId), 1, 80);
  await store.saveAuthorizationGrant('policy-' + operationId, authorizationGrant(operationId), 2, 90);
}

function budgetReservation(operationId: string): BudgetReservationSnapshot {
  const value: BudgetReservationSnapshot = new BudgetReservationSnapshot();
  value.reservationId = 'reservation-' + operationId;
  value.taskId = 'task-' + operationId;
  value.stepId = 'step-' + operationId;
  value.providerId = 'provider-device';
  value.requested.toolCalls = 1;
  value.requested.monetaryCostMicros = 100;
  value.state = BudgetReservationState.RESERVED;
  return value;
}

function toolOutcome(operationId: string): ToolOutcome {
  const value: ToolOutcome = new ToolOutcome();
  value.invocationId = 'invocation-' + operationId;
  value.status = ToolOutcomeStatus.SUCCEEDED;
  value.resultJson = '{"eventId":"device-event-1"}';
  value.resultDigest = 'sha256:device-result';
  value.providerReceipt = 'device-provider-receipt';
  value.startedAt = '2026-09-30T00:00:01.000Z';
  value.finishedAt = '2026-09-30T00:00:02.000Z';
  return value;
}

function actualBudget(): BudgetAmount {
  const value: BudgetAmount = new BudgetAmount();
  value.toolCalls = 1;
  value.monetaryCostMicros = 80;
  return value;
}

async function prepareAndLease(store: DurableExecutionRecoveryStore, operationId: string): Promise<number> {
  await authorize(store, operationId);
  const prepared = await store.prepareOperation(
    operationIntent(operationId),
    budgetReservation(operationId),
    budgetScopes(operationId),
    100
  );
  expect(prepared.accepted).assertTrue();
  const lease = await store.acquireLease('task-' + operationId, 'device-owner', 10000, 110);
  if (!lease.accepted || lease.lease === undefined) {
    throw new Error('device recovery lease was not acquired');
  }
  return lease.lease.fencingToken;
}

export default function storageDeviceRecoveryTest(): void {
  describe('StorageDeviceRecovery', () => {
    it('loadsAgentStorageHar', 0, () => {
      expect(AGENT_STORAGE_VERSION).assertEqual('0.8.0');
    });

    it('persistsPreparedIntentAndBudgetAcrossCloseReopen', 0, async () => {
      const context: common.Context = await appContext();
      const config: relationalStore.StoreConfig = storeConfig('harmony_agent_storage_prepared.db');
      await removeDatabase(context, config);
      let rdb: relationalStore.RdbStore | undefined = undefined;
      try {
        rdb = await relationalStore.getRdbStore(context, config);
        const first: DurableExecutionRecoveryStore = await openRecoveryStore(rdb);
        await authorize(first, 'prepared');
        expect((await first.prepareOperation(
          operationIntent('prepared'),
          budgetReservation('prepared'),
          budgetScopes('prepared'),
          100
        )).accepted).assertTrue();
        closeStore(rdb);
        rdb = undefined;

        rdb = await relationalStore.getRdbStore(context, config);
        const reopened: DurableExecutionRecoveryStore = await openRecoveryStore(rdb);
        expect(reopened.getOperation('prepared')?.state).assertEqual(OperationJournalState.PREPARED);
        expect(reopened.getBudgetReservation('reservation-prepared')?.snapshot.state)
          .assertEqual(BudgetReservationState.RESERVED);
      } finally {
        await closeAndRemoveDatabase(rdb, context, config);
      }
    });

    it('persistsOpaqueRuntimeCheckpointAndEnumerationAcrossCloseReopen', 0, async () => {
      const context: common.Context = await appContext();
      const config: relationalStore.StoreConfig = storeConfig('harmony_agent_storage_checkpoint.db');
      await removeDatabase(context, config);
      let rdb: relationalStore.RdbStore | undefined = undefined;
      try {
        rdb = await relationalStore.getRdbStore(context, config);
        const first: DurableExecutionRecoveryStore = await openRecoveryStore(rdb);
        const checkpointJson: string = '{"checkpointVersion":"1.1","taskId":"task-checkpoint"}';
        expect((await first.saveTask(
          runtimeSnapshot('task-checkpoint'), '1.1', checkpointJson, 0, 100)).accepted).assertTrue();
        closeStore(rdb);
        rdb = undefined;

        rdb = await relationalStore.getRdbStore(context, config);
        const reopened: DurableExecutionRecoveryStore = await openRecoveryStore(rdb);
        expect(reopened.listTaskIds().length).assertEqual(1);
        expect(reopened.listTaskIds()[0]).assertEqual('task-checkpoint');
        expect(reopened.getTask('task-checkpoint')?.checkpointVersion).assertEqual('1.1');
        expect(reopened.getTask('task-checkpoint')?.checkpointJson).assertEqual(checkpointJson);
      } finally {
        await closeAndRemoveDatabase(rdb, context, config);
      }
    });

    it('normalizesCrashDuringCallToUnknownBeforeRecovery', 0, async () => {
      const context: common.Context = await appContext();
      const config: relationalStore.StoreConfig = storeConfig('harmony_agent_storage_inflight.db');
      await removeDatabase(context, config);
      let rdb: relationalStore.RdbStore | undefined = undefined;
      try {
        rdb = await relationalStore.getRdbStore(context, config);
        const first: DurableExecutionRecoveryStore = await openRecoveryStore(rdb);
        const token: number = await prepareAndLease(first, 'inflight');
        expect((await first.markOperationInFlight('inflight', 'device-owner', token, 120)).accepted).assertTrue();
        closeStore(rdb);
        rdb = undefined;

        rdb = await relationalStore.getRdbStore(context, config);
        const reopened: DurableExecutionRecoveryStore = await openRecoveryStore(rdb);
        expect(reopened.getOperation('inflight')?.state).assertEqual(OperationJournalState.UNKNOWN_OUTCOME);
        expect(reopened.getBudgetReservation('reservation-inflight')?.snapshot.state)
          .assertEqual(BudgetReservationState.UNKNOWN);
      } finally {
        await closeAndRemoveDatabase(rdb, context, config);
      }
    });

    it('doesNotCommitObservedResultLostBeforeStorageCommit', 0, async () => {
      const context: common.Context = await appContext();
      const config: relationalStore.StoreConfig = storeConfig('harmony_agent_storage_result_gap.db');
      await removeDatabase(context, config);
      let rdb: relationalStore.RdbStore | undefined = undefined;
      try {
        rdb = await relationalStore.getRdbStore(context, config);
        const first: DurableExecutionRecoveryStore = await openRecoveryStore(rdb);
        const token: number = await prepareAndLease(first, 'result-gap');
        await first.markOperationInFlight('result-gap', 'device-owner', token, 120);
        const observedButNotCommitted: ToolOutcome = toolOutcome('result-gap');
        expect(observedButNotCommitted.providerReceipt).assertEqual('device-provider-receipt');
        closeStore(rdb);
        rdb = undefined;

        rdb = await relationalStore.getRdbStore(context, config);
        const reopened: DurableExecutionRecoveryStore = await openRecoveryStore(rdb);
        expect(reopened.getOperation('result-gap')?.state).assertEqual(OperationJournalState.UNKNOWN_OUTCOME);
        expect(reopened.getOperation('result-gap')?.outcome === undefined).assertTrue();
      } finally {
        await closeAndRemoveDatabase(rdb, context, config);
      }
    });

    it('persistsCommittedReceiptAndActualBudgetAcrossCloseReopen', 0, async () => {
      const context: common.Context = await appContext();
      const config: relationalStore.StoreConfig = storeConfig('harmony_agent_storage_committed.db');
      await removeDatabase(context, config);
      let rdb: relationalStore.RdbStore | undefined = undefined;
      try {
        rdb = await relationalStore.getRdbStore(context, config);
        const first: DurableExecutionRecoveryStore = await openRecoveryStore(rdb);
        const token: number = await prepareAndLease(first, 'committed');
        await first.markOperationInFlight('committed', 'device-owner', token, 120);
        expect((await first.recordOperationOutcome(
          'committed',
          toolOutcome('committed'),
          actualBudget(),
          'device-owner',
          token,
          130
        )).accepted).assertTrue();
        closeStore(rdb);
        rdb = undefined;

        rdb = await relationalStore.getRdbStore(context, config);
        const reopened: DurableExecutionRecoveryStore = await openRecoveryStore(rdb);
        expect(reopened.getOperation('committed')?.outcome?.providerReceipt)
          .assertEqual('device-provider-receipt');
        expect(reopened.getBudgetReservation('reservation-committed')?.snapshot.actual.monetaryCostMicros)
          .assertEqual(80);
      } finally {
        await closeAndRemoveDatabase(rdb, context, config);
      }
    });

    it('allowsOnlyOneLeaseOwnerFromStaleSessions', 0, async () => {
      const context: common.Context = await appContext();
      const config: relationalStore.StoreConfig = storeConfig('harmony_agent_storage_lease.db');
      await removeDatabase(context, config);
      let rdb: relationalStore.RdbStore | undefined = undefined;
      try {
        rdb = await relationalStore.getRdbStore(context, config);
        const bootstrap: DurableExecutionRecoveryStore = await openRecoveryStore(rdb);
        await authorize(bootstrap, 'lease');
        await bootstrap.prepareOperation(
          operationIntent('lease'), budgetReservation('lease'), budgetScopes('lease'), 100);
        const first: DurableExecutionRecoveryStore = await openRecoveryStore(rdb);
        const second: DurableExecutionRecoveryStore = await openRecoveryStore(rdb);
        expect((await first.acquireLease('task-lease', 'owner-first', 10000, 110)).accepted).assertTrue();
        const losing = await second.acquireLease('task-lease', 'owner-second', 10000, 110);
        expect(losing.code).assertEqual(StorageWriteCode.VERSION_CONFLICT);
        expect(second.getLease('task-lease') === undefined).assertTrue();
      } finally {
        await closeAndRemoveDatabase(rdb, context, config);
      }
    });

    it('failsClosedWhenPersistedSnapshotDigestIsCorrupt', 0, async () => {
      const context: common.Context = await appContext();
      const config: relationalStore.StoreConfig = storeConfig('harmony_agent_storage_corrupt.db');
      await removeDatabase(context, config);
      let rdb: relationalStore.RdbStore | undefined = undefined;
      try {
        rdb = await relationalStore.getRdbStore(context, config);
        const first: DurableExecutionRecoveryStore = await openRecoveryStore(rdb);
        await authorize(first, 'corrupt');
        await first.prepareOperation(
          operationIntent('corrupt'), budgetReservation('corrupt'), budgetScopes('corrupt'), 100);
        await rdb.execute(
          'UPDATE harmony_agent_recovery_snapshot SET payload_digest = ? WHERE slot_id = ?',
          ['corrupt-digest', 1]
        );
        const backend: DurableSnapshotBackendPort = new RdbSnapshotBackend(rdb);
        const opened = await DurableExecutionRecoveryStore.open(backend, new DeviceTestIntegrity());
        expect(opened.accepted).assertFalse();
        expect(opened.code).assertEqual(StorageWriteCode.CORRUPT_SNAPSHOT);
      } finally {
        await closeAndRemoveDatabase(rdb, context, config);
      }
    });
  });
}
