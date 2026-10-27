import { DEBUG } from 'BuildProfile';
import { Theme } from './Theme';
import { DeepSeekKeyField } from './DeepSeekKeyField';
import { CalendarDraftService } from '../services/calendar/CalendarDraftService';
import { CalendarDraftView } from '../services/calendar/CalendarDraftSession';
import { CalendarProbeDraft } from '../services/calendar/CalendarProbeSession';
import { ShuviRuntimeState } from '../services/model/ShuviRuntimeController';

/** One-sentence draft inside the workbench "new schedule" form; the result fills the form for review. */
@Component
export struct CalendarDraftPanel {
  @State view: CalendarDraftView = new CalendarDraftView();
  @State description: string = '';
  @State details: boolean = false;
  /** Only messages produced while this panel is shown; a stopped session from an earlier visit stays quiet. */
  @State active: boolean = false;
  onDraft: (draft: CalendarProbeDraft) => void = (_draft: CalendarProbeDraft): void => {};
  onBusy: (busy: boolean) => void = (_busy: boolean): void => {};
  aboutToAppear(): void {
    CalendarDraftService.session.attach((value: CalendarDraftView): void => {
      this.view = value;
      if (value.busy || value.lifecycle === ShuviRuntimeState.STARTING || value.lifecycle === ShuviRuntimeState.READY) {
        this.active = true;
      }
      this.onBusy(value.busy || value.lifecycle === ShuviRuntimeState.STARTING ||
        value.lifecycle === ShuviRuntimeState.STOPPING);
    }, (draft: CalendarProbeDraft): void => this.onDraft(draft));
  }
  aboutToDisappear(): void {
    this.description = ''; CalendarDraftService.session.detachView(); this.onBusy(false);
  }
  private async enable(key: Uint8Array): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext();
      if (context !== undefined) { await CalendarDraftService.start(context, DEBUG, key); }
    } finally { key.fill(0); }
  }
  private keyNeeded(): boolean {
    return this.view.lifecycle === ShuviRuntimeState.IDLE || this.view.lifecycle === ShuviRuntimeState.STOPPED ||
      this.view.lifecycle === ShuviRuntimeState.FAILED;
  }
  private statusShown(): boolean {
    return this.view.message.length > 0 && (this.active || this.view.lifecycle === ShuviRuntimeState.BLOCKED ||
      this.view.lifecycle === ShuviRuntimeState.FAILED);
  }
  build() {
    Column({ space: 10 }) {
      Text('说一句日期、起止时间和提醒，生成后回填下方表单，由你核对。').fontSize(13).fontColor(Theme.muted).width('100%')
      Button(this.details ? '收起范围与费用 ▴' : '了解范围与费用 ▾').fontSize(Theme.noteSize).fontColor(Theme.accent)
        .backgroundColor(Color.Transparent).padding({ left: 0, right: 0 }).constraintSize({ minHeight: 32 })
        .id('calendar-draft-details').onClick((): void => { this.details = !this.details; })
      if (this.details) {
        Column({ space: 6 }) {
          Text('生成时会把本次日程描述、当前时间和时区发送给 DeepSeek（deepseek-flash）。日程可能包含个人信息；不发送历史日历、联系人或知识库。描述与模型结果保存在本机加密执行记录中。')
            .fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
          Text('每次启用最多 10 次请求，不自动重试。最多 500 字符、1024 输出 tokens，模型超时 30 秒；本地预算检查 USD 0.01/次为估算，实际扣费以供应商账单为准，取消也可能计费。')
            .fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
          Text('模型只生成草稿，核对并确认后才写入日历。本页内确认、修改和新建复用已启用的会话；离开日历页或退后台才清除凭据，不自动恢复。')
            .fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
        }.width('100%').padding(10).backgroundColor(Theme.surface).borderRadius(Theme.radius)
      }
      if (this.keyNeeded()) {
        DeepSeekKeyField({ clearEpoch: this.view.clearEpoch, enableLabel: '同意并启用（暂不发送）', idPrefix: 'calendar-draft',
          purpose: '日程草稿', onKey: (key: Uint8Array): void => { void this.enable(key); } })
      } else if (this.view.lifecycle === ShuviRuntimeState.STARTING || this.view.lifecycle === ShuviRuntimeState.STOPPING) {
        Text(this.view.lifecycle === ShuviRuntimeState.STARTING ? '正在启用…' : '正在停止…').fontSize(13).fontColor(Theme.muted)
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
        Button('同意发送并生成草稿').width('100%').constraintSize({ minHeight: Theme.controlHeight }).borderRadius(Theme.radius)
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
