import { AgentRuntimeEventType, AgentTaskStatus } from '@harmony_agent/agent-contracts';
import { AgentFrontendAuthorizationPrompt, AgentFrontendClarificationPrompt, AgentFrontendEvent, AgentFrontendEventListener,
  AgentFrontendSubscription, AgentFrontendTaskRequest } from '@harmony_agent/agent-runtime';
import { RuntimeChatSession, RuntimeChatView } from '../model/RuntimeChatSession';
import { ShuviRuntimeController, ShuviRuntimeState } from '../model/ShuviRuntimeController';
import { ShuviRuntimeSessionFactory } from '../model/ShuviRuntimeSession';
import { AssistantContext, parseAssistantIntent } from './AssistantIntent';
import { CalendarRuntimeFactory } from './CalendarRuntimeAssembly';
import { CalendarToolPreview, parseCalendarToolResult } from './CalendarToolContract';
import { CalendarProbeDraft } from './CalendarProbeSession';

export class AssistantView extends RuntimeChatView {
  preview?: CalendarToolPreview;
  calendarStage: string = 'idle';
}
class CalendarListener implements AgentFrontendEventListener {
  private readonly owner: AssistantRuntimeSession; private readonly generation: number;
  constructor(owner: AssistantRuntimeSession, generation: number) { this.owner = owner; this.generation = generation; }
  onEvent(event: AgentFrontendEvent): void { this.owner.event(this.generation, event); }
  onAuthorizationRequired(prompt: AgentFrontendAuthorizationPrompt): void { this.owner.authorization(this.generation, prompt); }
  onClarificationRequired(_prompt: AgentFrontendClarificationPrompt): void { this.owner.unexpected(this.generation); }
}
/** Two separately journaled Runtime tasks: model intent/draft, then authorized native calendar tool. */
export class AssistantRuntimeSession {
  readonly context: AssistantContext = new AssistantContext();
  readonly calendar: ShuviRuntimeController = new ShuviRuntimeController();
  private readonly model: RuntimeChatSession;
  private view: AssistantView = new AssistantView();
  private listener?: (view: AssistantView) => void;
  private seenModelReply: number = 0;
  private awaiting: boolean = false;
  private factory?: CalendarRuntimeFactory;
  private generation: number = 0;
  private taskId: string = '';
  private sequence: number = 0;
  private subscription?: AgentFrontendSubscription;
  private prompt?: AgentFrontendAuthorizationPrompt;
  private timer?: number;
  private deciding: boolean = false;
  private stopping: boolean = false;
  private closing?: Promise<void>;
  private editingTask: string = '';
  private writing: boolean = false;
  private draftJson: string = '';
  constructor(controller: ShuviRuntimeController) {
    this.model = new RuntimeChatSession(controller);
    this.model.attach((view: RuntimeChatView): void => this.modelChanged(view));
  }
  attach(listener: (view: AssistantView) => void): void { this.listener = listener; this.publish(); }
  detach(): void { this.listener = undefined; void this.stop().catch((): void => {}); }
  snapshot(): AssistantView { const copy: AssistantView = JSON.parse(JSON.stringify(this.view)); return copy; }
  clearConversation(): void { if (!this.view.busy) this.context.clear(); }
  private publish(): void { this.listener?.(this.snapshot()); }
  private modelChanged(value: RuntimeChatView): void {
    this.view.lifecycle = value.lifecycle; this.view.clearEpoch = value.clearEpoch;
    if (this.stopping) return;
    if (value.replyId > this.seenModelReply) {
      this.seenModelReply = value.replyId;
      if (!this.awaiting) return;
      this.awaiting = false;
      if (!value.succeeded) { this.context.clear(); this.finish(value.reply); return; }
      const intent = parseAssistantIntent(value.reply, Date.now());
      if (intent.kind === 'clarify') this.context.rememberClarification(); else this.context.clear();
      if (intent.draft !== undefined) { void this.submitCalendar(intent.draft); return; }
      this.finish(intent.message, intent.kind === 'answer' || intent.kind === 'clarify'); return;
    }
    if (this.view.calendarStage === 'idle') { this.view.busy = value.busy; this.view.message = value.message; }
    if (value.lifecycle !== ShuviRuntimeState.READY && this.view.calendarStage !== 'idle') {
      void this.stop().catch((): void => {}); return;
    }
    this.publish();
  }
  async start(factory: ShuviRuntimeSessionFactory, calendarFactory: CalendarRuntimeFactory, key: Uint8Array): Promise<void> {
    if (this.view.lifecycle === ShuviRuntimeState.READY || this.view.lifecycle === ShuviRuntimeState.STARTING || this.stopping) { key.fill(0); return; }
    this.factory = calendarFactory;
    calendarFactory.onOutcomeRejected = (id: string): void => {
      if (this.taskId === id && this.view.busy) { this.finish('日历执行结果未能可靠保存，请到工作台核查日程；不要重复创建。'); void this.calendar.stop().catch((): void => {}); }
    };
    const generation = ++this.generation;
    this.view.lifecycle = ShuviRuntimeState.STARTING; this.view.message = '正在启用助手与日历工具…'; this.publish();
    try {
      await this.calendar.start(calendarFactory, new Uint8Array());
      if (generation !== this.generation) return;
      await this.model.start(factory, key);
      if (this.model.snapshot().lifecycle !== ShuviRuntimeState.READY) await this.calendar.stop();
    } catch {
      await this.stop(); this.view.lifecycle = this.calendar.lifecycleState() === ShuviRuntimeState.BLOCKED ? ShuviRuntimeState.BLOCKED : ShuviRuntimeState.FAILED;
      this.view.message = '助手启动失败，请检查本机存储；未调用模型或写入日历。'; this.publish();
    } finally { key.fill(0); }
  }
  async send(input: string): Promise<void> {
    if (this.view.busy || this.stopping || this.view.lifecycle !== ShuviRuntimeState.READY || !input.trim() || input.length > 500) return;
    this.context.bind(input, Date.now()); this.awaiting = true; await this.model.send(input);
  }
  private async submitCalendar(draft: CalendarProbeDraft): Promise<void> {
    this.view.busy = true; this.view.calendarStage = 'preparing'; this.view.message = '正在准备日程确认…';
    this.taskId = ''; this.sequence = 0; this.writing = false; this.draftJson = JSON.stringify(draft);
    const generation = ++this.generation; this.publish();
    this.timer = setTimeout((): void => { if (this.active(generation)) void this.cancel(); }, 150000);
    const request = new AgentFrontendTaskRequest(); request.intent = this.draftJson;
    try {
      const handle = await this.calendar.submit(request); if (!this.active(generation)) return;
      this.taskId = handle.taskId;
      const subscription = await this.calendar.subscribe(handle.taskId, new CalendarListener(this, generation), 0);
      if (!this.active(generation)) { subscription.close(); return; } this.subscription = subscription;
      const state = await this.calendar.getTask(handle.taskId);
      if (this.active(generation)) this.apply(state.status, state.resultJson);
    } catch {
      if (this.active(generation)) { this.finish('日程任务未能提交，未自动重试。请检查日历会话。'); await this.calendar.stop().catch((): void => {}); }
    }
  }
  private active(generation: number): boolean { return generation === this.generation && this.view.busy && !this.stopping; }
  authorization(generation: number, prompt: AgentFrontendAuthorizationPrompt): void {
    if (!this.active(generation) || prompt.taskId !== this.taskId) return;
    const preview = this.factory?.previews.resolve(prompt);
    if (preview === undefined || JSON.stringify(preview.draft) !== this.draftJson) { this.unexpected(generation); return; }
    this.prompt = prompt; this.view.preview = preview; this.view.calendarStage = 'authorization';
    this.view.message = '请核对日程。确认后才申请系统权限并写入日历。'; this.publish();
  }
  event(generation: number, event: AgentFrontendEvent): void {
    if (!this.active(generation) || event.taskId !== this.taskId || event.sequence <= this.sequence) return;
    this.sequence = event.sequence;
    if (event.eventType === AgentRuntimeEventType.TASK_COMPLETED) this.apply(AgentTaskStatus.COMPLETED, event.payloadJson);
    else if (event.eventType === AgentRuntimeEventType.TASK_FAILED) this.apply(AgentTaskStatus.FAILED, event.payloadJson);
    else if (event.eventType === AgentRuntimeEventType.TASK_CANCELLED) this.apply(AgentTaskStatus.CANCELLED, event.payloadJson);
    else if (event.eventType === AgentRuntimeEventType.RECONCILIATION_REQUIRED) this.apply(AgentTaskStatus.WAITING_RECONCILIATION, event.payloadJson);
  }
  unexpected(generation: number): void { if (this.active(generation)) void this.cancel(); }
  private apply(status: AgentTaskStatus, raw: string): void {
    if (status === AgentTaskStatus.COMPLETED) {
      const result = parseCalendarToolResult(raw);
      if (result === undefined || !result.verified || result.operationId !== this.view.preview?.operationId) {
        this.finish('日程结果未通过核验，请到工作台核查；不要重复创建。'); return;
      }
      this.finish(`已创建日程并读回核对，系统日程 ID：${result.eventId}。` +
        (result.reminderConfigured ? '提醒配置已核对；实际通知以系统送达为准。' : '提醒配置未核实，请到工作台核查。'), true);
    } else if (status === AgentTaskStatus.FAILED || status === AgentTaskStatus.CANCELLED || status === AgentTaskStatus.WAITING_RECONCILIATION) {
      const result = this.factory?.resultFor(this.taskId);
      const detail = result !== undefined && result.operationId === this.view.preview?.operationId && !result.verified ? result.message : '';
      this.finish(detail || (this.writing ? '日程执行未能确认，请到工作台查看记录并核查；不会自动重试。' : this.declinedMessage()));
    }
  }
  private declinedMessage(): string {
    return this.editingTask === this.taskId ? '原草稿已撤销，尚未创建日程。请修改输入框中的安排后发送，再次核对确认。' : '已取消本次日程，未写入日历。';
  }
  async revise(): Promise<string | undefined> {
    const preview = this.view.preview;
    if (preview === undefined || this.view.calendarStage !== 'authorization' || this.deciding || this.stopping) return undefined;
    const taskId = preview.taskId; const draft = preview.draft;
    const input = `请创建日程：标题“${draft.title}”；开始北京时间 ${draft.startAt.slice(0, 16).replace('T', ' ')}；` +
      `结束北京时间 ${draft.endAt.slice(0, 16).replace('T', ' ')}；` +
      (draft.reminderMinutes === 0 ? '开始时提醒。' : `提前 ${draft.reminderMinutes} 分钟提醒。`);
    if (input.length > 500) return undefined;
    this.editingTask = taskId;
    try {
      const declined = await this.decide(false);
      if (!declined || this.taskId !== taskId || this.view.busy || this.stopping || this.view.lifecycle !== ShuviRuntimeState.READY) return undefined;
      this.context.clear(); return input;
    } finally { if (this.editingTask === taskId) this.editingTask = ''; }
  }
  async decide(approved: boolean): Promise<boolean> {
    const prompt = this.prompt; const generation = this.generation;
    if (this.deciding || prompt === undefined || !this.active(generation) || this.view.calendarStage !== 'authorization') return false;
    if (approved && this.factory?.previews.resolve(prompt) === undefined) {
      await this.cancel();
      if (this.taskId === prompt.taskId && !this.view.busy && !this.stopping) {
        this.view.message = '确认已过期，未创建日程。请重新发送安排。'; this.publish();
      }
      return false;
    }
    this.deciding = true; this.writing = approved;
    this.view.calendarStage = approved ? 'writing' : 'cancelling';
    this.view.message = approved ? '正在创建日程并核对…' : (this.editingTask === this.taskId ? '正在撤销原草稿…' : '正在取消日程…'); this.publish();
    try {
      const receipt = await this.calendar.authorize(prompt, approved);
      if (!this.active(generation)) return receipt.accepted && this.taskId === prompt.taskId && !this.stopping && this.view.lifecycle === ShuviRuntimeState.READY;
      if (!receipt.accepted) { await this.cancel(); return false; }
      this.prompt = undefined;
      if (!approved) this.finish(this.declinedMessage());
      return true;
    } catch { if (this.active(generation)) await this.cancel(); return false; }
    finally { this.deciding = false; }
  }
  private finish(message: string, succeeded: boolean = false): void {
    ++this.generation; this.subscription?.close(); this.subscription = undefined;
    if (this.timer !== undefined) clearTimeout(this.timer); this.timer = undefined;
    this.factory?.previews.clear(); this.prompt = undefined; this.view.preview = undefined;
    this.view.busy = false; this.view.calendarStage = 'idle'; this.view.reply = message; this.view.replyId++;
    this.view.succeeded = succeeded;
    this.view.message = this.view.lifecycle === ShuviRuntimeState.READY && !this.stopping ?
      '助手已就绪；可继续提问或安排日程。' : this.model.snapshot().message;
    this.publish();
  }
  async cancel(): Promise<void> {
    if (!this.view.busy) return;
    this.awaiting = false; this.context.clear();
    if (this.view.calendarStage === 'idle') {
      await this.model.cancel(); this.finish('已取消本次回答，未写入日历；已发送的模型请求可能计费。'); return;
    }
    const id = this.taskId; const generation = this.generation;
    try {
      if (!id) { await this.calendar.stop(); }
      else {
        const receipt = await this.calendar.cancel(id);
        if (!receipt.accepted && this.active(generation)) {
          const state = await this.calendar.getTask(id); if (this.active(generation)) this.apply(state.status, state.resultJson);
          if (this.active(generation)) await this.calendar.stop();
        }
      }
    } catch { await this.calendar.stop().catch((): void => {}); }
    if (this.active(generation)) this.finish(this.writing ? '已停止等待；日历可能已写入，请到工作台核查，勿重复创建。' : '已取消日程，未写入日历。');
  }
  stop(): Promise<void> {
    if (this.closing !== undefined) return this.closing;
    this.stopping = true; this.closing = this.stopOnce(); return this.closing;
  }
  private async stopOnce(): Promise<void> {
    const pending = this.view.busy; const writing = this.writing && this.view.calendarStage !== 'idle';
    this.awaiting = false; this.context.clear(); this.stopping = true; ++this.generation;
    this.view.lifecycle = ShuviRuntimeState.STOPPING; this.view.message = '正在停止并清理会话…'; this.publish();
    this.subscription?.close(); this.subscription = undefined; if (this.timer !== undefined) clearTimeout(this.timer); this.timer = undefined;
    let failed = false;
    try { await this.calendar.stop(); } catch { failed = true; }
    try { await this.model.stop(); } catch { failed = true; }
    this.stopping = false; this.view.lifecycle = failed ? ShuviRuntimeState.BLOCKED : ShuviRuntimeState.STOPPED;
    if (pending) this.finish(writing ? '会话已停止；日历可能已写入，请到工作台核查。' : '会话已停止，本次未写入日历；模型请求可能计费。');
    this.view.busy = false; this.view.preview = undefined; this.view.calendarStage = 'idle';
    this.view.message = failed ? '资源关闭未确认，请重启排查。' : '会话已停止。'; this.publish();
    this.closing = undefined;
  }
}
