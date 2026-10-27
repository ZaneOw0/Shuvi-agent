import { copyRuntimeTaskRecoveryCheckpoint, copyToolOutcome } from './ChatSnapshotCopies';
import relationalStore from '@ohos.data.relationalStore';
import { ContractValidator, ReconciliationReport, ToolOutcome, WorkflowStepKind } from '@harmony_agent/agent-contracts';
import {
  DispatchPersistenceContext, ProductionRuntimePersistencePort, RuntimeCheckpointValidator,
  RuntimeDurableAuthorityPayload, RuntimePersistenceCode, RuntimePersistenceResult, RuntimeTaskRecoveryCheckpoint
} from '@harmony_agent/agent-runtime';
import {
  DurableSnapshotBackendPort, EncryptedRdbConfigurationRequest, RdbSnapshotBackend,
  StorageSnapshotEnvelope, createEncryptedRdbStoreConfigs
} from '@harmony_agent/agent-storage';
import { AgentHostDigest } from './AgentHostDigest';
import { AgentRdbOpenPort, OwnedAgentRdb } from './AgentRdbResources';
import { KNOWLEDGE_ANSWER_STEP_ID } from './KnowledgeAnswerTaskSupport';

const KNOWLEDGE_ANSWER_OWNER: string = 'shuvi-local-owner-v1';
const KNOWLEDGE_ANSWER_SCHEMA: string = 'shuvi-knowledge-answer-1.0';
const KNOWLEDGE_ANSWER_STORE: string = 'shuvi_knowledge_answer_v1.db';

/** App-owned answer journal policy; the storage layout is shared by grounded answer kinds. */
export class AnswerExecutionPolicy {
  owner: string = KNOWLEDGE_ANSWER_OWNER;
  schema: string = KNOWLEDGE_ANSWER_SCHEMA;
  storeName: string = KNOWLEDGE_ANSWER_STORE;
  memoryStoreName: string = 'shuvi_knowledge_answer_unused_memory_v1.db';
  stepId: string = KNOWLEDGE_ANSWER_STEP_ID;
}

export function knowledgeAnswerExecutionPolicy(): AnswerExecutionPolicy {
  return new AnswerExecutionPolicy();
}

// App-owned PERSONAL answer journal. It never writes the chat or tool recovery stores.
class KnowledgeAnswerRecord {
  checkpoint: RuntimeTaskRecoveryCheckpoint = new RuntimeTaskRecoveryCheckpoint();
  dispatchId: string = '';
  stepId: string = '';
  outcome?: ToolOutcome;
  rejectionCode: string = '';
}
function copyRecord(value: KnowledgeAnswerRecord): KnowledgeAnswerRecord {
  const copy: KnowledgeAnswerRecord = new KnowledgeAnswerRecord();
  copy.checkpoint = copyRuntimeTaskRecoveryCheckpoint(value.checkpoint);
  copy.dispatchId = value.dispatchId; copy.stepId = value.stepId; copy.rejectionCode = value.rejectionCode;
  if (value.outcome !== undefined) { copy.outcome = copyToolOutcome(value.outcome); }
  return copy;
}
class KnowledgeAnswerJournal { records: KnowledgeAnswerRecord[] = []; }

function response(accepted: boolean, duplicate: boolean = false): RuntimePersistenceResult {
  const value: RuntimePersistenceResult = new RuntimePersistenceResult();
  value.accepted = accepted; value.duplicate = duplicate;
  value.code = accepted ? (duplicate ? RuntimePersistenceCode.UNCHANGED : RuntimePersistenceCode.SAVED) : RuntimePersistenceCode.REJECTED;
  return value;
}
function recordObject(value: Object): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}

export class KnowledgeAnswerExecutionStore implements ProductionRuntimePersistencePort {
  private readonly backend: DurableSnapshotBackendPort;
  private readonly digest: AgentHostDigest;
  private readonly policy: AnswerExecutionPolicy;
  private journal: KnowledgeAnswerJournal = new KnowledgeAnswerJournal();
  private revision: number = 0;
  constructor(backend: DurableSnapshotBackendPort, digest: AgentHostDigest,
    policy: AnswerExecutionPolicy = knowledgeAnswerExecutionPolicy()) {
    this.backend = backend; this.digest = digest; this.policy = policy;
  }
  async open(): Promise<void> {
    await this.backend.initialize();
    const envelope = await this.backend.load();
    if (envelope === undefined) { return; }
    if (envelope.schemaVersion !== this.policy.schema || !Number.isSafeInteger(envelope.revision) || envelope.revision < 1 ||
      typeof envelope.payloadJson !== 'string' || envelope.payloadJson.length > 800000 ||
      this.digest.digest(envelope.payloadJson) !== envelope.payloadDigest) { throw new Error('KNOWLEDGE_ANSWER_JOURNAL_INVALID'); }
    const parsed: KnowledgeAnswerJournal = JSON.parse(envelope.payloadJson);
    if (!recordObject(parsed) || !Array.isArray(parsed.records) || parsed.records.length > 128) {
      throw new Error('KNOWLEDGE_ANSWER_JOURNAL_INVALID');
    }
    const ids: string[] = [];
    for (const item of parsed.records) {
      if (!recordObject(item) || !RuntimeCheckpointValidator.validate(item.checkpoint).valid ||
        typeof item.dispatchId !== 'string' || typeof item.stepId !== 'string' || typeof item.rejectionCode !== 'string' ||
        ids.indexOf(item.checkpoint.snapshot.taskId) >= 0 ||
        (item.outcome !== undefined && (!ContractValidator.validateToolOutcome(item.outcome).valid ||
          item.outcome.invocationId !== item.dispatchId))) { throw new Error('KNOWLEDGE_ANSWER_JOURNAL_INVALID'); }
      ids.push(item.checkpoint.snapshot.taskId);
    }
    this.journal = parsed; this.revision = envelope.revision;
  }
  private find(taskId: string): KnowledgeAnswerRecord | undefined {
    return this.journal.records.find((item: KnowledgeAnswerRecord): boolean => item.checkpoint.snapshot.taskId === taskId);
  }
  private async write(record: KnowledgeAnswerRecord): Promise<RuntimePersistenceResult> {
    const next: KnowledgeAnswerJournal = new KnowledgeAnswerJournal();
    next.records = this.journal.records.slice();
    const index: number = next.records.findIndex((item: KnowledgeAnswerRecord): boolean =>
      item.checkpoint.snapshot.taskId === record.checkpoint.snapshot.taskId);
    if (index < 0) { if (next.records.length >= 128) { return response(false); } next.records.push(record); }
    else { next.records[index] = record; }
    const envelope: StorageSnapshotEnvelope = new StorageSnapshotEnvelope();
    envelope.schemaVersion = this.policy.schema; envelope.revision = this.revision + 1;
    envelope.payloadJson = JSON.stringify(next);
    if (envelope.payloadJson.length > 800000) { return response(false); }
    envelope.payloadDigest = this.digest.digest(envelope.payloadJson);
    if (!await this.backend.compareAndSet(this.revision, envelope)) { return response(false); }
    this.revision = envelope.revision; this.journal = next; return response(true);
  }
  async saveCheckpoint(checkpoint: RuntimeTaskRecoveryCheckpoint, previous: number,
    authority: RuntimeDurableAuthorityPayload, _now: number): Promise<RuntimePersistenceResult> {
    const next: KnowledgeAnswerRecord | undefined = this.checkpointRecord(checkpoint, previous, authority);
    return next === undefined ? response(false) : await this.write(next);
  }
  private checkpointRecord(checkpoint: RuntimeTaskRecoveryCheckpoint, previous: number,
    authority: RuntimeDurableAuthorityPayload): KnowledgeAnswerRecord | undefined {
    if (!RuntimeCheckpointValidator.validate(checkpoint).valid || checkpoint.snapshot.snapshotVersion !== previous + 1 ||
      checkpoint.envelope.userId !== this.policy.owner || checkpoint.activeInvocation !== undefined ||
      authority.operation !== undefined || authority.taskId !== checkpoint.snapshot.taskId ||
      authority.checkpointSnapshotVersion !== checkpoint.snapshot.snapshotVersion) { return undefined; }
    const existing: KnowledgeAnswerRecord | undefined = this.find(checkpoint.snapshot.taskId);
    if ((existing?.checkpoint.snapshot.snapshotVersion ?? 0) !== previous) { return undefined; }
    const next: KnowledgeAnswerRecord = existing === undefined ? new KnowledgeAnswerRecord() : copyRecord(existing);
    next.checkpoint = copyRuntimeTaskRecoveryCheckpoint(checkpoint); return next;
  }
  async loadCheckpoint(taskId: string): Promise<RuntimeTaskRecoveryCheckpoint | undefined> {
    const record: KnowledgeAnswerRecord | undefined = this.find(taskId);
    return record === undefined ? undefined : copyRuntimeTaskRecoveryCheckpoint(record.checkpoint);
  }
  async beforeDispatch(checkpoint: RuntimeTaskRecoveryCheckpoint, previous: number,
    context: DispatchPersistenceContext | undefined, authority: RuntimeDurableAuthorityPayload,
    now: number): Promise<RuntimePersistenceResult> {
    const graph = checkpoint.workflow;
    if (context !== undefined || graph === undefined || graph.steps.length !== 1 ||
      graph.steps[0].kind !== WorkflowStepKind.LLM || graph.steps[0].stepId !== this.policy.stepId ||
      checkpoint.pendingDispatchId.length === 0) { return response(false); }
    const next: KnowledgeAnswerRecord | undefined = this.checkpointRecord(checkpoint, previous, authority);
    if (next === undefined || next.dispatchId.length > 0) { return response(false); }
    next.dispatchId = checkpoint.pendingDispatchId; next.stepId = this.policy.stepId;
    return await this.write(next);
  }
  async recordOutcome(taskId: string, stepId: string, dispatchId: string, outcome: ToolOutcome,
    _now: number): Promise<RuntimePersistenceResult> {
    const record: KnowledgeAnswerRecord | undefined = this.find(taskId);
    if (record === undefined || record.dispatchId !== dispatchId || record.stepId !== stepId ||
      !ContractValidator.validateToolOutcome(outcome).valid ||
      outcome.invocationId !== dispatchId) { return response(false); }
    if (record.outcome !== undefined) { return response(JSON.stringify(record.outcome) === JSON.stringify(outcome), true); }
    if (record.checkpoint.pendingDispatchId !== dispatchId) { return response(false); }
    const next: KnowledgeAnswerRecord = copyRecord(record); next.outcome = copyToolOutcome(outcome);
    return await this.write(next);
  }
  async recordDispatchRejected(_context: DispatchPersistenceContext | undefined, dispatchId: string,
    code: string, _now: number): Promise<RuntimePersistenceResult> {
    const record: KnowledgeAnswerRecord | undefined = this.journal.records.find((item: KnowledgeAnswerRecord): boolean =>
      item.dispatchId === dispatchId);
    if (record === undefined || record.outcome !== undefined || !code) { return response(false); }
    const next: KnowledgeAnswerRecord = copyRecord(record); next.rejectionCode = code; return await this.write(next);
  }
  // This slice retains interrupted evidence but exposes no resume/reconciliation operation.
  async normalizeRecoveredOperation(_checkpoint: RuntimeTaskRecoveryCheckpoint, _previous: number,
    _now: number): Promise<RuntimePersistenceResult> { return response(false); }
  async recordReconciliation(_report: ReconciliationReport, _now: number): Promise<RuntimePersistenceResult> {
    return response(false);
  }
}

function databaseConfig(policy: AnswerExecutionPolicy): relationalStore.StoreConfig {
  const request: EncryptedRdbConfigurationRequest = new EncryptedRdbConfigurationRequest();
  request.executionStoreName = policy.storeName;
  request.memoryStoreName = policy.memoryStoreName;
  return createEncryptedRdbStoreConfigs(request).execution;
}

export class KnowledgeAnswerExecutionResource extends OwnedAgentRdb implements ProductionRuntimePersistencePort {
  onOutcomeRejected: (taskId: string) => void = (_taskId: string): void => {};
  private journal?: KnowledgeAnswerExecutionStore;
  private readonly digest: AgentHostDigest;
  private readonly policy: AnswerExecutionPolicy;
  constructor(opener: AgentRdbOpenPort, digest: AgentHostDigest,
    policy: AnswerExecutionPolicy = knowledgeAnswerExecutionPolicy()) {
    super(opener, databaseConfig(policy), 'KNOWLEDGE_ANSWER_STORAGE');
    this.digest = digest; this.policy = policy;
  }
  protected async initialize(store: relationalStore.RdbStore): Promise<void> {
    const journal: KnowledgeAnswerExecutionStore = new KnowledgeAnswerExecutionStore(new RdbSnapshotBackend(store),
      this.digest, this.policy);
    await journal.open(); this.journal = journal;
  }
  protected detach(): void { this.journal = undefined; }
  private current(): KnowledgeAnswerExecutionStore {
    if (this.journal === undefined) { throw new Error('KNOWLEDGE_ANSWER_STORAGE_CLOSED'); } return this.journal;
  }
  saveCheckpoint(c: RuntimeTaskRecoveryCheckpoint, p: number, a: RuntimeDurableAuthorityPayload,
    n: number): Promise<RuntimePersistenceResult> { return this.run((): Promise<RuntimePersistenceResult> => this.current().saveCheckpoint(c, p, a, n)); }
  loadCheckpoint(id: string): Promise<RuntimeTaskRecoveryCheckpoint | undefined> {
    return this.run((): Promise<RuntimeTaskRecoveryCheckpoint | undefined> => this.current().loadCheckpoint(id));
  }
  beforeDispatch(c: RuntimeTaskRecoveryCheckpoint, p: number, d: DispatchPersistenceContext | undefined,
    a: RuntimeDurableAuthorityPayload, n: number): Promise<RuntimePersistenceResult> {
    return this.run((): Promise<RuntimePersistenceResult> => this.current().beforeDispatch(c, p, d, a, n));
  }
  async recordOutcome(t: string, s: string, d: string, o: ToolOutcome, n: number): Promise<RuntimePersistenceResult> {
    try {
      const result: RuntimePersistenceResult = await this.run((): Promise<RuntimePersistenceResult> =>
        this.current().recordOutcome(t, s, d, o, n));
      if (!result.accepted && !result.duplicate) { this.onOutcomeRejected(t); }
      return result;
    } catch (error) {
      this.onOutcomeRejected(t);
      if (error instanceof Error) { throw error; }
      throw new Error('KNOWLEDGE_ANSWER_OUTCOME_WRITE_FAILED');
    }
  }
  recordDispatchRejected(c: DispatchPersistenceContext | undefined, d: string, r: string,
    n: number): Promise<RuntimePersistenceResult> {
    return this.run((): Promise<RuntimePersistenceResult> => this.current().recordDispatchRejected(c, d, r, n));
  }
  normalizeRecoveredOperation(c: RuntimeTaskRecoveryCheckpoint, p: number,
    n: number): Promise<RuntimePersistenceResult> {
    return this.run((): Promise<RuntimePersistenceResult> => this.current().normalizeRecoveredOperation(c, p, n));
  }
  recordReconciliation(r: ReconciliationReport, n: number): Promise<RuntimePersistenceResult> {
    return this.run((): Promise<RuntimePersistenceResult> => this.current().recordReconciliation(r, n));
  }
}
