import { describe, expect, it } from '@ohos/hypium';
import {
  DerivedMemoryArtifact,
  DurableMemorySnapshotBackendPort,
  DurableMemoryStore,
  MemoryDigestPort,
  MemoryKind,
  MemoryPrivacyClass,
  MemoryQuery,
  MemoryRecord,
  MemorySnapshotEnvelope,
  MemorySnapshotIntegrityPort,
  MemorySnapshotMigrationPort,
  MemorySourceKind,
  MemoryWriteCode
} from '../../Index';

class FixtureMemoryDigest implements MemoryDigestPort {
  digest(value: string): string {
    return 'memory-digest:' + value;
  }
}

class FixtureSnapshotIntegrity implements MemorySnapshotIntegrityPort {
  digest(payloadJson: string): string {
    return 'snapshot-digest:' + payloadJson;
  }
}

class FixtureMemoryMigration implements MemorySnapshotMigrationPort {
  migrate(source: MemorySnapshotEnvelope): MemorySnapshotEnvelope {
    const result: MemorySnapshotEnvelope = copyEnvelope(source);
    result.schemaVersion = '1.0';
    return result;
  }
}

function copyEnvelope(source: MemorySnapshotEnvelope): MemorySnapshotEnvelope {
  const result: MemorySnapshotEnvelope = new MemorySnapshotEnvelope();
  result.schemaVersion = source.schemaVersion;
  result.revision = source.revision;
  result.payloadJson = source.payloadJson;
  result.payloadDigest = source.payloadDigest;
  return result;
}

class FixtureMemoryBackend implements DurableMemorySnapshotBackendPort {
  snapshot?: MemorySnapshotEnvelope;
  failNextWrite: boolean = false;

  async initialize(): Promise<void> {
  }

  async load(): Promise<MemorySnapshotEnvelope | undefined> {
    return this.snapshot === undefined ? undefined : copyEnvelope(this.snapshot);
  }

  async compareAndSet(expectedRevision: number, next: MemorySnapshotEnvelope): Promise<boolean> {
    if (this.failNextWrite) {
      this.failNextWrite = false;
      return false;
    }
    const currentRevision: number = this.snapshot === undefined ? 0 : this.snapshot.revision;
    if (currentRevision !== expectedRevision || next.revision <= expectedRevision) return false;
    this.snapshot = copyEnvelope(next);
    return true;
  }
}

function record(memoryId: string, content: string): MemoryRecord {
  const value: MemoryRecord = new MemoryRecord();
  value.memoryId = memoryId;
  value.ownerId = 'owner-1';
  value.kind = MemoryKind.STRUCTURED;
  value.privacyClass = MemoryPrivacyClass.SHAREABLE;
  value.sourceKind = MemorySourceKind.STRUCTURED_IMPORT;
  value.title = 'Durable memory';
  value.content = content;
  value.contentDigest = 'memory-digest:' + content;
  value.tags = ['durable'];
  value.version = 1;
  value.createdAtMs = 100;
  value.updatedAtMs = 101;
  return value;
}

function artifact(memoryId: string): DerivedMemoryArtifact {
  const value: DerivedMemoryArtifact = new DerivedMemoryArtifact();
  value.artifactId = 'summary-' + memoryId;
  value.memoryId = memoryId;
  value.ownerId = 'owner-1';
  value.memoryVersion = 1;
  value.artifactType = 'SUMMARY';
  value.sourceDigest = 'memory-digest:alpha durable';
  value.payloadJson = '{"summary":"alpha"}';
  value.createdAtMs = 102;
  return value;
}

async function openStore(backend: FixtureMemoryBackend): Promise<DurableMemoryStore> {
  const opened = await DurableMemoryStore.open(
    backend,
    new FixtureMemoryDigest(),
    new FixtureSnapshotIntegrity(),
    128
  );
  expect(opened.accepted).assertTrue();
  return opened.store as DurableMemoryStore;
}

export default function durableMemoryStoreTest(): void {
  describe('DurableMemoryStore', () => {
    it('persists authority records and rebuilds lexical index after reopen', 0, async () => {
      const backend: FixtureMemoryBackend = new FixtureMemoryBackend();
      const first: DurableMemoryStore = await openStore(backend);
      expect((await first.saveMemory(record('memory-1', 'alpha durable'), 0)).accepted).assertTrue();
      expect((await first.saveArtifact(artifact('memory-1'))).accepted).assertTrue();
      expect(backend.snapshot?.payloadJson.indexOf('LEXICAL_INDEX')).assertEqual(-1);

      const reopened: DurableMemoryStore = await openStore(backend);
      expect(reopened.revision()).assertEqual(2);
      expect(reopened.getMemory('owner-1', 'memory-1')?.content).assertEqual('alpha durable');
      const query: MemoryQuery = new MemoryQuery();
      query.ownerId = 'owner-1';
      query.terms = ['alpha'];
      expect(reopened.searchMemory(query).length).assertEqual(1);
      expect(reopened.listArtifacts('owner-1', 'memory-1').length).assertEqual(2);
    });

    it('does not publish a memory when durable CAS fails', 0, async () => {
      const backend: FixtureMemoryBackend = new FixtureMemoryBackend();
      const store: DurableMemoryStore = await openStore(backend);
      backend.failNextWrite = true;
      const result = await store.saveMemory(record('memory-1', 'alpha durable'), 0);
      expect(result.code).assertEqual(MemoryWriteCode.VERSION_CONFLICT);
      expect(store.getMemory('owner-1', 'memory-1') === undefined).assertTrue();
      expect(store.revision()).assertEqual(0);
    });

    it('keeps one winner across concurrent durable sessions', 0, async () => {
      const backend: FixtureMemoryBackend = new FixtureMemoryBackend();
      const first: DurableMemoryStore = await openStore(backend);
      const second: DurableMemoryStore = await openStore(backend);
      expect((await first.saveMemory(record('memory-1', 'alpha durable'), 0)).accepted).assertTrue();
      const losing = await second.saveMemory(record('memory-2', 'beta durable'), 0);
      expect(losing.code).assertEqual(MemoryWriteCode.VERSION_CONFLICT);
      expect(second.getMemory('owner-1', 'memory-2') === undefined).assertTrue();
      const reopened: DurableMemoryStore = await openStore(backend);
      expect(reopened.getMemory('owner-1', 'memory-1') === undefined).assertFalse();
      expect(reopened.getMemory('owner-1', 'memory-2') === undefined).assertTrue();
    });

    it('fails closed when a durable memory snapshot is corrupt', 0, async () => {
      const backend: FixtureMemoryBackend = new FixtureMemoryBackend();
      const store: DurableMemoryStore = await openStore(backend);
      await store.saveMemory(record('memory-1', 'alpha durable'), 0);
      if (backend.snapshot !== undefined) backend.snapshot.payloadDigest = 'corrupt';
      const reopened = await DurableMemoryStore.open(
        backend,
        new FixtureMemoryDigest(),
        new FixtureSnapshotIntegrity()
      );
      expect(reopened.accepted).assertFalse();
      expect(reopened.code).assertEqual(MemoryWriteCode.CORRUPT_SNAPSHOT);
    });

    it('requires an explicit migration port for older memory schemas', 0, async () => {
      const backend: FixtureMemoryBackend = new FixtureMemoryBackend();
      const store: DurableMemoryStore = await openStore(backend);
      await store.saveMemory(record('memory-1', 'alpha durable'), 0);
      if (backend.snapshot !== undefined) backend.snapshot.schemaVersion = '0.9';

      const rejected = await DurableMemoryStore.open(
        backend,
        new FixtureMemoryDigest(),
        new FixtureSnapshotIntegrity()
      );
      expect(rejected.accepted).assertFalse();
      expect(rejected.code).assertEqual(MemoryWriteCode.UNSUPPORTED_SCHEMA);

      const migrated = await DurableMemoryStore.open(
        backend,
        new FixtureMemoryDigest(),
        new FixtureSnapshotIntegrity(),
        512,
        new FixtureMemoryMigration()
      );
      expect(migrated.accepted).assertTrue();
      expect(migrated.store?.getMemory('owner-1', 'memory-1')?.content).assertEqual('alpha durable');
    });
  });
}
