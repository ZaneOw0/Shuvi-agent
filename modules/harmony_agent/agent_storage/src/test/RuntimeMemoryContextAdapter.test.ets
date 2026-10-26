import { describe, expect, it } from '@ohos/hypium';
import {
  PlanningMemoryContextRequest,
  PlanningMemoryContextResult
} from '@harmony_agent/agent-runtime';
import {
  DeterministicMemoryStore,
  MemoryDigestPort,
  MemoryKind,
  MemoryPrivacyClass,
  MemoryRecord,
  MemorySourceKind,
  RuntimeMemoryContextAdapter
} from '../../Index';

class ContextMemoryDigest implements MemoryDigestPort {
  digest(value: string): string {
    return 'digest:' + value;
  }
}

function record(memoryId: string, ownerId: string, content: string,
  privacyClass: MemoryPrivacyClass = MemoryPrivacyClass.SHAREABLE,
  sourceKind: MemorySourceKind = MemorySourceKind.USER_EXPLICIT): MemoryRecord {
  const value: MemoryRecord = new MemoryRecord();
  value.memoryId = memoryId;
  value.ownerId = ownerId;
  value.kind = MemoryKind.NOTE;
  value.privacyClass = privacyClass;
  value.sourceKind = sourceKind;
  value.title = memoryId;
  value.content = content;
  value.contentDigest = 'digest:' + content;
  value.tags = ['project'];
  value.version = 1;
  value.createdAtMs = 100;
  value.updatedAtMs = 101;
  return value;
}

function request(ownerId: string, maxItems: number = 4,
  maxCharacters: number = 256): PlanningMemoryContextRequest {
  const value: PlanningMemoryContextRequest = new PlanningMemoryContextRequest();
  value.taskId = 'task-1';
  value.ownerId = ownerId;
  value.queryTerms = ['alpha'];
  value.maxItems = maxItems;
  value.maxCharacters = maxCharacters;
  return value;
}

export default function runtimeMemoryContextAdapterTest(): void {
  describe('RuntimeMemoryContextAdapter', () => {
    it('returnsOnlyOwnerScopedNonSensitiveNonTraceMemory', 0, () => {
      const store: DeterministicMemoryStore = new DeterministicMemoryStore(new ContextMemoryDigest());
      store.saveMemory(record('memory-shareable', 'owner-1', 'alpha shareable'), 0);
      store.saveMemory(record('memory-sensitive', 'owner-1', 'alpha sensitive',
        MemoryPrivacyClass.SENSITIVE), 0);
      store.saveMemory(record('memory-trace', 'owner-1', 'alpha trace',
        MemoryPrivacyClass.PRIVATE, MemorySourceKind.RAW_PERSONAL_TRACE), 0);
      store.saveMemory(record('memory-other-owner', 'owner-2', 'alpha other owner'), 0);
      store.rebuildIndex('owner-1');
      store.rebuildIndex('owner-2');
      const adapter: RuntimeMemoryContextAdapter = new RuntimeMemoryContextAdapter(store);

      const result: PlanningMemoryContextResult = adapter.retrieve(request('owner-1'));

      expect(result.ownerId).assertEqual('owner-1');
      expect(result.taskId).assertEqual('task-1');
      expect(result.items.length).assertEqual(1);
      expect(result.items[0].memoryId).assertEqual('memory-shareable');
      expect(result.items[0].content).assertEqual('alpha shareable');
    });

    it('enforcesItemAndCharacterBudgetsDeterministically', 0, () => {
      const store: DeterministicMemoryStore = new DeterministicMemoryStore(new ContextMemoryDigest());
      store.saveMemory(record('memory-a', 'owner-1', 'alpha first memory'), 0);
      store.saveMemory(record('memory-b', 'owner-1', 'alpha second memory'), 0);
      store.rebuildIndex('owner-1');
      const adapter: RuntimeMemoryContextAdapter = new RuntimeMemoryContextAdapter(store);

      const result: PlanningMemoryContextResult = adapter.retrieve(request('owner-1', 1, 8));

      expect(result.items.length).assertEqual(1);
      expect(result.items[0].memoryId).assertEqual('memory-a');
      expect(result.items[0].content).assertEqual('alpha fi');
      expect(result.totalCharacters).assertEqual(8);
      expect(result.truncated).assertTrue();
    });

    it('cannotRecallDeletedOrInvalidatedMemory', 0, () => {
      const store: DeterministicMemoryStore = new DeterministicMemoryStore(new ContextMemoryDigest());
      store.saveMemory(record('memory-1', 'owner-1', 'alpha removable'), 0);
      store.rebuildIndex('owner-1');
      const adapter: RuntimeMemoryContextAdapter = new RuntimeMemoryContextAdapter(store);
      expect(adapter.retrieve(request('owner-1')).items.length).assertEqual(1);

      store.deleteMemory('owner-1', 'memory-1');

      expect(adapter.retrieve(request('owner-1')).items.length).assertEqual(0);
    });

    it('rejectsUnboundedOrOwnerlessRequests', 0, () => {
      const store: DeterministicMemoryStore = new DeterministicMemoryStore(new ContextMemoryDigest());
      const adapter: RuntimeMemoryContextAdapter = new RuntimeMemoryContextAdapter(store);
      const invalid: PlanningMemoryContextRequest = request('');
      let rejected: boolean = false;
      try {
        adapter.retrieve(invalid);
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });
  });
}
