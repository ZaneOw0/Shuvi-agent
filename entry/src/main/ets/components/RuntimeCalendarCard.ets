import { CalendarToolPreview } from '../services/calendar/CalendarToolContract';
import { CalendarProbeDraft } from '../services/calendar/CalendarProbeSession';
import {
  CALENDAR_REMINDER_CHOICES, calendarDateText, calendarEditedDraft, calendarReminderText, calendarTwoDigits, calendarWhenText
} from '../services/calendar/CalendarPresentation';
import { Theme } from './Theme';

/** Date/time field; a child component so its value refreshes when the picker changes it (a by-value @Builder would not). */
@Component
struct CalendarFieldButton {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop fieldId: string = '';
  onTap: () => void = (): void => {};
  build() {
    Column({ space: 2 }) {
      Text(this.label).fontSize(Theme.noteSize).fontColor(Theme.muted)
      Text(this.value).fontSize(Theme.bodySize).fontColor(Theme.ink)
    }.alignItems(HorizontalAlign.Start).width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .constraintSize({ minHeight: Theme.controlHeight }).backgroundColor(Theme.inputSurface)
      .border({ width: 1, color: Theme.line, radius: Theme.radius }).id(this.fieldId)
      .accessibilityText(`${this.label}：${this.value}，点击修改`).onClick((): void => { this.onTap(); })
  }
}

/** Pending calendar confirmation. Editing happens in the card; saving declines the old request and asks again. */
@Component
export struct RuntimeCalendarCard {
  @Prop @Watch('resetEdit') preview: CalendarToolPreview = new CalendarToolPreview();
  @Prop writing: boolean = false;
  @Prop pendingLabel: string = '正在创建并核对…';
  @State editing: boolean = false;
  @State saving: boolean = false;
  @State editTitle: string = '';
  @State editDate: string = '';
  @State editStart: string = '';
  @State editEnd: string = '';
  @State editReminder: number = 10;
  @State reminderChoices: number[] = CALENDAR_REMINDER_CHOICES;
  @State editError: string = '';
  onConfirm: () => void = (): void => {};
  onCancel: () => void = (): void => {};
  onResubmit: (draft: CalendarProbeDraft) => Promise<string> = async (_draft: CalendarProbeDraft): Promise<string> => '';

  private shownOperation: string = '';
  aboutToAppear(): void { this.shownOperation = this.preview.operationId; }
  // Every publish hands the card a fresh preview copy; only a different confirmation closes the editor.
  private resetEdit(): void {
    if (this.preview.operationId === this.shownOperation) { return; }
    this.shownOperation = this.preview.operationId; this.discardEdit();
  }
  private discardEdit(): void { this.editing = false; this.saving = false; this.editError = ''; }
  private startEdit(): void {
    const draft: CalendarProbeDraft = this.preview.draft;
    this.editTitle = draft.title; this.editDate = draft.startAt.slice(0, 10);
    this.editStart = draft.startAt.slice(11, 16); this.editEnd = draft.endAt.slice(11, 16);
    this.editReminder = draft.reminderMinutes;
    this.reminderChoices = CALENDAR_REMINDER_CHOICES.indexOf(draft.reminderMinutes) >= 0 ? CALENDAR_REMINDER_CHOICES :
      CALENDAR_REMINDER_CHOICES.concat([draft.reminderMinutes]).sort((a: number, b: number): number => a - b);
    this.editError = draft.endAt.slice(0, 10) !== this.editDate ? '原日程跨天；卡片内只能修改为同一天，如需跨天请重新描述。' : '';
    this.editing = true;
  }
  private pickDate(): void {
    const parts: number[] = this.editDate.split('-').map((value: string): number => Number(value));
    const now: Date = new Date();
    this.getUIContext().showDatePickerDialog({
      start: new Date(now.getFullYear(), now.getMonth(), now.getDate()), end: new Date(now.getFullYear() + 5, 11, 31),
      selected: new Date(parts[0], parts[1] - 1, parts[2]),
      onDateAccept: (value: Date): void => {
        this.editDate = `${value.getFullYear()}-${calendarTwoDigits(value.getMonth() + 1)}-${calendarTwoDigits(value.getDate())}`;
      }
    });
  }
  private pickTime(start: boolean): void {
    // The picker titles itself with the date of `selected`, so build it on the edited day, not today.
    const parts: string[] = (start ? this.editStart : this.editEnd).split(':');
    const day: number[] = this.editDate.split('-').map((value: string): number => Number(value));
    const selected: Date = new Date(day[0], day[1] - 1, day[2], Number(parts[0]), Number(parts[1]), 0, 0);
    this.getUIContext().showTimePickerDialog({
      selected: selected, useMilitaryTime: true,
      onAccept: (value: TimePickerResult): void => {
        const text: string = `${calendarTwoDigits(value.hour)}:${calendarTwoDigits(value.minute)}`;
        if (!start) { this.editEnd = text; return; }
        // Moving the start keeps the duration, as calendar apps do, while the end stays on the same day.
        const minutes = (hhmm: string): number => Number(hhmm.slice(0, 2)) * 60 + Number(hhmm.slice(3, 5));
        const duration: number = minutes(this.editEnd) - minutes(this.editStart);
        const end: number = value.hour * 60 + value.minute + duration;
        this.editStart = text;
        if (duration > 0 && end < 24 * 60) {
          this.editEnd = `${calendarTwoDigits(Math.floor(end / 60))}:${calendarTwoDigits(end % 60)}`;
        }
      }
    });
  }
  private async save(): Promise<void> {
    if (this.saving) { return; }
    this.saving = true; this.editError = '';
    const draft: CalendarProbeDraft = calendarEditedDraft(this.editTitle, this.editDate, this.editStart, this.editEnd, this.editReminder);
    try {
      const error: string = await this.onResubmit(draft);
      if (error.length > 0) { this.editError = error; } else { this.editing = false; }
    } catch { this.editError = '保存未完成，原确认保持不变。'; }
    finally { this.saving = false; }
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text(this.editing ? '修改日程' : '确认日程').fontSize(Theme.titleSize).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
        Blank()
        Text(this.writing ? '处理中' : '待确认').fontSize(Theme.noteSize).fontColor(Theme.accent)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 }).backgroundColor(Theme.soft).borderRadius(10)
      }.width('100%')
      if (!this.editing) {
        Text(this.preview.draft.title).fontSize(Theme.titleSize).fontColor(Theme.ink).width('100%')
        Text(calendarWhenText(this.preview.draft)).fontSize(Theme.bodySize).fontColor(Theme.ink).width('100%')
        Text(calendarReminderText(this.preview.draft.reminderMinutes)).fontSize(13).fontColor(Theme.muted).width('100%')
        Text('确认后写入系统日历；提醒需系统允许通知。').fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
        Button(this.writing ? this.pendingLabel : '确认创建').enabled(!this.writing).width('100%')
          .constraintSize({ minHeight: Theme.controlHeight }).fontColor(Color.White).backgroundColor(Theme.accent)
          .borderRadius(Theme.radius).id('runtime-calendar-confirm').onClick((): void => this.onConfirm())
        if (!this.writing) {
          Row({ space: 8 }) {
            Button('修改').layoutWeight(1).constraintSize({ minHeight: Theme.controlHeight }).backgroundColor(Theme.soft)
              .fontColor(Theme.accent).borderRadius(Theme.radius).id('runtime-calendar-modify').onClick((): void => this.startEdit())
            Button('取消').layoutWeight(1).constraintSize({ minHeight: Theme.controlHeight }).backgroundColor(Color.Transparent)
              .fontColor(Theme.muted).borderRadius(Theme.radius).id('runtime-calendar-cancel').onClick((): void => this.onCancel())
          }.width('100%')
        }
      } else {
        TextInput({ text: this.editTitle, placeholder: '日程标题' }).maxLength(200).fontSize(Theme.bodySize)
          .backgroundColor(Theme.inputSurface).borderRadius(Theme.radius).border({ width: 1, color: Theme.line })
          .constraintSize({ minHeight: Theme.controlHeight }).id('runtime-calendar-edit-title')
          .onChange((value: string): void => { this.editTitle = value; })
        Row({ space: 8 }) {
          CalendarFieldButton({ label: '日期', value: calendarDateText(this.editDate), fieldId: 'runtime-calendar-edit-date',
            onTap: (): void => this.pickDate() }).layoutWeight(1)
        }.width('100%')
        Row({ space: 8 }) {
          CalendarFieldButton({ label: '开始', value: this.editStart, fieldId: 'runtime-calendar-edit-start',
            onTap: (): void => this.pickTime(true) }).layoutWeight(1)
          CalendarFieldButton({ label: '结束', value: this.editEnd, fieldId: 'runtime-calendar-edit-end',
            onTap: (): void => this.pickTime(false) }).layoutWeight(1)
        }.width('100%')
        Row({ space: 8 }) {
          Text('提醒').fontSize(Theme.noteSize).fontColor(Theme.muted)
          Select(this.reminderChoices.map((minutes: number): SelectOption => ({ value: calendarReminderText(minutes) })))
            .value(calendarReminderText(this.editReminder)).selected(this.reminderChoices.indexOf(this.editReminder))
            .font({ size: Theme.bodySize }).fontColor(Theme.ink)
            .selectedOptionFont({ size: Theme.bodySize }).optionFont({ size: Theme.bodySize })
            .backgroundColor(Theme.inputSurface).border({ width: 1, color: Theme.line, radius: Theme.radius })
            .constraintSize({ minHeight: Theme.controlHeight }).layoutWeight(1).id('runtime-calendar-edit-reminder')
            .onSelect((index: number): void => { this.editReminder = this.reminderChoices[index]; })
        }.width('100%')
        if (this.editError.length > 0) {
          Text(this.editError).fontSize(13).fontColor(Theme.danger).width('100%').id('runtime-calendar-edit-error')
        }
        Button(this.saving ? '正在更新…' : '保存并重新确认').enabled(!this.saving && this.editTitle.trim().length > 0).width('100%')
          .constraintSize({ minHeight: Theme.controlHeight }).fontColor(Color.White).backgroundColor(Theme.accent)
          .borderRadius(Theme.radius).id('runtime-calendar-edit-save').onClick((): void => { void this.save(); })
        Button('放弃修改').enabled(!this.saving).width('100%').constraintSize({ minHeight: Theme.controlHeight })
          .backgroundColor(Color.Transparent).fontColor(Theme.muted).id('runtime-calendar-edit-discard')
          .onClick((): void => this.discardEdit())
        Text('保存后会撤销原确认、按新内容重新生成确认卡，不再调用模型；确认前不会写入日历。')
          .fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
      }
    }.padding(16).width('100%').alignItems(HorizontalAlign.Start).backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius).border({ width: 1, color: Theme.line }).id('runtime-calendar-card')
  }
}
