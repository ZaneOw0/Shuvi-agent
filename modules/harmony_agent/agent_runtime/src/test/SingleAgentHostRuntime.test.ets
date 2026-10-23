import { describe, expect, it } from '@ohos/hypium';
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
  SINGLE_AGENT_HOST_COMPOSITION_VERSION,
  ShutdownMode,
  SingleAgentHostError,
  SingleAgentHostErrorCode,
  SingleAgentHostPorts,
  SingleAgentHostResourcePort,
  SingleAgentHostRuntimeFactoryPort,
  SubscriptionRequest,
  createSingleAgentHostRuntime
} from '../../Index';

class FixtureHostResource implements SingleAgentHostResourcePort {
  private readonly name: string;
  private readonly events: string[];
  failOpen: boolean = false;
  failClose: boolean = false;

  constructor(name: string, events: string[]) {
    this.name = name;
    this.events = events;
  }

  async open(): Promise<void> {
    this.events.push('open:' + this.name);
    if (this.failOpen) throw new Error('open failed');
  }

  async close(): Promise<void> {
    this.events.push('close:' + this.name);
    if (this.failClose) throw new Error('close failed');
  }
}

class TrackingHostFacade implements AgentRuntimeFacade {
  private readonly events: string[];
  failShutdown: boolean = false;
  shutdownCalls: number = 0;

  constructor(events: string[]) {
    this.events = events;
  }

  async submitTask(_submission: TaskSubmission): Promise<TaskHandle> {
    throw new Error('unused');
  }

  async getTaskSnapshot(_taskId: string): Promise<AgentTaskSnapshot> {
    throw new Error('unused');
  }

  async cancelTask(_command: TaskControlCommand): Promise<CommandReceipt> {
    throw new Error('unused');
  }

  async pauseTask(_command: TaskControlCommand): Promise<CommandReceipt> {
    throw new Error('unused');
  }

  async resumeTask(_command: TaskControlCommand): Promise<CommandReceipt> {
    throw new Error('unused');
  }

  async provideAuthorization(_decision: AuthorizationDecision): Promise<CommandReceipt> {
    throw new Error('unused');
  }

  async provideClarification(_response: ClarificationResponse): Promise<CommandReceipt> {
    throw new Error('unused');
  }

  async provideReconciliation(_report: ReconciliationReport): Promise<CommandReceipt> {
    throw new Error('unused');
  }

  async subscribe(_request: SubscriptionRequest, _observer: AgentRuntimeObserver): Promise<AgentSubscription> {
    throw new Error('unused');
  }

  async shutdown(mode: ShutdownMode): Promise<void> {
    this.shutdownCalls++;
    this.events.push('runtime:shutdown:' + mode);
    if (this.failShutdown) throw new Error('shutdown failed');
  }
}

class FixtureHostRuntimeFactory implements SingleAgentHostRuntimeFactoryPort {
  private readonly events: string[];
  readonly facade: TrackingHostFacade;
  fail: boolean = false;
  calls: number = 0;

  constructor(events: string[]) {
    this.events = events;
    this.facade = new TrackingHostFacade(events);
  }

  async create(): Promise<AgentRuntimeFacade> {
    this.calls++;
    this.events.push('runtime:create');
    if (this.fail) throw new Error('factory failed');
    return this.facade;
  }
}

class HostFixture {
  readonly events: string[] = [];
  readonly credential: FixtureHostResource = new FixtureHostResource('credential', this.events);
  readonly execution: FixtureHostResource = new FixtureHostResource('execution', this.events);
  readonly memory: FixtureHostResource = new FixtureHostResource('memory', this.events);
  readonly mcp: FixtureHostResource = new FixtureHostResource('mcp', this.events);
  readonly factory: FixtureHostRuntimeFactory = new FixtureHostRuntimeFactory(this.events);
  readonly ports: SingleAgentHostPorts = new SingleAgentHostPorts();

  constructor() {
    this.ports.credentialStore = this.credential;
    this.ports.executionStorage = this.execution;
    this.ports.memoryStorage = this.memory;
    this.ports.mcpClient = this.mcp;
    this.ports.runtimeFactory = this.factory;
  }
}

function errorCode(error: Error): SingleAgentHostErrorCode | undefined {
  return error instanceof SingleAgentHostError ? error.code : undefined;
}

export default function singleAgentHostRuntimeTest(): void {
  describe('SingleAgentHostRuntime', () => {
    it('opensInDependencyOrderAndClosesAfterFacadeShutdownInReverse', 0, async () => {
      const fixture: HostFixture = new HostFixture();
      const runtime: AgentRuntimeFacade = await createSingleAgentHostRuntime(
        SINGLE_AGENT_HOST_COMPOSITION_VERSION, fixture.ports);
      expect(JSON.stringify(fixture.events)).assertEqual(JSON.stringify([
        'open:credential', 'open:execution', 'open:memory', 'open:mcp', 'runtime:create'
      ]));

      await runtime.shutdown(ShutdownMode.GRACEFUL);

      expect(JSON.stringify(fixture.events)).assertEqual(JSON.stringify([
        'open:credential', 'open:execution', 'open:memory', 'open:mcp', 'runtime:create',
        'runtime:shutdown:graceful', 'close:mcp', 'close:memory', 'close:execution', 'close:credential'
      ]));
    });

    it('rollsBackTheFailedAndPreviouslyOpenedResourcesWithoutCreatingRuntime', 0, async () => {
      const fixture: HostFixture = new HostFixture();
      fixture.memory.failOpen = true;
      let code: SingleAgentHostErrorCode | undefined = undefined;
      try {
        await createSingleAgentHostRuntime(SINGLE_AGENT_HOST_COMPOSITION_VERSION, fixture.ports);
      } catch (error) {
        if (error instanceof Error) code = errorCode(error);
      }
      expect(code).assertEqual(SingleAgentHostErrorCode.RESOURCE_OPEN_FAILED);
      expect(fixture.factory.calls).assertEqual(0);
      expect(JSON.stringify(fixture.events)).assertEqual(JSON.stringify([
        'open:credential', 'open:execution', 'open:memory',
        'close:memory', 'close:execution', 'close:credential'
      ]));
    });

    it('rollsBackEveryResourceWhenRuntimeFactoryFails', 0, async () => {
      const fixture: HostFixture = new HostFixture();
      fixture.factory.fail = true;
      let code: SingleAgentHostErrorCode | undefined = undefined;
      try {
        await createSingleAgentHostRuntime(SINGLE_AGENT_HOST_COMPOSITION_VERSION, fixture.ports);
      } catch (error) {
        if (error instanceof Error) code = errorCode(error);
      }
      expect(code).assertEqual(SingleAgentHostErrorCode.RUNTIME_FACTORY_FAILED);
      expect(JSON.stringify(fixture.events)).assertEqual(JSON.stringify([
        'open:credential', 'open:execution', 'open:memory', 'open:mcp', 'runtime:create',
        'close:mcp', 'close:memory', 'close:execution', 'close:credential'
      ]));
    });

    it('attemptsEveryCloseAndReturnsStableFailureWhenShutdownFails', 0, async () => {
      const fixture: HostFixture = new HostFixture();
      fixture.factory.facade.failShutdown = true;
      fixture.memory.failClose = true;
      const runtime: AgentRuntimeFacade = await createSingleAgentHostRuntime(
        SINGLE_AGENT_HOST_COMPOSITION_VERSION, fixture.ports);
      let code: SingleAgentHostErrorCode | undefined = undefined;
      try {
        await runtime.shutdown(ShutdownMode.IMMEDIATE);
      } catch (error) {
        if (error instanceof Error) code = errorCode(error);
      }
      expect(code).assertEqual(SingleAgentHostErrorCode.HOST_SHUTDOWN_FAILED);
      expect(fixture.events.indexOf('close:mcp') >= 0).assertTrue();
      expect(fixture.events.indexOf('close:memory') >= 0).assertTrue();
      expect(fixture.events.indexOf('close:execution') >= 0).assertTrue();
      expect(fixture.events.indexOf('close:credential') >= 0).assertTrue();
    });

    it('rejectsMissingDuplicateOrWrongVersionConfigurationBeforeOpening', 0, async () => {
      const missing: HostFixture = new HostFixture();
      missing.ports.memoryStorage = undefined;
      let missingCode: SingleAgentHostErrorCode | undefined = undefined;
      try {
        await createSingleAgentHostRuntime(SINGLE_AGENT_HOST_COMPOSITION_VERSION, missing.ports);
      } catch (error) {
        if (error instanceof Error) missingCode = errorCode(error);
      }
      expect(missingCode).assertEqual(SingleAgentHostErrorCode.INVALID_CONFIGURATION);
      expect(missing.events.length).assertEqual(0);

      const duplicate: HostFixture = new HostFixture();
      duplicate.ports.memoryStorage = duplicate.execution;
      let duplicateCode: SingleAgentHostErrorCode | undefined = undefined;
      try {
        await createSingleAgentHostRuntime(SINGLE_AGENT_HOST_COMPOSITION_VERSION, duplicate.ports);
      } catch (error) {
        if (error instanceof Error) duplicateCode = errorCode(error);
      }
      expect(duplicateCode).assertEqual(SingleAgentHostErrorCode.INVALID_CONFIGURATION);
      expect(duplicate.events.length).assertEqual(0);

      const wrongVersion: HostFixture = new HostFixture();
      let versionCode: SingleAgentHostErrorCode | undefined = undefined;
      try {
        await createSingleAgentHostRuntime('2.0', wrongVersion.ports);
      } catch (error) {
        if (error instanceof Error) versionCode = errorCode(error);
      }
      expect(versionCode).assertEqual(SingleAgentHostErrorCode.INVALID_CONFIGURATION);
      expect(wrongVersion.events.length).assertEqual(0);
    });

    it('keepsShutdownIdempotentAfterSuccessfulClose', 0, async () => {
      const fixture: HostFixture = new HostFixture();
      const runtime: AgentRuntimeFacade = await createSingleAgentHostRuntime(
        SINGLE_AGENT_HOST_COMPOSITION_VERSION, fixture.ports);
      await runtime.shutdown(ShutdownMode.GRACEFUL);
      await runtime.shutdown(ShutdownMode.IMMEDIATE);
      expect(fixture.factory.facade.shutdownCalls).assertEqual(1);
      let closeCalls: number = 0;
      for (let index: number = 0; index < fixture.events.length; index++) {
        if (fixture.events[index].startsWith('close:')) closeCalls++;
      }
      expect(closeCalls).assertEqual(4);
    });
  });
}
