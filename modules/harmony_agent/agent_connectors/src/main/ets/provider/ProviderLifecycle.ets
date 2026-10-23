import {
  ProviderCancellationSignalPort,
  ProviderCancellationSubscriptionPort,
  ProviderTimerHandlePort,
  ProviderTimerPort
} from './ProviderContracts';

class CancellationSubscription implements ProviderCancellationSubscriptionPort {
  private readonly source?: ProviderCancellationSource;
  private readonly listener?: () => void;
  private disposed: boolean = false;

  constructor(source?: ProviderCancellationSource, listener?: () => void) {
    this.source = source;
    this.listener = listener;
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    const source: ProviderCancellationSource | undefined = this.source;
    const listener: (() => void) | undefined = this.listener;
    if (source !== undefined && listener !== undefined) source.remove(listener);
  }
}

export class ProviderCancellationSource implements ProviderCancellationSignalPort {
  private cancelled: boolean = false;
  private listeners: (() => void)[] = [];

  isCancellationRequested(): boolean {
    return this.cancelled;
  }

  subscribe(listener: () => void): ProviderCancellationSubscriptionPort {
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
      } catch (error) {
        // One cancellation observer cannot prevent resource cleanup in another.
      }
    }
  }

  remove(listener: () => void): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) this.listeners.splice(index, 1);
  }
}

class SystemTimerHandle implements ProviderTimerHandlePort {
  private timerId: number;
  private active: boolean = true;

  constructor(timerId: number) {
    this.timerId = timerId;
  }

  cancel(): void {
    if (!this.active) return;
    this.active = false;
    clearTimeout(this.timerId);
  }
}

export class SystemProviderTimer implements ProviderTimerPort {
  schedule(delayMs: number, action: () => void): ProviderTimerHandlePort {
    const timerId: number = setTimeout(action, delayMs);
    return new SystemTimerHandle(timerId);
  }
}
