import { describe, expect, it } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import common from '@ohos.app.ability.common';
import relationalStore from '@ohos.data.relationalStore';
import {
  DurableMemorySnapshotBackendPort,
  DurableMemoryStore,
  MemoryDigestPort,
  MemoryKind,
  MemoryPrivacyClass,
  MemoryQuery,
  MemoryRecord,
  MemorySnapshotIntegrityPort,
  MemorySourceKind,
  MemoryWriteCode,
  RdbMemorySnapshotBackend
} from '@harmony_agent/agent-storage';

class DeviceMemoryDigest implements MemoryDigestPort {
  digest(value: string): string {
    return 'device-memory-digest:' + value;
  }
}

class DeviceMemorySnapshotIntegrity implements MemorySnapshotIntegrityPort {
  digest(payloadJson: string): string {
    return 'device-memory-snapshot:' + payloadJson;
  }
}

async function appContext(): Promise<common.UIAbilityContext> {
  try {
    const ability = await abilityDelegatorRegistry.getAbilityDelegator().getCurrentTopAbility();
    return ability.context;
  } catch (error) {
    throw error as Error;
  }
}

function storeConfig(name: string): relationalStore.StoreConfig {
  return {
    name: name,
    securityLevel: relationalStore.SecurityLevel.S1
  };
}

async function removeDatabase(context: common.Context, config: relationalStore.StoreConfig): Promise<void> {
  try {
    await relationalStore.deleteRdbStore(context, config);
  } catch (error) {
    throw error as Error;
  }
}

function closeStore(store: relationalStore.RdbStore | undefined): void {
  if (store === undefined) return;
  try {
    store.close();
  } catch (error) {
    throw error as Error;
  }
}

async function closeAndRemoveDatabase(store: relationalStore.RdbStore | undefined,
  context: common.Context, config: relationalStore.StoreConfig): Promise<void> {
  try {
    closeStore(store);
  } finally {
    await removeDatabase(context, config);
  }
}

async function openMemoryStore(store: relationalStore.RdbStore): Promise<DurableMemoryStore> {
  const backend: DurableMemorySnapshotBackendPort = new RdbMemorySnapshotBackend(store);
  const opened = await DurableMemoryStore.open(
    backend,
    new DeviceMemoryDigest(),
    new DeviceMemorySnapshotIntegrity(),
    128
  );
  if (!opened.accepted || opened.store === undefined) {
    throw new Error('durable memory store failed to open: ' + opened.code);
  }
  return opened.store;
}

function memory(memoryId: string, content: string): MemoryRecord {
  const value: MemoryRecord = new MemoryRecord();
  value.memoryId = memoryId;
  value.ownerId = 'device-owner';
  value.kind = MemoryKind.STRUCTURED;
  value.privacyClass = MemoryPrivacyClass.SHAREABLE;
  value.sourceKind = MemorySourceKind.USER_EXPLICIT;
  value.title = 'Device memory';
  value.content = content;
  value.contentDigest = 'device-memory-digest:' + content;
  value.tags = ['device'];
  value.version = 1;
  value.createdAtMs = 100;
  value.updatedAtMs = 101;
  return value;
}

export default function memoryDeviceRecoveryTest(): void {
  describe('MemoryDeviceRecovery', () => {
    it('persistsMemoryAndRebuildsIndexAcrossCloseReopen', 0, async () => {
      const context: common.Context = await appContext();
      const config: relationalStore.StoreConfig = storeConfig('harmony_agent_memory_reopen.db');
      await removeDatabase(context, config);
      let rdb: relationalStore.RdbStore | undefined = undefined;
      try {
        rdb = await relationalStore.getRdbStore(context, config);
        const first: DurableMemoryStore = await openMemoryStore(rdb);
        expect((await first.saveMemory(memory('memory-1', 'alpha durable device'), 0)).accepted).assertTrue();
        closeStore(rdb);
        rdb = undefined;

        rdb = await relationalStore.getRdbStore(context, config);
        const reopened: DurableMemoryStore = await openMemoryStore(rdb);
        expect(reopened.getMemory('device-owner', 'memory-1')?.content).assertEqual('alpha durable device');
        const query: MemoryQuery = new MemoryQuery();
        query.ownerId = 'device-owner';
        query.terms = ['alpha'];
        expect(reopened.searchMemory(query).length).assertEqual(1);
      } finally {
        await closeAndRemoveDatabase(rdb, context, config);
      }
    });

    it('allowsOnlyOneMemoryWriterFromStaleSessions', 0, async () => {
      const context: common.Context = await appContext();
      const config: relationalStore.StoreConfig = storeConfig('harmony_agent_memory_concurrent.db');
      await removeDatabase(context, config);
      let rdb: relationalStore.RdbStore | undefined = undefined;
      try {
        rdb = await relationalStore.getRdbStore(context, config);
        const first: DurableMemoryStore = await openMemoryStore(rdb);
        const second: DurableMemoryStore = await openMemoryStore(rdb);
        expect((await first.saveMemory(memory('memory-first', 'first wins'), 0)).accepted).assertTrue();
        const losing = await second.saveMemory(memory('memory-second', 'second loses'), 0);
        expect(losing.code).assertEqual(MemoryWriteCode.VERSION_CONFLICT);
        expect(second.getMemory('device-owner', 'memory-second') === undefined).assertTrue();
      } finally {
        await closeAndRemoveDatabase(rdb, context, config);
      }
    });

    it('failsClosedWhenMemorySnapshotDigestIsCorrupt', 0, async () => {
      const context: common.Context = await appContext();
      const config: relationalStore.StoreConfig = storeConfig('harmony_agent_memory_corrupt.db');
      await removeDatabase(context, config);
      let rdb: relationalStore.RdbStore | undefined = undefined;
      try {
        rdb = await relationalStore.getRdbStore(context, config);
        const first: DurableMemoryStore = await openMemoryStore(rdb);
        await first.saveMemory(memory('memory-corrupt', 'corrupt target'), 0);
        await rdb.execute(
          'UPDATE harmony_agent_memory_snapshot SET payload_digest = ? WHERE slot_id = ?',
          ['corrupt-digest', 1]
        );
        const backend: DurableMemorySnapshotBackendPort = new RdbMemorySnapshotBackend(rdb);
        const opened = await DurableMemoryStore.open(
          backend,
          new DeviceMemoryDigest(),
          new DeviceMemorySnapshotIntegrity()
        );
        expect(opened.accepted).assertFalse();
        expect(opened.code).assertEqual(MemoryWriteCode.CORRUPT_SNAPSHOT);
      } finally {
        await closeAndRemoveDatabase(rdb, context, config);
      }
    });
  });
}
