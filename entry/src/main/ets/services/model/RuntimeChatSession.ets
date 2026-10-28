import { AgentTaskStatus, AgentRuntimeEventType } from '@harmony_agent/agent-contracts';
import { AgentFrontendAuthorizationPrompt, AgentFrontendClarificationPrompt, AgentFrontendEvent,
  AgentFrontendEventListener, AgentFrontendSubscription, AgentFrontendTaskRequest } from '@harmony_agent/agent-runtime';
import { ShuviRuntimeController, ShuviRuntimeState } from './ShuviRuntimeController';
import { ShuviRuntimeSessionFactory } from './ShuviRuntimeSession';
import { parseChatAnswer } from './ChatRuntimeAssembly';

export class RuntimeChatView {
  lifecycle: ShuviRuntimeState = ShuviRuntimeState.IDLE;
  busy: boolean = false;
  message: string = '尚未启用真实对话。';
  reply: string = '';
  replyId: number = 0;
  succeeded: boolean = false;
  clearEpoch: number = 0;
}
class ChatListener implements AgentFrontendEventListener {
  private readonly owner: RuntimeChatSession; private readonly generation: number;
  constructor(owner: RuntimeChatSession, generation: number) { this.owner = owner; this.generation = generation; }
  onEvent(event: AgentFrontendEvent): void { this.owner.event(this.generation, event); }
  onAuthorizationRequired(_prompt: AgentFrontendAuthorizationPrompt): void { this.owner.unexpected(this.generation); }
  onClarificationRequired(_prompt: AgentFrontendClarificationPrompt): void { this.owner.unexpected(this.generation); }
}

/** UI projection only. It cannot access credentials, providers or device tools. */
export class RuntimeChatSession {
  private readonly controller: ShuviRuntimeController;
  private view: RuntimeChatView = new RuntimeChatView();
  private listener?: (view: RuntimeChatView) => void;
  private generation: number = 0;
  private taskId: string = '';
  private sequence: number = 0;
  private subscription?: AgentFrontendSubscription;
  private timer?: number;
  private documentTools: boolean = false;
  constructor(controller: ShuviRuntimeController) {
    this.controller = controller;
    controller.attach((state: ShuviRuntimeState): void => {
      this.view.lifecycle = state; this.view.clearEpoch++;
      if (state !== ShuviRuntimeState.READY && this.view.busy) this.finish('会话已中止，未自动重试；已发送的请求可能计费。');
      this.view.message = this.describe(state); this.publish();
    });
  }
  attach(listener: (view: RuntimeChatView) => void): void { this.listener = listener; this.publish(); }
  detach(): void { this.listener = undefined; void this.stop().catch((): void => {}); }
  snapshot(): RuntimeChatView { return copyRuntimeChatView(this.view); }
  private publish(): void { this.listener?.(this.snapshot()); }
  private describe(state: ShuviRuntimeState): string {
    switch (state) {
      case ShuviRuntimeState.STARTING: return '正在打开对话会话…';
      case ShuviRuntimeState.READY: return '真实对话已就绪；发送后才调用模型。';
      case ShuviRuntimeState.STOPPING: return '正在停止并清除凭据…';
      case ShuviRuntimeState.STOPPED: return '会话已停止，请重新配置后发送。';
      case ShuviRuntimeState.FAILED: return '会话启动失败，请检查本机存储与配置。';
      case ShuviRuntimeState.BLOCKED: return '资源关闭未确认，请重启应用后排查；未删除资料。';
      default: return '尚未启用真实对话。';
    }
  }
  async start(factory: ShuviRuntimeSessionFactory, key: Uint8Array): Promise<void> {
    this.documentTools = factory.documentToolsEnabled === true;
    try { await this.controller.start(factory, key); }
    catch { this.view.message = this.describe(this.controller.lifecycleState()); this.publish(); }
    finally { key.fill(0); }
  }
  async stop(): Promise<void> {
    if (this.view.busy) this.finish('会话已中止，未自动重试；已发送的请求可能计费。');
    await this.controller.stop();
  }
  async send(text: string): Promise<void> {
    if (this.view.busy) return;
    if (this.controller.lifecycleState() !== ShuviRuntimeState.READY) {
      this.view.message = '请先启用真实对话；本次未发送，也不会回退为演示回答。'; this.publish(); return;
    }
    if (!text.trim() || text.length > 500) return;
    this.view.busy = true; this.view.message = '正在等待模型回答…'; this.taskId = ''; this.sequence = 0;
    const generation = ++this.generation; this.publish();
    this.timer = setTimeout((): void => {
      if (this.active(generation)) {
        this.finish('等待超时，会话将关闭。请重新启用后手动重试；无法确认供应商是否已计费。');
        void this.controller.stop().catch((): void => {});
      }
    }, this.documentTools ? 120000 : 45000);
    const request = new AgentFrontendTaskRequest(); request.intent = text;
    try {
      const handle = await this.controller.submit(request);
      if (!this.active(generation)) return;
      this.taskId = handle.taskId;
      const subscription = await this.controller.subscribe(handle.taskId, new ChatListener(this, generation), 0);
      if (!this.active(generation)) { subscription.close(); return; }
      this.subscription = subscription;
      // Read after subscribing; synchronous replay or fast completion cannot be missed.
      const state = await this.controller.getTask(handle.taskId);
      if (!this.active(generation)) return;
      this.apply(state.status, state.resultJson);
    } catch {
      if (this.active(generation)) {
        this.finish('任务提交或状态读取失败，会话已停止。请重新启用后手动重试。');
        void this.controller.stop().catch((): void => {});
      }
    }
  }
  private active(generation: number): boolean { return generation === this.generation && this.view.busy; }
  event(generation: number, event: AgentFrontendEvent): void {
    if (!this.active(generation) || event.taskId !== this.taskId || !Number.isSafeInteger(event.sequence) || event.sequence <= this.sequence) return;
    this.sequence = event.sequence;
    if (event.eventType === AgentRuntimeEventType.TASK_COMPLETED) this.apply(AgentTaskStatus.COMPLETED, event.payloadJson);
    else if (event.eventType === AgentRuntimeEventType.TASK_FAILED) this.apply(AgentTaskStatus.FAILED, event.payloadJson);
    else if (event.eventType === AgentRuntimeEventType.TASK_CANCELLED) this.apply(AgentTaskStatus.CANCELLED, event.payloadJson);
  }
  unexpected(generation: number): void {
    if (!this.active(generation)) return;
    this.finish('当前仅支持普通对话，未批准工具调用或继续执行。');
    void this.controller.stop().catch((): void => {});
  }
  private apply(status: AgentTaskStatus, json: string): void {
    if (status === AgentTaskStatus.COMPLETED) {
      const answer = parseChatAnswer(json);
      this.finish(answer === undefined ? '回答格式无效，未显示为成功。' : answer.text, answer !== undefined);
    } else if (status === AgentTaskStatus.FAILED) this.finish(this.documentTools ?
      '本轮回答未完成；文档工具可能已执行，请先让模型核查文件结果，避免重复写入。也请检查 Key、余额、网络或会话调用上限。' :
      '回答失败。请检查 Key、余额、网络或本次会话的调用上限，再手动重试。');
    else if (status === AgentTaskStatus.CANCELLED) this.finish(this.cancelText());
    else if (status !== AgentTaskStatus.RECEIVED && status !== AgentTaskStatus.RUNNING) this.unexpected(this.generation);
  }
  private finish(text: string, succeeded: boolean = false): void {
    if (!this.view.busy) return;
    this.view.busy = false; this.generation++;
    if (this.timer !== undefined) clearTimeout(this.timer); this.timer = undefined;
    this.subscription?.close(); this.subscription = undefined;
    this.view.succeeded = succeeded;
    this.view.reply = text; this.view.replyId++; this.view.message = this.describe(this.view.lifecycle); this.publish();
  }
  private cancelText(): string {
    return this.documentTools ? '已取消后续回答；已提交的本地文件会保留，请核查文件结果。模型请求仍可能计费。' :
      '已取消本次回答；已发送的请求仍可能计费。';
  }
  async cancel(): Promise<void> {
    if (!this.view.busy) return;
    const generation = this.generation;
    if (!this.taskId) { await this.stop(); return; }
    this.view.message = '正在取消…'; this.publish();
    try {
      const receipt = await this.controller.cancel(this.taskId);
      if (!this.active(generation)) return;
      if (receipt.accepted) this.finish(this.cancelText());
      else {
        const state = await this.controller.getTask(this.taskId);
        if (this.active(generation)) { this.apply(state.status, state.resultJson); if (this.active(generation)) await this.stop(); }
      }
    } catch { if (this.active(generation)) await this.stop(); }
  }
}

function copyRuntimeChatView(value: RuntimeChatView): RuntimeChatView {
  const copy = new RuntimeChatView();
  copy.lifecycle = value.lifecycle;
  copy.busy = value.busy;
  copy.message = value.message;
  copy.reply = value.reply;
  copy.replyId = value.replyId;
  copy.succeeded = value.succeeded;
  copy.clearEpoch = value.clearEpoch;
  return copy;
}
