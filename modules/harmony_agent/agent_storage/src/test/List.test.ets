import executionRecoveryStoreTest from './ExecutionRecoveryStore.test';
import deterministicMemoryStoreTest from './DeterministicMemoryStore.test';
import durableMemoryStoreTest from './DurableMemoryStore.test';
import runtimeExecutionRecoveryBridgeTest from './RuntimeExecutionRecoveryBridge.test';
import durableArtifactRegistryAdapterTest from './DurableArtifactRegistryAdapter.test';
import runtimeMemoryContextAdapterTest from './RuntimeMemoryContextAdapter.test';
import encryptedRdbConfigurationTest from './EncryptedRdbConfiguration.test';

export default function testsuite(): void {
  executionRecoveryStoreTest();
  deterministicMemoryStoreTest();
  durableMemoryStoreTest();
  runtimeExecutionRecoveryBridgeTest();
  durableArtifactRegistryAdapterTest();
  runtimeMemoryContextAdapterTest();
  encryptedRdbConfigurationTest();
}
