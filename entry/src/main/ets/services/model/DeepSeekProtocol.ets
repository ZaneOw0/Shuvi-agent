import { AgentErrorClass, PrivacyClass } from '@harmony_agent/agent-contracts';
import {
  ModelInvocation, ModelProviderProfile, ModelTransportObserver, ModelTransportPort,
  ModelTransportResult, ProviderCredential, ProviderErrorCode, ProviderFinishReason,
  ProviderOperationHandle, ProviderTransportError
} from '@harmony_agent/agent-connectors';
import util from '@ohos.util';

export const DEEPSEEK_CHAT_ENDPOINT: string = 'https://api.deepseek.com/chat/completions';

// No model, version, price or availability is inferred from a local gateway alias.
export class DeepSeekProfile {
  modelId: string = '';
  modelVersion: string = '';
  region: string = '';
  maxInputTokens: number = 0;
  maxOutputTokens: number = 0;
  qualityTier: number = 0;
  privacyClasses: PrivacyClass[] = [];
  available: boolean = false;
  connectTimeoutMs: number = 10000;
  maxRequestBytes: number = 1048576;
  maxResponseBytes: number = 2097152;
}

export class DeepSeekHttpRequest {
  authorization: string = '';
  body: string = '';
  connectTimeoutMs: number = 0;
  timeoutMs: number = 0;
  maxResponseBytes: number = 0;
}

export class DeepSeekHttpResponse {
  statusCode: number = 0;
  body: string = '';
}

export interface DeepSeekHttpClientPort {
  start(request: DeepSeekHttpRequest): ProviderOperationHandle<DeepSeekHttpResponse>;
}

class ChatMessage {
  role: string = '';
  content: string = '';
}

class ThinkingMode { type: string = 'disabled'; }
class JsonFormat { type: string = 'json_object'; }
class ChatPayload {
  model: string = '';
  messages: ChatMessage[] = [];
  max_tokens: number = 0;
  temperature: number = 0;
  stream: boolean = false;
  thinking: ThinkingMode = new ThinkingMode();
  response_format?: JsonFormat;
}

// These are decoding shapes only. Every consumed field is checked at runtime.
class ResponseMessage {
  role?: string;
  content?: string;
  tool_calls?: Object;
}
class ResponseChoice {
  index?: number;
  message?: ResponseMessage;
  finish_reason?: string;
}
class ResponseUsage {
  prompt_tokens?: number;
  completion_tokens?: number;
  total_tokens?: number;
}
class ChatResponse {
  object?: string;
  model?: string;
  choices?: ResponseChoice[];
  usage?: ResponseUsage;
}

function objectValue(value: Object | undefined): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}

function positive(value: number, maximum: number): boolean {
  return Number.isSafeInteger(value) && value > 0 && value <= maximum;
}

function text(value: string): boolean {
  return typeof value === 'string' && value.trim().length > 0 && value === value.trim();
}

function invalidInput(): ProviderTransportError {
  return new ProviderTransportError(ProviderErrorCode.INVALID_REQUEST, AgentErrorClass.INVALID_INPUT,
    'DeepSeek request does not match the configured model');
}

function invalidResponse(): ProviderTransportError {
  return new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.SCHEMA_MISMATCH,
    'DeepSeek returned an invalid model response', true);
}

function jsonObject(value: string): Object {
  try {
    const decoded: Object = JSON.parse(value);
    if (!objectValue(decoded)) throw new Error('object required');
    return decoded;
  } catch (error) {
    throw invalidInput();
  }
}

export function createDeepSeekModelProfile(source: DeepSeekProfile): ModelProviderProfile {
  if (!text(source.modelId) || !/^[a-zA-Z0-9._-]{1,128}$/.test(source.modelId) ||
    !text(source.modelVersion) || !text(source.region) ||
    !positive(source.maxInputTokens, 10000000) || !positive(source.maxOutputTokens, 393216) ||
    !Number.isSafeInteger(source.qualityTier) || source.qualityTier < 0 ||
    source.privacyClasses.length === 0 ||
    !positive(source.connectTimeoutMs, 60000) || !positive(source.maxRequestBytes, 8388608) ||
    !positive(source.maxResponseBytes, 8388608)) {
    throw new ProviderTransportError(ProviderErrorCode.CONFIGURATION, AgentErrorClass.CONFIGURATION,
      'DeepSeek profile is incomplete or invalid');
  }
  const profile: ModelProviderProfile = new ModelProviderProfile();
  profile.registryModelId = 'model.deepseek.direct';
  profile.providerId = 'deepseek-direct';
  profile.providerModelId = source.modelId;
  profile.modelVersion = source.modelVersion;
  profile.region = source.region;
  profile.credentialScope = 'deepseek.invoke';
  profile.capabilityTags = ['chat', 'json'];
  profile.maxInputTokens = source.maxInputTokens;
  profile.maxOutputTokens = source.maxOutputTokens;
  profile.qualityTier = source.qualityTier;
  profile.privacyClasses = source.privacyClasses.slice();
  profile.available = source.available;
  return profile;
}

function statusFailure(status: number): ProviderTransportError {
  if (status === 401) return new ProviderTransportError(ProviderErrorCode.AUTHENTICATION,
    AgentErrorClass.AUTHENTICATION, 'DeepSeek authentication failed', true);
  if (status === 402) return new ProviderTransportError(ProviderErrorCode.PROVIDER,
    AgentErrorClass.PROVIDER, 'DeepSeek balance is insufficient (HTTP 402)', true);
  if (status === 403) return new ProviderTransportError(ProviderErrorCode.FORBIDDEN,
    AgentErrorClass.PERMISSION_DENIED, 'DeepSeek denied the request', true);
  if (status === 429) return new ProviderTransportError(ProviderErrorCode.RATE_LIMITED,
    AgentErrorClass.PROVIDER, 'DeepSeek rate limit reached', true);
  if (status >= 400 && status < 500) return new ProviderTransportError(ProviderErrorCode.INVALID_REQUEST,
    AgentErrorClass.INVALID_INPUT, 'DeepSeek rejected the request parameters', true);
  return new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.PROVIDER,
    'DeepSeek request failed', true);
}

class DeepSeekOperation implements ProviderOperationHandle<ModelTransportResult> {
  readonly result: Promise<ModelTransportResult>;
  private readonly source: ProviderOperationHandle<DeepSeekHttpResponse>;
  private cancelled: boolean = false;
  private settled: boolean = false;

  constructor(source: ProviderOperationHandle<DeepSeekHttpResponse>,
    mapper: (response: DeepSeekHttpResponse) => ModelTransportResult) {
    this.source = source;
    this.result = source.result.then((response: DeepSeekHttpResponse): ModelTransportResult => {
      if (this.cancelled) throw new ProviderTransportError(ProviderErrorCode.CANCELLED,
        AgentErrorClass.CANCELLED, 'DeepSeek request cancelled', true);
      return mapper(response);
    }).finally((): void => { this.settled = true; });
  }

  cancel(): void {
    if (this.cancelled || this.settled) return;
    this.cancelled = true;
    this.source.cancel();
  }
}

export class DeepSeekModelTransport implements ModelTransportPort {
  private readonly profile: ModelProviderProfile;
  private readonly client: DeepSeekHttpClientPort;
  private readonly connectTimeoutMs: number;
  private readonly maxRequestBytes: number;
  private readonly maxResponseBytes: number;

  constructor(profile: DeepSeekProfile, client: DeepSeekHttpClientPort) {
    this.profile = createDeepSeekModelProfile(profile);
    this.client = client;
    this.connectTimeoutMs = profile.connectTimeoutMs;
    this.maxRequestBytes = profile.maxRequestBytes;
    this.maxResponseBytes = profile.maxResponseBytes;
  }

  start(request: ModelInvocation, credential: ProviderCredential,
    _observer?: ModelTransportObserver): ProviderOperationHandle<ModelTransportResult> {
    if (!this.profile.available || request.modelId !== this.profile.providerModelId ||
      request.modelVersion !== this.profile.modelVersion || request.context.providerId !== this.profile.providerId ||
      request.context.region !== this.profile.region || request.context.credentialScope !== this.profile.credentialScope ||
      !positive(request.maxOutputTokens, this.profile.maxOutputTokens) ||
      !positive(request.context.timeoutMs, 180000) || !Number.isFinite(request.temperature) ||
      request.temperature < 0 || request.temperature > 2 || request.messages.length === 0 ||
      request.messages.length > 128) throw invalidInput();
    const payload: ChatPayload = new ChatPayload();
    payload.model = this.profile.providerModelId;
    payload.max_tokens = request.maxOutputTokens;
    payload.temperature = request.temperature;
    let mentionsJson: boolean = false;
    for (const source of request.messages) {
      if ((source.role !== 'system' && source.role !== 'user' && source.role !== 'assistant') ||
        typeof source.content !== 'string' || source.content.trim().length === 0) throw invalidInput();
      const message: ChatMessage = new ChatMessage();
      message.role = source.role;
      message.content = source.content;
      payload.messages.push(message);
      if ((message.role === 'system' || message.role === 'user') &&
        message.content.toLowerCase().includes('json')) mentionsJson = true;
    }
    const structured: boolean = Object.keys(jsonObject(request.responseSchemaJson)).length > 0;
    if (structured) {
      if (!mentionsJson) throw invalidInput();
      payload.response_format = new JsonFormat();
    }
    const body: string = JSON.stringify(payload);
    if (new util.TextEncoder('utf-8').encodeInto(body).byteLength > this.maxRequestBytes) throw invalidInput();
    // Only the existing credential port may supply the exact Bearer header; no extra headers are forwarded.
    const authorization: string = credential.headers.Authorization;
    if (Object.keys(credential.headers).length !== 1 || typeof authorization !== 'string' ||
      !/^Bearer [\x21-\x7e]+$/.test(authorization)) {
      throw new ProviderTransportError(ProviderErrorCode.AUTHENTICATION, AgentErrorClass.AUTHENTICATION,
        'DeepSeek requires one valid Bearer credential');
    }
    const outgoing: DeepSeekHttpRequest = new DeepSeekHttpRequest();
    outgoing.authorization = authorization;
    outgoing.body = body;
    outgoing.connectTimeoutMs = Math.min(this.connectTimeoutMs, request.context.timeoutMs);
    outgoing.timeoutMs = request.context.timeoutMs;
    outgoing.maxResponseBytes = this.maxResponseBytes;
    return new DeepSeekOperation(this.client.start(outgoing), (response: DeepSeekHttpResponse): ModelTransportResult => {
      const result: ModelTransportResult = parseDeepSeekResponse(response, this.profile.providerModelId,
        structured, this.maxResponseBytes);
      result.modelVersion = this.profile.modelVersion;
      result.region = this.profile.region;
      return result;
    });
  }
}

// Shared by the provider and the explicit, fixed-prompt connectivity check.
export function parseDeepSeekResponse(response: DeepSeekHttpResponse, modelId: string,
  structured: boolean, maxResponseBytes: number): ModelTransportResult {
    if (response.statusCode !== 200) throw statusFailure(response.statusCode);
    if (new util.TextEncoder('utf-8').encodeInto(response.body).byteLength > maxResponseBytes) {
      throw new ProviderTransportError(ProviderErrorCode.RESPONSE_TOO_LARGE, AgentErrorClass.PROVIDER,
        'DeepSeek response exceeded the configured limit', true);
    }
    let decoded: ChatResponse;
    try { decoded = JSON.parse(response.body); } catch (error) { throw invalidResponse(); }
    if (!objectValue(decoded) || decoded.object !== 'chat.completion' ||
      decoded.model !== modelId) throw invalidResponse();
    const choices: ResponseChoice[] | undefined = decoded.choices;
    const usage: ResponseUsage | undefined = decoded.usage;
    if (!Array.isArray(choices) || choices.length !== 1 || usage === undefined || !objectValue(usage)) {
      throw invalidResponse();
    }
    const choice: ResponseChoice = choices[0];
    if (!objectValue(choice) || choice.index !== 0) throw invalidResponse();
    const message: ResponseMessage | undefined = choice.message;
    if (message === undefined || !objectValue(message) || message.role !== 'assistant' ||
      typeof message.content !== 'string' || message.content.trim().length === 0 ||
      message.tool_calls !== undefined) throw invalidResponse();
    const input: number | undefined = usage.prompt_tokens;
    const output: number | undefined = usage.completion_tokens;
    const total: number | undefined = usage.total_tokens;
    if (typeof input !== 'number' || typeof output !== 'number' || typeof total !== 'number' ||
      !Number.isSafeInteger(input) || !Number.isSafeInteger(output) || !Number.isSafeInteger(total) ||
      input < 0 || output < 0 || total < 0 || !Number.isSafeInteger(input + output) || total !== input + output) {
      throw invalidResponse();
    }
    const result: ModelTransportResult = new ModelTransportResult();
    if (choice.finish_reason === 'stop') result.finishReason = ProviderFinishReason.STOP;
    else if (choice.finish_reason === 'length') result.finishReason = ProviderFinishReason.LENGTH;
    else if (choice.finish_reason === 'content_filter') result.finishReason = ProviderFinishReason.CONTENT_FILTER;
    else throw invalidResponse();
    result.outputText = message.content;
    // A truncated/refused response is never exposed as usable structured planner output.
    if (structured && result.finishReason === ProviderFinishReason.STOP) {
      try { jsonObject(message.content); } catch (error) { throw invalidResponse(); }
      result.outputJson = message.content;
    }
    result.usage.inputTokens = input;
    result.usage.outputTokens = output;
    result.usage.totalTokens = total;
    // Provider does not report a monetary charge here. GenericModelProvider settles using the registered price.
    return result;
}
