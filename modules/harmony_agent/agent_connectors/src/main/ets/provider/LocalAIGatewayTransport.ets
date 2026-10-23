import { AgentErrorClass, PrivacyClass } from '@harmony_agent/agent-contracts';
import http from '@ohos.net.http';
import util from '@ohos.util';
import {
  ModelInvocation,
  ModelTransportChunk,
  ModelTransportObserver,
  ModelTransportPort,
  ModelTransportResult,
  ProviderCredential,
  ProviderErrorCode,
  ProviderFinishReason,
  ProviderOperationHandle,
  ProviderTransportError,
  ProviderUsage
} from './ProviderContracts';
import { ModelProviderProfile } from './ProviderCatalog';

export class LocalAIGatewayTransportProfile {
  baseUrl: string = 'http://127.0.0.1:4000/v1';
  providerId: string = 'local-ai-gateway';
  registryModelId: string = 'model.local.gateway';
  publicModelAlias: string = 'aigw/default';
  modelVersion: string = '';
  region: string = 'local-windows';
  credentialScope: string = 'gateway.invoke';
  maxInputTokens: number = 0;
  maxOutputTokens: number = 0;
  qualityTier: number = 0;
  privacyClasses: PrivacyClass[] = [];
  connectTimeoutMs: number = 5000;
  maxRequestBytes: number = 1048576;
  maxResponseBytes: number = 8388608;
  available: boolean = false;
}

export class LocalAIGatewayHttpRequest {
  endpoint: string = '';
  headers: Record<string, string> = new Object() as Record<string, string>;
  body: string = '';
  connectTimeoutMs: number = 0;
  requestTimeoutMs: number = 0;
  maxResponseBytes: number = 0;
}

export class LocalAIGatewayHttpResponse {
  statusCode: number = 0;
  body: string = '';
}

export interface LocalAIGatewayHttpClientPort {
  start(request: LocalAIGatewayHttpRequest): ProviderOperationHandle<LocalAIGatewayHttpResponse>;
}

class GatewayChatMessagePayload {
  role: string = '';
  content: string = '';
}

class GatewayResponseFormatPayload {
  type: string = 'json_object';
}

class GatewayChatRequestPayload {
  model: string = '';
  messages: GatewayChatMessagePayload[] = [];
  max_tokens: number = 0;
  temperature: number = 0;
  stream: boolean = false;
  response_format?: GatewayResponseFormatPayload;
}

class GatewayResponseBuffer {
  private readonly limit: number;
  private readonly chunks: ArrayBuffer[] = [];
  private received: number = 0;

  constructor(limit: number) {
    this.limit = limit;
  }

  append(data: ArrayBuffer): void {
    if (this.received + data.byteLength > this.limit) {
      throw new ProviderTransportError(ProviderErrorCode.RESPONSE_TOO_LARGE, AgentErrorClass.PROVIDER,
        'Local AI Gateway response exceeded the configured limit', true);
    }
    this.received += data.byteLength;
    this.chunks.push(data);
  }

  decode(): string {
    const bytes: Uint8Array = new Uint8Array(this.received);
    let offset: number = 0;
    for (let index: number = 0; index < this.chunks.length; index++) {
      const part: Uint8Array = new Uint8Array(this.chunks[index]);
      bytes.set(part, offset);
      offset += part.byteLength;
    }
    try {
      return new util.TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decodeToString(bytes);
    } catch (error) {
      throw new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.SCHEMA_MISMATCH,
        'Local AI Gateway response is not valid UTF-8', true);
    }
  }
}

class ArkTsGatewayHttpOperation implements ProviderOperationHandle<LocalAIGatewayHttpResponse> {
  readonly result: Promise<LocalAIGatewayHttpResponse>;
  private readonly cancelAction: () => void;

  constructor(result: Promise<LocalAIGatewayHttpResponse>, cancelAction: () => void) {
    this.result = result;
    this.cancelAction = cancelAction;
  }

  cancel(): void {
    this.cancelAction();
  }
}

export class ArkTsLocalAIGatewayHttpClient implements LocalAIGatewayHttpClientPort {
  start(request: LocalAIGatewayHttpRequest): ProviderOperationHandle<LocalAIGatewayHttpResponse> {
    const httpRequest: http.HttpRequest = http.createHttp();
    let cancelAction: () => void = (): void => {};
    const result: Promise<LocalAIGatewayHttpResponse> =
      new Promise<LocalAIGatewayHttpResponse>((resolve, reject) => {
        const responseBuffer: GatewayResponseBuffer = new GatewayResponseBuffer(request.maxResponseBytes);
        let statusCode: number = 0;
        let streamEnded: boolean = false;
        let settled: boolean = false;

        const fail = (error: ProviderTransportError): void => {
          if (settled) return;
          settled = true;
          httpRequest.destroy();
          reject(error);
        };
        cancelAction = (): void => {
          fail(new ProviderTransportError(ProviderErrorCode.CANCELLED, AgentErrorClass.CANCELLED,
            'Local AI Gateway request cancelled', true));
        };
        const complete = (): void => {
          if (settled || statusCode === 0 || !streamEnded) return;
          try {
            const response: LocalAIGatewayHttpResponse = new LocalAIGatewayHttpResponse();
            response.statusCode = statusCode;
            response.body = responseBuffer.decode();
            settled = true;
            httpRequest.destroy();
            resolve(response);
          } catch (error) {
            if (error instanceof ProviderTransportError) {
              fail(error);
            } else {
              fail(new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.PROVIDER,
                'Unable to decode Local AI Gateway response', true));
            }
          }
        };

        httpRequest.on('dataReceive', (data: ArrayBuffer): void => {
          if (settled) return;
          try {
            responseBuffer.append(data);
          } catch (error) {
            if (error instanceof ProviderTransportError) fail(error);
          }
        });
        httpRequest.on('dataEnd', (): void => {
          streamEnded = true;
          complete();
        });
        const options: http.HttpRequestOptions = {
          method: http.RequestMethod.POST,
          header: request.headers,
          body: request.body,
          connectTimeout: request.connectTimeoutMs,
          readTimeout: request.requestTimeoutMs,
          usingCache: false,
          expectDataType: http.HttpDataType.ARRAY_BUFFER
        };
        httpRequest.requestInStream(request.endpoint, options).then((code: number): void => {
          statusCode = code;
          complete();
        }).catch((error: Error): void => {
          const message: string = error.message === undefined ? String(error) : error.message;
          const timedOut: boolean = message.indexOf('2300028') >= 0 ||
            message.toLowerCase().indexOf('timeout') >= 0;
          fail(new ProviderTransportError(timedOut ? ProviderErrorCode.TIMEOUT : ProviderErrorCode.NETWORK,
            timedOut ? AgentErrorClass.TIMEOUT : AgentErrorClass.NETWORK,
            timedOut ? 'Local AI Gateway request timed out' : 'Local AI Gateway network request failed', true));
        });
      });
    return new ArkTsGatewayHttpOperation(result, (): void => cancelAction());
  }
}

class MappedGatewayOperation implements ProviderOperationHandle<ModelTransportResult> {
  readonly result: Promise<ModelTransportResult>;
  private readonly source: ProviderOperationHandle<LocalAIGatewayHttpResponse>;

  constructor(source: ProviderOperationHandle<LocalAIGatewayHttpResponse>,
    mapper: (response: LocalAIGatewayHttpResponse) => ModelTransportResult) {
    this.source = source;
    this.result = source.result.then(mapper);
  }

  cancel(): void {
    this.source.cancel();
  }
}

function validText(value: string): boolean {
  return value.trim().length > 0;
}

function positiveInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

function loopbackBaseUrl(value: string): boolean {
  if (value.endsWith('/')) return false;
  const lower: string = value.toLowerCase();
  const ipv4Prefix: string = 'http://127.0.0.1:';
  const hostPrefix: string = 'http://localhost:';
  const suffix: string = '/v1';
  let prefix: string = '';
  if (lower.startsWith(ipv4Prefix)) {
    prefix = ipv4Prefix;
  } else if (lower.startsWith(hostPrefix)) {
    prefix = hostPrefix;
  } else {
    return false;
  }
  if (!lower.endsWith(suffix)) return false;
  const portText: string = lower.substring(prefix.length, lower.length - suffix.length);
  if (portText.length === 0) return false;
  for (let index: number = 0; index < portText.length; index++) {
    const character: string = portText.substring(index, index + 1);
    if (character < '0' || character > '9') return false;
  }
  const port: number = Number(portText);
  return Number.isSafeInteger(port) && port >= 1 && port <= 65535;
}

function copyProfile(source: LocalAIGatewayTransportProfile): LocalAIGatewayTransportProfile {
  const result: LocalAIGatewayTransportProfile = new LocalAIGatewayTransportProfile();
  result.baseUrl = source.baseUrl;
  result.providerId = source.providerId;
  result.registryModelId = source.registryModelId;
  result.publicModelAlias = source.publicModelAlias;
  result.modelVersion = source.modelVersion;
  result.region = source.region;
  result.credentialScope = source.credentialScope;
  result.maxInputTokens = source.maxInputTokens;
  result.maxOutputTokens = source.maxOutputTokens;
  result.qualityTier = source.qualityTier;
  result.privacyClasses = source.privacyClasses.slice();
  result.connectTimeoutMs = source.connectTimeoutMs;
  result.maxRequestBytes = source.maxRequestBytes;
  result.maxResponseBytes = source.maxResponseBytes;
  result.available = source.available;
  return result;
}

export class LocalAIGatewayTransportProfileValidator {
  static valid(profile: LocalAIGatewayTransportProfile): boolean {
    return loopbackBaseUrl(profile.baseUrl) && validText(profile.providerId) &&
      validText(profile.registryModelId) && profile.publicModelAlias.startsWith('aigw/') &&
      validText(profile.modelVersion) && validText(profile.region) && validText(profile.credentialScope) &&
      positiveInteger(profile.maxInputTokens) && positiveInteger(profile.maxOutputTokens) &&
      Number.isSafeInteger(profile.qualityTier) && profile.qualityTier >= 0 &&
      profile.privacyClasses.length > 0 && positiveInteger(profile.connectTimeoutMs) &&
      positiveInteger(profile.maxRequestBytes) && positiveInteger(profile.maxResponseBytes);
  }
}

export function createLocalAIGatewayModelProfile(
  source: LocalAIGatewayTransportProfile): ModelProviderProfile {
  if (!LocalAIGatewayTransportProfileValidator.valid(source)) {
    throw new ProviderTransportError(ProviderErrorCode.CONFIGURATION, AgentErrorClass.CONFIGURATION,
      'Local AI Gateway transport profile is invalid');
  }
  const result: ModelProviderProfile = new ModelProviderProfile();
  result.registryModelId = source.registryModelId;
  result.providerId = source.providerId;
  result.providerModelId = source.publicModelAlias;
  result.modelVersion = source.modelVersion;
  result.region = source.region;
  result.capabilityTags = ['chat', 'json', 'local-gateway'];
  result.privacyClasses = source.privacyClasses.slice();
  result.maxInputTokens = source.maxInputTokens;
  result.maxOutputTokens = source.maxOutputTokens;
  result.qualityTier = source.qualityTier;
  result.credentialScope = source.credentialScope;
  result.available = source.available;
  return result;
}

export class LocalAIGatewayModelTransport implements ModelTransportPort {
  private readonly profile: LocalAIGatewayTransportProfile;
  private readonly client: LocalAIGatewayHttpClientPort;

  constructor(profile: LocalAIGatewayTransportProfile, client: LocalAIGatewayHttpClientPort) {
    if (!LocalAIGatewayTransportProfileValidator.valid(profile)) {
      throw new ProviderTransportError(ProviderErrorCode.CONFIGURATION, AgentErrorClass.CONFIGURATION,
        'Local AI Gateway transport profile is invalid');
    }
    this.profile = copyProfile(profile);
    this.client = client;
  }

  start(request: ModelInvocation, credential: ProviderCredential,
    observer?: ModelTransportObserver): ProviderOperationHandle<ModelTransportResult> {
    if (request.modelId !== this.profile.publicModelAlias || request.modelVersion !== this.profile.modelVersion ||
      request.context.region !== this.profile.region) {
      throw new ProviderTransportError(ProviderErrorCode.INVALID_REQUEST, AgentErrorClass.INVALID_INPUT,
        'Model invocation does not match the Local AI Gateway profile');
    }
    const headers: Record<string, string> = this.authenticationHeaders(credential);
    headers['Content-Type'] = 'application/json';
    headers['Accept'] = 'application/json';
    const payload: GatewayChatRequestPayload = new GatewayChatRequestPayload();
    payload.model = this.profile.publicModelAlias;
    payload.max_tokens = request.maxOutputTokens;
    payload.temperature = request.temperature;
    for (let index: number = 0; index < request.messages.length; index++) {
      if (request.messages[index].role !== 'system' && request.messages[index].role !== 'user' &&
        request.messages[index].role !== 'assistant') {
        throw new ProviderTransportError(ProviderErrorCode.INVALID_REQUEST, AgentErrorClass.INVALID_INPUT,
          'Local AI Gateway chat transport supports system, user, and assistant messages');
      }
      const message: GatewayChatMessagePayload = new GatewayChatMessagePayload();
      message.role = request.messages[index].role;
      message.content = request.messages[index].content;
      payload.messages.push(message);
    }
    let schemaRecord: Record<string, Object>;
    try {
      const schema: Object = JSON.parse(request.responseSchemaJson) as Object;
      if (schema === null || Array.isArray(schema) || typeof schema !== 'object') throw new Error('not an object');
      schemaRecord = schema as Record<string, Object>;
    } catch (error) {
      throw new ProviderTransportError(ProviderErrorCode.INVALID_REQUEST, AgentErrorClass.INVALID_INPUT,
        'Local AI Gateway response schema is invalid');
    }
    const structured: boolean = Object.keys(schemaRecord).length > 0;
    if (structured) {
      // Chat Completions exposes portable JSON-object mode. The complete schema remains
      // authoritative in the planner validator after the response is parsed.
      payload.response_format = new GatewayResponseFormatPayload();
    }
    const body: string = JSON.stringify(payload);
    if (new util.TextEncoder('utf-8').encodeInto(body).byteLength > this.profile.maxRequestBytes) {
      throw new ProviderTransportError(ProviderErrorCode.INVALID_REQUEST, AgentErrorClass.INVALID_INPUT,
        'Local AI Gateway request exceeded the configured limit');
    }
    const httpRequest: LocalAIGatewayHttpRequest = new LocalAIGatewayHttpRequest();
    httpRequest.endpoint = this.profile.baseUrl + '/chat/completions';
    httpRequest.headers = headers;
    httpRequest.body = body;
    httpRequest.connectTimeoutMs = this.profile.connectTimeoutMs;
    httpRequest.requestTimeoutMs = request.context.timeoutMs;
    httpRequest.maxResponseBytes = this.profile.maxResponseBytes;
    const operation: ProviderOperationHandle<LocalAIGatewayHttpResponse> = this.client.start(httpRequest);
    return new MappedGatewayOperation(operation, (response: LocalAIGatewayHttpResponse): ModelTransportResult => {
      const result: ModelTransportResult = this.parseResponse(response, structured);
      const target: ModelTransportObserver | undefined = observer;
      if (target !== undefined && result.outputText.length > 0) {
        const chunk: ModelTransportChunk = new ModelTransportChunk();
        chunk.delta = result.outputText;
        target.onChunk(chunk);
      }
      return result;
    });
  }

  private authenticationHeaders(credential: ProviderCredential): Record<string, string> {
    const result: Record<string, string> = {};
    const keys: string[] = Object.keys(credential.headers);
    let authenticationCount: number = 0;
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      const lower: string = key.toLowerCase();
      const value: string = credential.headers[key];
      if (lower === 'authorization') {
        authenticationCount++;
        if (!value.startsWith('Bearer ') || value.substring('Bearer '.length).trim().length === 0) {
          throw new ProviderTransportError(ProviderErrorCode.AUTHENTICATION, AgentErrorClass.AUTHENTICATION,
            'Local AI Gateway bearer credential is invalid');
        }
        result['Authorization'] = value;
      } else if (lower === 'x-api-key') {
        authenticationCount++;
        if (!validText(value)) {
          throw new ProviderTransportError(ProviderErrorCode.AUTHENTICATION, AgentErrorClass.AUTHENTICATION,
            'Local AI Gateway API key credential is invalid');
        }
        result['x-api-key'] = value;
      } else {
        throw new ProviderTransportError(ProviderErrorCode.AUTHENTICATION, AgentErrorClass.AUTHENTICATION,
          'Local AI Gateway credential contains an unsupported header');
      }
    }
    if (authenticationCount !== 1) {
      throw new ProviderTransportError(ProviderErrorCode.AUTHENTICATION, AgentErrorClass.AUTHENTICATION,
        'Local AI Gateway requires exactly one authentication header');
    }
    return result;
  }

  private parseResponse(response: LocalAIGatewayHttpResponse, structured: boolean): ModelTransportResult {
    if (response.statusCode < 200 || response.statusCode >= 300) throw this.statusError(response.statusCode);
    let root: Record<string, Object>;
    try {
      const decoded: Object = JSON.parse(response.body) as Object;
      if (decoded === null || Array.isArray(decoded) || typeof decoded !== 'object') throw new Error('not an object');
      root = decoded as Record<string, Object>;
    } catch (error) {
      throw new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.SCHEMA_MISMATCH,
        'Local AI Gateway returned malformed JSON', true);
    }
    const choicesValue: Object | undefined = root['choices'];
    if (!Array.isArray(choicesValue) || choicesValue.length !== 1) {
      throw new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.SCHEMA_MISMATCH,
        'Local AI Gateway response must contain exactly one choice', true);
    }
    const choiceValue: Object = choicesValue[0];
    if (choiceValue === null || Array.isArray(choiceValue) || typeof choiceValue !== 'object') {
      throw new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.SCHEMA_MISMATCH,
        'Local AI Gateway response choice is invalid', true);
    }
    const choice: Record<string, Object> = choiceValue as Record<string, Object>;
    const messageValue: Object | undefined = choice['message'];
    if (messageValue === undefined || messageValue === null || Array.isArray(messageValue) ||
      typeof messageValue !== 'object') {
      throw new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.SCHEMA_MISMATCH,
        'Local AI Gateway response does not contain a message', true);
    }
    const message: Record<string, Object> = messageValue as Record<string, Object>;
    if (typeof message['content'] !== 'string') {
      throw new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.SCHEMA_MISMATCH,
        'Local AI Gateway response does not contain text content', true);
    }
    const outputText: string = message['content'] as string;
    if (structured) {
      try {
        const output: Object = JSON.parse(outputText) as Object;
        if (output === null || Array.isArray(output) || typeof output !== 'object') throw new Error('not an object');
      } catch (error) {
        throw new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.SCHEMA_MISMATCH,
          'Local AI Gateway structured output is not a JSON object', true);
      }
    }
    const result: ModelTransportResult = new ModelTransportResult();
    result.outputText = outputText;
    if (structured) result.outputJson = outputText;
    result.finishReason = this.finishReason(choice['finish_reason']);
    result.modelVersion = this.profile.modelVersion;
    result.region = this.profile.region;
    result.usage = this.usage(root['usage']);
    return result;
  }

  private finishReason(value: Object | undefined): ProviderFinishReason {
    if (value === 'stop') return ProviderFinishReason.STOP;
    if (value === 'length') return ProviderFinishReason.LENGTH;
    if (value === 'content_filter') return ProviderFinishReason.CONTENT_FILTER;
    throw new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.SCHEMA_MISMATCH,
      'Local AI Gateway returned an unsupported finish reason', true);
  }

  private usage(value: Object | undefined): ProviderUsage {
    if (value === undefined || value === null || Array.isArray(value) || typeof value !== 'object') {
      throw new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.SCHEMA_MISMATCH,
        'Local AI Gateway response is missing usage', true);
    }
    const source: Record<string, Object> = value as Record<string, Object>;
    const input: number = this.tokenCount(source['prompt_tokens']);
    const output: number = this.tokenCount(source['completion_tokens']);
    const total: number = this.tokenCount(source['total_tokens']);
    if (total !== input + output) {
      throw new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.SCHEMA_MISMATCH,
        'Local AI Gateway token totals are inconsistent', true);
    }
    const result: ProviderUsage = new ProviderUsage();
    result.inputTokens = input;
    result.outputTokens = output;
    result.totalTokens = total;
    result.providerReportedCostMicros = 0;
    return result;
  }

  private tokenCount(value: Object | undefined): number {
    if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
      throw new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.SCHEMA_MISMATCH,
        'Local AI Gateway token usage is invalid', true);
    }
    return value;
  }

  private statusError(statusCode: number): ProviderTransportError {
    if (statusCode === 401) {
      return new ProviderTransportError(ProviderErrorCode.AUTHENTICATION, AgentErrorClass.AUTHENTICATION,
        'Local AI Gateway rejected authentication', true);
    }
    if (statusCode === 403) {
      return new ProviderTransportError(ProviderErrorCode.FORBIDDEN, AgentErrorClass.PERMISSION_DENIED,
        'Local AI Gateway denied the request', true);
    }
    if (statusCode === 429) {
      return new ProviderTransportError(ProviderErrorCode.RATE_LIMITED, AgentErrorClass.PROVIDER,
        'Local AI Gateway rate limited the request', true);
    }
    if (statusCode >= 400 && statusCode < 500) {
      return new ProviderTransportError(ProviderErrorCode.INVALID_REQUEST, AgentErrorClass.INVALID_INPUT,
        'Local AI Gateway rejected the request', true);
    }
    return new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.PROVIDER,
      'Local AI Gateway returned an upstream failure', true);
  }
}
