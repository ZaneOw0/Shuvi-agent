import { describe, expect, it } from '@ohos/hypium';
import {
  createEncryptedRdbStoreConfigs,
  ENCRYPTED_RDB_CONFIGURATION_VERSION,
  EncryptedRdbConfigurationRequest,
  EncryptedRdbStoreConfigs
} from '../../Index';

export default function encryptedRdbConfigurationTest(): void {
  describe('EncryptedRdbConfiguration', () => {
    it('createsDistinctPersistentEncryptedStoreConfigs', 0, () => {
      const request: EncryptedRdbConfigurationRequest = new EncryptedRdbConfigurationRequest();

      const configs: EncryptedRdbStoreConfigs = createEncryptedRdbStoreConfigs(request);

      expect(configs.version).assertEqual(ENCRYPTED_RDB_CONFIGURATION_VERSION);
      expect(configs.execution.name).assertEqual('harmony_agent_execution.db');
      expect(configs.memory.name).assertEqual('harmony_agent_memory.db');
      expect(configs.execution.encrypt).assertTrue();
      expect(configs.memory.encrypt).assertTrue();
      expect(configs.execution.persist).assertTrue();
      expect(configs.memory.persist).assertTrue();
      expect(configs.execution.securityLevel).assertEqual(configs.memory.securityLevel);
      expect(JSON.stringify(configs).includes('cryptoParam')).assertFalse();
    });

    it('rejectsSharedOrUnsafeStoreNames', 0, () => {
      const shared: EncryptedRdbConfigurationRequest = new EncryptedRdbConfigurationRequest();
      shared.memoryStoreName = shared.executionStoreName;
      const traversal: EncryptedRdbConfigurationRequest = new EncryptedRdbConfigurationRequest();
      traversal.executionStoreName = '../execution.db';

      expectRejected(shared);
      expectRejected(traversal);
    });

    it('returnsIndependentConfigObjects', 0, () => {
      const configs: EncryptedRdbStoreConfigs =
        createEncryptedRdbStoreConfigs(new EncryptedRdbConfigurationRequest());

      configs.execution.encrypt = false;

      expect(configs.memory.encrypt).assertTrue();
    });
  });
}

function expectRejected(request: EncryptedRdbConfigurationRequest): void {
  let rejected: boolean = false;
  try {
    createEncryptedRdbStoreConfigs(request);
  } catch (error) {
    rejected = true;
  }
  expect(rejected).assertTrue();
}
