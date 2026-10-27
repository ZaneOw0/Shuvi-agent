import relationalStore from '@ohos.data.relationalStore';
import { ContractValidator, ReconciliationReport, ToolInvocation, ToolOutcome } from '@harmony_agent/agent-contracts';
import { OperationJournalState } from '@harmony_agent/agent-core';
import { DispatchPersistenceContext, ProductionRuntimePersistencePort, RuntimeDurableAuthorityPayload,
  RuntimePersistenceResult, RuntimeTaskRecoveryCheckpoint } from '@harmony_agent/agent-runtime';
import { DurableExecutionRecoveryStore, EncryptedRdbConfigurationRequest, RdbSnapshotBackend,
  RuntimeExecutionRecoveryBridge, RuntimeExecutionRecoveryBridgeConfig, createEncryptedRdbStoreConfigs } from '@harmony_agent/agent-storage';

import { AgentRdbOpenPort, OwnedAgentRdb } from '../model/AgentRdbResources';
import { AgentHostDigest } from '../model/AgentHostDigest';

function calendarStoreConfig(): relationalStore.StoreConfig {
  const config = new EncryptedRdbConfigurationRequest();
  config.executionStoreName = 'shuvi_calendar_runtime_v1.db'; config.memoryStoreName = 'shuvi_calendar_unused_memory.db';
  return createEncryptedRdbStoreConfigs(config).execution;
}

/** Durable native-tool grants and outcomes; never auto-replays a calendar write. */
export class CalendarExecutionResource extends OwnedAgentRdb implements ProductionRuntimePersistencePort {
  onOutcomeRejected: (taskId: string) => void = (_taskId: string): void => {};
  private durable?: DurableExecutionRecoveryStore;
  private bridge?: RuntimeExecutionRecoveryBridge;
  private readonly recoveryConfig: RuntimeExecutionRecoveryBridgeConfig;
  private readonly digest: AgentHostDigest;
  private consumed: string[] = [];
  constructor(opener: AgentRdbOpenPort, config: RuntimeExecutionRecoveryBridgeConfig, digest: AgentHostDigest) {
    super(opener, calendarStoreConfig(), 'CALENDAR_EXECUTION'); this.recoveryConfig = config; this.digest = digest;
  }
  protected async initialize(store: relationalStore.RdbStore): Promise<void> {
    const opened = await DurableExecutionRecoveryStore.openForRuntimeRecovery(new RdbSnapshotBackend(store), this.digest);
    if (!opened.accepted || opened.store === undefined) throw new Error('CALENDAR_STORAGE_REJECTED');
    this.durable = opened.store; this.bridge = new RuntimeExecutionRecoveryBridge(opened.store, this.recoveryConfig);
  }
  protected detach(): void { this.bridge = undefined; this.durable = undefined; this.consumed = []; }
  private current(): RuntimeExecutionRecoveryBridge {
    if (this.bridge === undefined) throw new Error('CALENDAR_STORAGE_NOT_READY'); return this.bridge;
  }
  available(): boolean {
    this.assertReady();
    const store = this.durable; if (store === undefined) return false;
    return store.listTaskIds().length < 128;
  }
  saveCheckpoint(checkpoint: RuntimeTaskRecoveryCheckpoint, previous: number, authority: RuntimeDurableAuthorityPayload,
    now: number): Promise<RuntimePersistenceResult> {
    return this.run(() => this.current().saveCheckpoint(checkpoint, previous, authority, now));
  }
  loadCheckpoint(task: string): Promise<RuntimeTaskRecoveryCheckpoint | undefined> {
    return this.run(() => this.current().loadCheckpoint(task));
  }
  beforeDispatch(checkpoint: RuntimeTaskRecoveryCheckpoint, previous: number, context: DispatchPersistenceContext | undefined,
    authority: RuntimeDurableAuthorityPayload, now: number): Promise<RuntimePersistenceResult> {
    return this.run(async (): Promise<RuntimePersistenceResult> => {
      if (!this.available() || context === undefined) throw new Error('CALENDAR_TRIAL_ALLOWANCE_EXHAUSTED');
      // The bridge persists checkpoint, grant, operation and budget in one CAS before adapter invocation.
      return await this.current().beforeDispatch(checkpoint, previous, context, authority, now);
    });
  }
  recordDispatchRejected(context: DispatchPersistenceContext | undefined, dispatchId: string, code: string,
    now: number): Promise<RuntimePersistenceResult> {
    return this.run(() => this.current().recordDispatchRejected(context, dispatchId, code, now));
  }
  recordOutcome(task: string, step: string, dispatch: string, outcome: ToolOutcome, now: number): Promise<RuntimePersistenceResult> {
    return this.run(async (): Promise<RuntimePersistenceResult> => {
      try {
        const result = await this.current().recordOutcome(task, step, dispatch, outcome, now);
        if (!result.accepted) this.onOutcomeRejected(task);
        return result;
      } catch {
        this.onOutcomeRejected(task); throw new Error('CALENDAR_OUTCOME_NOT_DURABLE');
      }
    });
  }
  recordReconciliation(_report: ReconciliationReport, _now: number): Promise<RuntimePersistenceResult> {
    return Promise.reject(new Error('CALENDAR_TRIAL_RECONCILIATION_OFFLINE_ONLY'));
  }
  normalizeRecoveredOperation(_checkpoint: RuntimeTaskRecoveryCheckpoint, _previous: number,
    _now: number): Promise<RuntimePersistenceResult> { return Promise.reject(new Error('CALENDAR_NO_AUTO_RECOVERY')); }
  verify(invocation: ToolInvocation): boolean {

    try {
      this.assertReady(); const store = this.durable;
      if (store === undefined || !ContractValidator.validateToolInvocation(invocation).valid ||
        this.consumed.includes(invocation.invocationId)) return false;
      const operation = store.getOperation(invocation.operationId); if (operation === undefined) return false;
      const intent = operation.intent; const record = store.getPolicyRecord(intent.policyRequestId); const grant = record?.grant;
      if (operation.state !== OperationJournalState.IN_FLIGHT || operation.dispatchCount !== 1 ||
        grant === undefined || !ContractValidator.validateAuthorizationGrant(grant).valid ||
        intent.taskId !== invocation.taskId || intent.stepId !== invocation.stepId || intent.attemptId !== invocation.attemptId ||
        intent.invocationId !== invocation.invocationId || intent.toolId !== invocation.toolId ||
        intent.toolIdentityVersion !== invocation.toolIdentityVersion || intent.schemaDigest !== invocation.schemaDigest ||
        intent.argumentsDigest !== invocation.argumentsDigest || grant.grantId !== invocation.authorizationGrantId ||
        grant.taskId !== invocation.taskId || grant.stepId !== invocation.stepId || grant.operationId !== invocation.operationId ||
        grant.toolId !== invocation.toolId || grant.toolIdentityVersion !== invocation.toolIdentityVersion ||
        grant.schemaDigest !== invocation.schemaDigest || grant.argumentsDigest !== invocation.argumentsDigest ||
        grant.budgetReservationId !== intent.budgetReservationId || grant.policyRequestId !== intent.policyRequestId ||
        grant.policyVersion !== this.recoveryConfig.policyVersion || grant.userId !== this.recoveryConfig.ownerId ||
        grant.expiresAtMs <= Date.now() || grant.issuedAtMs > Date.now()) return false;
      this.consumed.push(invocation.invocationId); return true;
    } catch { return false; }
  }
}
