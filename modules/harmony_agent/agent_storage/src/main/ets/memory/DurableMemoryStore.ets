import { DeterministicMemoryStore } from './DeterministicMemoryStore';
import {
  DurableMemorySnapshotBackendPort,
  MemoryDigestPort,
  MemorySnapshotIntegrityPort,
  MemorySnapshotMigrationPort
} from './MemoryPorts';
import {
  DerivedMemoryArtifact,
  MemoryDeleteResult,
  MemoryExportPolicy,
  MemoryExportRecord,
  MemoryHit,
  MemoryImportPolicy,
  MemoryImportResult,
  MemoryQuery,
  MemoryRecord,
  MemorySnapshotEnvelope,
  MemoryWriteCode,
  MemoryWriteResult
} from './MemoryTypes';

export class DurableMemoryStoreOpenResult {
  accepted: boolean = false;
  code: MemoryWriteCode = MemoryWriteCode.CORRUPT_SNAPSHOT;
  store?: DurableMemoryStore;
}

function conflictWriteResult(): MemoryWriteResult {
  const result: MemoryWriteResult = new MemoryWriteResult();
  result.code = MemoryWriteCode.VERSION_CONFLICT;
  return result;
}

function conflictDeleteResult(): MemoryDeleteResult {
  const result: MemoryDeleteResult = new MemoryDeleteResult();
  result.code = MemoryWriteCode.VERSION_CONFLICT;
  return result;
}

function conflictImportResult(): MemoryImportResult {
  const result: MemoryImportResult = new MemoryImportResult();
  result.code = MemoryWriteCode.VERSION_CONFLICT;
  return result;
}

/**
 * Durable CAS session over the deterministic memory semantics.
 *
 * Authority records and non-index artifacts are persisted. Chunks and lexical
 * index artifacts are intentionally rebuilt from authority records after open
 * and after every accepted authority mutation.
 */
export class DurableMemoryStore {
  private readonly backend: DurableMemorySnapshotBackendPort;
  private readonly integrity: MemorySnapshotIntegrityPort;
  private current: DeterministicMemoryStore;
  private durableRevision: number;

  private constructor(backend: DurableMemorySnapshotBackendPort, integrity: MemorySnapshotIntegrityPort,
    current: DeterministicMemoryStore, durableRevision: number) {
    this.backend = backend;
    this.integrity = integrity;
    this.current = current;
    this.durableRevision = durableRevision;
  }

  static async open(backend: DurableMemorySnapshotBackendPort, digestPort: MemoryDigestPort,
    integrity: MemorySnapshotIntegrityPort, maxChunkChars: number = 512,
    migration?: MemorySnapshotMigrationPort): Promise<DurableMemoryStoreOpenResult> {
    await backend.initialize();
    const source: MemorySnapshotEnvelope | undefined = await backend.load();
    const result: DurableMemoryStoreOpenResult = new DurableMemoryStoreOpenResult();
    if (source === undefined) {
      result.accepted = true;
      result.code = MemoryWriteCode.CREATED;
      result.store = new DurableMemoryStore(
        backend,
        integrity,
        new DeterministicMemoryStore(digestPort, maxChunkChars),
        0
      );
      return result;
    }
    const restored = DeterministicMemoryStore.restore(source, digestPort, integrity, maxChunkChars, migration);
    if (!restored.accepted || restored.store === undefined) {
      result.code = restored.code;
      return result;
    }
    restored.store.rebuildAllIndexes();
    result.accepted = true;
    result.code = MemoryWriteCode.UPDATED;
    result.store = new DurableMemoryStore(backend, integrity, restored.store, source.revision);
    return result;
  }

  revision(): number {
    return this.durableRevision;
  }

  getMemory(ownerId: string, memoryId: string): MemoryRecord | undefined {
    return this.current.getMemory(ownerId, memoryId);
  }

  listMemories(ownerId: string): MemoryRecord[] {
    return this.current.listMemories(ownerId);
  }

  searchMemory(query: MemoryQuery): MemoryHit[] {
    return this.current.searchMemory(query);
  }

  exportMemories(policy: MemoryExportPolicy): MemoryExportRecord[] {
    return this.current.exportMemories(policy);
  }

  listArtifacts(ownerId: string, memoryId: string): DerivedMemoryArtifact[] {
    return this.current.listArtifacts(ownerId, memoryId);
  }

  async saveMemory(record: MemoryRecord, expectedPreviousVersion: number): Promise<MemoryWriteResult> {
    const candidate: DeterministicMemoryStore = this.current.forkForTransaction();
    const result: MemoryWriteResult = candidate.saveMemory(record, expectedPreviousVersion);
    if (!result.accepted || result.duplicate) return result;
    candidate.rebuildIndex(record.ownerId);
    return await this.commit(candidate) ? result : conflictWriteResult();
  }

  async importMemories(records: MemoryRecord[], policy: MemoryImportPolicy): Promise<MemoryImportResult> {
    const candidate: DeterministicMemoryStore = this.current.forkForTransaction();
    const result: MemoryImportResult = candidate.importMemories(records, policy);
    if (!result.accepted || result.importedRecords === 0) return result;
    candidate.rebuildIndex(policy.ownerId);
    return await this.commit(candidate) ? result : conflictImportResult();
  }

  async deleteMemory(ownerId: string, memoryId: string): Promise<MemoryDeleteResult> {
    const candidate: DeterministicMemoryStore = this.current.forkForTransaction();
    const result: MemoryDeleteResult = candidate.deleteMemory(ownerId, memoryId);
    if (!result.accepted) return result;
    candidate.rebuildIndex(ownerId);
    return await this.commit(candidate) ? result : conflictDeleteResult();
  }

  async saveArtifact(artifact: DerivedMemoryArtifact): Promise<MemoryWriteResult> {
    const candidate: DeterministicMemoryStore = this.current.forkForTransaction();
    const result: MemoryWriteResult = candidate.saveArtifact(artifact);
    if (!result.accepted || result.duplicate) return result;
    return await this.commit(candidate) ? result : conflictWriteResult();
  }

  private async commit(candidate: DeterministicMemoryStore): Promise<boolean> {
    if (!Number.isSafeInteger(this.durableRevision + 1)) return false;
    const next: MemorySnapshotEnvelope = candidate.checkpoint(this.integrity, this.durableRevision + 1);
    const accepted: boolean = await this.backend.compareAndSet(this.durableRevision, next);
    if (accepted) {
      this.current = candidate;
      this.durableRevision = next.revision;
    }
    return accepted;
  }
}
