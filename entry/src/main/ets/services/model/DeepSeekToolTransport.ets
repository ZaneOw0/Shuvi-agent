import util from '@ohos.util';
import { AgentErrorClass } from '@harmony_agent/agent-contracts';
import {
  ModelInvocation, ModelTransportObserver, ModelTransportPort, ModelTransportResult, ProviderCredential,
  ProviderErrorCode, ProviderFinishReason, ProviderOperationHandle, ProviderTransportError
} from '@harmony_agent/agent-connectors';
import { SingleAgentHostResourcePort } from '@harmony_agent/agent-runtime';
import { ModelDocumentToolsPort } from '../documents/DocumentToolContracts';
import { DOCUMENT_MODEL_TOOL_NAMES, documentModelToolDefinitions } from '../documents/ModelDocumentTools';
import { DeepSeekHttpClientPort, DeepSeekHttpRequest, DeepSeekHttpResponse, DeepSeekProfile,
  createDeepSeekModelProfile, parseDeepSeekResponse } from './DeepSeekProtocol';

export class ModelToolFunction { name: string = ''; arguments: string = ''; }
export class ModelToolCall { id: string = ''; type: string = 'function'; function: ModelToolFunction = new ModelToolFunction(); }
export class ToolChatMessage {
  role: string = ''; content: string | null = ''; tool_calls?: ModelToolCall[]; tool_call_id?: string;
}
class ToolThinking { type: string = 'disabled'; }
class ToolPayload {
  model: string = ''; messages: ToolChatMessage[] = []; max_tokens: number = 0; temperature: number = 0;
  stream: boolean = false; thinking: ToolThinking = new ToolThinking();
  tools: Object[] = documentModelToolDefinitions(); tool_choice: string = 'auto';
}
class ToolRound { message: ToolChatMessage = new ToolChatMessage(); input: number = 0; output: number = 0; final: boolean = false; }

function failure(code: ProviderErrorCode = ProviderErrorCode.PROVIDER): ProviderTransportError {
  return new ProviderTransportError(code, code === ProviderErrorCode.CANCELLED ? AgentErrorClass.CANCELLED :
    AgentErrorClass.SCHEMA_MISMATCH, 'Model tool turn failed; committed local operations are not retried', true);
}
function record(value: Object): Record<string, Object> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw failure();
  return value as Record<string, Object>;
}
function count(value: Object): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) throw failure(); return value;
}
function documentErrorText(code: string): string {
  if (code === 'DOCUMENT_VERSION_CONFLICT') return '版本冲突，未覆盖原文件';
  if (code === 'DOCUMENT_ALREADY_EXISTS') return '同名文档已存在，未覆盖';
  if (code === 'DOCUMENT_NOT_FOUND') return '没有找到该文档';
  if (code === 'DOCUMENT_DOWNLOAD_CONFLICT') return '下载目录存在同名文件或文件已被外部修改，未覆盖';
  if (code === 'DOCUMENT_DOWNLOAD_UNAVAILABLE') return '无法访问下载目录，未完成保存';
  if (code === 'DOCUMENT_DOWNLOAD_SAVE_FAILED') return '下载目录写入失败，文档版本未更新';
  if (code === 'DOCUMENT_DOWNLOAD_UNCERTAIN') return '内部版本已保留，但下载目录保存结果未确认，请核查文件，未自动重试';
  if (code === 'DOCUMENT_RESULT_UNCERTAIN' || code === 'DOCUMENT_COMMIT_UNCERTAIN' ||
    code === 'DOCUMENT_OUTCOME_NOT_DURABLE') return '写入结果未确认，请核查文件，未自动重试';
  if (code.startsWith('DOCUMENT_INVALID')) return '工具参数无效，未执行写入';
  return '操作未完成，请核查文件结果';
}

/** Validate the provider envelope and every tool call before allowing local execution. */
export function parseModelToolRound(response: DeepSeekHttpResponse, modelId: string, maxBytes: number): ToolRound {
  if (response.statusCode !== 200 || new util.TextEncoder().encodeInto(response.body).length > maxBytes) {
    parseDeepSeekResponse(response, modelId, false, maxBytes); throw failure();
  }
  const root: Record<string, Object> = record(JSON.parse(response.body) as Object);
  if (root['object'] !== 'chat.completion' || root['model'] !== modelId || !Array.isArray(root['choices']) ||
    (root['choices'] as Object[]).length !== 1) throw failure();
  const choice: Record<string, Object> = record((root['choices'] as Object[])[0]);
  if (choice['index'] !== 0) throw failure();
  const message: Record<string, Object> = record(choice['message']);
  const usage: Record<string, Object> = record(root['usage']);
  const result: ToolRound = new ToolRound();
  result.input = count(usage['prompt_tokens']); result.output = count(usage['completion_tokens']);
  if (count(usage['total_tokens']) !== result.input + result.output || message['role'] !== 'assistant') throw failure();
  result.message.role = 'assistant';
  if (choice['finish_reason'] === 'stop') {
    const parsed: ModelTransportResult = parseDeepSeekResponse(response, modelId, false, maxBytes);
    if (parsed.finishReason !== ProviderFinishReason.STOP) throw failure();
    result.final = true; result.message.content = parsed.outputText; return result;
  }
  if (choice['finish_reason'] !== 'tool_calls' || !Array.isArray(message['tool_calls']) ||
    (message['tool_calls'] as Object[]).length === 0 || (message['tool_calls'] as Object[]).length > 4 ||
    (message['content'] !== null && message['content'] !== undefined && typeof message['content'] !== 'string')) throw failure();
  result.message.content = typeof message['content'] === 'string' ? message['content'] as string : null;
  const calls: ModelToolCall[] = []; const ids: string[] = [];
  for (const raw of message['tool_calls'] as Object[]) {
    const call: Record<string, Object> = record(raw); const fn: Record<string, Object> = record(call['function']);
    if (call['type'] !== 'function' || typeof call['id'] !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(call['id'] as string) ||
      ids.includes(call['id'] as string) || typeof fn['name'] !== 'string' || !DOCUMENT_MODEL_TOOL_NAMES.includes(fn['name'] as string) ||
      typeof fn['arguments'] !== 'string' || (fn['arguments'] as string).length > 300000) throw failure();
    record(JSON.parse(fn['arguments'] as string) as Object);
    const value: ModelToolCall = new ModelToolCall(); value.id = call['id'] as string;
    value.function.name = fn['name'] as string; value.function.arguments = fn['arguments'] as string;
    ids.push(value.id); calls.push(value);
  }
  result.message.tool_calls = calls; return result;
}

class ToolLoopOperation implements ProviderOperationHandle<ModelTransportResult> {
  readonly result: Promise<ModelTransportResult>;
  private readonly stop: () => void;
  constructor(result: Promise<ModelTransportResult>, stop: () => void) { this.result = result; this.stop = stop; }
  cancel(): void { this.stop(); }
}

/** assistant tool_calls -> local Runtime -> matching tool_call_id -> model continuation. */
export class DeepSeekToolTransport implements ModelTransportPort, SingleAgentHostResourcePort {
  private readonly profile: DeepSeekProfile;
  private readonly client: DeepSeekHttpClientPort;
  private readonly tools: ModelDocumentToolsPort;
  private turns: ToolChatMessage[][] = [];
  private attempts: number = 0;
  private stopped: boolean = false;
  private active?: ProviderOperationHandle<ModelTransportResult>;
  constructor(profile: DeepSeekProfile, client: DeepSeekHttpClientPort, tools: ModelDocumentToolsPort) {
    createDeepSeekModelProfile(profile);
    this.profile = JSON.parse(JSON.stringify(profile)) as DeepSeekProfile; this.client = client; this.tools = tools;
  }
  async open(): Promise<void> { if (this.stopped) throw failure(ProviderErrorCode.CANCELLED); }
  async close(): Promise<void> {
    this.stopped = true; this.active?.cancel(); this.turns = []; await this.tools.close();
  }
  start(request: ModelInvocation, credential: ProviderCredential, _observer?: ModelTransportObserver): ProviderOperationHandle<ModelTransportResult> {
    if (this.stopped || !this.profile.available || this.active !== undefined || request.modelId !== this.profile.modelId ||
      request.modelVersion !== this.profile.modelVersion || request.context.providerId !== 'deepseek-direct' ||
      request.context.region !== this.profile.region || request.context.credentialScope !== 'deepseek.invoke' ||
      !Number.isSafeInteger(request.maxOutputTokens) || request.maxOutputTokens < 1 || request.maxOutputTokens > 1024 ||
      request.maxOutputTokens > this.profile.maxOutputTokens || !Number.isSafeInteger(request.context.timeoutMs) ||
      !Number.isFinite(request.temperature) || request.temperature < 0 || request.temperature > 2 || request.context.timeoutMs > 120000 ||
      request.context.timeoutMs < 1 || request.messages.length !== 2 || request.messages[0].role !== 'system' ||
      request.messages[1].role !== 'user' || !request.messages[1].content.trim() || request.messages[1].content.length > 500 ||
      Object.keys(credential.headers).length !== 1 || !/^Bearer [\x21-\x7e]+$/.test(credential.headers.Authorization)) throw failure();
    const captured: ModelInvocation = JSON.parse(JSON.stringify(request)) as ModelInvocation;
    const authorization: string = credential.headers.Authorization;
    let cancelled: boolean = false; let source: ProviderOperationHandle<DeepSeekHttpResponse> | undefined = undefined;
    const promise: Promise<ModelTransportResult> = this.run(captured, authorization, (): boolean => cancelled,
      (current: ProviderOperationHandle<DeepSeekHttpResponse>): void => { source = current; });
    const operation: ToolLoopOperation = new ToolLoopOperation(promise.finally((): void => { this.active = undefined; }), (): void => {
      if (cancelled) return; cancelled = true; source?.cancel(); void this.tools.cancel().catch((): void => { this.stopped = true; });
    });
    this.active = operation; return operation;
  }
  private async run(request: ModelInvocation, authorization: string, cancelled: () => boolean,
    current: (operation: ProviderOperationHandle<DeepSeekHttpResponse>) => void): Promise<ModelTransportResult> {
    await Promise.resolve();
    const system: ToolChatMessage = new ToolChatMessage(); system.role = 'system'; system.content = request.messages[0].content;
    const turn: ToolChatMessage[] = []; const user: ToolChatMessage = new ToolChatMessage();
    user.role = 'user'; user.content = request.messages[1].content; turn.push(user);
    const deadline: number = Date.now() + request.context.timeoutMs;
    let input: number = 0; let output: number = 0; let toolCount: number = 0; let blockTools: boolean = false;
    let blockWrites: boolean = false;
    const receipts: string[] = [];
    const errors: string[] = [];
    let readbacks: string[] = [];
    try {
      for (let roundIndex: number = 0; roundIndex < 6; roundIndex++) {
        if (cancelled() || this.stopped) throw failure(ProviderErrorCode.CANCELLED);
        if (this.attempts >= 10 || Date.now() >= deadline || output >= request.maxOutputTokens) throw failure();
        const payload: ToolPayload = new ToolPayload(); payload.model = this.profile.modelId;
        payload.max_tokens = request.maxOutputTokens - output; payload.temperature = request.temperature;
        payload.tool_choice = blockTools ? 'none' : 'auto';
        payload.tools = documentModelToolDefinitions(blockWrites);
        while (this.turns.length > 0 && JSON.stringify([system, ...this.turns.flat(), ...turn]).length > 18000) this.turns.shift();
        payload.messages = [system, ...this.turns.flat(), ...turn];
        const body: string = JSON.stringify(payload);
        if (new util.TextEncoder().encodeInto(body).length > this.profile.maxRequestBytes) throw failure();
        const outgoing: DeepSeekHttpRequest = new DeepSeekHttpRequest(); outgoing.authorization = authorization; outgoing.body = body;
        outgoing.timeoutMs = Math.min(30000, deadline - Date.now()); outgoing.connectTimeoutMs = Math.min(this.profile.connectTimeoutMs, outgoing.timeoutMs);
        outgoing.maxResponseBytes = this.profile.maxResponseBytes;
        this.attempts++; const operation = this.client.start(outgoing); current(operation);
        const response = await operation.result;
        if (cancelled() || this.stopped) throw failure(ProviderErrorCode.CANCELLED);
        const result: ToolRound = parseModelToolRound(response, this.profile.modelId, this.profile.maxResponseBytes);
        input += result.input; output += result.output;
        if (input > 8192 || output > request.maxOutputTokens) throw failure();
        turn.push(result.message);
        if (result.final) {
          if (/<[｜|]*DSML[｜|]*\s+(?:calls|invoke|parameter)\b|<tool_call(?:>|\s)/i.test(result.message.content ?? '')) {
            result.message.content = '模型返回了未执行的工具调用文本；没有根据这些文本执行操作，本轮未完成这一步核查。';
          }
          this.turns.push(turn); if (this.turns.length > 8) this.turns.shift();
          const value: ModelTransportResult = new ModelTransportResult();
          value.outputText = (errors.length > 0 ? '本轮有工具未完成：' + errors.join('；') + '\n\n' : '') +
            (result.message.content ?? '') + (receipts.length > 0 ? '\n\n本地文件回执：\n' + receipts.join('\n') : '') +
            (readbacks.length > 0 ? '\n\n实际读取结果：\n' + readbacks.join('\n') : '');
          value.finishReason = ProviderFinishReason.STOP; value.modelVersion = this.profile.modelVersion; value.region = this.profile.region;
          value.usage.inputTokens = input; value.usage.outputTokens = output; value.usage.totalTokens = input + output; return value;
        }
        if (blockTools) throw failure();
        const calls: ModelToolCall[] = result.message.tool_calls as ModelToolCall[];
        for (const call of calls) {
          const reply: ToolChatMessage = new ToolChatMessage(); reply.role = 'tool'; reply.tool_call_id = call.id;
          if (blockWrites && call.function.name !== 'document_read') {
            reply.content = '{"ok":false,"error":"WRITE_BLOCKED_PENDING_VERIFICATION","allowedTools":["document_read"]}';
            errors.push('本轮写入结果待核查，后续写入未执行');
          } else if (blockTools || cancelled() || this.stopped || toolCount >= 6) {
            reply.content = '{"ok":false,"error":"NOT_EXECUTED_LIMIT_OR_CANCELLED"}'; blockTools = true;
            errors.push('已达到工具调用限制或已取消，后续工具未执行');
          } else {
            toolCount++;
            try {
              if (call.function.name !== 'document_read') readbacks = [];
              reply.content = await this.tools.invoke(call.function.name, call.function.arguments);
              const data: Record<string, Object> = record(JSON.parse(reply.content) as Object);
              if (data['ok'] === true && call.function.name !== 'document_read' && typeof data['receipt'] === 'string') {
                receipts.push(String(data['fileName']) + ' · v' + String(data['version']) +
                  '\n保存位置：' + String(data['storageLocation']) + '\n' + (data['receipt'] as string));
              }
              if (data['ok'] === true && call.function.name === 'document_read') {
                readbacks.push(String(data['fileName']) + ' · v' + String(data['version']) + '\n位置：' + String(data['storageLocation']));
              }
            } catch (error) {
              const raw: string = error instanceof Error ? error.message : '';
              const code: string = /^[A-Z_]{3,90}$/.test(raw) ? raw : 'DOCUMENT_OPERATION_FAILED';
              reply.content = JSON.stringify({ ok: false, error: code });
              errors.push(documentErrorText(code));
              if (code === 'DOCUMENT_RESULT_UNCERTAIN' || code === 'DOCUMENT_COMMIT_UNCERTAIN' ||
                code === 'DOCUMENT_OUTCOME_NOT_DURABLE' || code === 'DOCUMENT_DOWNLOAD_UNCERTAIN') {
                blockWrites = true;
                reply.content = JSON.stringify({ ok: false, error: code, writesBlocked: true, allowedTools: ['document_read'] });
              }
            }
          }
          turn.push(reply);
        }
      }
      throw failure();
    } catch (error) {
      const last: ToolChatMessage | undefined = turn[turn.length - 1];
      if (last?.role === 'tool' && !this.stopped && !cancelled()) this.turns.push(turn);
      throw error as Error;
    }
  }
}
