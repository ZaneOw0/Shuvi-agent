import { CalendarProbeDraft, CalendarProbeRecord, calendarProbeTime } from './CalendarProbeSession';

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

/** Builds a draft from form fields: dates "YYYY-MM-DD", times "HH:MM", all Beijing wall-clock time. */
export function calendarFormDraft(title: string, startDate: string, startTime: string, endDate: string, endTime: string,
  reminderMinutes: number): CalendarProbeDraft {
  const draft: CalendarProbeDraft = new CalendarProbeDraft();
  draft.title = title.trim(); draft.startAt = `${startDate}T${startTime}:00+08:00`; draft.endAt = `${endDate}T${endTime}:00+08:00`;
  draft.timeZone = 'Asia/Shanghai'; draft.reminderMinutes = reminderMinutes;
  return draft;
}
/** Same-day variant used by the chat confirmation card. */
export function calendarEditedDraft(title: string, date: string, start: string, end: string, reminderMinutes: number): CalendarProbeDraft {
  return calendarFormDraft(title, date, start, date, end, reminderMinutes);
}
export function calendarTwoDigits(value: number): string { return value < 10 ? `0${value}` : `${value}`; }

// ---- Workbench calendar list and form (Beijing wall clock; `now` is an instant in milliseconds) ----
const BEIJING_OFFSET_MS: number = 8 * 3600000;
const DAY_MS: number = 86400000;

export function calendarBeijingDate(now: number): string { return new Date(now + BEIJING_OFFSET_MS).toISOString().slice(0, 10); }
function calendarDateShift(date: string, days: number): string {
  const parts: number[] = dateParts(date);
  return new Date(Date.UTC(parts[0], parts[1] - 1, parts[2]) + days * DAY_MS).toISOString().slice(0, 10);
}
function wallMinutes(date: string, time: string): number {
  const parts: number[] = dateParts(date);
  return Date.UTC(parts[0], parts[1] - 1, parts[2]) / 60000 + Number(time.slice(0, 2)) * 60 + Number(time.slice(3, 5));
}
function wallParts(minutes: number): string[] {
  const iso: string = new Date(minutes * 60000).toISOString();
  return [iso.slice(0, 10), iso.slice(11, 16)];
}

/** "15:00–16:00", "23:00–次日 01:00", or with the full end date for longer events. */
export function calendarTimeRange(draft: CalendarProbeDraft): string {
  const startDate: string = draft.startAt.slice(0, 10);
  const endDate: string = draft.endAt.slice(0, 10);
  const endTime: string = draft.endAt.slice(11, 16);
  const end: string = endDate === startDate ? endTime :
    (endDate === calendarDateShift(startDate, 1) ? `次日 ${endTime}` : `${calendarDateText(endDate)} ${endTime}`);
  return `${draft.startAt.slice(11, 16)}–${end}`;
}

/** Next whole Beijing hour for one hour; from 22:00 on it moves to tomorrow 09:00–10:00. Returns [startDate, startTime, endDate, endTime]. */
export function calendarDefaultSlot(now: number): string[] {
  const wall: Date = new Date(now + BEIJING_OFFSET_MS);
  let date: string = wall.toISOString().slice(0, 10);
  let hour: number = wall.getUTCHours() + 1;
  if (hour > 22) { date = calendarDateShift(date, 1); hour = 9; }
  return [date, `${calendarTwoDigits(hour)}:00`, date, `${calendarTwoDigits(hour + 1)}:00`];
}

/** End after the start moves: keeps the old duration, or one hour when the old range was empty or inverted. Returns [endDate, endTime]. */
export function calendarShiftedEnd(oldStartDate: string, oldStartTime: string, endDate: string, endTime: string,
  newStartDate: string, newStartTime: string): string[] {
  const duration: number = wallMinutes(endDate, endTime) - wallMinutes(oldStartDate, oldStartTime);
  return wallParts(wallMinutes(newStartDate, newStartTime) + (duration > 0 ? duration : 60));
}

export const CALENDAR_STATUS_OK: string = 'ok';
export const CALENDAR_STATUS_REMINDER: string = 'reminder';
export const CALENDAR_STATUS_PENDING: string = 'pending';

export function calendarRecordStatus(record: CalendarProbeRecord): string {
  return !record.verified ? CALENDAR_STATUS_PENDING : (record.reminderConfigured ? CALENDAR_STATUS_OK : CALENDAR_STATUS_REMINDER);
}
export function calendarRecordStatusText(status: string): string {
  if (status === CALENDAR_STATUS_PENDING) { return '待核查：可能已写入系统日历，核清前不能新建日程'; }
  return status === CALENDAR_STATUS_REMINDER ? '日程一致，提醒配置待核对' : '上次核查：日程和提醒配置一致';
}

export class CalendarRecordRow {
  operationId: string = '';
  title: string = '';
  time: string = '';
  when: string = '';
  reminder: string = '';
  status: string = CALENDAR_STATUS_OK;
  eventId: number = -1;
}
export class CalendarRecordGroup {
  key: string = '';
  label: string = '';
  rows: CalendarRecordRow[] = [];
}
export class CalendarRecordSections {
  /** Pending first (always shown), then upcoming/ongoing by start, at most `limit` upcoming rows. */
  groups: CalendarRecordGroup[] = [];
  hiddenUpcoming: number = 0;
  /** Finished events, most recent first. */
  past: CalendarRecordGroup[] = [];
  pastCount: number = 0;
}

function recordOrder(a: CalendarProbeRecord, b: CalendarProbeRecord): number {
  if (a.draft.startAt !== b.draft.startAt) { return a.draft.startAt < b.draft.startAt ? -1 : 1; }
  return a.draft.title < b.draft.title ? -1 : (a.draft.title > b.draft.title ? 1 : 0);
}
function recordRow(record: CalendarProbeRecord, withDate: boolean): CalendarRecordRow {
  const row: CalendarRecordRow = new CalendarRecordRow();
  row.operationId = record.operationId; row.title = record.draft.title; row.when = calendarWhenText(record.draft);
  row.time = withDate ? row.when : calendarTimeRange(record.draft);
  row.reminder = calendarReminderText(record.draft.reminderMinutes); row.status = calendarRecordStatus(record);
  row.eventId = record.eventId;
  return row;
}
function addToGroup(groups: CalendarRecordGroup[], key: string, label: string, row: CalendarRecordRow): void {
  const last: CalendarRecordGroup | undefined = groups.length > 0 ? groups[groups.length - 1] : undefined;
  if (last !== undefined && last.key === key) { last.rows.push(row); return; }
  const group: CalendarRecordGroup = new CalendarRecordGroup();
  group.key = key; group.label = label; group.rows.push(row); groups.push(group);
}

/** Groups Shuvi's calendar records by Beijing day: pending first, upcoming ascending, finished folded and descending. */
export function calendarRecordSections(records: CalendarProbeRecord[], now: number, limit: number): CalendarRecordSections {
  const sections: CalendarRecordSections = new CalendarRecordSections();
  const today: string = calendarBeijingDate(now);
  const tomorrow: string = calendarDateShift(today, 1);
  const dayLabel = (date: string): string => date === today ? `今天 · ${calendarDateText(date)}` :
    (date === tomorrow ? `明天 · ${calendarDateText(date)}` : calendarDateText(date));
  const pending: CalendarProbeRecord[] = records.filter((r: CalendarProbeRecord): boolean => !r.verified).sort(recordOrder);
  const finished = (r: CalendarProbeRecord): boolean => !(calendarProbeTime(r.draft.endAt) > now);
  const upcoming: CalendarProbeRecord[] = records.filter((r: CalendarProbeRecord): boolean => r.verified && !finished(r))
    .sort(recordOrder);
  const past: CalendarProbeRecord[] = records.filter((r: CalendarProbeRecord): boolean => r.verified && finished(r))
    .sort((a: CalendarProbeRecord, b: CalendarProbeRecord): number => recordOrder(b, a));
  for (const record of pending) { addToGroup(sections.groups, 'pending', '待核查', recordRow(record, true)); }
  for (const record of upcoming) {
    if (upcoming.indexOf(record) >= limit) { sections.hiddenUpcoming++; continue; }
    const date: string = record.draft.startAt.slice(0, 10);
    addToGroup(sections.groups, date, dayLabel(date), recordRow(record, false));
  }
  for (const record of past) {
    const date: string = record.draft.startAt.slice(0, 10);
    addToGroup(sections.past, 'past:' + date, dayLabel(date), recordRow(record, false));
  }
  sections.pastCount = past.length;
  return sections;
}
