import relationalStore from '@ohos.data.relationalStore';
import { ContractValidator, ReconciliationReport, ToolInvocation, ToolOutcome } from '@harmony_agent/agent-contracts';
import { BudgetAmount, OperationJournalState } from '@harmony_agent/agent-core';
import {
  DispatchPersistenceContext, ProductionRuntimePersistencePort, RuntimeDurableAuthorityPayload,
  RuntimePersistenceResult, RuntimeTaskRecoveryCheckpoint
} from '@harmony_agent/agent-runtime';
import {
  DurableExecutionRecoveryStore, EncryptedRdbConfigurationRequest, RdbSnapshotBackend,
  RuntimeExecutionRecoveryBridge, RuntimeExecutionRecoveryBridgeConfig, RuntimeOutcomeAccountingPort,
  createEncryptedRdbStoreConfigs
} from '@harmony_agent/agent-storage';
import { RuntimePendingInvoicePort } from '@harmony_agent/agent-storage';
import { StoredOperation } from '@harmony_agent/agent-storage';
import { AgentRdbOpenPort, OwnedAgentRdb } from './AgentRdbResources';
import { AgentHostDigest } from './AgentHostDigest';
import { copyToolOutcome } from './ChatSnapshotCopies';

function knowledgeStoreConfig(name: string): relationalStore.StoreConfig {
  const config = new EncryptedRdbConfigurationRequest();
  config.executionStoreName = name; config.memoryStoreName = 'shuvi_knowledge_runtime_unused.db';
  return createEncryptedRdbStoreConfigs(config).execution;
}

class LocalKnowledgeAccounting implements RuntimeOutcomeAccountingPort {
  actualForOutcome(_operation: StoredOperation, _outcome: ToolOutcome): BudgetAmount {
    const amount: BudgetAmount = new BudgetAmount(); amount.toolCalls = 1; return amount;
  }
}

/** Durable authority and grant verifier for the zero-cost, local knowledge-read tool. */
export class KnowledgeExecutionResource extends OwnedAgentRdb implements ProductionRuntimePersistencePort {
  lastOutcome?: ToolOutcome;
  beginOperation(): void { this.lastOutcome = undefined; }
  onOutcomeRejected: (taskId: string) => void = (_taskId: string): void => {};
  private durable?: DurableExecutionRecoveryStore;
  private bridge?: RuntimeExecutionRecoveryBridge;
  private readonly recoveryConfig: RuntimeExecutionRecoveryBridgeConfig;
  private consumed: string[] = [];

  constructor(opener: AgentRdbOpenPort, ownerId: string, policyVersion: string, digest: AgentHostDigest,
    accounting: RuntimeOutcomeAccountingPort = new LocalKnowledgeAccounting(), name: string = 'shuvi_knowledge_runtime_v1.db',
    pendingInvoice?: RuntimePendingInvoicePort) {
    super(opener,knowledgeStoreConfig(name),'KNOWLEDGE_RUNTIME_EXECUTION');
    const config: RuntimeExecutionRecoveryBridgeConfig = new RuntimeExecutionRecoveryBridgeConfig();
    config.ownerId = ownerId; config.policyVersion = policyVersion; config.leaseTtlMs = 60000;
    config.outcomeAccounting = accounting; this.recoveryConfig = config; this.digest = digest;
    config.pendingInvoice = pendingInvoice;
  }

  private readonly digest: AgentHostDigest;

  protected async initialize(store: relationalStore.RdbStore): Promise<void> {
    const opened = await DurableExecutionRecoveryStore.openForRuntimeRecovery(new RdbSnapshotBackend(store),this.digest);
    if (!opened.accepted || opened.store === undefined) { throw new Error('KNOWLEDGE_RUNTIME_STORAGE_REJECTED'); }
    this.durable = opened.store; this.bridge = new RuntimeExecutionRecoveryBridge(opened.store,this.recoveryConfig);
  }
  protected detach(): void { this.bridge = undefined; this.durable = undefined; this.consumed = []; this.lastOutcome = undefined; }
  private current(): RuntimeExecutionRecoveryBridge {
    if (this.bridge === undefined) { throw new Error('KNOWLEDGE_RUNTIME_STORAGE_NOT_READY'); } return this.bridge;
  }
  saveCheckpoint(c: RuntimeTaskRecoveryCheckpoint,p: number,a: RuntimeDurableAuthorityPayload,n: number): Promise<RuntimePersistenceResult> {
    return this.run((): Promise<RuntimePersistenceResult> => this.current().saveCheckpoint(c,p,a,n));
  }
  loadCheckpoint(id: string): Promise<RuntimeTaskRecoveryCheckpoint | undefined> {
    return this.run((): Promise<RuntimeTaskRecoveryCheckpoint | undefined> => this.current().loadCheckpoint(id));
  }
  beforeDispatch(c: RuntimeTaskRecoveryCheckpoint,p: number,d: DispatchPersistenceContext | undefined,
    a: RuntimeDurableAuthorityPayload,n: number): Promise<RuntimePersistenceResult> {
    return this.run((): Promise<RuntimePersistenceResult> => this.current().beforeDispatch(c,p,d,a,n));
  }
  recordDispatchRejected(c: DispatchPersistenceContext | undefined,d: string,r: string,n: number): Promise<RuntimePersistenceResult> {
    return this.run((): Promise<RuntimePersistenceResult> => this.current().recordDispatchRejected(c,d,r,n));
  }
  async recordOutcome(t: string,s: string,d: string,o: ToolOutcome,n: number): Promise<RuntimePersistenceResult> {
    try {
      const result: RuntimePersistenceResult = await this.run((): Promise<RuntimePersistenceResult> =>
        this.current().recordOutcome(t,s,d,o,n));
      if (!result.accepted && !result.duplicate) { this.onOutcomeRejected(t); }
      else { this.lastOutcome = copyToolOutcome(o); }
      return result;
    } catch (error) {
      this.onOutcomeRejected(t);
      if (error instanceof Error) { throw error; }
      throw new Error('KNOWLEDGE_OUTCOME_WRITE_FAILED');
    }
  }
  recordReconciliation(_r: ReconciliationReport,_n: number): Promise<RuntimePersistenceResult> {
    return Promise.reject(new Error('KNOWLEDGE_RUNTIME_RECONCILIATION_DISABLED'));
  }
  normalizeRecoveredOperation(_c: RuntimeTaskRecoveryCheckpoint,_p: number,_n: number): Promise<RuntimePersistenceResult> {
    return Promise.reject(new Error('KNOWLEDGE_RUNTIME_NO_AUTO_RECOVERY'));
  }

  verify(invocation: ToolInvocation): boolean {
    try {
      this.assertReady(); const store: DurableExecutionRecoveryStore | undefined = this.durable;
      if (store === undefined || !ContractValidator.validateToolInvocation(invocation).valid ||
        this.consumed.indexOf(invocation.invocationId) >= 0) { return false; }
      const operation = store.getOperation(invocation.operationId); if (operation === undefined) { return false; }
      const intent = operation.intent; const record = store.getPolicyRecord(intent.policyRequestId); const grant = record?.grant;
      if (operation.state !== OperationJournalState.IN_FLIGHT || operation.dispatchCount !== 1 || grant === undefined ||
        !ContractValidator.validateAuthorizationGrant(grant).valid || intent.taskId !== invocation.taskId ||
        intent.stepId !== invocation.stepId || intent.attemptId !== invocation.attemptId || intent.invocationId !== invocation.invocationId ||
        intent.toolId !== invocation.toolId || intent.toolIdentityVersion !== invocation.toolIdentityVersion ||
        intent.schemaDigest !== invocation.schemaDigest || intent.argumentsDigest !== invocation.argumentsDigest ||
        grant.grantId !== invocation.authorizationGrantId || grant.taskId !== invocation.taskId || grant.stepId !== invocation.stepId ||
        grant.operationId !== invocation.operationId || grant.toolId !== invocation.toolId ||
        grant.toolIdentityVersion !== invocation.toolIdentityVersion || grant.schemaDigest !== invocation.schemaDigest ||
        grant.argumentsDigest !== invocation.argumentsDigest || grant.budgetReservationId !== intent.budgetReservationId ||
        grant.policyRequestId !== intent.policyRequestId || grant.policyVersion !== this.recoveryConfig.policyVersion ||
        grant.userId !== this.recoveryConfig.ownerId || grant.expiresAtMs <= Date.now() || grant.issuedAtMs > Date.now()) { return false; }
      this.consumed.push(invocation.invocationId); return true;
    } catch { return false; }
  }
}
