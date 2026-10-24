import { ModelTransportResult, ProviderFinishReason, ProviderOperationHandle,
  ProviderTransportError } from '@harmony_agent/agent-connectors';
import { DeepSeekHttpClientPort, DeepSeekHttpRequest, DeepSeekHttpResponse, parseDeepSeekResponse } from './DeepSeekProtocol';

export class DirectModelCheckState {
  busy: boolean = false;
  message: string = '尚未发送测试请求。';
}

class CheckMessage { role: string = 'user'; content: string = 'Reply with exactly OK.'; }
class CheckThinking { type: string = 'disabled'; }
class CheckPayload {
  model: string = '';
  messages: CheckMessage[] = [new CheckMessage()];
  max_tokens: number = 64;
  stream: boolean = false;
  thinking: CheckThinking = new CheckThinking();
}

export type DirectModelCheckListener = (state: DirectModelCheckState) => void;

// A one-request diagnostic, not an Agent task, model profile or price snapshot.
export class DirectModelCheckSession {
  private readonly client: DeepSeekHttpClientPort;
  private readonly enabled: boolean;
  private operation?: ProviderOperationHandle<DeepSeekHttpResponse>;
  private listener?: DirectModelCheckListener;
  private state: DirectModelCheckState = new DirectModelCheckState();
  private cancelled: boolean = false;
  private generation: number = 0;

  constructor(client: DeepSeekHttpClientPort, enabled: boolean) {
    this.client = client;
    this.enabled = enabled;
  }

  attach(listener: DirectModelCheckListener): void { this.listener = listener; listener(this.state); }
  detach(): void { this.listener = undefined; this.cancel(); }
  clearInput(): void { this.publish(this.state.busy, this.state.message); }

  cancel(): void {
    if (!this.state.busy || this.cancelled) return;
    this.cancelled = true;
    this.publish(true, '正在停止模型请求；已发出的请求仍可能产生费用。');
    const current: ProviderOperationHandle<DeepSeekHttpResponse> | undefined = this.operation;
    if (current !== undefined) current.cancel();
  }

  async run(modelId: string, apiKey: string): Promise<void> {
    if (this.state.busy) return;
    if (!this.enabled) { this.publish(false, '正式构建不提供模型直连调试入口。'); return; }
    if (!/^[a-zA-Z0-9._-]{1,128}$/.test(modelId) || !/^[\x21-\x7e]{1,2048}$/.test(apiKey)) {
      this.publish(false, '请填写准确的模型标识和有效的 API Key。'); return;
    }
    const generation: number = ++this.generation;
    this.cancelled = false;
    this.publish(true, '正在向 DeepSeek 发送一次公开测试问题…');
    try {
      const payload: CheckPayload = new CheckPayload();
      payload.model = modelId;
      const request: DeepSeekHttpRequest = new DeepSeekHttpRequest();
      request.authorization = 'Bearer ' + apiKey;
      request.body = JSON.stringify(payload);
      request.timeoutMs = 30000;
      request.connectTimeoutMs = 10000;
      request.maxResponseBytes = 65536;
      this.operation = this.client.start(request);
      const response: DeepSeekHttpResponse = await this.operation.result;
      if (this.cancelled || generation !== this.generation) return;
      const result: ModelTransportResult = parseDeepSeekResponse(response, modelId, false, request.maxResponseBytes);
      if (result.finishReason !== ProviderFinishReason.STOP || result.outputText.trim() !== 'OK') {
        this.publish(false, '请求已返回，但测试回答不符合预期；未记为通过。');
      } else {
        this.publish(false, `模型直连测试通过。输入 ${result.usage.inputTokens} / 输出 ${result.usage.outputTokens} tokens；未调用搜索或 Agent 任务。`);
      }
    } catch (error) {
      if (!this.cancelled) {
        const code: string = error instanceof ProviderTransportError ? error.code : 'UNEXPECTED';
        const balance: boolean = error instanceof ProviderTransportError && error.message.includes('HTTP 402');
        this.publish(false, balance ? 'DeepSeek 余额不足（HTTP 402）。' : `模型直连未完成（${code}），请核对网络、模型和凭据后手动重试。`);
      }
    } finally {
      this.operation = undefined;
      if (this.cancelled) this.publish(false, '已停止本地请求；服务端是否已完成及费用请以供应商记录为准。');
    }
  }

  private publish(busy: boolean, message: string): void {
    const next: DirectModelCheckState = new DirectModelCheckState();
    next.busy = busy;
    next.message = message;
    this.state = next;
    const listener: DirectModelCheckListener | undefined = this.listener;
    if (listener !== undefined) listener(next);
  }
}
