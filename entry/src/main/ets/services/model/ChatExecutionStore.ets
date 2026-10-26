import { copyRuntimeTaskRecoveryCheckpoint, copyToolOutcome } from './ChatSnapshotCopies';
import relationalStore from '@ohos.data.relationalStore';
import { ContractValidator, ReconciliationReport, ToolOutcome, WorkflowStepKind } from '@harmony_agent/agent-contracts';
import {
  DispatchPersistenceContext, ProductionRuntimePersistencePort, RuntimeCheckpointValidator,
  RuntimeDurableAuthorityPayload, RuntimePersistenceCode, RuntimePersistenceResult, RuntimeTaskRecoveryCheckpoint
} from '@harmony_agent/agent-runtime';
import { DurableSnapshotBackendPort, EncryptedRdbConfigurationRequest, RdbSnapshotBackend,
  StorageSnapshotEnvelope, createEncryptedRdbStoreConfigs } from '@harmony_agent/agent-storage';
import { AgentHostDigest } from './AgentHostDigest';
import { AgentRdbOpenPort, OwnedAgentRdb } from './AgentRdbResources';

// App-owned model-only journal. It never writes the tool recovery store or settles an invoice.
class ChatRecord {
  checkpoint: RuntimeTaskRecoveryCheckpoint = new RuntimeTaskRecoveryCheckpoint();
  dispatchId: string = '';
  stepId: string = '';
  outcome?: ToolOutcome;
  rejectionCode: string = '';
}
function copyRecord(value: ChatRecord): ChatRecord {
  const copy = new ChatRecord();
  copy.checkpoint = copyRuntimeTaskRecoveryCheckpoint(value.checkpoint);
  copy.dispatchId = value.dispatchId; copy.stepId = value.stepId; copy.rejectionCode = value.rejectionCode;
  if (value.outcome !== undefined) copy.outcome = copyToolOutcome(value.outcome);
  return copy;
}
class ChatJournal { records: ChatRecord[] = []; }

function response(accepted: boolean, duplicate: boolean = false): RuntimePersistenceResult {
  const value = new RuntimePersistenceResult(); value.accepted = accepted; value.duplicate = duplicate;
  value.code = accepted ? (duplicate ? RuntimePersistenceCode.UNCHANGED : RuntimePersistenceCode.SAVED) : RuntimePersistenceCode.REJECTED;
  return value;
}
function recordObject(value: Object): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}

export class ChatExecutionStore implements ProductionRuntimePersistencePort {
  private readonly backend: DurableSnapshotBackendPort;
  private readonly digest: AgentHostDigest;
  private journal: ChatJournal = new ChatJournal();
  private revision: number = 0;
  constructor(backend: DurableSnapshotBackendPort, digest: AgentHostDigest) { this.backend = backend; this.digest = digest; }
  async open(): Promise<void> {
    await this.backend.initialize();
    const envelope = await this.backend.load();
    if (envelope === undefined) return;
    if (envelope.schemaVersion !== 'shuvi-chat-1.0' || !Number.isSafeInteger(envelope.revision) || envelope.revision < 1 ||
      typeof envelope.payloadJson !== 'string' || envelope.payloadJson.length > 800000 ||
      this.digest.digest(envelope.payloadJson) !== envelope.payloadDigest) throw new Error('CHAT_JOURNAL_INVALID');
    const parsed: ChatJournal = JSON.parse(envelope.payloadJson);
    if (!recordObject(parsed) || !Array.isArray(parsed.records) || parsed.records.length > 128) throw new Error('CHAT_JOURNAL_INVALID');
    const ids: string[] = [];
    for (const item of parsed.records) {
      if (!recordObject(item) || !RuntimeCheckpointValidator.validate(item.checkpoint).valid ||
        typeof item.dispatchId !== 'string' || typeof item.stepId !== 'string' || typeof item.rejectionCode !== 'string' ||
        ids.indexOf(item.checkpoint.snapshot.taskId) >= 0 ||
        (item.outcome !== undefined && (!ContractValidator.validateToolOutcome(item.outcome).valid ||
          item.outcome.invocationId !== item.dispatchId))) throw new Error('CHAT_JOURNAL_INVALID');
      ids.push(item.checkpoint.snapshot.taskId);
    }
    this.journal = parsed; this.revision = envelope.revision;
  }
  private find(taskId: string): ChatRecord | undefined {
    return this.journal.records.find((item: ChatRecord): boolean => item.checkpoint.snapshot.taskId === taskId);
  }
  private async write(record: ChatRecord): Promise<RuntimePersistenceResult> {
    const next = new ChatJournal();
    // Stored records are immutable; only the array and the replaced record change.
    next.records = this.journal.records.slice();
    const index = next.records.findIndex((item: ChatRecord): boolean => item.checkpoint.snapshot.taskId === record.checkpoint.snapshot.taskId);
    if (index < 0) { if (next.records.length >= 128) return response(false); next.records.push(record); }
    else next.records[index] = record;
    const envelope = new StorageSnapshotEnvelope(); envelope.schemaVersion = 'shuvi-chat-1.0';
    envelope.revision = this.revision + 1; envelope.payloadJson = JSON.stringify(next);
    if (envelope.payloadJson.length > 800000) return response(false);
    envelope.payloadDigest = this.digest.digest(envelope.payloadJson);
    if (!await this.backend.compareAndSet(this.revision, envelope)) return response(false);
    this.revision = envelope.revision; this.journal = next; return response(true);
  }
  async saveCheckpoint(checkpoint: RuntimeTaskRecoveryCheckpoint, previous: number,
    authority: RuntimeDurableAuthorityPayload, _now: number): Promise<RuntimePersistenceResult> {
    const next = this.checkpointRecord(checkpoint, previous, authority);
    return next === undefined ? response(false) : await this.write(next);
  }
  private checkpointRecord(checkpoint: RuntimeTaskRecoveryCheckpoint, previous: number,
    authority: RuntimeDurableAuthorityPayload): ChatRecord | undefined {
    if (!RuntimeCheckpointValidator.validate(checkpoint).valid || checkpoint.snapshot.snapshotVersion !== previous + 1 ||
      checkpoint.envelope.userId !== 'shuvi-local-owner-v1' || checkpoint.activeInvocation !== undefined ||
      authority.operation !== undefined || authority.taskId !== checkpoint.snapshot.taskId ||
      authority.checkpointSnapshotVersion !== checkpoint.snapshot.snapshotVersion) return undefined;
    const existing = this.find(checkpoint.snapshot.taskId);
    if ((existing?.checkpoint.snapshot.snapshotVersion ?? 0) !== previous) return undefined;
    const next: ChatRecord = existing === undefined ? new ChatRecord() : copyRecord(existing);
    next.checkpoint = copyRuntimeTaskRecoveryCheckpoint(checkpoint); return next;
  }
  async loadCheckpoint(taskId: string): Promise<RuntimeTaskRecoveryCheckpoint | undefined> {
    const record = this.find(taskId); return record === undefined ? undefined : copyRuntimeTaskRecoveryCheckpoint(record.checkpoint);
  }
  async beforeDispatch(checkpoint: RuntimeTaskRecoveryCheckpoint, previous: number,
    context: DispatchPersistenceContext | undefined, authority: RuntimeDurableAuthorityPayload,
    now: number): Promise<RuntimePersistenceResult> {
    const graph = checkpoint.workflow;
    if (context !== undefined || graph === undefined || graph.steps.length !== 1 || graph.steps[0].kind !== WorkflowStepKind.LLM ||
      graph.steps[0].stepId !== 'chat-answer' || checkpoint.pendingDispatchId.length === 0) return response(false);
    const next = this.checkpointRecord(checkpoint, previous, authority);
    if (next === undefined || next.dispatchId.length > 0) return response(false);
    next.dispatchId = checkpoint.pendingDispatchId; next.stepId = 'chat-answer';
    return await this.write(next);
  }
  async recordOutcome(taskId: string, stepId: string, dispatchId: string, outcome: ToolOutcome,
    _now: number): Promise<RuntimePersistenceResult> {
    const record = this.find(taskId);
    if (record === undefined || record.dispatchId !== dispatchId || record.stepId !== stepId ||
      !ContractValidator.validateToolOutcome(outcome).valid ||
      outcome.invocationId !== dispatchId) return response(false);
    if (record.outcome !== undefined) return response(JSON.stringify(record.outcome) === JSON.stringify(outcome), true);
    if (record.checkpoint.pendingDispatchId !== dispatchId) return response(false);
    const next: ChatRecord = copyRecord(record); next.outcome = copyToolOutcome(outcome);
    return await this.write(next);
  }
  async recordDispatchRejected(_context: DispatchPersistenceContext | undefined, dispatchId: string,
    code: string, _now: number): Promise<RuntimePersistenceResult> {
    const record = this.journal.records.find((item: ChatRecord): boolean => item.dispatchId === dispatchId);
    if (record === undefined || record.outcome !== undefined || !code) return response(false);
    const next: ChatRecord = copyRecord(record); next.rejectionCode = code; return await this.write(next);
  }
  // This slice retains interrupted evidence but deliberately exposes no resume/reconciliation operation.
  async normalizeRecoveredOperation(_checkpoint: RuntimeTaskRecoveryCheckpoint, _previous: number, _now: number): Promise<RuntimePersistenceResult> { return response(false); }
  async recordReconciliation(_report: ReconciliationReport, _now: number): Promise<RuntimePersistenceResult> { return response(false); }
}

function databaseConfig(): relationalStore.StoreConfig {
  const request = new EncryptedRdbConfigurationRequest();
  request.executionStoreName = 'shuvi_chat_execution_v1.db'; request.memoryStoreName = 'shuvi_chat_unused_memory_v1.db';
  return createEncryptedRdbStoreConfigs(request).execution;
}
export class ChatExecutionResource extends OwnedAgentRdb implements ProductionRuntimePersistencePort {
  private journal?: ChatExecutionStore;
  private readonly digest: AgentHostDigest;
  constructor(opener: AgentRdbOpenPort, digest: AgentHostDigest) { super(opener, databaseConfig(), 'CHAT_STORAGE'); this.digest = digest; }
  protected async initialize(store: relationalStore.RdbStore): Promise<void> {
    const journal = new ChatExecutionStore(new RdbSnapshotBackend(store), this.digest); await journal.open(); this.journal = journal;
  }
  protected detach(): void { this.journal = undefined; }
  private current(): ChatExecutionStore { if (this.journal === undefined) throw new Error('CHAT_STORAGE_CLOSED'); return this.journal; }
  saveCheckpoint(c: RuntimeTaskRecoveryCheckpoint, p: number, a: RuntimeDurableAuthorityPayload, n: number): Promise<RuntimePersistenceResult> { return this.run(() => this.current().saveCheckpoint(c, p, a, n)); }
  loadCheckpoint(id: string): Promise<RuntimeTaskRecoveryCheckpoint | undefined> { return this.run(() => this.current().loadCheckpoint(id)); }
  beforeDispatch(c: RuntimeTaskRecoveryCheckpoint, p: number, d: DispatchPersistenceContext | undefined, a: RuntimeDurableAuthorityPayload, n: number): Promise<RuntimePersistenceResult> { return this.run(() => this.current().beforeDispatch(c, p, d, a, n)); }
  recordOutcome(t: string, s: string, d: string, o: ToolOutcome, n: number): Promise<RuntimePersistenceResult> { return this.run(() => this.current().recordOutcome(t, s, d, o, n)); }
  recordDispatchRejected(c: DispatchPersistenceContext | undefined, d: string, r: string, n: number): Promise<RuntimePersistenceResult> { return this.run(() => this.current().recordDispatchRejected(c, d, r, n)); }
  normalizeRecoveredOperation(c: RuntimeTaskRecoveryCheckpoint, p: number, n: number): Promise<RuntimePersistenceResult> { return this.run(() => this.current().normalizeRecoveredOperation(c, p, n)); }
  recordReconciliation(r: ReconciliationReport, n: number): Promise<RuntimePersistenceResult> { return this.run(() => this.current().recordReconciliation(r, n)); }
}
