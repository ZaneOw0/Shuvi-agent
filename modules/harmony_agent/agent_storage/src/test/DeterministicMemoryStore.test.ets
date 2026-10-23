import { describe, expect, it } from '@ohos/hypium';
import {
  DerivedMemoryArtifact,
  DeterministicMemoryStore,
  MemoryDigestPort,
  MemoryExportPolicy,
  MemoryImportPolicy,
  MemoryKind,
  MemoryPrivacyClass,
  MemoryQuery,
  MemoryRecord,
  MemorySourceKind,
  MemoryWriteCode
} from '../../Index';

class FixtureMemoryDigest implements MemoryDigestPort {
  digest(value: string): string {
    return 'digest:' + value;
  }
}

function memory(memoryId: string, ownerId: string, content: string, version: number = 1): MemoryRecord {
  const value: MemoryRecord = new MemoryRecord();
  value.memoryId = memoryId;
  value.ownerId = ownerId;
  value.kind = MemoryKind.NOTE;
  value.privacyClass = MemoryPrivacyClass.SHAREABLE;
  value.sourceKind = MemorySourceKind.USER_EXPLICIT;
  value.title = 'Memory ' + memoryId;
  value.content = content;
  value.contentDigest = 'digest:' + content;
  value.tags = ['project'];
  value.version = version;
  value.createdAtMs = 100;
  value.updatedAtMs = 100 + version;
  return value;
}

function query(ownerId: string, term: string): MemoryQuery {
  const value: MemoryQuery = new MemoryQuery();
  value.ownerId = ownerId;
  value.terms = [term];
  return value;
}

export default function deterministicMemoryStoreTest(): void {
  describe('DeterministicMemoryStore', () => {
    it('creates versioned memory and returns defensive copies', 0, () => {
      const store: DeterministicMemoryStore = new DeterministicMemoryStore(new FixtureMemoryDigest());
      const original: MemoryRecord = memory('memory-1', 'owner-1', 'alpha beta');
      const created = store.saveMemory(original, 0);
      expect(created.accepted).assertTrue();
      expect(created.code).assertEqual(MemoryWriteCode.CREATED);

      original.content = 'mutated outside';
      const saved: MemoryRecord | undefined = store.getMemory('owner-1', 'memory-1');
      expect(saved === undefined).assertFalse();
      if (saved !== undefined) {
        expect(saved.content).assertEqual('alpha beta');
        saved.tags.push('mutated');
      }
      const readAgain: MemoryRecord | undefined = store.getMemory('owner-1', 'memory-1');
      expect(readAgain === undefined).assertFalse();
      if (readAgain !== undefined) expect(readAgain.tags.length).assertEqual(1);
    });

    it('rejects bad digests and stale versions without mutation', 0, () => {
      const store: DeterministicMemoryStore = new DeterministicMemoryStore(new FixtureMemoryDigest());
      const invalid: MemoryRecord = memory('memory-1', 'owner-1', 'alpha');
      invalid.contentDigest = 'wrong';
      expect(store.saveMemory(invalid, 0).code).assertEqual(MemoryWriteCode.INVALID_INPUT);

      const first: MemoryRecord = memory('memory-1', 'owner-1', 'alpha');
      expect(store.saveMemory(first, 0).accepted).assertTrue();
      const stale: MemoryRecord = memory('memory-1', 'owner-1', 'beta', 2);
      expect(store.saveMemory(stale, 0).code).assertEqual(MemoryWriteCode.VERSION_CONFLICT);
      const saved: MemoryRecord | undefined = store.getMemory('owner-1', 'memory-1');
      if (saved !== undefined) expect(saved.content).assertEqual('alpha');
    });

    it('builds deterministic chunks and lexical search results', 0, () => {
      const store: DeterministicMemoryStore = new DeterministicMemoryStore(new FixtureMemoryDigest(), 64);
      store.saveMemory(memory('memory-b', 'owner-1', 'alpha schedule'), 0);
      store.saveMemory(memory('memory-a', 'owner-1', 'alpha project'), 0);
      store.saveMemory(memory('memory-x', 'owner-2', 'alpha private owner'), 0);
      expect(store.rebuildIndex('owner-1')).assertEqual(2);
      expect(store.searchMemory(query('owner-1', 'alpha')).length).assertEqual(2);
      expect(store.searchMemory(query('owner-1', 'alpha'))[0].memoryId).assertEqual('memory-a');
      expect(store.searchMemory(query('owner-2', 'alpha')).length).assertEqual(0);
      expect(store.listChunks('owner-1', 'memory-a')[0].chunkId).assertEqual('memory-a:v1:c0');
    });

    it('excludes sensitive and raw trace memories unless explicitly requested', 0, () => {
      const store: DeterministicMemoryStore = new DeterministicMemoryStore(new FixtureMemoryDigest());
      const sensitive: MemoryRecord = memory('memory-sensitive', 'owner-1', 'secret agenda');
      sensitive.privacyClass = MemoryPrivacyClass.SENSITIVE;
      const trace: MemoryRecord = memory('memory-trace', 'owner-1', 'trace agenda');
      trace.sourceKind = MemorySourceKind.RAW_PERSONAL_TRACE;
      store.saveMemory(sensitive, 0);
      store.saveMemory(trace, 0);
      store.rebuildIndex('owner-1');

      const normalQuery: MemoryQuery = query('owner-1', 'agenda');
      expect(store.searchMemory(normalQuery).length).assertEqual(0);
      normalQuery.includeSensitive = true;
      expect(store.searchMemory(normalQuery).length).assertEqual(1);
      normalQuery.includeRawPersonalTrace = true;
      expect(store.searchMemory(normalQuery).length).assertEqual(2);
    });

    it('imports atomically and denies raw traces by default', 0, () => {
      const store: DeterministicMemoryStore = new DeterministicMemoryStore(new FixtureMemoryDigest());
      const policy: MemoryImportPolicy = new MemoryImportPolicy();
      policy.ownerId = 'owner-1';
      const allowed: MemoryRecord = memory('memory-1', 'owner-1', 'allowed');
      const denied: MemoryRecord = memory('memory-2', 'owner-1', 'raw trace');
      denied.sourceKind = MemorySourceKind.RAW_PERSONAL_TRACE;
      const deniedResult = store.importMemories([allowed, denied], policy);
      expect(deniedResult.accepted).assertFalse();
      expect(deniedResult.code).assertEqual(MemoryWriteCode.POLICY_DENIED);
      expect(store.listMemories('owner-1').length).assertEqual(0);

      policy.allowRawPersonalTrace = true;
      const accepted = store.importMemories([allowed, denied], policy);
      expect(accepted.accepted).assertTrue();
      expect(accepted.importedRecords).assertEqual(2);
    });

    it('exports only allowed classes and redacts configured secrets', 0, () => {
      const store: DeterministicMemoryStore = new DeterministicMemoryStore(new FixtureMemoryDigest());
      const shareable: MemoryRecord = memory('memory-shareable', 'owner-1', 'token abc123');
      shareable.tags = ['project-abc123'];
      const privateRecord: MemoryRecord = memory('memory-private', 'owner-1', 'private abc123');
      privateRecord.privacyClass = MemoryPrivacyClass.PRIVATE;
      store.saveMemory(shareable, 0);
      store.saveMemory(privateRecord, 0);
      const policy: MemoryExportPolicy = new MemoryExportPolicy();
      policy.ownerId = 'owner-1';
      policy.redactionVersion = 'redaction-v1';
      policy.secrets = ['abc123'];
      const exported = store.exportMemories(policy);
      expect(exported.length).assertEqual(1);
      expect(exported[0].memoryId).assertEqual('memory-shareable');
      expect(exported[0].content).assertEqual('token [REDACTED]');
      expect(exported[0].tags[0]).assertEqual('project-[REDACTED]');
      expect(exported[0].redactionVersion).assertEqual('redaction-v1');
    });

    it('invalidates derived chunks and artifacts on update', 0, () => {
      const store: DeterministicMemoryStore = new DeterministicMemoryStore(new FixtureMemoryDigest());
      store.saveMemory(memory('memory-1', 'owner-1', 'alpha'), 0);
      store.rebuildIndex('owner-1');
      expect(store.listChunks('owner-1', 'memory-1').length).assertEqual(1);
      expect(store.listArtifacts('owner-1', 'memory-1').length).assertEqual(1);

      const update: MemoryRecord = memory('memory-1', 'owner-1', 'beta', 2);
      const result = store.saveMemory(update, 1);
      expect(result.code).assertEqual(MemoryWriteCode.UPDATED);
      expect(result.invalidatedChunks).assertEqual(1);
      expect(result.invalidatedArtifacts).assertEqual(2);
      expect(store.listChunks('owner-1', 'memory-1').length).assertEqual(0);
      expect(store.searchMemory(query('owner-1', 'alpha')).length).assertEqual(0);
    });

    it('rejects stale artifacts and cascades deletion', 0, () => {
      const store: DeterministicMemoryStore = new DeterministicMemoryStore(new FixtureMemoryDigest());
      store.saveMemory(memory('memory-1', 'owner-1', 'alpha'), 0);
      const staleArtifact: DerivedMemoryArtifact = new DerivedMemoryArtifact();
      staleArtifact.artifactId = 'summary-1';
      staleArtifact.memoryId = 'memory-1';
      staleArtifact.ownerId = 'owner-1';
      staleArtifact.memoryVersion = 2;
      staleArtifact.artifactType = 'SUMMARY';
      staleArtifact.sourceDigest = 'digest:alpha';
      staleArtifact.payloadJson = '{"summary":"alpha"}';
      staleArtifact.createdAtMs = 101;
      expect(store.saveArtifact(staleArtifact).code).assertEqual(MemoryWriteCode.VERSION_CONFLICT);

      staleArtifact.memoryVersion = 1;
      expect(store.saveArtifact(staleArtifact).accepted).assertTrue();
      store.rebuildIndex('owner-1');
      const deleted = store.deleteMemory('owner-1', 'memory-1');
      expect(deleted.accepted).assertTrue();
      expect(deleted.removedRecords).assertEqual(1);
      expect(deleted.removedChunks).assertEqual(1);
      expect(deleted.removedArtifacts).assertEqual(3);
      expect(store.listArtifacts('owner-1', 'memory-1').length).assertEqual(0);
      expect(store.searchMemory(query('owner-1', 'alpha')).length).assertEqual(0);
    });
  });
}
