import common from '@ohos.app.ability.common';
import { RuntimeExecutionRecoveryBridgeConfig } from '@harmony_agent/agent-storage';
import { AgentHostDigest } from './AgentHostDigest';
import { AgentExecutionResource, AgentMemoryResource, AgentRdbOpenPort, NativeAgentRdbOpen } from './AgentRdbResources';
import { SessionModelCredentials } from './SessionModelCredentials';
import { ShuviModelBackendPorts } from './ShuviModelBackend';
import { ShuviSessionResources } from './ShuviRuntimeSession';

/** One bundle per host. Let SingleAgentHostRuntime own open/rollback/shutdown order. */
export class ShuviDeviceHostResources implements ShuviSessionResources {
  private bound: boolean = false;
  readonly credentials: SessionModelCredentials = new SessionModelCredentials();
  readonly digest: AgentHostDigest = new AgentHostDigest();
  readonly execution: AgentExecutionResource;
  readonly memory: AgentMemoryResource;

  constructor(opener: AgentRdbOpenPort, recovery: RuntimeExecutionRecoveryBridgeConfig) {
    this.execution = new AgentExecutionResource(opener, recovery, this.digest);
    this.memory = new AgentMemoryResource(opener, this.digest);
  }

  bind(ports: ShuviModelBackendPorts): void {
    if (this.bound || ports.host.credentialStore !== undefined || ports.host.executionStorage !== undefined ||
      ports.host.memoryStorage !== undefined || ports.runtime.persistence !== undefined ||
      ports.runtime.recovery !== undefined || ports.memoryContext !== undefined || ports.digest !== undefined) {
      throw new Error('AGENT_HOST_RESOURCE_BINDING_CONFLICT');
    }
    ports.host.credentialStore = this.credentials;
    ports.host.executionStorage = this.execution;
    ports.host.memoryStorage = this.memory;
    ports.runtime.persistence = this.execution;
    ports.runtime.recovery = this.execution;
    ports.memoryContext = this.memory;
    ports.digest = this.digest;
    this.bound = true;
  }
}

export function createShuviDeviceHostResources(context: common.Context,
  recovery: RuntimeExecutionRecoveryBridgeConfig): ShuviDeviceHostResources {
  return new ShuviDeviceHostResources(new NativeAgentRdbOpen(context), recovery);
}
