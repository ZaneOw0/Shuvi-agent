import {
  AgentFrontendAuthorizationPrompt, AgentFrontendClarificationPrompt, AgentFrontendCommandReceipt,
  AgentFrontendEvent, AgentFrontendEventListener, AgentFrontendSubscription,
  AgentFrontendTaskHandle, AgentFrontendTaskRequest, AgentFrontendTaskState
} from '@harmony_agent/agent-runtime';
import { ShuviRuntimeSessionFactory, ShuviRuntimeSessionPort } from './ShuviRuntimeSession';

export enum ShuviRuntimeState { IDLE, STARTING, READY, STOPPING, STOPPED, FAILED, BLOCKED }

class SessionEventListener implements AgentFrontendEventListener {
  private readonly active: () => boolean;
  private readonly listener: AgentFrontendEventListener;
  constructor(active: () => boolean, listener: AgentFrontendEventListener) {
    this.active = active; this.listener = listener;
  }
  onEvent(event: AgentFrontendEvent): void { if (this.active()) this.listener.onEvent(event); }
  onAuthorizationRequired(prompt: AgentFrontendAuthorizationPrompt): void {
    if (this.active()) this.listener.onAuthorizationRequired(prompt);
  }
  onClarificationRequired(prompt: AgentFrontendClarificationPrompt): void {
    if (this.active()) this.listener.onClarificationRequired(prompt);
  }
}

/** Ability-owned gate. Foreground notification alone never starts/restarts a session. */
export class ShuviRuntimeController {
  private state: ShuviRuntimeState = ShuviRuntimeState.IDLE;
  private foreground: boolean = false;
  private generation: number = 0;
  private session?: ShuviRuntimeSessionPort;
  private stopping?: Promise<void>;
  private subscriptions: AgentFrontendSubscription[] = [];
  private listener?: (state: ShuviRuntimeState) => void;
  lifecycleState(): ShuviRuntimeState { return this.state; }
  attach(listener: (state: ShuviRuntimeState) => void): void { this.listener = listener; this.publish(); }
  detach(): void { this.listener = undefined; }
  private publish(): void {
    try { this.listener?.(this.state); } catch (error) { /* View failures cannot interrupt cleanup. */ }
  }
  private setState(state: ShuviRuntimeState): void { this.state = state; this.publish(); }
  onForeground(): void { this.foreground = true; }
  onBackground(): Promise<void> { this.foreground = false; this.publish(); return this.stop(); }
  onDestroy(): Promise<void> { this.foreground = false; this.publish(); return this.stop(); }

  async start(factory: ShuviRuntimeSessionFactory, key: Uint8Array): Promise<void> {
    let owned: ShuviRuntimeSessionPort | undefined;
    try {
      if (!this.foreground || this.session !== undefined || this.state === ShuviRuntimeState.BLOCKED ||
        this.state === ShuviRuntimeState.STARTING || this.state === ShuviRuntimeState.READY ||
        this.state === ShuviRuntimeState.STOPPING) throw new Error('AGENT_SESSION_START_NOT_ALLOWED');
      this.setState(ShuviRuntimeState.STARTING);
      const generation: number = ++this.generation;
      try { owned = factory.create(); } catch (error) {
        this.setState(ShuviRuntimeState.FAILED);
        throw new Error('AGENT_SESSION_CONFIGURATION_FAILED');
      }
      this.session = owned;
      try { await owned.start(key); } catch (error) {
        if (generation === this.generation) {
          try { await this.stop(); } catch (stopError) { throw new Error('AGENT_SESSION_SHUTDOWN_FAILED'); }
          if (this.generation === generation + 1 && this.session === undefined) this.setState(ShuviRuntimeState.FAILED);
        }
        throw new Error('AGENT_SESSION_START_FAILED');
      }
      if (generation !== this.generation || !this.foreground) throw new Error('AGENT_SESSION_START_INTERRUPTED');
      this.setState(ShuviRuntimeState.READY);
    } finally { key.fill(0); }
  }

  stop(): Promise<void> {
    if (this.stopping !== undefined) return this.stopping;
    if (this.session === undefined) return Promise.resolve();
    this.setState(ShuviRuntimeState.STOPPING);
    ++this.generation;
    let failed: boolean = false;
    for (let i: number = 0; i < this.subscriptions.length; i++) {
      try { this.subscriptions[i].close(); } catch (error) { failed = true; }
    }
    this.subscriptions = [];
    this.stopping = this.stopOwned(this.session, failed);
    return this.stopping;
  }

  private async stopOwned(session: ShuviRuntimeSessionPort, subscriptionFailure: boolean): Promise<void> {
    let failed: boolean = subscriptionFailure;
    try { await session.stop(); } catch (error) { failed = true; }
    if (failed) {
      this.setState(ShuviRuntimeState.BLOCKED);
      throw new Error('AGENT_SESSION_SHUTDOWN_FAILED');
    }
    this.session = undefined;
    this.setState(ShuviRuntimeState.STOPPED);
    this.stopping = undefined;
  }

  private current(): ShuviRuntimeSessionPort {
    if (!this.foreground || this.state !== ShuviRuntimeState.READY || this.session === undefined) {
      throw new Error('AGENT_SESSION_NOT_READY');
    }
    return this.session;
  }
  private active(generation: number): boolean {
    return this.foreground && this.generation === generation && this.state === ShuviRuntimeState.READY;
  }
  private checkResult(generation: number): void {
    if (!this.active(generation)) throw new Error('AGENT_SESSION_RESULT_DISCARDED');
  }
  async submit(request: AgentFrontendTaskRequest): Promise<AgentFrontendTaskHandle> {
    const session = this.current(); const generation = this.generation;
    const result = await session.submit(request); this.checkResult(generation); return result;
  }
  async authorize(prompt: AgentFrontendAuthorizationPrompt, approved: boolean): Promise<AgentFrontendCommandReceipt> {
    const session = this.current(); const generation = this.generation;
    const result = await session.authorize(prompt, approved); this.checkResult(generation); return result;
  }
  async cancel(taskId: string): Promise<AgentFrontendCommandReceipt> {
    const session = this.current(); const generation = this.generation;
    const result = await session.cancel(taskId); this.checkResult(generation); return result;
  }
  async getTask(taskId: string): Promise<AgentFrontendTaskState> {
    const session = this.current(); const generation = this.generation;
    const result = await session.getTask(taskId); this.checkResult(generation); return result;
  }
  async subscribe(taskId: string, listener: AgentFrontendEventListener,
    afterSequence: number = 0): Promise<AgentFrontendSubscription> {
    const session = this.current(); const generation = this.generation;
    const guarded = new SessionEventListener((): boolean => this.active(generation), listener);
    const subscription = await session.subscribe(taskId, guarded, afterSequence);
    if (!this.active(generation)) {
      subscription.close();
      throw new Error('AGENT_SESSION_RESULT_DISCARDED');
    }
    this.subscriptions = this.subscriptions.filter((item: AgentFrontendSubscription): boolean => !item.isClosed());
    this.subscriptions.push(subscription);
    return subscription;
  }
}
