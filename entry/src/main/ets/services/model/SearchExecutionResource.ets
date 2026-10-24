import relationalStore from '@ohos.data.relationalStore';
import { ContractValidator, ReconciliationReport, ToolInvocation, ToolOutcome } from '@harmony_agent/agent-contracts';
import { OperationJournalState } from '@harmony_agent/agent-core';
import { DispatchPersistenceContext, ProductionRuntimePersistencePort, RuntimeDurableAuthorityPayload,
  RuntimePersistenceResult, RuntimeTaskRecoveryCheckpoint } from '@harmony_agent/agent-runtime';
import { DurableExecutionRecoveryStore, EncryptedRdbConfigurationRequest, RdbSnapshotBackend,
  RuntimeExecutionRecoveryBridge, RuntimeExecutionRecoveryBridgeConfig, createEncryptedRdbStoreConfigs } from '@harmony_agent/agent-storage';
import { McpGrantVerification, McpGrantVerifierPort } from '@harmony_agent/agent-connectors';
import { AgentRdbOpenPort, OwnedAgentRdb } from './AgentRdbResources';
import { AgentHostDigest } from './AgentHostDigest';

function searchStoreConfig(): relationalStore.StoreConfig {
  const config = new EncryptedRdbConfigurationRequest();
  config.executionStoreName = 'shuvi_search_execution_v1.db'; config.memoryStoreName = 'shuvi_search_unused_memory.db';
  return createEncryptedRdbStoreConfigs(config).execution;
}

/** One durable dispatch allowance for the debug trial, across sessions and process restarts.
 * No reset button, no auto recovery/re-dispatch, and no release on timeout/failed/unknown outcomes.
 * Billing reconciliation and an audited allowance release are intentionally separate future work.
 */
export class SearchExecutionResource extends OwnedAgentRdb implements ProductionRuntimePersistencePort, McpGrantVerifierPort {
  onOutcomeRejected: (taskId: string) => void = (_taskId: string): void => {};
  private durable?: DurableExecutionRecoveryStore;
  private bridge?: RuntimeExecutionRecoveryBridge;
  private readonly recoveryConfig: RuntimeExecutionRecoveryBridgeConfig;
  private readonly digest: AgentHostDigest;
  private consumed: string[] = [];
  constructor(opener: AgentRdbOpenPort, config: RuntimeExecutionRecoveryBridgeConfig, digest: AgentHostDigest) {
    super(opener, searchStoreConfig(), 'SEARCH_EXECUTION'); this.recoveryConfig = config; this.digest = digest;
  }
  protected async initialize(store: relationalStore.RdbStore): Promise<void> {
    const opened = await DurableExecutionRecoveryStore.openForRuntimeRecovery(new RdbSnapshotBackend(store), this.digest);
    if (!opened.accepted || opened.store === undefined) throw new Error('SEARCH_STORAGE_REJECTED');
    this.durable = opened.store; this.bridge = new RuntimeExecutionRecoveryBridge(opened.store, this.recoveryConfig);
  }
  protected detach(): void { this.bridge = undefined; this.durable = undefined; this.consumed = []; }
  private current(): RuntimeExecutionRecoveryBridge {
    if (this.bridge === undefined) throw new Error('SEARCH_STORAGE_NOT_READY'); return this.bridge;
  }
  available(): boolean {
    this.assertReady();
    const store = this.durable; if (store === undefined) return false;
    const tasks = store.listTaskIds();
    // Count every persisted reservation, including ambiguous and settled outcomes. No implicit release.
    for (let i = 0; i < tasks.length; i++) if (store.getBudgetReservations(tasks[i]).length > 0) return false;
    return tasks.length < 128;
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
      if (!this.available() || context === undefined) throw new Error('SEARCH_TRIAL_ALLOWANCE_EXHAUSTED');
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
        this.onOutcomeRejected(task); throw new Error('SEARCH_OUTCOME_NOT_DURABLE');
      }
    });
  }
  recordReconciliation(_report: ReconciliationReport, _now: number): Promise<RuntimePersistenceResult> {
    return Promise.reject(new Error('SEARCH_TRIAL_RECONCILIATION_OFFLINE_ONLY'));
  }
  normalizeRecoveredOperation(_checkpoint: RuntimeTaskRecoveryCheckpoint, _previous: number,
    _now: number): Promise<RuntimePersistenceResult> { return Promise.reject(new Error('SEARCH_NO_AUTO_RECOVERY')); }
  verify(invocation: ToolInvocation): McpGrantVerification {
    const result = new McpGrantVerification();
    try {
      this.assertReady(); const store = this.durable;
      if (store === undefined || !ContractValidator.validateToolInvocation(invocation).valid ||
        this.consumed.includes(invocation.invocationId)) return result;
      const operation = store.getOperation(invocation.operationId); if (operation === undefined) return result;
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
        grant.expiresAtMs <= Date.now() || grant.issuedAtMs > Date.now()) return result;
      this.consumed.push(invocation.invocationId); result.allowed = true; result.code = 'DURABLE_GRANT_VERIFIED'; return result;
    } catch { return result; }
  }
}
