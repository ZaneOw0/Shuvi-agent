import common from '@ohos.app.ability.common';
import relationalStore from '@ohos.data.relationalStore';
import { ContractValidator, ReconciliationReport, ToolInvocation, ToolOutcome } from '@harmony_agent/agent-contracts';
import { OperationJournalState } from '@harmony_agent/agent-core';
import { DispatchPersistenceContext, ProductionRuntimePersistencePort, RuntimeDurableAuthorityPayload,
  RuntimePersistenceResult, RuntimeTaskRecoveryCheckpoint } from '@harmony_agent/agent-runtime';
import { DurableExecutionRecoveryStore, DurableSnapshotBackendPort, EncryptedRdbConfigurationRequest, RdbSnapshotBackend,
  RuntimeExecutionRecoveryBridge, RuntimeExecutionRecoveryBridgeConfig, StorageSnapshotEnvelope,
  createEncryptedRdbStoreConfigs } from '@harmony_agent/agent-storage';
import { McpGrantVerification, McpGrantVerifierPort } from '@harmony_agent/agent-connectors';
import { AgentRdbOpenPort, OwnedAgentRdb } from './AgentRdbResources';
import { AgentHostDigest } from './AgentHostDigest';

function searchStoreConfig(): relationalStore.StoreConfig {
  const config = new EncryptedRdbConfigurationRequest();
  config.executionStoreName = 'shuvi_search_execution_v1.db'; config.memoryStoreName = 'shuvi_search_unused_memory.db';
  return createEncryptedRdbStoreConfigs(config).execution;
}

/** Deletes the whole search record database (file and journal), used only when it is full. */
export interface SearchStoreEraserPort {
  erase(config: relationalStore.StoreConfig): Promise<void>;
}
export class NativeSearchStoreEraser implements SearchStoreEraserPort {
  private readonly context: common.Context;
  constructor(context: common.Context) { this.context = context; }
  async erase(config: relationalStore.StoreConfig): Promise<void> { await relationalStore.deleteRdbStore(this.context, config); }
}

/** Search tasks the durable store may hold; each send creates one, including denied or cancelled ones. */
export const SEARCH_HISTORY_LIMIT: number = 128;
/**
 * The whole store is one RDB row, rewritten on every change; a row over about 2 MB can be written but not read back.
 * New searches stop at the soft limit (one search adds roughly 20-40 KB); no write may ever pass the hard limit.
 */
export const SEARCH_STORE_SOFT_LIMIT_BYTES: number = 1200000;
export const SEARCH_STORE_DISPATCH_LIMIT_BYTES: number = 1500000;
export const SEARCH_STORE_HARD_LIMIT_BYTES: number = 1800000;

export function utf8Length(value: string): number {
  let bytes: number = 0;
  for (let i: number = 0; i < value.length; i++) {
    const code: number = value.charCodeAt(i);
    if (code < 0x80) bytes += 1;
    else if (code < 0x800) bytes += 2;
    else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < value.length &&
      value.charCodeAt(i + 1) >= 0xDC00 && value.charCodeAt(i + 1) <= 0xDFFF) { bytes += 4; i++; }
    else bytes += 3;
  }
  return bytes;
}
/** Tracks the stored row size and refuses any write that could make the row unreadable. */
class MeasuredSnapshotBackend implements DurableSnapshotBackendPort {
  bytes: number = 0;
  private readonly delegate: DurableSnapshotBackendPort;
  constructor(delegate: DurableSnapshotBackendPort) { this.delegate = delegate; }
  initialize(): Promise<void> { return this.delegate.initialize(); }
  async load(): Promise<StorageSnapshotEnvelope | undefined> {
    const envelope = await this.delegate.load();
    this.bytes = envelope === undefined ? 0 : utf8Length(envelope.payloadJson);
    return envelope;
  }
  async compareAndSet(expectedRevision: number, next: StorageSnapshotEnvelope): Promise<boolean> {
    const size = utf8Length(next.payloadJson);
    if (size > SEARCH_STORE_HARD_LIMIT_BYTES) throw new Error('SEARCH_STORE_TOO_LARGE');
    const written = await this.delegate.compareAndSet(expectedRevision, next);
    if (written) this.bytes = size;
    return written;
  }
}

/** Durable execution record for phone-direct Tavily searches. Every authorized search is recorded before it is sent,
 * with its pending (unreconciled) usage; nothing is ever re-sent automatically. The store keeps every task, so it
 * accepts at most SEARCH_HISTORY_LIMIT of them and stops new searches near the row-size limit. When it is opened full,
 * the whole database is deleted and started empty (the user chose clearing over archiving); this happens only while
 * opening, so no search of this process is in flight. Supplier-side usage stays visible in the Tavily console.
 */
export class SearchExecutionResource extends OwnedAgentRdb implements ProductionRuntimePersistencePort, McpGrantVerifierPort {
  onOutcomeRejected: (taskId: string) => void = (_taskId: string): void => {};
  private durable?: DurableExecutionRecoveryStore;
  private measured?: MeasuredSnapshotBackend;
  private bridge?: RuntimeExecutionRecoveryBridge;
  private readonly recoveryConfig: RuntimeExecutionRecoveryBridgeConfig;
  private readonly digest: AgentHostDigest;
  private consumed: string[] = [];
  private readonly eraser?: SearchStoreEraserPort;
  private readonly storeConfig: relationalStore.StoreConfig = searchStoreConfig();
  private readonly softLimitBytes: number;
  private opened?: Promise<void>;
  /** True once this resource deleted a full store while opening. */
  cleared: boolean = false;
  constructor(opener: AgentRdbOpenPort, config: RuntimeExecutionRecoveryBridgeConfig, digest: AgentHostDigest,
    eraser?: SearchStoreEraserPort, softLimitBytes: number = SEARCH_STORE_SOFT_LIMIT_BYTES) {
    super(opener, searchStoreConfig(), 'SEARCH_EXECUTION'); this.recoveryConfig = config; this.digest = digest;
    this.eraser = eraser; this.softLimitBytes = softLimitBytes;
  }
  /** Opens the store; a full one is deleted and reopened empty when an eraser is configured. */
  open(): Promise<void> {
    if (this.opened === undefined) {
      const work: Promise<void> = this.openClearingWhenFull();
      this.opened = work.finally((): void => { this.opened = undefined; });
    }
    return this.opened;
  }
  private async openClearingWhenFull(): Promise<void> {
    await super.open();
    if (this.eraser === undefined || this.available()) return;
    await super.close();
    await this.eraser.erase(this.storeConfig);
    this.cleared = true;
    await super.open();
  }
  protected async initialize(store: relationalStore.RdbStore): Promise<void> {
    const measured = new MeasuredSnapshotBackend(new RdbSnapshotBackend(store));
    const opened = await DurableExecutionRecoveryStore.openForRuntimeRecovery(measured, this.digest);
    if (!opened.accepted || opened.store === undefined) throw new Error('SEARCH_STORAGE_REJECTED');
    this.measured = measured; this.durable = opened.store; this.bridge = new RuntimeExecutionRecoveryBridge(opened.store, this.recoveryConfig);
  }
  protected detach(): void { this.bridge = undefined; this.durable = undefined; this.measured = undefined; this.consumed = []; }
  private current(): RuntimeExecutionRecoveryBridge {
    if (this.bridge === undefined) throw new Error('SEARCH_STORAGE_NOT_READY'); return this.bridge;
  }
  private taskCount(): number {
    this.assertReady();
    const store = this.durable; if (store === undefined) return SEARCH_HISTORY_LIMIT + 1;
    return store.listTaskIds().length;
  }
  private storedBytes(): number { return this.measured === undefined ? SEARCH_STORE_HARD_LIMIT_BYTES : this.measured.bytes; }
  /** Room for one more search task. Earlier searches, including ambiguous or failed ones, no longer block a new one. */
  available(): boolean {
    return this.taskCount() < SEARCH_HISTORY_LIMIT && this.storedBytes() < this.softLimitBytes;
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
      // The dispatching task already holds its own record, so it may use the last slot.
      if (this.taskCount() > SEARCH_HISTORY_LIMIT || this.storedBytes() >= SEARCH_STORE_DISPATCH_LIMIT_BYTES ||
        context === undefined) throw new Error('SEARCH_HISTORY_FULL');
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
