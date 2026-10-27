import util from '@ohos.util';
import { AgentErrorClass } from '@harmony_agent/agent-contracts';
import {
  ProviderCancellationSource, ProviderErrorCode, ProviderOperationHandle, ProviderTransportError
} from '@harmony_agent/agent-connectors';

export const VISION_CHAT_ENDPOINT: string = 'https://api.deepseek.com/chat/completions';
export const VISION_CHAT_MAX_REQUEST_BYTES: number = 12 * 1024 * 1024;
export const VISION_CHAT_MAX_RESPONSE_BYTES: number = 2 * 1024 * 1024;
export const VISION_CHAT_MAX_IMAGE_BYTES: number = 8 * 1024 * 1024;
export const VISION_CHAT_MAX_OUTPUT_TOKENS: number = 1024;
export const VISION_CHAT_TIMEOUT_MS: number = 60000;

/** Sanitized image bytes: no original path, filename, EXIF or database identity. */
export class VisionChatImage {
  mime: string = '';
  width: number = 0;
  height: number = 0;
  sha256: string = '';
  bytes: Uint8Array = new Uint8Array(0);
}

export class VisionChatRequest {
  modelId: string = '';
  systemPrompt: string = '';
  question: string = '';
  image: VisionChatImage = new VisionChatImage();
  maxOutputTokens: number = VISION_CHAT_MAX_OUTPUT_TOKENS;
  timeoutMs: number = VISION_CHAT_TIMEOUT_MS;
}

export class VisionChatResult {
  outputText: string = '';
  inputTokens: number = 0;
  outputTokens: number = 0;
  finishReason: string = '';
  modelId: string = '';
}

export interface VisionChatTransportPort {
  start(request: VisionChatRequest, cancellation: ProviderCancellationSource): ProviderOperationHandle<VisionChatResult>;
}

class VisionTextPart {
  type: string = 'text';
  text: string = '';
}
class VisionImageUrl {
  url: string = '';
  detail: string = 'original';
}
class VisionImagePart {
  type: string = 'image_url';
  image_url: VisionImageUrl = new VisionImageUrl();
}
class VisionSystemMessage {
  role: string = 'system';
  content: string = '';
}
class VisionUserMessage {
  role: string = 'user';
  content: Object[] = [];
}
class VisionThinkingMode {
  type: string = 'disabled';
}
class VisionJsonFormat {
  type: string = 'json_object';
}
class VisionChatPayload {
  model: string = '';
  messages: Object[] = [];
  max_tokens: number = 0;
  temperature: number = 0;
  stream: boolean = false;
  thinking: VisionThinkingMode = new VisionThinkingMode();
  response_format?: VisionJsonFormat;
}

class VisionResponseMessage {
  role?: string;
  content?: string;
  tool_calls?: Object;
}
class VisionResponseChoice {
  index?: number;
  message?: VisionResponseMessage;
  finish_reason?: string;
}
class VisionResponseUsage {
  prompt_tokens?: number;
  completion_tokens?: number;
  total_tokens?: number;
}
class VisionChatResponse {
  object?: string;
  model?: string;
  choices?: VisionResponseChoice[];
  usage?: VisionResponseUsage;
}

function objectValue(value: Object | undefined): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}
function validText(value: string, maximum: number): boolean {
  return typeof value === 'string' && value.trim().length > 0 && value === value.trim() && value.length <= maximum;
}
function validModelId(value: string): boolean {
  return typeof value === 'string' && /^[a-zA-Z0-9._-]{1,128}$/.test(value);
}
function invalidInput(): ProviderTransportError {
  return new ProviderTransportError(ProviderErrorCode.INVALID_REQUEST, AgentErrorClass.INVALID_INPUT,
    'Vision chat request is invalid');
}
function invalidResponse(): ProviderTransportError {
  return new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.SCHEMA_MISMATCH,
    'Vision chat response is invalid', true);
}
function statusFailure(status: number): ProviderTransportError {
  if (status === 401) {
    return new ProviderTransportError(ProviderErrorCode.AUTHENTICATION, AgentErrorClass.AUTHENTICATION,
      'DeepSeek authentication failed', true);
  }
  if (status === 402) {
    return new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.PROVIDER,
      'DeepSeek balance is insufficient (HTTP 402)', true);
  }
  if (status === 403) {
    return new ProviderTransportError(ProviderErrorCode.FORBIDDEN, AgentErrorClass.PERMISSION_DENIED,
      'DeepSeek denied the request', true);
  }
  if (status === 429) {
    return new ProviderTransportError(ProviderErrorCode.RATE_LIMITED, AgentErrorClass.PROVIDER,
      'DeepSeek rate limit reached', true);
  }
  if (status >= 400 && status < 500) {
    return new ProviderTransportError(ProviderErrorCode.INVALID_REQUEST, AgentErrorClass.INVALID_INPUT,
      'DeepSeek rejected the request parameters', true);
  }
  return new ProviderTransportError(ProviderErrorCode.PROVIDER, AgentErrorClass.PROVIDER,
    'DeepSeek request failed', true);
}

/** Payload contains no path, filename, database ID, history or EXIF; only the question and sanitized image. */
export function buildVisionChatBody(request: VisionChatRequest, imageBase64: string,
  maximumBytes: number = VISION_CHAT_MAX_REQUEST_BYTES): string | undefined {
  if (!validModelId(request.modelId) || !validText(request.systemPrompt, 4000) ||
    !validText(request.question, 500) || !validText(request.image.mime, 64) ||
    ['image/jpeg', 'image/png', 'image/webp'].indexOf(request.image.mime) < 0 ||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(imageBase64) || imageBase64.length === 0 ||
    request.image.bytes.length < 1 || request.image.bytes.length > VISION_CHAT_MAX_IMAGE_BYTES ||
    !Number.isSafeInteger(request.maxOutputTokens) || request.maxOutputTokens < 1 ||
    request.maxOutputTokens > VISION_CHAT_MAX_OUTPUT_TOKENS ||
    !Number.isSafeInteger(request.timeoutMs) || request.timeoutMs < 1 ||
    request.timeoutMs > VISION_CHAT_TIMEOUT_MS || !Number.isSafeInteger(maximumBytes) || maximumBytes < 1) {
    return undefined;
  }
  const system: VisionSystemMessage = new VisionSystemMessage(); system.content = request.systemPrompt;
  const text: VisionTextPart = new VisionTextPart();
  text.text = '问题：\n' + request.question + '\n\n请仅依据图片回答，并为事实性结论标注 [1]。' +
    '只输出严格 JSON，不要输出 JSON 以外的任何内容：{"answer":"回答文本，含 [1] 引用","citations":[1]}';
  const imageUrl: VisionImageUrl = new VisionImageUrl();
  imageUrl.url = 'data:' + request.image.mime + ';base64,' + imageBase64;
  const image: VisionImagePart = new VisionImagePart(); image.image_url = imageUrl;
  const user: VisionUserMessage = new VisionUserMessage(); user.content = [text, image];
  const payload: VisionChatPayload = new VisionChatPayload();
  payload.model = request.modelId; payload.messages = [system, user];
  payload.max_tokens = request.maxOutputTokens; payload.temperature = 0;
  payload.stream = false; payload.response_format = new VisionJsonFormat();
  const body: string = JSON.stringify(payload);
  if (new util.TextEncoder('utf-8').encodeInto(body).byteLength > maximumBytes) { return undefined; }
  return body;
}

export function parseVisionChatResponse(statusCode: number, body: string, expectedModel: string,
  maximumBytes: number = VISION_CHAT_MAX_RESPONSE_BYTES): VisionChatResult {
  if (statusCode !== 200) { throw statusFailure(statusCode); }
  if (typeof body !== 'string' || new util.TextEncoder('utf-8').encodeInto(body).byteLength > maximumBytes) {
    throw new ProviderTransportError(ProviderErrorCode.RESPONSE_TOO_LARGE, AgentErrorClass.PROVIDER,
      'Vision chat response exceeded the configured limit', true);
  }
  let decoded: VisionChatResponse;
  try { decoded = JSON.parse(body); } catch (error) { throw invalidResponse(); }
  if (!objectValue(decoded) || decoded.object !== 'chat.completion' || decoded.model !== expectedModel) {
    throw invalidResponse();
  }
  const choices: VisionResponseChoice[] | undefined = decoded.choices;
  const usage: VisionResponseUsage | undefined = decoded.usage;
  if (!Array.isArray(choices) || choices.length !== 1 || usage === undefined || !objectValue(usage)) {
    throw invalidResponse();
  }
  const choice: VisionResponseChoice = choices[0];
  if (!objectValue(choice) || choice.index !== 0 || choice.finish_reason !== 'stop') { throw invalidResponse(); }
  const message: VisionResponseMessage | undefined = choice.message;
  if (message === undefined || !objectValue(message) || message.role !== 'assistant' ||
    typeof message.content !== 'string' || message.content.trim().length === 0 ||
    message.content.length > 24000 || message.tool_calls !== undefined) { throw invalidResponse(); }
  const input: number | undefined = usage.prompt_tokens;
  const output: number | undefined = usage.completion_tokens;
  const total: number | undefined = usage.total_tokens;
  if (typeof input !== 'number' || typeof output !== 'number' || typeof total !== 'number' ||
    !Number.isSafeInteger(input) || !Number.isSafeInteger(output) || !Number.isSafeInteger(total) ||
    input < 0 || output < 0 || total < 0 || !Number.isSafeInteger(input + output) || total !== input + output) {
    throw invalidResponse();
  }
  const result: VisionChatResult = new VisionChatResult();
  result.outputText = message.content; result.inputTokens = input; result.outputTokens = output;
  result.finishReason = 'stop'; result.modelId = expectedModel;
  return result;
}
