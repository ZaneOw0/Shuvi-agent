import { AgentErrorClass } from '@harmony_agent/agent-contracts';
import {
  ProviderCancellationSignalPort,
  ProviderCancellationSubscriptionPort,
  ProviderCredential,
  ProviderCredentialPort,
  ProviderErrorCode,
  ProviderOperationHandle,
  ProviderRequestContext,
  ProviderTimerHandlePort,
  ProviderTimerPort,
  ProviderTransportError
} from './ProviderContracts';

export interface ProviderOperationFactory<T> {
  start(credential: ProviderCredential): ProviderOperationHandle<T>;
}

function cancelledError(operationStarted: boolean = false): ProviderTransportError {
  return new ProviderTransportError(ProviderErrorCode.CANCELLED, AgentErrorClass.CANCELLED,
    'Provider operation cancelled', operationStarted);
}

function timeoutError(): ProviderTransportError {
  return new ProviderTransportError(ProviderErrorCode.TIMEOUT, AgentErrorClass.TIMEOUT,
    'Provider operation timed out', true);
}

function normalize(error: Object, operationStarted: boolean = false): ProviderTransportError {
  if (error instanceof ProviderTransportError) {
    return new ProviderTransportError(error.code, error.errorClass, error.message,
      error.operationStarted || operationStarted);
  }
  return new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.PROVIDER,
    error instanceof Error ? error.message : String(error), operationStarted);
}

export class ProviderOperationRunner {
  private readonly credentials: ProviderCredentialPort;
  private readonly timer: ProviderTimerPort;

  constructor(credentials: ProviderCredentialPort, timer: ProviderTimerPort) {
    this.credentials = credentials;
    this.timer = timer;
  }

  async run<T>(context: ProviderRequestContext, cancellation: ProviderCancellationSignalPort,
    factory: ProviderOperationFactory<T>): Promise<T> {
    if (context.providerId.trim().length === 0 || context.credentialScope.trim().length === 0 ||
      !Number.isSafeInteger(context.timeoutMs) || context.timeoutMs <= 0) {
      throw new ProviderTransportError(ProviderErrorCode.CONFIGURATION, AgentErrorClass.CONFIGURATION,
        'Provider request context is invalid');
    }
    if (cancellation.isCancellationRequested()) throw cancelledError();
    let credential: ProviderCredential;
    try {
      credential = await this.credentials.resolve(context.providerId, context.credentialScope);
    } catch (error) {
      throw new ProviderTransportError(ProviderErrorCode.AUTHENTICATION, AgentErrorClass.AUTHENTICATION,
        'Credential resolution failed');
    }
    if (cancellation.isCancellationRequested()) throw cancelledError();
    return await this.execute(context, cancellation, factory, credential);
  }

  private execute<T>(context: ProviderRequestContext, cancellation: ProviderCancellationSignalPort,
    factory: ProviderOperationFactory<T>, credential: ProviderCredential): Promise<T> {
    return new Promise<T>((resolve: (value: T) => void, reject: (reason: Object) => void): void => {
      let settled: boolean = false;
      let cancellationRequested: boolean = false;
      let operation: ProviderOperationHandle<T> | undefined = undefined;
      let timerHandle: ProviderTimerHandlePort | undefined = undefined;
      let subscription: ProviderCancellationSubscriptionPort | undefined = undefined;

      const cleanup = (): void => {
        const timer: ProviderTimerHandlePort | undefined = timerHandle;
        const observer: ProviderCancellationSubscriptionPort | undefined = subscription;
        if (timer !== undefined) {
          try {
            timer.cancel();
          } catch (error) {
            // Cleanup is best effort; one faulty hook cannot suppress the original result.
          }
        }
        if (observer !== undefined) {
          try {
            observer.dispose();
          } catch (error) {
            // Cleanup is best effort; one faulty hook cannot suppress the original result.
          }
        }
      };
      const fail = (error: ProviderTransportError, cancelOperation: boolean): void => {
        if (settled) return;
        settled = true;
        const active: ProviderOperationHandle<T> | undefined = operation;
        if (cancelOperation && active !== undefined) {
          try {
            active.cancel();
          } catch (cancelError) {
            // Preserve the cancellation/timeout error even if transport cleanup reports a failure.
          }
        }
        cleanup();
        reject(error);
      };
      const cancel = (): void => {
        cancellationRequested = true;
        fail(cancelledError(operation !== undefined), true);
      };

      subscription = cancellation.subscribe(cancel);
      if (cancellationRequested || cancellation.isCancellationRequested()) {
        fail(cancelledError(), true);
        return;
      }
      try {
        operation = factory.start(credential);
      } catch (error) {
        fail(normalize(error), false);
        return;
      }
      if (cancellationRequested || cancellation.isCancellationRequested()) {
        fail(cancelledError(true), true);
        return;
      }
      try {
        timerHandle = this.timer.schedule(context.timeoutMs, (): void => {
          fail(timeoutError(), true);
        });
      } catch (error) {
        fail(normalize(error, true), true);
        return;
      }
      operation.result.then((value: T): void => {
        if (settled) return;
        settled = true;
        cleanup();
        resolve(value);
      }).catch((error: Object): void => {
        fail(normalize(error, true), false);
      });
    });
  }
}
