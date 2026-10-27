import { Theme } from './Theme';
import { CalendarProbeDraft, CalendarProbeRecord, CalendarProbeResult } from '../services/calendar/CalendarProbeSession';
import { CalendarProbeService } from '../services/calendar/CalendarProbeService';
import { CalendarDraftPanel } from './CalendarDraftPanel';
import { CalendarDraftService } from '../services/calendar/CalendarDraftService';
import { DEBUG } from 'BuildProfile';

@Component
export struct CalendarCapabilityCheck {
  @State result: CalendarProbeResult = new CalendarProbeResult();
  @State title: string = '';
  @State start: string = '';
  @State end: string = '';
  @State reminder: string = '10';
  @State draftBusy: boolean = false;

  aboutToAppear(): void {
    CalendarProbeService.session.attach((value: CalendarProbeResult): void => { this.result = value; });
  }

  aboutToDisappear(): void {
    CalendarDraftService.session.detach();
    CalendarProbeService.session.detach();
  }

  private preview(): void {
    const draft = new CalendarProbeDraft();
    draft.title = this.title;
    draft.startAt = `${this.start.trim().replace(' ', 'T')}:00+08:00`;
    draft.endAt = `${this.end.trim().replace(' ', 'T')}:00+08:00`;
    draft.reminderMinutes = /^\d+$/.test(this.reminder.trim()) ? Number(this.reminder) : NaN;
    CalendarProbeService.session.preview(draft);
  }

  build() {
    Column({ space: 12 }) {
      Text('日历日程').fontSize(22).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
      Text('确认后保存到系统日历 · 支持手动填写')
        .fontSize(12).fontColor(Theme.muted).width('100%')
      Text(this.result.message).fontSize(14).fontColor(Theme.ink).width('100%')
        .id('calendar-probe-status').accessibilityText(this.result.message)
      if (!this.result.locked && !this.result.busy && this.result.phase !== 'confirm') {
        if (DEBUG && this.result.canCreate) {
          CalendarDraftPanel({
            onBusy: (busy: boolean): void => { this.draftBusy = busy; },
            onDraft: (draft: CalendarProbeDraft): void => {
              this.title = draft.title; this.start = draft.startAt.slice(0, 16).replace('T', ' ');
              this.end = draft.endAt.slice(0, 16).replace('T', ' '); this.reminder = String(draft.reminderMinutes);
              CalendarProbeService.session.preview(draft);
            }
          })
        }
        Text('手动填写 / 修改').fontSize(16).fontColor(Theme.ink)
        Text('日程标题').fontSize(13).fontColor(Theme.muted)
        TextInput({ text: this.title, placeholder: '例如：项目讨论' }).maxLength(200).enabled(!this.draftBusy)
          .onChange((value: string): void => { this.title = value; }).id('calendar-probe-title')
          .accessibilityText('日程标题')
        Text('开始时间 · 北京时间（Asia/Shanghai）').fontSize(13).fontColor(Theme.muted)
        TextInput({ text: this.start, placeholder: 'YYYY-MM-DD HH:mm' }).maxLength(16).enabled(!this.draftBusy)
          .onChange((value: string): void => { this.start = value; }).id('calendar-probe-start')
          .accessibilityText('开始时间，格式为年-月-日 空格 时:分')
        Text('结束时间 · 北京时间').fontSize(13).fontColor(Theme.muted)
        TextInput({ text: this.end, placeholder: 'YYYY-MM-DD HH:mm' }).maxLength(16).enabled(!this.draftBusy)
          .onChange((value: string): void => { this.end = value; }).id('calendar-probe-end')
          .accessibilityText('结束时间，格式为年-月-日 空格 时:分')
        Text('提前提醒（分钟，0 表示开始时提醒）').fontSize(13).fontColor(Theme.muted)
        TextInput({ text: this.reminder }).type(InputType.Number).maxLength(5).enabled(!this.draftBusy)
          .onChange((value: string): void => { this.reminder = value; }).id('calendar-probe-reminder')
          .accessibilityText('提前提醒分钟数')
        Button('核对日程').backgroundColor(Theme.accent).fontColor(Color.White)
          .enabled(!this.draftBusy)
          .onClick(() => this.preview()).id('calendar-probe-preview')
      }
      if (this.result.draft !== undefined) {
        Column({ space: 6 }) {
          Text(this.result.draft.title).fontSize(16).fontWeight(FontWeight.Medium)
          Text(`开始：${this.result.draft.startAt}`).fontSize(13)
          Text(`结束：${this.result.draft.endAt}`).fontSize(13)
          Text(`Asia/Shanghai · 提前 ${this.result.draft.reminderMinutes} 分钟提醒`).fontSize(13)
        }.width('100%').padding(12).backgroundColor(Theme.soft).borderRadius(12)
          .alignItems(HorizontalAlign.Start)
      }
      if (this.result.phase === 'confirm' && !this.result.busy) {
        Button('确认并创建真实日程').backgroundColor(Theme.accent).fontColor(Color.White)
          .onClick(() => { void CalendarProbeService.session.confirm(); }).id('calendar-probe-confirm')
        Button('返回修改 / 取消').backgroundColor(Theme.soft).fontColor(Theme.accent)
          .onClick(() => CalendarProbeService.session.cancelDraft()).id('calendar-probe-cancel')
      }
      if (this.result.busy && this.result.phase === 'working') {
        Button('停止后续操作').backgroundColor(Theme.soft).fontColor(Theme.accent)
          .onClick(() => CalendarProbeService.session.stop()).id('calendar-probe-stop')
      }
      if (this.result.eventId > 0) {
        Text(`系统日程 ID：${this.result.eventId}`).fontSize(12).fontColor(Theme.muted)
      }
      if (this.result.locked && this.result.draft !== undefined && !this.result.busy) {
        Button('核查原日程').backgroundColor(Theme.soft).fontColor(Theme.accent)
          .onClick(() => { void CalendarProbeService.session.reconcile(); }).id('calendar-probe-reconcile')
      }
      if (this.result.canCreate && this.result.locked) {
        Button('新建日程').backgroundColor(Theme.accent).fontColor(Color.White)
          .id('calendar-new-draft').onClick((): void => {
            this.title = ''; this.start = ''; this.end = ''; this.reminder = '10';
            CalendarProbeService.session.newDraft();
          })
      }
      if (this.result.records.length > 0) {
        Text(`已记录 ${this.result.records.length} 条操作`).fontSize(16).fontColor(Theme.ink)
        if (this.result.pendingCount > 0) {
          Text('存在待核查操作，核清前暂不能新建日程。').fontSize(13).fontColor(Theme.ink)
        }
        if (this.result.records.length >= 64) {
          Text('当前已达到 64 条记录上限，既有记录保留，可继续核查。').fontSize(13).fontColor(Theme.muted)
        }
        Text('下方为本机保存的核查记录；日程当前状态请点击核查。').fontSize(12).fontColor(Theme.muted)
        ForEach(this.result.records, (record: CalendarProbeRecord) => {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 5 }) {
              Text(record.draft.title).fontSize(15).fontColor(Theme.ink)
              Text(record.draft.startAt).fontSize(12).fontColor(Theme.muted)
              Text(record.verified ? (record.reminderConfigured ? '上次核查：日程和提醒配置一致' :
                '上次核查：日程一致，提醒配置待核对') : '结果待核查').fontSize(12).fontColor(Theme.muted)
            }.alignItems(HorizontalAlign.Start).padding(12).width('100%')
          }.width('100%').backgroundColor(Theme.soft).borderRadius(12).enabled(!this.result.busy && !this.draftBusy)
            .id(`calendar-record-${record.operationId}`)
            .onClick((): void => CalendarProbeService.session.select(record.operationId))
        }, (record: CalendarProbeRecord): string => record.operationId)
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16)
      .backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line })
  }
}
