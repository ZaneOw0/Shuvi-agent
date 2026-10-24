import common from '@ohos.app.ability.common';
import relationalStore from '@ohos.data.relationalStore';

export const ENCRYPTED_RDB_LIFECYCLE_VERSION: string = '1.0';

/** Supplies an ephemeral database key without exposing its storage mechanism. */
export interface RdbEncryptionKeyPort {
  resolveKey(keyId: string): Promise<Uint8Array>;
}

function validIdentifier(value: string): boolean {
  return value.length > 0 && value.length <= 128 && value === value.trim() &&
    !value.includes('\r') && !value.includes('\n') && !value.includes('\u0000');
}

function validStoreName(value: string): boolean {
  return validIdentifier(value) && value !== '.' && value !== '..' &&
    !value.includes('/') && !value.includes('\\');
}

function clearBytes(value: Uint8Array): void {
  for (let index: number = 0; index < value.length; index += 1) value[index] = 0;
}

function ownedKey(source: Uint8Array): Uint8Array {
  if (source.length === 0 || source.length > 4096) {
    clearBytes(source);
    throw new Error('RDB encryption key is invalid');
  }
  const copied: Uint8Array = new Uint8Array(source.length);
  copied.set(source);
  clearBytes(source);
  return copied;
}

async function resolveOwnedKey(keys: RdbEncryptionKeyPort, keyId: string): Promise<Uint8Array> {
  if (!validIdentifier(keyId)) throw new Error('RDB encryption key identifier is invalid');
  let resolved: Uint8Array;
  try {
    resolved = await keys.resolveKey(keyId);
  } catch (error) {
    throw new Error('RDB encryption key resolution failed');
  }
  return ownedKey(resolved);
}

function validateEncryptedConfig(config: relationalStore.StoreConfig): void {
  if (!validStoreName(config.name) || config.encrypt !== true || config.persist !== true) {
    throw new Error('RDB encrypted store configuration is invalid');
  }
}

/**
 * Opens a persistent encrypted store with an ephemeral host-supplied key. The
 * key returned by the port and the temporary copy passed to RDB are both
 * cleared before this call returns.
 */
export async function openKeyedEncryptedRdbStore(context: common.Context,
  config: relationalStore.StoreConfig, keyId: string,
  keys: RdbEncryptionKeyPort): Promise<relationalStore.RdbStore> {
  validateEncryptedConfig(config);
  const key: Uint8Array = await resolveOwnedKey(keys, keyId);
  const openConfig: relationalStore.StoreConfig = {
    name: config.name,
    securityLevel: config.securityLevel,
    encrypt: true,
    persist: true,
    cryptoParam: {
      encryptionKey: key
    }
  };
  try {
    return await relationalStore.getRdbStore(context, openConfig);
  } catch (error) {
    throw new Error('Encrypted RDB store open failed');
  } finally {
    clearBytes(key);
  }
}

/** Rotates an open encrypted database to a new host-supplied key using rekeyEx. */
export async function rekeyEncryptedRdbStore(store: relationalStore.RdbStore,
  keyId: string, keys: RdbEncryptionKeyPort): Promise<void> {
  const key: Uint8Array = await resolveOwnedKey(keys, keyId);
  try {
    await store.rekeyEx({ encryptionKey: key });
  } catch (error) {
    throw new Error('Encrypted RDB rekey failed');
  } finally {
    clearBytes(key);
  }
}
