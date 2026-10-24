import relationalStore from '@ohos.data.relationalStore';
import {
  AgentRuntimeFacade,
  ProductionAgentRuntimeConfig,
  ProductionAgentRuntimePorts,
  createRecoveredProductionAgentRuntime
} from '@harmony_agent/agent-runtime';
import { DurableExecutionRecoveryStore } from '../storage/DurableExecutionRecoveryStore';
import { RdbSnapshotBackend } from '../storage/RdbSnapshotBackend';
import { SnapshotIntegrityPort, StorageMigrationPort } from '../storage/StoragePorts';
import {
  RuntimeExecutionRecoveryBridge,
  RuntimeExecutionRecoveryBridgeConfig
} from './RuntimeExecutionRecoveryBridge';

function composedRuntimePorts(source: ProductionAgentRuntimePorts,
  bridge: RuntimeExecutionRecoveryBridge): ProductionAgentRuntimePorts {
  const value: ProductionAgentRuntimePorts = new ProductionAgentRuntimePorts();
  value.clock = source.clock;
  value.ids = source.ids;
  value.planner = source.planner;
  value.collaboration = source.collaboration;
  value.collaborationPlan = source.collaborationPlan;
  value.collaborationPreparation = source.collaborationPreparation;
  value.toolPreparer = source.toolPreparer;
  value.adapterFactory = source.adapterFactory;
  value.persistence = bridge;
  value.recovery = bridge;
  return value;
}

function validateComposition(runtimeConfig: ProductionAgentRuntimeConfig,
  runtimePorts: ProductionAgentRuntimePorts,
  bridgeConfig: RuntimeExecutionRecoveryBridgeConfig): void {
  if (runtimePorts.persistence !== undefined || runtimePorts.recovery !== undefined) {
    throw new Error('RDB recovery composition owns persistence and recovery ports');
  }
  if (bridgeConfig.ownerId.trim().length === 0 ||
    !Number.isSafeInteger(bridgeConfig.leaseTtlMs) || bridgeConfig.leaseTtlMs <= 0 ||
    bridgeConfig.policyVersion.length === 0 ||
    bridgeConfig.policyVersion !== runtimeConfig.policyVersion) {
    throw new Error('invalid RDB recovery bridge configuration');
  }
}

/**
 * Composes an already-open host RDB store with durable recovery and returns
 * the sole task-control facade only after every persisted task is recovered.
 *
 * The host retains ownership of RdbStore configuration, encryption, backup
 * and close. This function always uses openForRuntimeRecovery so active
 * operation, budget, lease/fencing and Runtime checkpoint changes are
 * published by the bridge in one later backend CAS.
 */
export async function createRdbRecoveredAgentRuntime(rdbStore: relationalStore.RdbStore,
  integrity: SnapshotIntegrityPort,
  bridgeConfig: RuntimeExecutionRecoveryBridgeConfig,
  runtimeConfig: ProductionAgentRuntimeConfig,
  runtimePorts: ProductionAgentRuntimePorts,
  migration?: StorageMigrationPort): Promise<AgentRuntimeFacade> {
  validateComposition(runtimeConfig, runtimePorts, bridgeConfig);
  const backend: RdbSnapshotBackend = new RdbSnapshotBackend(rdbStore);
  const opened = await DurableExecutionRecoveryStore.openForRuntimeRecovery(
    backend, integrity, migration);
  if (!opened.accepted || opened.store === undefined) {
    throw new Error('RDB recovery store failed to open: ' + opened.code);
  }
  const bridge: RuntimeExecutionRecoveryBridge =
    new RuntimeExecutionRecoveryBridge(opened.store, bridgeConfig);
  return await createRecoveredProductionAgentRuntime(
    runtimeConfig, composedRuntimePorts(runtimePorts, bridge));
}
