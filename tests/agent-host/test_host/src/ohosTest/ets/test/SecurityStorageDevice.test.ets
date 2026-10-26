import { describe, expect, it } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import relationalStore from '@ohos.data.relationalStore';
import {
  AssetStoreCredentialManager,
  HarmonyAssetSecretMutationPort,
  HarmonyAssetSecretQueryPort
} from '@harmony_agent/agent-connectors';
import {
  createEncryptedRdbStoreConfigs,
  EncryptedRdbConfigurationRequest,
  openKeyedEncryptedRdbStore,
  RdbEncryptionKeyPort,
  rekeyEncryptedRdbStore
} from '@harmony_agent/agent-storage';

function bytes(value: string): Uint8Array {
  const result: Uint8Array = new Uint8Array(value.length);
  for (let index: number = 0; index < value.length; index += 1) {
    result[index] = value.charCodeAt(index);
  }
  return result;
}

function text(value: Uint8Array): string {
  let result: string = '';
  for (let index: number = 0; index < value.length; index += 1) {
    result += String.fromCharCode(value[index]);
  }
  return result;
}

function clear(value: Uint8Array): void {
  for (let index: number = 0; index < value.length; index += 1) value[index] = 0;
}

function allZero(value: Uint8Array): boolean {
  for (let index: number = 0; index < value.length; index += 1) {
    if (value[index] !== 0) return false;
  }
  return true;
}

async function appContext(): Promise<common.UIAbilityContext> {
  try {
    const ability = await abilityDelegatorRegistry.getAbilityDelegator().getCurrentTopAbility();
    return ability.context;
  } catch (error) {
    throw error as Error;
  }
}

class DeviceRdbKeyPort implements RdbEncryptionKeyPort {
  private readonly first: Uint8Array = bytes('0123456789abcdef0123456789abcdef');
  private readonly second: Uint8Array = bytes('fedcba9876543210fedcba9876543210');
  lastResolved: Uint8Array = new Uint8Array();

  resolveKey(keyId: string): Promise<Uint8Array> {
    const source: Uint8Array = keyId === 'device-rdb-key-1' ? this.first : this.second;
    const result: Uint8Array = new Uint8Array(source.length);
    result.set(source);
    this.lastResolved = result;
    return Promise.resolve(result);
  }
}

async function removeDatabase(context: common.Context,
  config: relationalStore.StoreConfig): Promise<void> {
  try {
    await relationalStore.deleteRdbStore(context, config);
  } catch (error) {
  }
}

async function removeFile(path: string): Promise<void> {
  try {
    await fs.unlink(path);
  } catch (error) {
  }
}

function closeStore(store: relationalStore.RdbStore | undefined): void {
  if (store === undefined) return;
  try {
    store.close();
  } catch (error) {
  }
}

async function storedValue(store: relationalStore.RdbStore): Promise<string> {
  let resultSet: relationalStore.ResultSet | undefined = undefined;
  try {
    resultSet = await store.querySql('SELECT value FROM security_probe WHERE id = 1');
    if (!resultSet.goToFirstRow()) throw new Error('security probe row is missing');
    return resultSet.getString(resultSet.getColumnIndex('value'));
  } catch (error) {
    throw error as Error;
  } finally {
    try {
      if (resultSet !== undefined) resultSet.close();
    } catch (error) {
    }
  }
}

export default function securityStorageDeviceTest(): void {
  describe('SecurityStorageDevice', (): void => {
    it('provisionsReadsRotatesAndRemovesCredentialAsset', 0, async () => {
      const alias: string = 'harmony_agent.device.credential.acceptance';
      const manager: AssetStoreCredentialManager = new AssetStoreCredentialManager(
        new HarmonyAssetSecretMutationPort());
      const query: HarmonyAssetSecretQueryPort = new HarmonyAssetSecretQueryPort();
      try {
        await manager.remove(alias);
      } catch (error) {
      }

      const initial: Uint8Array = bytes('device-initial-token');
      const rotated: Uint8Array = bytes('device-rotated-token');
      try {
        await manager.provision(alias, initial);
        expect(allZero(initial)).assertTrue();
        const firstRead: Uint8Array = await query.querySecret(alias);
        try {
          expect(text(firstRead)).assertEqual('device-initial-token');
        } finally {
          clear(firstRead);
        }

        await manager.rotate(alias, rotated);
        expect(allZero(rotated)).assertTrue();
        const secondRead: Uint8Array = await query.querySecret(alias);
        try {
          expect(text(secondRead)).assertEqual('device-rotated-token');
        } finally {
          clear(secondRead);
        }

        await manager.remove(alias);
        let rejected: boolean = false;
        try {
          await query.querySecret(alias);
        } catch (error) {
          rejected = true;
        }
        expect(rejected).assertTrue();
      } finally {
        try {
          await manager.remove(alias);
        } catch (error) {
        }
      }
    });

    it('restoresEncryptedDatabaseAndReopensAfterRekeyEx', 0, async () => {
      const context: common.UIAbilityContext = await appContext();
      const request: EncryptedRdbConfigurationRequest = new EncryptedRdbConfigurationRequest();
      request.executionStoreName = 'harmony_agent_security_device.db';
      request.memoryStoreName = 'harmony_agent_security_device_memory.db';
      request.securityLevel = relationalStore.SecurityLevel.S1;
      const config: relationalStore.StoreConfig = createEncryptedRdbStoreConfigs(request).execution;
      const backupName: string = 'harmony_agent_security_device_backup.db';
      const backupPath: string = context.databaseDir + '/' + backupName;
      const keys: DeviceRdbKeyPort = new DeviceRdbKeyPort();
      let store: relationalStore.RdbStore | undefined = undefined;
      await removeDatabase(context, config);
      await removeFile(backupPath);
      try {
        store = await openKeyedEncryptedRdbStore(context, config, 'device-rdb-key-1', keys);
        expect(allZero(keys.lastResolved)).assertTrue();
        await store.execute('CREATE TABLE IF NOT EXISTS security_probe ' +
          '(id INTEGER PRIMARY KEY, value TEXT NOT NULL)');
        await store.execute('INSERT OR REPLACE INTO security_probe (id, value) VALUES (?, ?)',
          [1, 'before-backup']);
        await store.backup(backupName);
        await store.execute('UPDATE security_probe SET value = ? WHERE id = 1', ['after-backup']);
        expect(await storedValue(store)).assertEqual('after-backup');
        await store.restore(backupName);
        expect(await storedValue(store)).assertEqual('before-backup');

        await rekeyEncryptedRdbStore(store, 'device-rdb-key-2', keys);
        expect(allZero(keys.lastResolved)).assertTrue();
        closeStore(store);
        store = undefined;

        store = await openKeyedEncryptedRdbStore(context, config, 'device-rdb-key-2', keys);
        expect(allZero(keys.lastResolved)).assertTrue();
        expect(await storedValue(store)).assertEqual('before-backup');
      } finally {
        closeStore(store);
        await removeDatabase(context, config);
        await removeFile(backupPath);
      }
    });
  });
}
