import common from '@ohos.app.ability.common';
import relationalStore from '@ohos.data.relationalStore';
import { ReconciliationReport, ToolOutcome } from '@harmony_agent/agent-contracts';
import {
  DispatchPersistenceContext, PlanningMemoryContextPort, PlanningMemoryContextRequest, PlanningMemoryContextResult,
  ProductionRuntimePersistencePort, ProductionRuntimeRecoverySourcePort, RuntimeDurableAuthorityPayload,
  RuntimePersistenceResult, RuntimeRecoveryAuthority, RuntimeTaskRecoveryCheckpoint, SingleAgentHostResourcePort
} from '@harmony_agent/agent-runtime';
import {
  DurableExecutionRecoveryStore, DurableMemoryStore, EncryptedRdbConfigurationRequest,
  MemoryHit, MemoryQuery, RebuildableMemoryIndexPort, RdbMemorySnapshotBackend, RdbSnapshotBackend, RuntimeExecutionRecoveryBridge,
  RuntimeExecutionRecoveryBridgeConfig, RuntimeMemoryContextAdapter, createEncryptedRdbStoreConfigs
} from '@harmony_agent/agent-storage';
import { AgentHostDigest } from './AgentHostDigest';

export interface AgentRdbOpenPort {
  open(config: relationalStore.StoreConfig): Promise<relationalStore.RdbStore>;
}

/** Context is supplied by the Ability; construction does not open a database. */
export class NativeAgentRdbOpen implements AgentRdbOpenPort {
  private readonly context: common.Context;
  constructor(context: common.Context) { this.context = context; }
  async open(config: relationalStore.StoreConfig): Promise<relationalStore.RdbStore> {
    return await relationalStore.getRdbStore(this.context, config);
  }
}

enum ResourceState { CLOSED, OPENING, READY, CLOSING, FAULTED }

/** Serializes lifecycle and durable operations; a failed close retains ownership for retry. */
export abstract class OwnedAgentRdb implements SingleAgentHostResourcePort {
  private state: ResourceState = ResourceState.CLOSED;
  private store?: relationalStore.RdbStore;
  private opening?: Promise<void>;
  private closing?: Promise<void>;
  private operations: Promise<void> = Promise.resolve();
  private readonly opener: AgentRdbOpenPort;
  private readonly config: relationalStore.StoreConfig;
  private readonly label: string;

  constructor(opener: AgentRdbOpenPort, config: relationalStore.StoreConfig, label: string) {
    this.opener = opener;
    this.config = config;
    this.label = label;
  }

  protected abstract initialize(store: relationalStore.RdbStore): Promise<void>;
  protected abstract detach(): void;

  protected assertReady(): void {
    if (this.state !== ResourceState.READY) throw new Error(this.label + '_NOT_READY');
  }

  protected run<T>(operation: () => Promise<T>): Promise<T> {
    try { this.assertReady(); } catch (error) { return Promise.reject(new Error(this.label + '_NOT_READY')); }
    // Already accepted writes finish before close; new writes are rejected once closing starts.
    const result: Promise<T> = this.operations.then(operation);
    this.operations = result.then(() => {}, () => {});
    return result;
  }

  open(): Promise<void> {
    if (this.state === ResourceState.READY) return Promise.resolve();
    if (this.state === ResourceState.OPENING && this.opening !== undefined) return this.opening;
    if (this.state !== ResourceState.CLOSED) return Promise.reject(new Error(this.label + '_NOT_CLOSED'));
    this.state = ResourceState.OPENING;
    this.opening = this.openStore();
    return this.opening;
  }

  private async openStore(): Promise<void> {
    try {
      this.store = await this.opener.open(this.config);
      if (this.state !== ResourceState.OPENING) throw new Error(this.label + '_OPEN_INTERRUPTED');
      await this.initialize(this.store);
      if (this.state !== ResourceState.OPENING) throw new Error(this.label + '_OPEN_INTERRUPTED');
      this.state = ResourceState.READY;
    } catch (error) {
      this.detach();
      try { await this.release(); } catch (closeError) {
        this.state = ResourceState.FAULTED;
        throw new Error(this.label + '_ROLLBACK_FAILED');
      }
      if (this.state !== ResourceState.CLOSING) this.state = ResourceState.CLOSED;
      throw new Error(this.label + '_OPEN_FAILED');
    } finally {
      this.opening = undefined;
    }
  }

  close(): Promise<void> {
    if (this.closing !== undefined) return this.closing;
    if (this.state === ResourceState.CLOSED) return Promise.resolve();
    this.state = ResourceState.CLOSING;
    this.closing = this.closeStore();
    return this.closing;
  }

  private async closeStore(): Promise<void> {
    try {
      if (this.opening !== undefined) {
        try { await this.opening; } catch (error) { /* The acquired handle still belongs to this resource. */ }
      }
      await this.operations;
      this.detach();
      await this.release();
      this.state = ResourceState.CLOSED;
    } catch (error) {
      this.state = ResourceState.FAULTED;
      throw new Error(this.label + '_CLOSE_FAILED');
    } finally {
      this.closing = undefined;
    }
  }

  private async release(): Promise<void> {
    if (this.store !== undefined) {
      await this.store.close();
      this.store = undefined;
    }
  }
}

function executionConfig(): relationalStore.StoreConfig {
  const request: EncryptedRdbConfigurationRequest = new EncryptedRdbConfigurationRequest();
  request.executionStoreName = 'shuvi_agent_execution_v1.db';
  request.memoryStoreName = 'shuvi_agent_memory_v1.db';
  return createEncryptedRdbStoreConfigs(request).execution;
}

function memoryConfig(): relationalStore.StoreConfig {
  const request: EncryptedRdbConfigurationRequest = new EncryptedRdbConfigurationRequest();
  request.executionStoreName = 'shuvi_agent_execution_v1.db';
  request.memoryStoreName = 'shuvi_agent_memory_v1.db';
  return createEncryptedRdbStoreConfigs(request).memory;
}

export class AgentExecutionResource extends OwnedAgentRdb implements ProductionRuntimePersistencePort,
  ProductionRuntimeRecoverySourcePort {
  private bridge?: RuntimeExecutionRecoveryBridge;
  private readonly bridgeConfig: RuntimeExecutionRecoveryBridgeConfig;
  private readonly digest: AgentHostDigest;

  constructor(opener: AgentRdbOpenPort, config: RuntimeExecutionRecoveryBridgeConfig, digest: AgentHostDigest) {
    super(opener, executionConfig(), 'AGENT_EXECUTION_STORAGE');
    if (config.ownerId.trim().length === 0 || config.policyVersion.trim().length === 0 ||
      !Number.isSafeInteger(config.leaseTtlMs) || config.leaseTtlMs <= 0 || config.outcomeAccounting === undefined) {
      throw new Error('AGENT_EXECUTION_CONFIGURATION_REQUIRED');
    }
    this.bridgeConfig = new RuntimeExecutionRecoveryBridgeConfig();
    this.bridgeConfig.ownerId = config.ownerId;
    this.bridgeConfig.policyVersion = config.policyVersion;
    this.bridgeConfig.leaseTtlMs = config.leaseTtlMs;
    this.bridgeConfig.outcomeAccounting = config.outcomeAccounting;
    this.bridgeConfig.pendingInvoice = config.pendingInvoice;
    this.bridgeConfig.reconciliationSettlement = config.reconciliationSettlement;
    this.digest = digest;
  }

  protected async initialize(store: relationalStore.RdbStore): Promise<void> {
    const opened = await DurableExecutionRecoveryStore.openForRuntimeRecovery(new RdbSnapshotBackend(store), this.digest);
    if (!opened.accepted || opened.store === undefined) throw new Error('AGENT_EXECUTION_SNAPSHOT_REJECTED');
    this.bridge = new RuntimeExecutionRecoveryBridge(opened.store, this.bridgeConfig);
  }

  protected detach(): void { this.bridge = undefined; }
  private current(): RuntimeExecutionRecoveryBridge {
    if (this.bridge === undefined) throw new Error('AGENT_EXECUTION_STORAGE_NOT_READY');
    return this.bridge;
  }
  saveCheckpoint(checkpoint: RuntimeTaskRecoveryCheckpoint, previous: number,
    authority: RuntimeDurableAuthorityPayload, now: number): Promise<RuntimePersistenceResult> {
    return this.run(() => this.current().saveCheckpoint(checkpoint, previous, authority, now));
  }
  loadCheckpoint(taskId: string): Promise<RuntimeTaskRecoveryCheckpoint | undefined> {
    return this.run(() => this.current().loadCheckpoint(taskId));
  }
  normalizeRecoveredOperation(checkpoint: RuntimeTaskRecoveryCheckpoint, previous: number,
    now: number): Promise<RuntimePersistenceResult> {
    return this.run(() => this.current().normalizeRecoveredOperation(checkpoint, previous, now));
  }
  listRecoveryTaskIds(): Promise<string[]> { return this.run(() => this.current().listRecoveryTaskIds()); }
  loadRecoveryAuthority(taskId: string): Promise<RuntimeRecoveryAuthority | undefined> {
    return this.run(() => this.current().loadRecoveryAuthority(taskId));
  }
  beforeDispatch(checkpoint: RuntimeTaskRecoveryCheckpoint, previous: number,
    context: DispatchPersistenceContext | undefined, authority: RuntimeDurableAuthorityPayload,
    now: number): Promise<RuntimePersistenceResult> {
    return this.run(() => this.current().beforeDispatch(checkpoint, previous, context, authority, now));
  }
  recordDispatchRejected(context: DispatchPersistenceContext | undefined, dispatchId: string,
    rejectionCode: string, now: number): Promise<RuntimePersistenceResult> {
    return this.run(() => this.current().recordDispatchRejected(context, dispatchId, rejectionCode, now));
  }
  recordOutcome(taskId: string, stepId: string, dispatchId: string, outcome: ToolOutcome,
    now: number): Promise<RuntimePersistenceResult> {
    return this.run(() => this.current().recordOutcome(taskId, stepId, dispatchId, outcome, now));
  }
  recordReconciliation(report: ReconciliationReport, now: number): Promise<RuntimePersistenceResult> {
    return this.run(() => this.current().recordReconciliation(report, now));
  }
}

// The upstream context adapter only queries this port. Durable writes maintain their own derived index.
class ReadOnlyDurableMemoryIndex implements RebuildableMemoryIndexPort {
  private readonly store: DurableMemoryStore;
  constructor(store: DurableMemoryStore) { this.store = store; }
  searchMemory(query: MemoryQuery): MemoryHit[] { return this.store.searchMemory(query); }
  rebuildIndex(ownerId: string): number { throw new Error('AGENT_MEMORY_CONTEXT_IS_READ_ONLY'); }
  invalidateMemory(ownerId: string, memoryId: string): number { throw new Error('AGENT_MEMORY_CONTEXT_IS_READ_ONLY'); }
}

export class AgentMemoryResource extends OwnedAgentRdb implements PlanningMemoryContextPort {
  private adapter?: RuntimeMemoryContextAdapter;
  private readonly digest: AgentHostDigest;
  constructor(opener: AgentRdbOpenPort, digest: AgentHostDigest) {
    super(opener, memoryConfig(), 'AGENT_MEMORY_STORAGE');
    this.digest = digest;
  }
  protected async initialize(store: relationalStore.RdbStore): Promise<void> {
    const opened = await DurableMemoryStore.open(new RdbMemorySnapshotBackend(store), this.digest, this.digest);
    if (!opened.accepted || opened.store === undefined) throw new Error('AGENT_MEMORY_SNAPSHOT_REJECTED');
    this.adapter = new RuntimeMemoryContextAdapter(new ReadOnlyDurableMemoryIndex(opened.store));
  }
  protected detach(): void { this.adapter = undefined; }
  retrieve(request: PlanningMemoryContextRequest): PlanningMemoryContextResult {
    this.assertReady();
    if (this.adapter === undefined) throw new Error('AGENT_MEMORY_STORAGE_NOT_READY');
    return this.adapter.retrieve(request);
  }
}
