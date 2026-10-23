import relationalStore from '@ohos.data.relationalStore';

export const ENCRYPTED_RDB_CONFIGURATION_VERSION: string = '1.0';

/**
 * Product-host input for the two durable stores used by the single Agent runtime.
 * The default S3 level is appropriate for private task and memory data, but the
 * product host remains responsible for confirming its data classification.
 */
export class EncryptedRdbConfigurationRequest {
  executionStoreName: string = 'harmony_agent_execution.db';
  memoryStoreName: string = 'harmony_agent_memory.db';
  securityLevel: relationalStore.SecurityLevel = relationalStore.SecurityLevel.S3;
}

/** StoreConfig values that a product host passes to relationalStore.getRdbStore. */
export class EncryptedRdbStoreConfigs {
  readonly version: string = ENCRYPTED_RDB_CONFIGURATION_VERSION;
  readonly execution: relationalStore.StoreConfig;
  readonly memory: relationalStore.StoreConfig;

  constructor(execution: relationalStore.StoreConfig, memory: relationalStore.StoreConfig) {
    this.execution = execution;
    this.memory = memory;
  }
}

/**
 * Builds persistent, encrypted API 26 RDB configurations without accepting raw
 * key material. The platform default encrypted-store key lifecycle is used.
 */
export function createEncryptedRdbStoreConfigs(
  request: EncryptedRdbConfigurationRequest
): EncryptedRdbStoreConfigs {
  validateStoreName(request.executionStoreName, 'executionStoreName');
  validateStoreName(request.memoryStoreName, 'memoryStoreName');
  if (request.executionStoreName === request.memoryStoreName) {
    throw new Error('execution and memory RDB stores must use different names');
  }
  if (!supportedSecurityLevel(request.securityLevel)) {
    throw new Error('unsupported RDB security level');
  }

  const execution: relationalStore.StoreConfig = {
    name: request.executionStoreName,
    securityLevel: request.securityLevel,
    encrypt: true,
    persist: true
  };
  const memory: relationalStore.StoreConfig = {
    name: request.memoryStoreName,
    securityLevel: request.securityLevel,
    encrypt: true,
    persist: true
  };
  return new EncryptedRdbStoreConfigs(execution, memory);
}

function validateStoreName(value: string, field: string): void {
  if (value.length === 0 || value.length > 128 || value.trim() !== value ||
    value === '.' || value === '..' || value.indexOf('/') >= 0 || value.indexOf('\\') >= 0 ||
    value.indexOf('\u0000') >= 0) {
    throw new Error(field + ' must be a safe database file name');
  }
}

function supportedSecurityLevel(value: relationalStore.SecurityLevel): boolean {
  return value === relationalStore.SecurityLevel.S1 || value === relationalStore.SecurityLevel.S2 ||
    value === relationalStore.SecurityLevel.S3 || value === relationalStore.SecurityLevel.S4;
}
