import { Theme } from './Theme';
import { CalendarProbeDraft, CalendarProbeRecord, CalendarProbeResult } from '../services/calendar/CalendarProbeSession';
import { CalendarProbeService } from '../services/calendar/CalendarProbeService';
import { CalendarDraftPanel } from './CalendarDraftPanel';
import { CalendarDraftService } from '../services/calendar/CalendarDraftService';
import { CalendarFieldButton } from './CalendarFieldButton';
import { CalendarRecordItem } from './CalendarRecordItem';
import {
  CALENDAR_REMINDER_CHOICES, CalendarRecordGroup, CalendarRecordRow, CalendarRecordSections, calendarDateText,
  calendarDefaultSlot, calendarFormDraft, calendarRecordSections, calendarReminderText, calendarShiftedEnd, calendarTwoDigits,
  calendarWhenText
} from '../services/calendar/CalendarPresentation';
import { DEBUG } from 'BuildProfile';

const UPCOMING_LIMIT: number = 5;
const TOAST_PHASES: string[] = ['failed', 'working', 'stopping', 'loading', 'partial', 'verified'];
const WARNING_PHASES: string[] = ['failed', 'unknown', 'partial'];
const ROW_RESULT_PHASES: string[] = ['working', 'stopping', 'verified', 'partial', 'unknown'];

function rowKey(row: CalendarRecordRow): string { return `${row.operationId}:${row.status}:${row.eventId}:${row.time}`; }
function groupKey(group: CalendarRecordGroup): string {
  return group.key + '|' + group.rows.map((row: CalendarRecordRow): string => rowKey(row)).join(',');
}

/**
 * The 日程 page: Shuvi's schedules grouped by day (one line each, expanding in place), a folded "new schedule"
 * form with pickers, and the same confirm → write → read-back session as before. Session rules are unchanged.
 */
@Component
export struct CalendarCapabilityCheck {
  /** Opens 我的 → API Key 管理 when the one-sentence draft needs the DeepSeek key. */
  onKeys: () => void = (): void => {};
  @State result: CalendarProbeResult = new CalendarProbeResult();
  @State sections: CalendarRecordSections = new CalendarRecordSections();
  @State title: string = '';
  @State startDate: string = '';
  @State startTime: string = '';
  @State endDate: string = '';
  @State endTime: string = '';
  @State reminder: number = 10;
  @State reminderChoices: number[] = CALENDAR_REMINDER_CHOICES;
  @State draftBusy: boolean = false;
  @State formOpen: boolean = false;
  @State quickOpen: boolean = false;
  @State expandedId: string = '';
  @State showAll: boolean = false;
  @State pastOpen: boolean = false;
  /** 'reconcile' keeps that result next to its row; a creation is announced at the top. */
  @State lastAction: string = '';
  /** The state replayed on attach is old news; only later messages are shown as a status strip. */
  private replayed: string | undefined = undefined;

  aboutToAppear(): void {
    this.resetForm();
    CalendarProbeService.session.attach((value: CalendarProbeResult): void => {
      const first: boolean = this.replayed === undefined;
      if (first) { this.replayed = value.message; }
      this.result = value;
      if (value.locked) { this.formOpen = false; }
      // Open the record a new result is about; on load the session also "restores" the last verified record,
      // which needs no attention, so only an unverified one opens by itself.
      if (!first && value.operationId.length > 0 &&
        (value.phase === 'verified' || value.phase === 'partial' || (value.phase === 'unknown' && this.selectedUnverified(value)))) {
        this.expandedId = value.operationId;
      }
      this.refreshSections();
    });
  }

  private selectedUnverified(value: CalendarProbeResult): boolean {
    const record: CalendarProbeRecord | undefined =
      value.records.find((item: CalendarProbeRecord): boolean => item.operationId === value.operationId);
    return record !== undefined && !record.verified;
  }

  aboutToDisappear(): void {
    CalendarDraftService.session.detach();
    CalendarProbeService.session.detach();
  }

  private refreshSections(): void {
    this.sections = calendarRecordSections(this.result.records, Date.now(), this.showAll ? 64 : UPCOMING_LIMIT);
  }

  private resetForm(): void {
    const slot: string[] = calendarDefaultSlot(Date.now());
    this.title = ''; this.startDate = slot[0]; this.startTime = slot[1]; this.endDate = slot[2]; this.endTime = slot[3];
    this.reminder = 10; this.reminderChoices = CALENDAR_REMINDER_CHOICES;
  }

  private fillForm(draft: CalendarProbeDraft): void {
    this.title = draft.title;
    this.startDate = draft.startAt.slice(0, 10); this.startTime = draft.startAt.slice(11, 16);
    this.endDate = draft.endAt.slice(0, 10); this.endTime = draft.endAt.slice(11, 16);
    this.reminder = draft.reminderMinutes;
    this.reminderChoices = CALENDAR_REMINDER_CHOICES.indexOf(draft.reminderMinutes) >= 0 ? CALENDAR_REMINDER_CHOICES :
      CALENDAR_REMINDER_CHOICES.concat([draft.reminderMinutes]).sort((a: number, b: number): number => a - b);
  }

  private formVisible(): boolean {
    return this.result.canCreate && !this.result.locked && !this.result.busy && this.result.phase !== 'confirm' &&
      (this.formOpen || this.result.records.length === 0);
  }

  private newVisible(): boolean {
    return this.result.canCreate && !this.formVisible() && this.result.phase !== 'confirm' && !this.result.busy;
  }

  private openForm(): void {
    if (this.result.locked) { CalendarProbeService.session.newDraft(); }
    this.resetForm(); this.quickOpen = false; this.formOpen = true; this.expandedId = ''; this.lastAction = '';
  }

  private reconcileResult(): boolean {
    return this.lastAction === 'reconcile' && this.result.locked && ROW_RESULT_PHASES.indexOf(this.result.phase) >= 0;
  }

  private rowNote(operationId: string): string {
    return this.reconcileResult() && this.result.operationId === operationId && this.result.message !== this.replayed ?
      this.result.message : '';
  }

  private startReconcile(): void {
    this.lastAction = 'reconcile';
    void CalendarProbeService.session.reconcile();
  }

  private toastVisible(): boolean {
    const value: CalendarProbeResult = this.result;
    if (value.message === this.replayed || this.reconcileResult()) { return false; }
    if (TOAST_PHASES.indexOf(value.phase) >= 0) { return true; }
    return value.phase === 'unknown' && this.selectedUnverified(value);
  }

  private toastBackground(): string {
    return WARNING_PHASES.indexOf(this.result.phase) >= 0 ? Theme.warning :
      (this.result.phase === 'verified' ? Theme.okSoft : Theme.inputSurface);
  }

  private toastColor(): string {
    return WARNING_PHASES.indexOf(this.result.phase) >= 0 ? Theme.amber : (this.result.phase === 'verified' ? Theme.ok : Theme.ink);
  }

  private tapRecord(operationId: string): void {
    this.lastAction = '';
    if (this.expandedId === operationId) { this.expandedId = ''; return; }
    CalendarProbeService.session.select(operationId);
    this.formOpen = false; this.expandedId = operationId;
  }

  private rowsDisabled(): boolean { return this.result.busy || this.draftBusy || this.result.phase === 'confirm'; }

  private pickDate(start: boolean): void {
    const value: string = start ? this.startDate : this.endDate;
    const parts: number[] = value.split('-').map((item: string): number => Number(item));
    const startParts: number[] = this.startDate.split('-').map((item: string): number => Number(item));
    const now: Date = new Date();
    this.getUIContext().showDatePickerDialog({
      start: start ? new Date(now.getFullYear(), now.getMonth(), now.getDate()) : new Date(startParts[0], startParts[1] - 1, startParts[2]),
      end: new Date(now.getFullYear() + 5, 11, 31),
      selected: new Date(parts[0], parts[1] - 1, parts[2]),
      onDateAccept: (picked: Date): void => {
        const date: string = `${picked.getFullYear()}-${calendarTwoDigits(picked.getMonth() + 1)}-${calendarTwoDigits(picked.getDate())}`;
        if (start) { this.moveStart(date, this.startTime); } else { this.endDate = date; }
      }
    });
  }

  private pickTime(start: boolean): void {
    const date: string = start ? this.startDate : this.endDate;
    const time: string = start ? this.startTime : this.endTime;
    const day: number[] = date.split('-').map((item: string): number => Number(item));
    // The picker titles itself with the date of `selected`, so build it on the edited day.
    const selected: Date = new Date(day[0], day[1] - 1, day[2], Number(time.slice(0, 2)), Number(time.slice(3, 5)), 0, 0);
    this.getUIContext().showTimePickerDialog({
      selected: selected, useMilitaryTime: true,
      onAccept: (value: TimePickerResult): void => {
        const text: string = `${calendarTwoDigits(value.hour)}:${calendarTwoDigits(value.minute)}`;
        if (start) { this.moveStart(this.startDate, text); } else { this.endTime = text; }
      }
    });
  }

  /** Moving the start keeps the duration, as calendar apps do. */
  private moveStart(date: string, time: string): void {
    const end: string[] = calendarShiftedEnd(this.startDate, this.startTime, this.endDate, this.endTime, date, time);
    this.startDate = date; this.startTime = time; this.endDate = end[0]; this.endTime = end[1];
  }

  private preview(): void {
    CalendarProbeService.session.preview(
      calendarFormDraft(this.title, this.startDate, this.startTime, this.endDate, this.endTime, this.reminder));
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('日历日程').fontSize(20).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
          Text('写入系统日历中的 Shuvi 专用日历，创建前都会请你确认').fontSize(Theme.noteSize).fontColor(Theme.muted)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        if (this.newVisible()) {
          Button('＋ 新建').fontSize(14).fontColor(Color.White).backgroundColor(Theme.accent).borderRadius(Theme.radius)
            .constraintSize({ minHeight: Theme.controlHeight }).id('calendar-new-draft').onClick((): void => this.openForm())
        }
      }.width('100%')

      if (this.toastVisible()) {
        Text(this.result.message).fontSize(13).fontColor(this.toastColor()).width('100%').padding(10)
          .backgroundColor(this.toastBackground()).borderRadius(Theme.radius)
          .id('calendar-probe-status').accessibilityText(this.result.message)
      }
      if (this.result.busy && this.result.phase === 'working') {
        Button('停止后续操作').width('100%').constraintSize({ minHeight: Theme.controlHeight }).borderRadius(Theme.radius)
          .backgroundColor(Theme.soft).fontColor(Theme.accent)
          .onClick((): void => CalendarProbeService.session.stop()).id('calendar-probe-stop')
      }

      if (this.formVisible()) {
        Column({ space: 10 }) {
          Row() {
            Text('新建日程').fontSize(Theme.titleSize).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
            Blank()
            if (this.result.records.length > 0) {
              Button('收起').fontSize(13).fontColor(Theme.muted).backgroundColor(Color.Transparent).enabled(!this.draftBusy)
                .constraintSize({ minHeight: Theme.controlHeight }).id('calendar-form-close')
                .onClick((): void => { this.formOpen = false; })
            }
          }.width('100%')
          if (DEBUG) {
            Row() {
              Text('用一句话安排').fontSize(14).fontColor(Theme.accent)
              Blank()
              Text(this.quickOpen ? '▴' : '▾').fontSize(14).fontColor(Theme.accent)
            }.width('100%').constraintSize({ minHeight: Theme.controlHeight }).padding({ left: 12, right: 12 })
              .backgroundColor(Theme.soft).borderRadius(Theme.radius).id('calendar-quick-toggle')
              .opacity(this.draftBusy ? 0.5 : 1)
              .onClick((): void => { if (!this.draftBusy) { this.quickOpen = !this.quickOpen; } })
            if (this.quickOpen) {
              CalendarDraftPanel({
                onBusy: (busy: boolean): void => { this.draftBusy = busy; },
                onDraft: (draft: CalendarProbeDraft): void => { this.fillForm(draft); CalendarProbeService.session.preview(draft); },
                onKeys: (): void => { this.onKeys(); }
              })
            }
          }
          TextInput({ text: this.title, placeholder: '日程标题，例如：项目讨论' }).maxLength(200).enabled(!this.draftBusy)
            .fontSize(Theme.bodySize).backgroundColor(Theme.inputSurface).border({ width: 1, color: Theme.line, radius: Theme.radius })
            .constraintSize({ minHeight: Theme.controlHeight })
            .onChange((value: string): void => { this.title = value; }).id('calendar-probe-title').accessibilityText('日程标题')
          Row({ space: 8 }) {
            CalendarFieldButton({ label: '开始日期', value: calendarDateText(this.startDate), fieldId: 'calendar-probe-start-date',
              disabled: this.draftBusy, onTap: (): void => this.pickDate(true) }).layoutWeight(3)
            CalendarFieldButton({ label: '开始时间', value: this.startTime, fieldId: 'calendar-probe-start',
              disabled: this.draftBusy, onTap: (): void => this.pickTime(true) }).layoutWeight(2)
          }.width('100%')
          Row({ space: 8 }) {
            CalendarFieldButton({ label: '结束日期', value: calendarDateText(this.endDate), fieldId: 'calendar-probe-end-date',
              disabled: this.draftBusy, onTap: (): void => this.pickDate(false) }).layoutWeight(3)
            CalendarFieldButton({ label: '结束时间', value: this.endTime, fieldId: 'calendar-probe-end',
              disabled: this.draftBusy, onTap: (): void => this.pickTime(false) }).layoutWeight(2)
          }.width('100%')
          Row({ space: 8 }) {
            Text('提醒').fontSize(Theme.noteSize).fontColor(Theme.muted)
            Select(this.reminderChoices.map((minutes: number): SelectOption => ({ value: calendarReminderText(minutes) })))
              .value(calendarReminderText(this.reminder)).selected(this.reminderChoices.indexOf(this.reminder))
              .font({ size: Theme.bodySize }).fontColor(Theme.ink)
              .selectedOptionFont({ size: Theme.bodySize }).optionFont({ size: Theme.bodySize })
              .backgroundColor(Theme.inputSurface).border({ width: 1, color: Theme.line, radius: Theme.radius })
              .constraintSize({ minHeight: Theme.controlHeight }).layoutWeight(1).enabled(!this.draftBusy)
              .id('calendar-probe-reminder')
              .onSelect((index: number): void => { this.reminder = this.reminderChoices[index]; })
          }.width('100%')
          Button('核对日程').width('100%').constraintSize({ minHeight: Theme.controlHeight }).borderRadius(Theme.radius)
            .backgroundColor(Theme.accent).fontColor(Color.White)
            .enabled(!this.draftBusy && this.title.trim().length > 0)
            .onClick((): void => this.preview()).id('calendar-probe-preview')
        }.width('100%').padding(12).alignItems(HorizontalAlign.Start)
          .border({ width: 1, color: Theme.line, radius: Theme.radius })
      }

      if (this.result.phase === 'confirm' && !this.result.busy && this.result.draft !== undefined) {
        Column({ space: 8 }) {
          Text('确认日程').fontSize(Theme.titleSize).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
          Text(this.result.draft?.title ?? '').fontSize(Theme.titleSize).fontColor(Theme.ink).width('100%')
          Text(this.result.draft === undefined ? '' : calendarWhenText(this.result.draft)).fontSize(Theme.bodySize)
            .fontColor(Theme.ink).width('100%')
          Text(calendarReminderText(this.result.draft?.reminderMinutes ?? 0)).fontSize(13).fontColor(Theme.muted)
          Text('确认后将申请日历权限，并写入 Shuvi 专用日历。').fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
          Button('确认并创建').width('100%').constraintSize({ minHeight: Theme.controlHeight }).borderRadius(Theme.radius)
            .backgroundColor(Theme.accent).fontColor(Color.White)
            .onClick((): void => { this.lastAction = 'create'; void CalendarProbeService.session.confirm(); }).id('calendar-probe-confirm')
          Button('返回修改').width('100%').constraintSize({ minHeight: Theme.controlHeight }).borderRadius(Theme.radius)
            .backgroundColor(Theme.soft).fontColor(Theme.accent).id('calendar-probe-cancel')
            .onClick((): void => { CalendarProbeService.session.cancelDraft(); this.formOpen = true; })
        }.width('100%').padding(12).alignItems(HorizontalAlign.Start).backgroundColor(Theme.inputSurface)
          .border({ width: 1, color: Theme.line, radius: Theme.radius })
      }

      if (this.result.records.length > 0) {
        Column({ space: 4 }) {
          Row() {
            Text('我的日程').fontSize(Theme.titleSize).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
            Blank()
            Text(`共 ${this.result.records.length} 条`).fontSize(Theme.noteSize).fontColor(Theme.muted)
          }.width('100%').margin({ top: 8, bottom: 4 })
          if (this.result.pendingCount > 0) {
            Text('有待核查的操作，核清前暂不能新建日程。').fontSize(13).fontColor(Theme.amber).width('100%')
          }
          if (this.result.records.length >= 64) {
            Text('已达到 64 条记录上限，既有记录保留，可继续核查。').fontSize(13).fontColor(Theme.muted).width('100%')
          }
          ForEach(this.sections.groups, (group: CalendarRecordGroup) => {
            Text(group.label).fontSize(Theme.noteSize).fontColor(Theme.muted).margin({ top: 8 })
            ForEach(group.rows, (row: CalendarRecordRow, index: number) => {
              if (index > 0) { Divider().color(Theme.line) }
              CalendarRecordItem({ row: row, expanded: this.expandedId === row.operationId,
                selected: this.result.locked && this.result.operationId === row.operationId,
                disabled: this.rowsDisabled(), busy: this.result.busy, note: this.rowNote(row.operationId),
                noteWarning: WARNING_PHASES.indexOf(this.result.phase) >= 0,
                onTap: (): void => this.tapRecord(row.operationId), onReconcile: (): void => this.startReconcile() })
            }, (row: CalendarRecordRow): string => rowKey(row))
          }, (group: CalendarRecordGroup): string => groupKey(group))
          if (this.sections.groups.length === 0) {
            Text('没有即将到来的日程。').fontSize(13).fontColor(Theme.muted).margin({ top: 8 })
          }
          if (this.sections.hiddenUpcoming > 0) {
            Button(`再显示 ${this.sections.hiddenUpcoming} 条`).fontSize(13).fontColor(Theme.accent)
              .backgroundColor(Color.Transparent).constraintSize({ minHeight: Theme.controlHeight }).id('calendar-show-all')
              .onClick((): void => { this.showAll = true; this.refreshSections(); })
          }
          if (this.sections.pastCount > 0) {
            Button(this.pastOpen ? '收起已过去的日程 ▴' : `已过去 ${this.sections.pastCount} 条 ▾`).fontSize(13)
              .fontColor(Theme.muted).backgroundColor(Color.Transparent).padding({ left: 0, right: 0 })
              .constraintSize({ minHeight: Theme.controlHeight }).id('calendar-past-toggle')
              .onClick((): void => { this.pastOpen = !this.pastOpen; })
            if (this.pastOpen) {
              ForEach(this.sections.past, (group: CalendarRecordGroup) => {
                Text(group.label).fontSize(Theme.noteSize).fontColor(Theme.muted).margin({ top: 8 })
                ForEach(group.rows, (row: CalendarRecordRow, index: number) => {
                  if (index > 0) { Divider().color(Theme.line) }
                  CalendarRecordItem({ row: row, expanded: this.expandedId === row.operationId,
                    selected: this.result.locked && this.result.operationId === row.operationId,
                    disabled: this.rowsDisabled(), busy: this.result.busy, note: this.rowNote(row.operationId),
                    noteWarning: WARNING_PHASES.indexOf(this.result.phase) >= 0,
                    onTap: (): void => this.tapRecord(row.operationId), onReconcile: (): void => this.startReconcile() })
                }, (row: CalendarRecordRow): string => rowKey(row))
              }, (group: CalendarRecordGroup): string => groupKey(group))
            }
          }
          Text('状态为上次核查结果，系统中的日程可能已有变化；点开一条可再次核查。').fontSize(Theme.noteSize)
            .fontColor(Theme.muted).width('100%').margin({ top: 8 })
        }.width('100%').alignItems(HorizontalAlign.Start)
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16)
      .backgroundColor(Theme.surface).border({ width: 1, color: Theme.line, radius: Theme.cardRadius })
  }
}
