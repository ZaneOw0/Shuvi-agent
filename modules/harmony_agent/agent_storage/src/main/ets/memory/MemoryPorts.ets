import {
  DerivedMemoryArtifact,
  MemoryDeleteResult,
  MemoryExportPolicy,
  MemoryExportRecord,
  MemoryHit,
  MemoryImportPolicy,
  MemoryImportResult,
  MemorySnapshotEnvelope,
  MemoryQuery,
  MemoryRecord,
  MemoryWriteResult
} from './MemoryTypes';

export interface MemoryDigestPort {
  digest(value: string): string;
}

export interface MemorySnapshotIntegrityPort {
  digest(payloadJson: string): string;
}

export interface MemorySnapshotMigrationPort {
  migrate(source: MemorySnapshotEnvelope): MemorySnapshotEnvelope;
}

export interface DurableMemorySnapshotBackendPort {
  initialize(): Promise<void>;
  load(): Promise<MemorySnapshotEnvelope | undefined>;
  compareAndSet(expectedRevision: number, next: MemorySnapshotEnvelope): Promise<boolean>;
}

export interface MemoryRepository {
  saveMemory(record: MemoryRecord, expectedPreviousVersion: number): MemoryWriteResult;
  getMemory(ownerId: string, memoryId: string): MemoryRecord | undefined;
  listMemories(ownerId: string): MemoryRecord[];
  deleteMemory(ownerId: string, memoryId: string): MemoryDeleteResult;
}

export interface ArtifactRepository {
  saveArtifact(artifact: DerivedMemoryArtifact): MemoryWriteResult;
  listArtifacts(ownerId: string, memoryId: string): DerivedMemoryArtifact[];
}

export interface RebuildableMemoryIndexPort {
  rebuildIndex(ownerId: string): number;
  searchMemory(query: MemoryQuery): MemoryHit[];
  invalidateMemory(ownerId: string, memoryId: string): number;
}

export interface MemoryTransferPort {
  importMemories(records: MemoryRecord[], policy: MemoryImportPolicy): MemoryImportResult;
  exportMemories(policy: MemoryExportPolicy): MemoryExportRecord[];
}
