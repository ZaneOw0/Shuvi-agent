import { DEBUG } from 'BuildProfile';
import { Theme } from './Theme';
import { CalendarDraftService } from '../services/calendar/CalendarDraftService';
import { CalendarDraftView } from '../services/calendar/CalendarDraftSession';
import { CalendarProbeDraft } from '../services/calendar/CalendarProbeSession';
import { ShuviRuntimeState } from '../services/model/ShuviRuntimeController';
import { DeepSeekKeyService, DeepSeekKeyStatus } from '../services/model/DeepSeekCredentialStore';

/**
 * One-sentence draft inside the calendar "new schedule" form; the result fills the form for review. The session connects
 * with the DeepSeek key saved in 我的 → API Key 管理 when the panel opens; connecting sends no model request.
 */
@Component
export struct CalendarDraftPanel {
  @State view: CalendarDraftView = new CalendarDraftView();
  @State description: string = '';
  @State details: boolean = false;
  @State keyStatus: DeepSeekKeyStatus = DeepSeekKeyStatus.Checking;
  @State connecting: boolean = false;
  /** Only messages produced while this panel is shown; a stopped session from an earlier visit stays quiet. */
  @State active: boolean = false;
  onDraft: (draft: CalendarProbeDraft) => void = (_draft: CalendarProbeDraft): void => {};
  onBusy: (busy: boolean) => void = (_busy: boolean): void => {};
  onKeys: () => void = (): void => {};
  private alive: boolean = true;
  aboutToAppear(): void {
    CalendarDraftService.session.attach((value: CalendarDraftView): void => {
      this.view = value;
      if (value.busy || value.lifecycle === ShuviRuntimeState.STARTING || value.lifecycle === ShuviRuntimeState.READY) {
        this.active = true;
      }
      this.onBusy(value.busy || value.lifecycle === ShuviRuntimeState.STARTING ||
        value.lifecycle === ShuviRuntimeState.STOPPING);
    }, (draft: CalendarProbeDraft): void => this.onDraft(draft));
    void this.connect();
  }
  aboutToDisappear(): void {
    this.alive = false; this.description = ''; CalendarDraftService.session.detachView(); this.onBusy(false);
  }
  private disconnected(): boolean {
    return this.view.lifecycle === ShuviRuntimeState.IDLE || this.view.lifecycle === ShuviRuntimeState.STOPPED ||
      this.view.lifecycle === ShuviRuntimeState.FAILED;
  }
  /** Starts the draft session with the saved key; a failed start is retried only when the user taps 重新连接. */
  private async connect(retry: boolean = false): Promise<void> {
    if (this.connecting || !this.alive) { return; }
    if (!this.disconnected() || (this.view.lifecycle === ShuviRuntimeState.FAILED && !retry)) { return; }
    this.connecting = true;
    try {
      try { this.keyStatus = await DeepSeekKeyService.store.status(); } catch { this.keyStatus = DeepSeekKeyStatus.Unavailable; }
      if (this.keyStatus !== DeepSeekKeyStatus.Saved || !this.alive) { return; }
      const key: Uint8Array | undefined = await DeepSeekKeyService.store.load();
      if (key === undefined) { this.keyStatus = DeepSeekKeyStatus.Missing; return; }
      try {
        const context = this.getUIContext().getHostContext();
        if (context !== undefined && this.alive) { await CalendarDraftService.start(context, DEBUG, key); }
      } finally { key.fill(0); }
    } catch {
      // The session view carries the failure message; the key stays only in the device store.
    } finally { this.connecting = false; }
  }
  private statusShown(): boolean {
    return this.view.message.length > 0 && (this.active || this.view.lifecycle === ShuviRuntimeState.BLOCKED ||
      this.view.lifecycle === ShuviRuntimeState.FAILED);
  }
  build() {
    Column({ space: 10 }) {
      Text('说一句日期、起止时间和提醒，生成后回填下方表单，由你核对。').fontSize(13).fontColor(Theme.muted).width('100%')
      Button(this.details ? '收起说明 ▴' : '范围与费用 ▾').fontSize(Theme.noteSize).fontColor(Theme.accent)
        .backgroundColor(Color.Transparent).padding({ left: 0, right: 0 }).constraintSize({ minHeight: 32 })
        .id('calendar-draft-details').onClick((): void => { this.details = !this.details; })
      if (this.details) {
        Column({ space: 6 }) {
          Text('生成时只把这句描述、当前时间和时区发送给 DeepSeek，不发送历史日历、联系人或知识库；可能产生费用，以供应商账单为准。')
            .fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
          Text('模型只生成草稿，核对并确认后才写入日历。离开日程页或应用退到后台时，本次连接会断开。')
            .fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
        }.width('100%').padding(10).backgroundColor(Theme.surface).borderRadius(Theme.radius)
      }
      if (this.keyStatus === DeepSeekKeyStatus.Missing || this.keyStatus === DeepSeekKeyStatus.Unavailable) {
        Text(this.keyStatus === DeepSeekKeyStatus.Unavailable ? '本机安全存储暂时不可用，请稍后重试。' :
          '需要先在「我的 → API Key 管理」保存 DeepSeek Key。').fontSize(13).fontColor(Theme.ink).width('100%')
        Button('去设置').width('100%').constraintSize({ minHeight: Theme.controlHeight }).borderRadius(Theme.radius)
          .backgroundColor(Theme.soft).fontColor(Theme.accent).id('calendar-draft-open-keys')
          .onClick((): void => { this.onKeys(); })
      } else if (this.connecting || this.view.lifecycle === ShuviRuntimeState.STARTING ||
        this.view.lifecycle === ShuviRuntimeState.STOPPING) {
        Text(this.view.lifecycle === ShuviRuntimeState.STOPPING ? '正在断开…' : '正在连接…').fontSize(13).fontColor(Theme.muted)
      } else if (this.disconnected()) {
        Button(this.view.lifecycle === ShuviRuntimeState.FAILED ? '重新连接' : '连接').width('100%')
          .constraintSize({ minHeight: Theme.controlHeight }).borderRadius(Theme.radius)
          .backgroundColor(Theme.soft).fontColor(Theme.accent).id('calendar-draft-connect')
          .onClick((): void => { void this.connect(true); })
      }
      TextArea({ text: this.description, placeholder: '例如：明天下午三点到四点项目讨论，提前十分钟提醒' })
        .maxLength(500).constraintSize({ minHeight: 72 }).fontSize(Theme.bodySize).enabled(!this.view.busy)
        .backgroundColor(Theme.surface).border({ width: 1, color: Theme.line, radius: Theme.radius })
        .onChange((value: string): void => { this.description = value; })
        .accessibilityText('描述单次日程，包含日期、起止时间和提醒分钟数').id('calendar-draft-description')
      if (this.view.busy) {
        Button('停止生成').width('100%').constraintSize({ minHeight: Theme.controlHeight }).borderRadius(Theme.radius)
          .backgroundColor(Theme.soft).fontColor(Theme.accent)
          .onClick((): void => { void CalendarDraftService.session.cancel().catch((): void => {}); })
          .id('calendar-draft-stop')
      } else {
        Button('生成草稿').width('100%').constraintSize({ minHeight: Theme.controlHeight }).borderRadius(Theme.radius)
          .backgroundColor(Theme.accent).fontColor(Color.White)
          .enabled(this.view.lifecycle === ShuviRuntimeState.READY && this.description.trim().length > 0)
          .onClick((): void => { void CalendarDraftService.session.generate(this.description, true); })
          .id('calendar-draft-generate')
      }
      if (this.statusShown()) {
        Text(this.view.message).fontSize(13).fontColor(Theme.ink).width('100%').id('calendar-draft-status')
      }
    }.width('100%').padding(12).alignItems(HorizontalAlign.Start)
      .backgroundColor(Theme.inputSurface).borderRadius(Theme.radius)
  }
}
