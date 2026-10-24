export enum McpProbeState {
  Idle = 'idle',
  Checking = 'checking',
  Stopping = 'stopping',
  Connected = 'connected',
  Failed = 'failed',
  Cancelled = 'cancelled'
}

export class McpProbeResult {
  state: McpProbeState = McpProbeState.Idle;
  message: string = '仅检查连接和工具发现，不执行搜索。';
  protocolVersion: string = '';
}

// This boundary deliberately has no tool invocation method.
export interface McpProbeTransport {
  connect(): Promise<string>;
  discover(): Promise<void>;
  interrupt(): Promise<void>;
  close(): Promise<void>;
}

export interface McpProbeFactory {
  create(): McpProbeTransport;
}

export type McpProbeListener = (result: McpProbeResult) => void;

export class McpProbeSession {
  private readonly factory: McpProbeFactory;
  private readonly enabled: boolean;
  private readonly timeoutMs: number;
  private transport?: McpProbeTransport;
  private listener?: McpProbeListener;
  private result: McpProbeResult = new McpProbeResult();
  private running: boolean = false;
  private stopped: boolean = false;
  private timedOut: boolean = false;
  private interruption?: Promise<void>;
  private interruptFailed: boolean = false;
  private cleaning: boolean = false;

  constructor(factory: McpProbeFactory, enabled: boolean, timeoutMs: number = 15000) {
    this.factory = factory;
    this.enabled = enabled;
    this.timeoutMs = timeoutMs;
  }

  attach(listener: McpProbeListener): void {
    this.listener = listener;
    listener(this.result);
  }

  detach(): void {
    this.listener = undefined;
    this.cancel();
  }

  cancel(): void {
    if (!this.running || this.stopped) return;
    this.stopped = true;
    this.publish(McpProbeState.Stopping, this.timedOut ? '连接检查超时，正在释放连接…' : '正在停止并释放连接…');
    const transport = this.transport;
    if (transport !== undefined && !this.cleaning) {
      this.interruption = transport.interrupt().catch(() => {
        this.interruptFailed = true;
      });
    }
  }

  async run(): Promise<void> {
    if (this.running) return;
    if (!this.enabled) {
      this.publish(McpProbeState.Failed, '正式版本不提供本机连接检查。');
      return;
    }
    this.running = true;
    this.stopped = false;
    this.timedOut = false;
    this.interruptFailed = false;
    this.cleaning = false;
    this.interruption = undefined;
    this.publish(McpProbeState.Checking, '正在连接搜索服务并检查工具…');
    const timer: number = setTimeout(() => {
      this.timedOut = true;
      this.cancel();
    }, this.timeoutMs);
    let protocol: string = '';
    let failure: string = '';
    let cleanupFailed: boolean = false;
    try {
      const transport: McpProbeTransport = this.factory.create();
      this.transport = transport;
      protocol = await transport.connect();
      if (!this.stopped) await transport.discover();
    } catch (error) {
      // The transport exposes only sanitized messages, never remote payloads or credentials.
      failure = error instanceof Error ? error.message : '连接检查失败（INTERNAL）。';
    } finally {
      this.cleaning = true;
      clearTimeout(timer);
      const interruption = this.interruption;
      if (interruption !== undefined) await interruption;
      const transport = this.transport;
      if (transport !== undefined) {
        try {
          // Repeat cleanup after an interrupted operation settles: a late handshake may have
          // created a session after the first disconnect captured the old session ID.
          await transport.close();
        } catch (_error) {
          cleanupFailed = true;
        }
      }
      this.transport = undefined;
      this.running = false;
      this.cleaning = false;
    }
    if (cleanupFailed || this.interruptFailed) {
      this.publish(McpProbeState.Failed, '连接释放未完成（CLEANUP），请检查服务状态后重试。');
    } else if (this.timedOut) {
      this.publish(McpProbeState.Failed, '连接检查超时（TIMEOUT），请检查服务与 HDC 转发。');
    } else if (this.stopped) {
      this.publish(McpProbeState.Cancelled, '已停止连接检查。');
    } else if (failure.length > 0) {
      this.publish(McpProbeState.Failed, failure);
    } else {
      this.publish(McpProbeState.Connected, '已连接搜索服务，发现 web_search。检查已结束。', protocol);
    }
  }

  private publish(state: McpProbeState, message: string, protocol: string = ''): void {
    const next: McpProbeResult = new McpProbeResult();
    next.state = state;
    next.message = message;
    next.protocolVersion = protocol;
    this.result = next;
    const listener = this.listener;
    if (listener !== undefined) listener(next);
  }
}
