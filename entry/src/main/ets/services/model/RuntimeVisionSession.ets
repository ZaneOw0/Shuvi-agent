import { AgentRuntimeEventType, AgentTaskStatus } from '@harmony_agent/agent-contracts';
import {
  AgentFrontendAuthorizationPrompt, AgentFrontendClarificationPrompt, AgentFrontendEvent,
  AgentFrontendEventListener, AgentFrontendSubscription, AgentFrontendTaskRequest
} from '@harmony_agent/agent-runtime';
import { parseKnowledgeAnswer, parseKnowledgeInsufficient } from './KnowledgeAnswerTaskSupport';
import {
  VisionAnswerContext, VISION_ANSWER_MAX_REQUESTS, VISION_ANSWER_PRICING_STATE
} from './VisionAnswerTaskSupport';
import { VisionChatImage } from './VisionChatProtocol';
import { VisionImagePreparerPort, VisionImageFailure, VisionPreparedImage } from './VisionImagePorts';
import { ShuviRuntimeController, ShuviRuntimeState } from './ShuviRuntimeController';
import { ShuviRuntimeSessionFactory } from './ShuviRuntimeSession';

export class RuntimeVisionView {
  lifecycle: ShuviRuntimeState = ShuviRuntimeState.IDLE;
  busy: boolean = false;
  stage: string = 'idle';
  message: string = '尚未启用原图问答。';
  query: string = '';
  answer: string = '';
  imageReady: boolean = false;
  imageName: string = '';
  imageMime: string = '';
  imageWidth: number = 0;
  imageHeight: number = 0;
  imageBytes: number = 0;
  requestCount: number = 0;
  maxRequests: number = VISION_ANSWER_MAX_REQUESTS;
  pricingState: string = VISION_ANSWER_PRICING_STATE;
  consent: boolean = false;
  clearEpoch: number = 0;
}

class VisionListener implements AgentFrontendEventListener {
  private readonly owner: RuntimeVisionSession;
  private readonly generation: number;
  constructor(owner: RuntimeVisionSession, generation: number) {
    this.owner = owner; this.generation = generation;
  }
  onEvent(event: AgentFrontendEvent): void { this.owner.event(this.generation, event); }
  onAuthorizationRequired(_prompt: AgentFrontendAuthorizationPrompt): void {
    this.owner.unexpected(this.generation);
  }
  onClarificationRequired(_prompt: AgentFrontendClarificationPrompt): void {
    this.owner.unexpected(this.generation);
  }
}

/** One consent-gated image + question request to the DeepSeek vision endpoint. */
export class RuntimeVisionSession {
  readonly answer: ShuviRuntimeController = new ShuviRuntimeController();
  readonly answerContext: VisionAnswerContext = new VisionAnswerContext();
  private readonly preparer: VisionImagePreparerPort;
  private view: RuntimeVisionView = new RuntimeVisionView();
  private listener?: (view: RuntimeVisionView) => void;
  private generation: number = 0; private taskId: string = ''; private sequence: number = 0;
  private subscription?: AgentFrontendSubscription; private timer?: number;
  private stopping: boolean = false; private attaching: boolean = false;
  private consentGranted: boolean = false; private modelTaskDispatched: boolean = false;
  private cancelRequested: boolean = false;
  private image?: VisionChatImage;

  constructor(preparer: VisionImagePreparerPort) { this.preparer = preparer; }

  attach(listener: (view: RuntimeVisionView) => void): void { this.listener = listener; this.publish(); }
  detach(): void { this.listener = undefined; void this.stop(); }
  snapshot(): RuntimeVisionView { return copyRuntimeVisionView(this.view); }
  private publish(): void { this.listener?.(this.snapshot()); }
  private active(generation: number): boolean {
    return this.generation === generation && this.view.busy && !this.stopping && this.consentGranted;
  }
  onForeground(): void { this.answer.onForeground(); }
  async onBackground(): Promise<void> {
    await this.stop(); await this.answer.onBackground();
  }
  async onDestroy(): Promise<void> { await this.onBackground(); }

  async start(factory: ShuviRuntimeSessionFactory, key: Uint8Array, consent: boolean): Promise<void> {
    if (!consent) {
      key.fill(0);
      if (this.view.lifecycle === ShuviRuntimeState.READY || this.view.lifecycle === ShuviRuntimeState.STARTING) {
        await this.stop();
      } else {
        this.view.consent = false;
        this.view.message = '未同意原图发送范围，未启用视觉问答。'; this.publish();
      }
      return;
    }
    if (this.view.lifecycle === ShuviRuntimeState.STARTING || this.view.lifecycle === ShuviRuntimeState.READY ||
      this.view.lifecycle === ShuviRuntimeState.BLOCKED || this.stopping || this.attaching) {
      key.fill(0); return;
    }
    const generation: number = ++this.generation;
    this.consentGranted = true; this.modelTaskDispatched = false; this.cancelRequested = false;
    this.view.consent = true; this.view.stage = 'starting'; this.view.lifecycle = ShuviRuntimeState.STARTING;
    this.view.clearEpoch++; this.view.message = '正在打开原图问答会话…'; this.publish();
    try {
      await this.answer.start(factory, key);
      if (generation !== this.generation) { return; }
      this.view.lifecycle = ShuviRuntimeState.READY; this.view.requestCount = 0;
      this.view.message = this.image === undefined ?
        '已就绪。选择一张图片并输入问题；只有点击发送才会请求 DeepSeek。' :
        '已就绪。图片已选择；点击发送才会请求 DeepSeek。';
      this.publish();
    } catch {
      if (generation === this.generation) {
        this.consentGranted = false; this.view.consent = false;
        let closeFailed: boolean = false;
        try { await this.answer.stop(); } catch { closeFailed = true; }
        if (closeFailed || this.answer.lifecycleState() === ShuviRuntimeState.BLOCKED) {
          this.view.lifecycle = ShuviRuntimeState.BLOCKED;
          this.view.message = '原图问答启动失败，且资源关闭未确认；图片未发送，请重启应用排查。';
        } else {
          this.view.lifecycle = ShuviRuntimeState.FAILED;
          this.view.stage = 'idle';
          this.view.message = '原图问答启动失败；没有发送图片、问题或凭据。';
        }
        this.view.clearEpoch++; this.publish();
      }
    } finally { key.fill(0); }
  }

  async attachImage(uri: string, displayName: string): Promise<boolean> {
    if (this.view.busy || this.attaching || this.stopping ||
      this.view.lifecycle === ShuviRuntimeState.STARTING || this.view.lifecycle === ShuviRuntimeState.STOPPING ||
      this.view.lifecycle === ShuviRuntimeState.BLOCKED) { return false; }
    this.attaching = true; const generation: number = this.generation;
    this.view.stage = 'attaching'; this.view.message = '正在读取、校验并重新编码图片…'; this.publish();
    try {
      const prepared: VisionPreparedImage = await this.preparer.prepare(uri, displayName);
      if (generation !== this.generation || this.stopping) {
        prepared.image.bytes.fill(0); return false;
      }
      this.clearImage();
      this.image = prepared.image;
      this.view.imageReady = true; this.view.imageName = prepared.displayName;
      this.view.imageMime = prepared.image.mime; this.view.imageWidth = prepared.image.width;
      this.view.imageHeight = prepared.image.height; this.view.imageBytes = prepared.image.bytes.length;
      this.view.query = ''; this.view.answer = ''; this.view.stage = 'idle';
      this.view.message = '图片已就绪；点击发送后仅发送重新编码后的图片与本次问题。';
      this.publish(); return true;
    } catch (error) {
      if (generation === this.generation && !this.stopping) {
        this.clearImage(); this.view.stage = 'imageFailed';
        this.view.message = error instanceof VisionImageFailure ?
          '图片读取或校验失败（' + error.code + '），未发送。' : '图片读取或校验失败，未发送。';
        this.publish();
      }
      return false;
    } finally { this.attaching = false; }
  }

  removeImage(): boolean {
    if (this.view.busy || this.attaching) { return false; }
    this.clearImage(); this.view.query = ''; this.view.answer = ''; this.view.stage = 'idle';
    this.view.message = '尚未选择图片。'; this.publish(); return true;
  }

  clearConversation(): void {
    if (this.view.busy || this.attaching) { return; }
    this.clearImage(); this.answerContext.clear();
    this.view.query = ''; this.view.answer = ''; this.view.stage = 'idle';
    this.view.message = this.view.lifecycle === ShuviRuntimeState.READY ? '已就绪。选择一张图片并输入问题。' : '尚未启用原图问答。';
    this.publish();
  }

  private clearImage(): void {
    const image: VisionChatImage | undefined = this.image;
    if (image !== undefined) { image.bytes.fill(0); }
    this.image = undefined; this.answerContext.clear();
    this.view.imageReady = false; this.view.imageName = ''; this.view.imageMime = '';
    this.view.imageWidth = 0; this.view.imageHeight = 0; this.view.imageBytes = 0;
  }

  async send(query: string): Promise<boolean> {
    const value: string = query.trim();
    if (this.view.busy || this.attaching || this.view.lifecycle !== ShuviRuntimeState.READY || !this.consentGranted ||
      this.image === undefined || value !== query || !value || value.length > 500) {
      if (this.image === undefined && this.view.lifecycle === ShuviRuntimeState.READY) {
        this.view.message = '请先选择一张图片。'; this.publish();
      }
      return false;
    }
    if (this.view.requestCount >= this.view.maxRequests) {
      this.view.message = '本次会话已达到 ' + this.view.maxRequests.toString() +
        ' 次模型请求上限；请停止会话并重新启用。'; this.publish(); return false;
    }
    this.answerContext.clear();
    if (!this.answerContext.freeze(value, this.image)) {
      this.view.stage = 'imageFailed'; this.view.message = '图片证据无法安全固定，未发送。'; this.publish();
      return false;
    }
    this.view.query = value; this.view.answer = ''; this.view.requestCount++; this.view.busy = true;
    this.view.stage = 'answering'; this.view.message = '正在请求 DeepSeek 视觉回答…';
    this.modelTaskDispatched = false; this.cancelRequested = false;
    const generation: number = ++this.generation; this.watch(generation); this.publish();
    await this.submit(generation); return true;
  }

  private watch(generation: number): void {
    this.timer = setTimeout((): void => { if (this.active(generation)) { void this.stop(); } }, 120000);
  }
  private clearWatch(): void {
    if (this.timer !== undefined) { clearTimeout(this.timer); } this.timer = undefined;
    this.subscription?.close(); this.subscription = undefined;
  }
  private async submit(generation: number): Promise<void> {
    this.taskId = ''; this.sequence = 0; let submittedTaskId: string = '';
    const request: AgentFrontendTaskRequest = new AgentFrontendTaskRequest(); request.intent = this.view.query;
    try {
      const handle = await this.answer.submit(request);
      if (!this.active(generation)) {
        try { await this.answer.cancel(handle.taskId); } catch { /* Best effort after close; late events are gated. */ }
        return;
      }
      submittedTaskId = handle.taskId; this.taskId = handle.taskId; this.modelTaskDispatched = true;
      const subscription = await this.answer.subscribe(handle.taskId, new VisionListener(this, generation), 0);
      if (!this.active(generation) || this.taskId !== handle.taskId) { subscription.close(); return; }
      this.subscription = subscription;
      const state = await this.answer.getTask(handle.taskId);
      if (this.active(generation) && this.taskId === handle.taskId) {
        this.apply(generation, state.status, state.resultJson);
      }
    } catch {
      if (this.active(generation)) {
        if (submittedTaskId.length > 0) {
          try { await this.answer.cancel(submittedTaskId); } catch { /* Late events are generation-gated. */ }
        }
        if (this.active(generation)) {
          this.finish('answerFailed', 'DeepSeek 视觉回答未完成；图片保留，可重试。');
        }
      }
    }
  }

  unexpected(generation: number): void { if (this.active(generation)) { void this.stop(); } }
  answerOutcomeRejected(taskId: string): void {
    if (this.active(this.generation) && this.taskId === taskId) {
      this.finish('answerFailed', 'DeepSeek 视觉回答结果未能可靠保存；图片保留，可重试。');
    }
  }

  event(generation: number, event: AgentFrontendEvent): void {
    if (!this.active(generation) || event.taskId !== this.taskId ||
      !Number.isSafeInteger(event.sequence) || event.sequence <= this.sequence) { return; }
    this.sequence = event.sequence;
    if (event.eventType === AgentRuntimeEventType.TASK_COMPLETED) {
      this.apply(generation, AgentTaskStatus.COMPLETED, event.payloadJson);
    } else if (event.eventType === AgentRuntimeEventType.TASK_FAILED) {
      this.apply(generation, AgentTaskStatus.FAILED, event.payloadJson);
    } else if (event.eventType === AgentRuntimeEventType.TASK_CANCELLED) {
      this.apply(generation, AgentTaskStatus.CANCELLED, event.payloadJson);
    }
  }

  private apply(generation: number, status: AgentTaskStatus, json: string): void {
    if (!this.active(generation)) { return; }
    if (status === AgentTaskStatus.COMPLETED) {
      if (this.cancelRequested) {
        this.finish('answerFailed', '已取消 DeepSeek 视觉回答；图片保留，可重试。'); return;
      }
      const answer = parseKnowledgeAnswer(json, 1);
      if (answer !== undefined) {
        this.view.answer = answer.text;
        this.finish('complete', 'DeepSeek 视觉回答已完成；请核对图片与回答。'); return;
      }
      if (parseKnowledgeInsufficient(json) !== undefined) {
        this.view.answer = '';
        this.finish('insufficient', '图片中没有足够依据；未生成回答。'); return;
      }
      this.finish('answerFailed', '回答格式或引用编号无效；图片保留，可重试。');
    } else if (status === AgentTaskStatus.FAILED || status === AgentTaskStatus.CANCELLED) {
      this.finish('answerFailed', 'DeepSeek 视觉回答失败或已取消；图片保留，可重试。');
    }
  }

  private finish(stage: string, message: string): void {
    this.clearWatch(); ++this.generation; this.view.busy = false; this.view.stage = stage;
    this.view.message = message; this.cancelRequested = false;
    if (stage !== 'answerFailed') { this.answerContext.clear(); }
    this.publish();
  }

  async retryAnswer(): Promise<void> {
    if (this.view.busy || this.view.lifecycle !== ShuviRuntimeState.READY || this.view.stage !== 'answerFailed' ||
      !this.consentGranted || this.image === undefined ||
      this.answerContext.snapshotFor(this.view.query) === undefined) { return; }
    if (this.view.requestCount >= this.view.maxRequests) {
      this.view.message = '本次会话已达到 ' + this.view.maxRequests.toString() +
        ' 次模型请求上限；请停止会话并重新启用。'; this.publish(); return;
    }
    this.view.requestCount++; this.view.busy = true; this.view.stage = 'answering';
    this.view.message = '仅重试 DeepSeek 视觉回答，不重新读取图片。';
    this.modelTaskDispatched = false; this.cancelRequested = false;
    const generation: number = ++this.generation; this.watch(generation);
    this.publish(); await this.submit(generation);
  }

  async cancelCurrent(): Promise<void> {
    if (!this.view.busy) { return; }
    const generation: number = this.generation; const taskId: string = this.taskId;
    if (!taskId) { await this.stop(); return; }
    this.cancelRequested = true; this.view.message = '正在取消当前视觉任务…'; this.publish();
    try {
      const receipt = await this.answer.cancel(taskId);
      if (!this.active(generation)) { return; }
      if (receipt.accepted) {
        this.finish('answerFailed', '已取消 DeepSeek 视觉回答；图片保留，可重试。已发送请求仍可能计费。');
      } else {
        const state = await this.answer.getTask(taskId);
        if (this.active(generation)) {
          this.apply(generation, state.status, state.resultJson);
          if (this.active(generation)) { await this.stop(); }
        }
      }
    } catch { if (this.active(generation)) { await this.stop(); } }
  }

  async stop(): Promise<void> {
    if (this.stopping) { return; }
    if (this.view.lifecycle === ShuviRuntimeState.IDLE &&
      this.answer.lifecycleState() === ShuviRuntimeState.IDLE) {
      this.clearWatch(); this.consentGranted = false; this.modelTaskDispatched = false; this.cancelRequested = false;
      this.clearImage(); this.view.consent = false; this.view.clearEpoch++; this.publish(); return;
    }
    const mayBill: boolean = this.modelTaskDispatched;
    this.stopping = true; ++this.generation; this.clearWatch();
    this.consentGranted = false; this.modelTaskDispatched = false; this.cancelRequested = false;
    this.answerContext.clear(); this.clearImage();
    this.view.consent = false; this.view.busy = false; this.view.clearEpoch++;
    this.view.lifecycle = ShuviRuntimeState.STOPPING; this.view.message = '正在停止并清除凭据…'; this.publish();
    let failed: boolean = false;
    try { await this.answer.stop(); } catch { failed = true; }
    this.stopping = false; this.view.lifecycle = failed ? ShuviRuntimeState.BLOCKED : ShuviRuntimeState.STOPPED;
    this.view.stage = 'stopped';
    this.view.message = failed ? '资源关闭未确认，请重启应用排查；图片已从会话移除。' : (mayBill ?
      '会话已停止；凭据已清除，图片已从会话移除；已发送请求仍可能计费。' :
      '会话已停止；凭据已清除，图片已从会话移除；未发送模型请求。');
    this.publish();
  }
}

function copyRuntimeVisionView(value: RuntimeVisionView): RuntimeVisionView {
  const copy: RuntimeVisionView = new RuntimeVisionView();
  copy.lifecycle = value.lifecycle; copy.busy = value.busy; copy.stage = value.stage;
  copy.message = value.message; copy.query = value.query; copy.answer = value.answer;
  copy.imageReady = value.imageReady; copy.imageName = value.imageName; copy.imageMime = value.imageMime;
  copy.imageWidth = value.imageWidth; copy.imageHeight = value.imageHeight; copy.imageBytes = value.imageBytes;
  copy.requestCount = value.requestCount; copy.maxRequests = value.maxRequests; copy.pricingState = value.pricingState;
  copy.consent = value.consent; copy.clearEpoch = value.clearEpoch; return copy;
}
