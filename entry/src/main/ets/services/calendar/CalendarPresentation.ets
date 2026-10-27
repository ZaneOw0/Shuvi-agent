import { CalendarProbeDraft } from './CalendarProbeSession';

// Display helpers for chat calendar cards. They read the draft's own +08:00 wall-clock fields and never the device zone.
const WEEKDAYS: string[] = ['日', '一', '二', '三', '四', '五', '六'];
export const CALENDAR_REMINDER_CHOICES: number[] = [0, 5, 10, 15, 30, 60];

function dateParts(value: string): number[] {
  return [Number(value.slice(0, 4)), Number(value.slice(5, 7)), Number(value.slice(8, 10))];
}
export function calendarDateText(value: string): string {
  const parts: number[] = dateParts(value);
  const weekday: string = WEEKDAYS[new Date(Date.UTC(parts[0], parts[1] - 1, parts[2])).getUTCDay()];
  return `${parts[1]}月${parts[2]}日 周${weekday}`;
}
/** "10月28日 周三 16:00–17:00", or with the end date when the event crosses midnight. */
export function calendarWhenText(draft: CalendarProbeDraft): string {
  const sameDay: boolean = draft.endAt.slice(0, 10) === draft.startAt.slice(0, 10);
  const end: string = sameDay ? draft.endAt.slice(11, 16) : `${calendarDateText(draft.endAt)} ${draft.endAt.slice(11, 16)}`;
  return `${calendarDateText(draft.startAt)} ${draft.startAt.slice(11, 16)}–${end}`;
}
export function calendarReminderText(minutes: number): string {
  return minutes === 0 ? '开始时提醒' : `提前 ${minutes} 分钟提醒`;
}

export class CalendarCreatedSummary {
  title: string = '';
  when: string = '';
  reminder: string = '';
  eventId: number = -1;
  reminderConfigured: boolean = false;
}
export function calendarCreatedSummary(draft: CalendarProbeDraft, eventId: number, reminderConfigured: boolean): CalendarCreatedSummary {
  const summary: CalendarCreatedSummary = new CalendarCreatedSummary();
  summary.title = draft.title; summary.when = calendarWhenText(draft); summary.reminder = calendarReminderText(draft.reminderMinutes);
  summary.eventId = eventId; summary.reminderConfigured = reminderConfigured;
  return summary;
}

/** Builds a draft from card fields: date "YYYY-MM-DD", times "HH:MM", all Beijing wall-clock time. */
export function calendarEditedDraft(title: string, date: string, start: string, end: string, reminderMinutes: number): CalendarProbeDraft {
  const draft: CalendarProbeDraft = new CalendarProbeDraft();
  draft.title = title.trim(); draft.startAt = `${date}T${start}:00+08:00`; draft.endAt = `${date}T${end}:00+08:00`;
  draft.timeZone = 'Asia/Shanghai'; draft.reminderMinutes = reminderMinutes;
  return draft;
}
export function calendarTwoDigits(value: number): string { return value < 10 ? `0${value}` : `${value}`; }
