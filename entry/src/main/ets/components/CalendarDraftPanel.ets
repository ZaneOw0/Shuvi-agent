import util from '@ohos.util';
import { DEBUG } from 'BuildProfile';
import { Theme } from './Theme';
import { CalendarDraftService } from '../services/calendar/CalendarDraftService';
import { CalendarDraftView } from '../services/calendar/CalendarDraftSession';
import { CalendarProbeDraft } from '../services/calendar/CalendarProbeSession';
import { ShuviRuntimeState } from '../services/model/ShuviRuntimeController';

@Component
export struct CalendarDraftPanel {
  @State view: CalendarDraftView = new CalendarDraftView();
  @State apiKey: string = '';
  @State description: string = '';
  onDraft: (draft: CalendarProbeDraft) => void = (_draft: CalendarProbeDraft): void => {};
  onBusy: (busy: boolean) => void = (_busy: boolean): void => {};
  aboutToAppear(): void {
    CalendarDraftService.session.attach((value: CalendarDraftView): void => {
      if (value.clearEpoch !== this.view.clearEpoch) this.apiKey = '';
      this.view = value; this.onBusy(value.busy || value.lifecycle === ShuviRuntimeState.STARTING ||
        value.lifecycle === ShuviRuntimeState.STOPPING);
    }, (draft: CalendarProbeDraft): void => this.onDraft(draft));
  }
  aboutToDisappear(): void {
    this.apiKey = ''; this.description = ''; CalendarDraftService.session.detachView(); this.onBusy(false);
  }
  private async enable(): Promise<void> {
    const key = new util.TextEncoder().encodeInto(this.apiKey); this.apiKey = '';
    try {
      const context = this.getUIContext().getHostContext();
      if (context !== undefined) await CalendarDraftService.start(context, DEBUG, key);
    } finally { key.fill(0); }
  }
  build() {
    Column({ space: 10 }) {
      Text('用一句话安排日程 · 调试').fontSize(16).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
      Text('生成时会把本次日程描述、当前时间和时区发送给 DeepSeek（deepseek-flash）。日程可能包含个人信息；不发送历史日历、联系人或知识库。描述与模型结果保存在本机加密执行记录中。')
        .fontSize(12).fontColor(Theme.muted).width('100%')
      Text('每次启用最多 10 次请求，不自动重试。最多 500 字符、1024 输出 tokens，模型超时 30 秒；本地预算检查 USD 0.01/次为估算，实际扣费以供应商账单为准，取消也可能计费。')
        .fontSize(12).fontColor(Theme.muted).width('100%')
      if (this.view.lifecycle !== ShuviRuntimeState.READY) {
        TextInput({ text: this.apiKey, placeholder: 'DeepSeek API Key，仅本次会话' })
          .type(InputType.Password).showPasswordIcon(false).copyOption(CopyOptions.None).selectionMenuHidden(false)
          .enableAutoFill(false).enablePreviewText(false).maxLength(2048)
          .enabled(this.view.lifecycle !== ShuviRuntimeState.STARTING && this.view.lifecycle !== ShuviRuntimeState.STOPPING)
          .onChange((value: string): void => { this.apiKey = value; })
          .accessibilityText('日程草稿 API Key，仅本次会话，允许粘贴').id('calendar-draft-key')
        Button('启用草稿生成（暂不发送）').backgroundColor(Theme.soft).fontColor(Theme.accent)
          .enabled(this.apiKey.trim().length > 0 && this.view.lifecycle !== ShuviRuntimeState.STARTING &&
            this.view.lifecycle !== ShuviRuntimeState.STOPPING && this.view.lifecycle !== ShuviRuntimeState.BLOCKED)
          .onClick((): void => { void this.enable(); }).id('calendar-draft-enable')
      }
      TextArea({ text: this.description, placeholder: '例如：明天下午三点到四点项目讨论，提前十分钟提醒' })
        .maxLength(500).constraintSize({ minHeight: 96 }).enabled(!this.view.busy)
        .onChange((value: string): void => { this.description = value; })
        .accessibilityText('描述单次日程，包含日期、起止时间和提醒分钟数').id('calendar-draft-description')
      if (this.view.busy) {
        Button('停止生成').backgroundColor(Theme.soft).fontColor(Theme.accent)
          .onClick((): void => { void CalendarDraftService.session.cancel().catch((): void => {}); })
          .id('calendar-draft-stop')
      } else {
        Button('同意发送并生成草稿').backgroundColor(Theme.accent).fontColor(Color.White)
          .enabled(this.view.lifecycle === ShuviRuntimeState.READY && this.description.trim().length > 0)
          .onClick((): void => { void CalendarDraftService.session.generate(this.description, true); })
          .id('calendar-draft-generate')
      }
      Text(this.view.message).fontSize(13).fontColor(Theme.ink).width('100%').id('calendar-draft-status')
      Text('模型仅生成草稿，核对并确认后才写入日历。在本页确认、修改和新建日程复用已启用的会话；离开日历页或退后台才清除凭据，不自动恢复。')
        .fontSize(12).fontColor(Theme.muted).width('100%')
    }.width('100%').padding(12).alignItems(HorizontalAlign.Start)
      .backgroundColor(Theme.soft).borderRadius(12)
  }
}
