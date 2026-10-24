import { AgentErrorClass } from '@harmony_agent/agent-contracts';
import { ProviderErrorCode, ProviderOperationHandle, ProviderTransportError } from '@harmony_agent/agent-connectors';
import { DeepSeekHttpClientPort, DeepSeekHttpRequest, DeepSeekHttpResponse } from './DeepSeekProtocol';

function sessionCancelled(operationStarted: boolean = false): ProviderTransportError {
  return new ProviderTransportError(ProviderErrorCode.CANCELLED, AgentErrorClass.CANCELLED,
    'Model session is stopped', operationStarted);
}

class OwnedModelRequest implements ProviderOperationHandle<DeepSeekHttpResponse> {
  readonly result: Promise<DeepSeekHttpResponse>;
  private settled: boolean = false;
  private rejectResult: (error: ProviderTransportError) => void = (): void => {};
  private readonly delegate: ProviderOperationHandle<DeepSeekHttpResponse>;
  private readonly finished: (handle: OwnedModelRequest) => void;
  constructor(delegate: ProviderOperationHandle<DeepSeekHttpResponse>, finished: (handle: OwnedModelRequest) => void) {
    this.delegate = delegate; this.finished = finished;
    this.result = new Promise<DeepSeekHttpResponse>((resolve, reject): void => {
      this.rejectResult = reject;
      delegate.result.then((response: DeepSeekHttpResponse): void => {
        if (this.settled) return;
        this.settled = true; this.finished(this); resolve(response);
      }, (error: Error): void => {
        if (this.settled) return;
        this.settled = true; this.finished(this); reject(error);
      });
    });
  }
  cancel(): void {
    if (this.settled) return;
    this.settled = true;
    this.finished(this);
    this.rejectResult(sessionCancelled(true));
    // Reject the owned operation even when an underlying implementation cannot finish cancellation promptly.
    this.delegate.cancel();
  }
}

/** One session owns every HTTP handle; a stopped session can never be reopened. */
export class SessionModelHttpClient implements DeepSeekHttpClientPort {
  private stopped: boolean = false;
  private readonly delegate: DeepSeekHttpClientPort;
  private handles: ProviderOperationHandle<DeepSeekHttpResponse>[] = [];
  constructor(delegate: DeepSeekHttpClientPort) { this.delegate = delegate; }

  start(request: DeepSeekHttpRequest): ProviderOperationHandle<DeepSeekHttpResponse> {
    if (this.stopped) throw sessionCancelled();
    const handle = new OwnedModelRequest(this.delegate.start(request),
      (finished: OwnedModelRequest): void => this.remove(finished));
    this.handles.push(handle);
    return handle;
  }

  stop(): void {
    if (this.stopped) return;
    this.stopped = true;
    const handles = this.handles;
    this.handles = [];
    let failed: boolean = false;
    for (let i: number = 0; i < handles.length; i++) {
      try { handles[i].cancel(); } catch (error) { failed = true; }
    }
    if (failed) throw new Error('MODEL_SESSION_CANCEL_FAILED');
  }

  private remove(handle: ProviderOperationHandle<DeepSeekHttpResponse>): void {
    this.handles = this.handles.filter((item: ProviderOperationHandle<DeepSeekHttpResponse>): boolean => item !== handle);
  }
}
