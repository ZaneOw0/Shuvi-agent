import {
  ArtifactRegistryEntry,
  copyArtifactRegistryEntry
} from './ArtifactRegistryTypes';
import {
  ArtifactBaselinePolicyPort,
  ArtifactPolicyCancellationSignalPort,
  ArtifactPolicyCancellationSubscriptionPort,
  ArtifactPolicyDecision,
  ArtifactPolicyRequest,
  ArtifactReleasedPolicyPort,
  copyArtifactPolicyDecision,
  copyArtifactPolicyRequest
} from './ArtifactPolicyReleaseTypes';

/** One concrete process, worker, IPC or network policy attempt. */
export interface ArtifactPolicyResourceOperationPort {
  result(): Promise<ArtifactPolicyDecision>;
  cancel(): void;
  close(): void;
}

export interface ArtifactBaselinePolicyLoaderPort {
  load(request: ArtifactPolicyRequest): ArtifactPolicyResourceOperationPort;
}

export interface ArtifactReleasedPolicyLoaderPort {
  load(artifact: ArtifactRegistryEntry,
    request: ArtifactPolicyRequest): ArtifactPolicyResourceOperationPort;
}

function cancellationRequested(signal: ArtifactPolicyCancellationSignalPort | undefined): boolean {
  if (signal === undefined) return false;
  try {
    return signal.isCancellationRequested();
  } catch (error) {
    return true;
  }
}

class ManagedPolicyAttempt {
  private readonly operation: ArtifactPolicyResourceOperationPort;
  private subscription?: ArtifactPolicyCancellationSubscriptionPort;
  private stopped: boolean = false;
  private cancelled: boolean = false;

  constructor(operation: ArtifactPolicyResourceOperationPort) {
    this.operation = operation;
  }

  bind(signal: ArtifactPolicyCancellationSignalPort | undefined): void {
    if (signal === undefined) return;
    let current: ArtifactPolicyCancellationSubscriptionPort;
    try {
      current = signal.subscribe((): void => {
        this.stop(true);
      });
    } catch (error) {
      this.stop(true);
      throw new Error('policy cancellation subscription failed');
    }
    if (this.stopped) {
      try {
        current.dispose();
      } catch (error) {
      }
      return;
    }
    this.subscription = current;
    if (cancellationRequested(signal)) this.stop(true);
  }

  async wait(): Promise<ArtifactPolicyDecision> {
    if (this.cancelled) throw new Error('policy operation cancelled');
    let pending: Promise<ArtifactPolicyDecision>;
    try {
      pending = this.operation.result();
    } catch (error) {
      this.stop(true);
      throw new Error('policy operation failed to start');
    }
    try {
      const decision: ArtifactPolicyDecision = await pending;
      if (this.cancelled) throw new Error('policy operation cancelled');
      if (!this.stop(false)) throw new Error('policy operation cleanup failed');
      return copyArtifactPolicyDecision(decision);
    } catch (error) {
      this.stop(true);
      throw new Error('policy operation failed');
    }
  }

  private stop(cancel: boolean): boolean {
    if (this.stopped) return !this.cancelled;
    this.stopped = true;
    this.cancelled = cancel;
    if (cancel) {
      try {
        this.operation.cancel();
      } catch (error) {
      }
    }
    try {
      this.operation.close();
    } catch (error) {
      this.cancelled = true;
      try {
        this.operation.cancel();
      } catch (cancelError) {
      }
    }
    const current: ArtifactPolicyCancellationSubscriptionPort | undefined = this.subscription;
    this.subscription = undefined;
    if (current !== undefined) {
      try {
        current.dispose();
      } catch (error) {
        this.cancelled = true;
      }
    }
    return !this.cancelled;
  }
}

async function execute(operation: ArtifactPolicyResourceOperationPort,
  cancellation?: ArtifactPolicyCancellationSignalPort): Promise<ArtifactPolicyDecision> {
  const attempt: ManagedPolicyAttempt = new ManagedPolicyAttempt(operation);
  attempt.bind(cancellation);
  return await attempt.wait();
}

/** Adapts a resource-owning baseline loader to the release runner. */
export class ManagedArtifactBaselinePolicy implements ArtifactBaselinePolicyPort {
  private readonly loader: ArtifactBaselinePolicyLoaderPort;

  constructor(loader: ArtifactBaselinePolicyLoaderPort) {
    this.loader = loader;
  }

  async decide(request: ArtifactPolicyRequest,
    cancellation?: ArtifactPolicyCancellationSignalPort): Promise<ArtifactPolicyDecision> {
    if (cancellationRequested(cancellation)) throw new Error('policy operation cancelled');
    let operation: ArtifactPolicyResourceOperationPort;
    try {
      operation = this.loader.load(copyArtifactPolicyRequest(request));
    } catch (error) {
      throw new Error('baseline policy loader failed');
    }
    return await execute(operation, cancellation);
  }
}

/** Adapts a resource-owning artifact loader to shadow/canary/active execution. */
export class ManagedArtifactReleasedPolicy implements ArtifactReleasedPolicyPort {
  private readonly loader: ArtifactReleasedPolicyLoaderPort;

  constructor(loader: ArtifactReleasedPolicyLoaderPort) {
    this.loader = loader;
  }

  async decide(artifact: ArtifactRegistryEntry, request: ArtifactPolicyRequest,
    cancellation?: ArtifactPolicyCancellationSignalPort): Promise<ArtifactPolicyDecision> {
    if (cancellationRequested(cancellation)) throw new Error('policy operation cancelled');
    let operation: ArtifactPolicyResourceOperationPort;
    try {
      operation = this.loader.load(copyArtifactRegistryEntry(artifact), copyArtifactPolicyRequest(request));
    } catch (error) {
      throw new Error('released policy loader failed');
    }
    return await execute(operation, cancellation);
  }
}
