import {
  ArtifactPolicyCancellationSignalPort,
  ArtifactPolicyCancellationSubscriptionPort,
  ArtifactPolicyTimerHandlePort,
  ArtifactPolicyTimerPort
} from './ArtifactPolicyReleaseTypes';

class ArtifactPolicyCancellationSubscription implements ArtifactPolicyCancellationSubscriptionPort {
  private readonly source?: ArtifactPolicyCancellationSource;
  private readonly listener?: () => void;
  private disposed: boolean = false;

  constructor(source?: ArtifactPolicyCancellationSource, listener?: () => void) {
    this.source = source;
    this.listener = listener;
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    const source: ArtifactPolicyCancellationSource | undefined = this.source;
    const listener: (() => void) | undefined = this.listener;
    if (source !== undefined && listener !== undefined) source.remove(listener);
  }
}

export class ArtifactPolicyCancellationSource implements ArtifactPolicyCancellationSignalPort {
  private cancelled: boolean = false;
  private listeners: (() => void)[] = [];

  isCancellationRequested(): boolean {
    return this.cancelled;
  }

  subscribe(listener: () => void): ArtifactPolicyCancellationSubscriptionPort {
    if (this.cancelled) {
      listener();
      return new ArtifactPolicyCancellationSubscription();
    }
    this.listeners.push(listener);
    return new ArtifactPolicyCancellationSubscription(this, listener);
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
        // One observer cannot prevent another policy resource from being released.
      }
    }
  }

  remove(listener: () => void): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) this.listeners.splice(index, 1);
  }
}

class SystemArtifactPolicyTimerHandle implements ArtifactPolicyTimerHandlePort {
  private readonly timerId: number;
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

export class SystemArtifactPolicyTimer implements ArtifactPolicyTimerPort {
  schedule(delayMs: number, action: () => void): ArtifactPolicyTimerHandlePort {
    const timerId: number = setTimeout(action, delayMs);
    return new SystemArtifactPolicyTimerHandle(timerId);
  }
}
