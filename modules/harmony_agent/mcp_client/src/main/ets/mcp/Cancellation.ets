import { McpCancellationSignal, McpCancellationSubscription } from './Types';

class CancellationSubscription implements McpCancellationSubscription {
  private readonly source?: McpCancellationSource;
  private readonly listener?: () => void;
  private disposed: boolean = false;

  constructor(source?: McpCancellationSource, listener?: () => void) {
    this.source = source;
    this.listener = listener;
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    if (this.source !== undefined && this.listener !== undefined) {
      this.source.remove(this.listener);
    }
  }
}

export class McpCancellationSource implements McpCancellationSignal {
  private cancelled: boolean = false;
  private listeners: (() => void)[] = [];

  isCancellationRequested(): boolean {
    return this.cancelled;
  }

  subscribe(listener: () => void): McpCancellationSubscription {
    if (this.cancelled) {
      listener();
      return new CancellationSubscription();
    }
    this.listeners.push(listener);
    return new CancellationSubscription(this, listener);
  }

  cancel(): void {
    if (this.cancelled) return;
    this.cancelled = true;
    const callbacks: (() => void)[] = this.listeners.slice();
    this.listeners = [];
    for (let index: number = 0; index < callbacks.length; index++) {
      try {
        callbacks[index]();
      } catch (_error) {
        // One observer cannot prevent the other HTTP requests from being cancelled.
      }
    }
  }

  remove(listener: () => void): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) this.listeners.splice(index, 1);
  }
}
