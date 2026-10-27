import util from '@ohos.util';
import { AgentErrorClass } from '@harmony_agent/agent-contracts';
import {
  ProviderCancellationSource, ProviderCredentialPort, ProviderErrorCode, ProviderOperationHandle,
  ProviderTransportError
} from '@harmony_agent/agent-connectors';
import {
  DeepSeekHttpClientPort, DeepSeekHttpRequest, DeepSeekHttpResponse
} from './DeepSeekProtocol';
import {
  buildVisionChatBody, parseVisionChatResponse, VisionChatRequest, VisionChatResult, VisionChatTransportPort,
  VISION_CHAT_MAX_RESPONSE_BYTES
} from './VisionChatProtocol';

function cancelledError(): ProviderTransportError {
  return new ProviderTransportError(ProviderErrorCode.CANCELLED, AgentErrorClass.CANCELLED,
    'Vision chat request cancelled', true);
}
function invalidRequest(): ProviderTransportError {
  return new ProviderTransportError(ProviderErrorCode.INVALID_REQUEST, AgentErrorClass.INVALID_INPUT,
    'Vision chat request is invalid');
}
function invalidCredential(): ProviderTransportError {
  return new ProviderTransportError(ProviderErrorCode.AUTHENTICATION, AgentErrorClass.AUTHENTICATION,
    'Vision chat requires one valid Bearer credential', true);
}

class VisionChatOperation implements ProviderOperationHandle<VisionChatResult> {
  readonly result: Promise<VisionChatResult>;
  private readonly request: VisionChatRequest;
  private readonly credentials: ProviderCredentialPort;
  private readonly http: DeepSeekHttpClientPort;
  private readonly cancellation: ProviderCancellationSource;
  private handle?: ProviderOperationHandle<DeepSeekHttpResponse>;
  private cancelled: boolean = false;

  constructor(request: VisionChatRequest, credentials: ProviderCredentialPort,
    http: DeepSeekHttpClientPort, cancellation: ProviderCancellationSource) {
    this.request = request; this.credentials = credentials; this.http = http; this.cancellation = cancellation;
    this.result = this.run();
  }

  cancel(): void {
    if (this.cancelled) { return; }
    this.cancelled = true; this.cancellation.cancel();
    const handle: ProviderOperationHandle<DeepSeekHttpResponse> | undefined = this.handle;
    if (handle !== undefined) { handle.cancel(); }
  }

  private async run(): Promise<VisionChatResult> {
    if (this.cancelled) { throw cancelledError(); }
    const base64: string = await new util.Base64Helper().encodeToString(this.request.image.bytes, util.Type.BASIC);
    if (this.cancelled) { throw cancelledError(); }
    const body: string | undefined = buildVisionChatBody(this.request, base64);
    if (body === undefined) { throw invalidRequest(); }
    const credential = await this.credentials.resolve('deepseek-direct', 'deepseek.invoke');
    if (this.cancelled) { throw cancelledError(); }
    if (Object.keys(credential.headers).length !== 1) { throw invalidCredential(); }
    const authorization: string = credential.headers.Authorization;
    if (typeof authorization !== 'string' || !/^Bearer [\x21-\x7e]+$/.test(authorization)) {
      throw invalidCredential();
    }
    const outgoing: DeepSeekHttpRequest = new DeepSeekHttpRequest();
    outgoing.authorization = authorization; outgoing.body = body;
    outgoing.connectTimeoutMs = 10000; outgoing.timeoutMs = this.request.timeoutMs;
    outgoing.maxResponseBytes = VISION_CHAT_MAX_RESPONSE_BYTES;
    const handle: ProviderOperationHandle<DeepSeekHttpResponse> = this.http.start(outgoing);
    this.handle = handle;
    const response: DeepSeekHttpResponse = await handle.result;
    if (this.cancelled) { throw cancelledError(); }
    return parseVisionChatResponse(response.statusCode, response.body, this.request.modelId);
  }
}

/** Session-key vision request; no persistent vision credential or filename is involved. */
export class ArkTsVisionChatTransport implements VisionChatTransportPort {
  private readonly http: DeepSeekHttpClientPort;
  private readonly credentials: ProviderCredentialPort;
  constructor(http: DeepSeekHttpClientPort, credentials: ProviderCredentialPort) {
    this.http = http; this.credentials = credentials;
  }
  start(request: VisionChatRequest, cancellation: ProviderCancellationSource): ProviderOperationHandle<VisionChatResult> {
    return new VisionChatOperation(request, this.credentials, this.http, cancellation);
  }
}
