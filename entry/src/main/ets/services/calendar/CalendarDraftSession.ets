import { RuntimeChatSession, RuntimeChatView } from '../model/RuntimeChatSession';
import { ShuviRuntimeController, ShuviRuntimeState } from '../model/ShuviRuntimeController';
import { ShuviRuntimeSessionFactory } from '../model/ShuviRuntimeSession';
import { CalendarDraftContext, parseCalendarProposal } from './CalendarDraftContract';
import { CalendarProbeDraft } from './CalendarProbeSession';

export class CalendarDraftView {
  lifecycle: ShuviRuntimeState = ShuviRuntimeState.IDLE;
  busy: boolean = false;
  message: string = '可手动填写，或启用模型生成待确认草稿。';
  clearEpoch: number = 0;
}

/** Owns only draft generation; there is deliberately no calendar write port here. */
export class CalendarDraftSession {
  readonly context: CalendarDraftContext = new CalendarDraftContext();
  private readonly chat: RuntimeChatSession;
  private view: CalendarDraftView = new CalendarDraftView();
  private seenReply: number = 0;
  private awaiting: boolean = false;
  private listener?: (view: CalendarDraftView) => void;
  private proposalListener?: (draft: CalendarProbeDraft) => void;
  constructor(controller: ShuviRuntimeController) {
    this.chat = new RuntimeChatSession(controller);
    this.chat.attach((value: RuntimeChatView): void => this.update(value));
  }
  attach(listener: (view: CalendarDraftView) => void, proposal: (draft: CalendarProbeDraft) => void): void {
    this.listener = listener; this.proposalListener = proposal; this.publish();
  }
  // A draft panel is removed when the same page displays confirmation/history.
  // Its disappearance is not a page exit and must not tear down an idle model session.
  detachView(): void {
    this.listener = undefined; this.proposalListener = undefined;
    const unfinished = this.awaiting || this.view.busy;
    this.awaiting = false; this.context.clear();
    if (unfinished) void this.stop().catch((): void => {});
  }
  detach(): void {
    this.listener = undefined; this.proposalListener = undefined;
    this.awaiting = false; this.context.clear(); void this.stop().catch((): void => {});
  }
  snapshot(): CalendarDraftView {
    const copy = new CalendarDraftView(); copy.lifecycle = this.view.lifecycle; copy.busy = this.view.busy;
    copy.message = this.view.message; copy.clearEpoch = this.view.clearEpoch; return copy;
  }
  private publish(): void { this.listener?.(this.snapshot()); }
  private update(value: RuntimeChatView): void {
    this.view.lifecycle = value.lifecycle; this.view.busy = value.busy; this.view.clearEpoch = value.clearEpoch;
    if (value.replyId > this.seenReply) {
      this.seenReply = value.replyId;
      const accepted = this.awaiting; this.awaiting = false; this.context.clear();
      if (accepted) {
        if (value.succeeded) {
          const proposal = parseCalendarProposal(value.reply, Date.now()); this.view.message = proposal.message;
          if (proposal.draft !== undefined) this.proposalListener?.(proposal.draft);
        } else this.view.message = value.reply;
      }
    } else if (value.busy) this.view.message = '正在生成草稿；尚未写入日历…';
    else if (value.lifecycle !== ShuviRuntimeState.READY) {
      this.awaiting = false; this.context.clear();
      this.view.message = value.lifecycle === ShuviRuntimeState.STARTING ? '正在启用草稿生成…' :
        '草稿生成尚未启用或会话已停止；可重新启用，也可手动填写。';
    }
    this.publish();
  }
  async start(factory: ShuviRuntimeSessionFactory, key: Uint8Array): Promise<void> {
    await this.chat.start(factory, key);
    if (this.view.lifecycle === ShuviRuntimeState.READY) {
      this.view.message = '已就绪；点击“同意发送并生成草稿”才调用模型。'; this.publish();
    }
  }
  async generate(input: string, approved: boolean): Promise<void> {
    if (this.view.busy) return;
    if (!approved || this.view.lifecycle !== ShuviRuntimeState.READY || !input.trim() || input.length > 500) {
      this.view.message = '请先启用模型，并明确同意发送本次 1–500 字符的描述。'; this.publish(); return;
    }
    this.context.bind(input, Date.now()); this.awaiting = true;
    await this.chat.send(input);
  }
  async stop(): Promise<void> {
    // Revoke delivery before stopping: even a completed task racing cancellation cannot create a proposal.
    this.awaiting = false; this.context.clear();
    this.view.message = '已停止草稿生成，未写入日历；已发送请求仍可能计费。'; this.publish();
    await this.chat.stop();
  }
  async cancel(): Promise<void> {
    this.awaiting = false; this.context.clear();
    this.view.message = '已取消本次生成，未写入日历；已发送请求仍可能计费。'; this.publish();
    await this.chat.cancel();
  }
}
