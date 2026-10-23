import {
  AgentTaskSnapshot,
  AuthorizationDecision,
  ClarificationResponse,
  CommandReceipt,
  ReconciliationReport,
  TaskControlCommand,
  TaskHandle,
  TaskSubmission
} from '@harmony_agent/agent-contracts';
import {
  AgentRuntimeFacade,
  AgentRuntimeObserver,
  AgentSubscription,
  ShutdownMode,
  SubscriptionRequest
} from '../api/RuntimeApi';

export const SINGLE_AGENT_HOST_COMPOSITION_VERSION: string = '1.0';

export enum SingleAgentHostErrorCode {
  INVALID_CONFIGURATION = 'INVALID_CONFIGURATION',
  RESOURCE_OPEN_FAILED = 'RESOURCE_OPEN_FAILED',
  RESOURCE_ROLLBACK_FAILED = 'RESOURCE_ROLLBACK_FAILED',
  RUNTIME_FACTORY_FAILED = 'RUNTIME_FACTORY_FAILED',
  HOST_SHUTDOWN_FAILED = 'HOST_SHUTDOWN_FAILED',
  INVALID_SHUTDOWN_MODE = 'INVALID_SHUTDOWN_MODE'
}

export class SingleAgentHostError extends Error {
  readonly code: SingleAgentHostErrorCode;

  constructor(code: SingleAgentHostErrorCode, message: string) {
    super(message);
    this.name = 'SingleAgentHostError';
    this.code = code;
  }
}

/** Host-owned resource with explicit open/close lifecycle and no task-control methods. */
export interface SingleAgentHostResourcePort {
  open(): Promise<void>;
  close(): Promise<void>;
}

/**
 * Factory captures the already-open concrete resources and must return the
 * sole AgentRuntimeFacade. It must not expose a coordinator or adapter.
 */
export interface SingleAgentHostRuntimeFactoryPort {
  create(): Promise<AgentRuntimeFacade>;
}

export class SingleAgentHostPorts {
  credentialStore?: SingleAgentHostResourcePort;
  executionStorage?: SingleAgentHostResourcePort;
  memoryStorage?: SingleAgentHostResourcePort;
  mcpClient?: SingleAgentHostResourcePort;
  runtimeFactory?: SingleAgentHostRuntimeFactoryPort;
}

class HostResourceStack {
  private readonly resources: SingleAgentHostResourcePort[] = [];

  async open(resource: SingleAgentHostResourcePort): Promise<void> {
    this.resources.push(resource);
    await resource.open();
  }

  async closeAll(): Promise<boolean> {
    let accepted: boolean = true;
    for (let index: number = this.resources.length - 1; index >= 0; index--) {
      try {
        await this.resources[index].close();
      } catch (error) {
        accepted = false;
      }
    }
    this.resources.length = 0;
    return accepted;
  }
}

class HostedAgentRuntimeFacade implements AgentRuntimeFacade {
  private readonly delegate: AgentRuntimeFacade;
  private readonly resources: HostResourceStack;
  private shutdownPromise?: Promise<void>;

  constructor(delegate: AgentRuntimeFacade, resources: HostResourceStack) {
    this.delegate = delegate;
    this.resources = resources;
  }

  async submitTask(submission: TaskSubmission): Promise<TaskHandle> {
    return await this.delegate.submitTask(submission);
  }

  async getTaskSnapshot(taskId: string): Promise<AgentTaskSnapshot> {
    return await this.delegate.getTaskSnapshot(taskId);
  }

  async cancelTask(command: TaskControlCommand): Promise<CommandReceipt> {
    return await this.delegate.cancelTask(command);
  }

  async pauseTask(command: TaskControlCommand): Promise<CommandReceipt> {
    return await this.delegate.pauseTask(command);
  }

  async resumeTask(command: TaskControlCommand): Promise<CommandReceipt> {
    return await this.delegate.resumeTask(command);
  }

  async provideAuthorization(decision: AuthorizationDecision): Promise<CommandReceipt> {
    return await this.delegate.provideAuthorization(decision);
  }

  async provideClarification(response: ClarificationResponse): Promise<CommandReceipt> {
    return await this.delegate.provideClarification(response);
  }

  async provideReconciliation(report: ReconciliationReport): Promise<CommandReceipt> {
    return await this.delegate.provideReconciliation(report);
  }

  async subscribe(request: SubscriptionRequest, observer: AgentRuntimeObserver): Promise<AgentSubscription> {
    return await this.delegate.subscribe(request, observer);
  }

  async shutdown(mode: ShutdownMode): Promise<void> {
    if (mode !== ShutdownMode.GRACEFUL && mode !== ShutdownMode.IMMEDIATE) {
      throw new SingleAgentHostError(SingleAgentHostErrorCode.INVALID_SHUTDOWN_MODE,
        'Single Agent host received an invalid shutdown mode');
    }
    if (this.shutdownPromise === undefined) this.shutdownPromise = this.shutdownOnce(mode);
    await this.shutdownPromise;
  }

  private async shutdownOnce(mode: ShutdownMode): Promise<void> {
    let accepted: boolean = true;
    try {
      await this.delegate.shutdown(mode);
    } catch (error) {
      accepted = false;
    }
    if (!await this.resources.closeAll()) accepted = false;
    if (!accepted) {
      throw new SingleAgentHostError(SingleAgentHostErrorCode.HOST_SHUTDOWN_FAILED,
        'Single Agent host shutdown failed');
    }
  }
}

function distinctResources(ports: SingleAgentHostPorts): boolean {
  const credential = ports.credentialStore;
  const execution = ports.executionStorage;
  const memory = ports.memoryStorage;
  const mcp = ports.mcpClient;
  if (credential === undefined || execution === undefined || memory === undefined || mcp === undefined) return false;
  return credential !== execution && credential !== memory && credential !== mcp &&
    execution !== memory && execution !== mcp && memory !== mcp;
}

/**
 * Opens all production resources before exposing the sole AgentRuntimeFacade.
 * Any failed open or factory call closes every attempted resource in reverse.
 */
export async function createSingleAgentHostRuntime(version: string,
  ports: SingleAgentHostPorts): Promise<AgentRuntimeFacade> {
  if (version !== SINGLE_AGENT_HOST_COMPOSITION_VERSION || !distinctResources(ports) ||
    ports.credentialStore === undefined || ports.executionStorage === undefined ||
    ports.memoryStorage === undefined || ports.mcpClient === undefined || ports.runtimeFactory === undefined) {
    throw new SingleAgentHostError(SingleAgentHostErrorCode.INVALID_CONFIGURATION,
      'Single Agent host composition is invalid');
  }
  const stack: HostResourceStack = new HostResourceStack();
  try {
    await stack.open(ports.credentialStore);
    await stack.open(ports.executionStorage);
    await stack.open(ports.memoryStorage);
    await stack.open(ports.mcpClient);
  } catch (error) {
    const rolledBack: boolean = await stack.closeAll();
    throw new SingleAgentHostError(rolledBack ? SingleAgentHostErrorCode.RESOURCE_OPEN_FAILED :
      SingleAgentHostErrorCode.RESOURCE_ROLLBACK_FAILED,
    rolledBack ? 'Single Agent host resource open failed' : 'Single Agent host resource rollback failed');
  }
  try {
    const runtime: AgentRuntimeFacade = await ports.runtimeFactory.create();
    return new HostedAgentRuntimeFacade(runtime, stack);
  } catch (error) {
    const rolledBack: boolean = await stack.closeAll();
    throw new SingleAgentHostError(rolledBack ? SingleAgentHostErrorCode.RUNTIME_FACTORY_FAILED :
      SingleAgentHostErrorCode.RESOURCE_ROLLBACK_FAILED,
    rolledBack ? 'Single Agent Runtime factory failed' : 'Single Agent host resource rollback failed');
  }
}
