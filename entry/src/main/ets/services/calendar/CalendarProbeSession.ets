// Application-owned probe contract; not an Agent public tool contract.
export class CalendarProbeDraft {
  title: string = '';
  startAt: string = '';
  endAt: string = '';
  timeZone: string = 'Asia/Shanghai';
  reminderMinutes: number = 10;
}

export class CalendarProbeRecord {
  schemaVersion: number = 1;
  operationId: string = '';
  draft: CalendarProbeDraft = new CalendarProbeDraft();
  eventId: number = -1;
  verified: boolean = false;
  reminderConfigured: boolean = false;
}

export class CalendarProbeResult {
  phase: string = 'idle';
  message: string = '填写未来日程，核对后创建。此入口会写入真实系统日历。';
  busy: boolean = false;
  locked: boolean = false;
  draft: CalendarProbeDraft | undefined = undefined;
  eventId: number = -1;
  records: CalendarProbeRecord[] = [];
  canCreate: boolean = false;
  operationId: string = '';
  pendingCount: number = 0;
}

export class CalendarProbeReadback {
  eventId: number = -1;
  matches: boolean = false;
  reminderConfigured: boolean = false;
}

export interface CalendarProbePort {
  authorize(): Promise<void>;
  prepare(): Promise<void>;
  add(record: CalendarProbeRecord): Promise<number>;
  read(record: CalendarProbeRecord): Promise<CalendarProbeReadback>;
}

export interface CalendarProbeStore {
  load(): Promise<CalendarProbeRecord | undefined>;
  list(): Promise<CalendarProbeRecord[]>;
  save(record: CalendarProbeRecord): Promise<void>;
}

// The first device probe deliberately uses an explicit fixed zone, never the device's implicit zone.
export function calendarProbeTime(value: string): number {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00\+08:00$/.test(value)) return NaN;
  const instant = Date.parse(value);
  if (!Number.isFinite(instant)) return NaN;
  const wall = new Date(instant + 8 * 3600000).toISOString().slice(0, 19);
  return wall === value.slice(0, 19) ? instant : NaN;
}

export function calendarProbeDraftError(draft: CalendarProbeDraft, now: number, future: boolean = true): string {
  if (draft === null || typeof draft !== 'object' || Array.isArray(draft) ||
    typeof draft.title !== 'string' || draft.title.trim().length === 0 || draft.title.length > 200) {
    return '请输入 1–200 字的日程标题。';
  }
  if (typeof draft.startAt !== 'string' || typeof draft.endAt !== 'string' || draft.timeZone !== 'Asia/Shanghai') {
    return '日期或时区无效。';
  }
  const start = calendarProbeTime(draft.startAt);
  const end = calendarProbeTime(draft.endAt);
  if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) {
    return '请输入有效起止日期，结束必须晚于开始。';
  }
  if (!Number.isInteger(draft.reminderMinutes) || draft.reminderMinutes < 0 || draft.reminderMinutes > 10080) {
    return '提前提醒须为 0–10080 分钟的整数。';
  }
  if (future && start - draft.reminderMinutes * 60000 <= now) {
    return '日程开始和提醒时间都必须在未来，请调整时间后重新确认。';
  }
  return '';
}

export function parseCalendarProbeRecord(raw: string): CalendarProbeRecord {
  const value: CalendarProbeRecord = JSON.parse(raw);
  if (value === null || typeof value !== 'object' || Array.isArray(value) || value.schemaVersion !== 1 ||
    typeof value.operationId !== 'string' || !/^shuvi-calendar-[a-zA-Z0-9-]+$/.test(value.operationId) ||
    value.draft === undefined || calendarProbeDraftError(value.draft, 0, false).length > 0 ||
    !Number.isInteger(value.eventId) || value.eventId < -1 || value.eventId === 0 ||
    (value.verified !== undefined && typeof value.verified !== 'boolean') ||
    (value.reminderConfigured !== undefined && typeof value.reminderConfigured !== 'boolean') ||
    (value.verified === true && value.eventId <= 0)) {
    throw new Error('日历检查记录无效或版本不兼容，已停止写入；请保留记录排查。');
  }
  // v1 probe files predate verification flags; migrate conservatively to pending.
  value.verified = value.verified === true;
  value.reminderConfigured = value.reminderConfigured === true;
  return value;
}

export function copyCalendarRecord(value: CalendarProbeRecord): CalendarProbeRecord {
  return parseCalendarProbeRecord(JSON.stringify(value));
}

function copyDraft(value: CalendarProbeDraft): CalendarProbeDraft {
  const draft = new CalendarProbeDraft();
  draft.title = value.title.trim();
  draft.startAt = value.startAt;
  draft.endAt = value.endAt;
  draft.timeZone = value.timeZone;
  draft.reminderMinutes = value.reminderMinutes;
  return draft;
}

export class CalendarProbeSession {
  private result: CalendarProbeResult = new CalendarProbeResult();
  private listener: ((value: CalendarProbeResult) => void) | undefined = undefined;
  private record: CalendarProbeRecord | undefined = undefined;
  private draft: CalendarProbeDraft | undefined = undefined;
  private ready: boolean = false;
  private running: boolean = false;
  private stopped: boolean = false;
  private records: CalendarProbeRecord[] = [];
  private readonly port: CalendarProbePort;
  private readonly store: CalendarProbeStore;
  private readonly newId: () => string;
  private readonly now: () => number;
  private readonly timeoutMs: number;

  constructor(port: CalendarProbePort, store: CalendarProbeStore,
    newId: () => string, now: () => number = Date.now, timeoutMs: number = 20000) {
    this.port = port;
    this.store = store;
    this.newId = newId;
    this.now = now;
    this.timeoutMs = timeoutMs;
  }

  attach(listener: (value: CalendarProbeResult) => void): void {
    this.listener = listener;
    this.publish(this.result.phase, this.result.message);
    if (!this.ready && !this.running) void this.load();
  }

  detach(): void {
    this.listener = undefined;
    this.stop();
  }

  private publish(phase: string, message: string): void {
    const value = new CalendarProbeResult();
    value.phase = phase;
    value.message = message;
    value.busy = this.running;
    value.locked = !this.ready || this.record !== undefined;
    const draft = this.record?.draft ?? this.draft;
    value.draft = draft === undefined ? undefined : copyDraft(draft);
    value.eventId = this.record?.eventId ?? -1;
    value.operationId = this.record?.operationId ?? '';
    value.records = this.records.map((record: CalendarProbeRecord): CalendarProbeRecord => copyCalendarRecord(record));
    value.pendingCount = this.records.filter((record: CalendarProbeRecord): boolean => !record.verified).length;
    value.canCreate = this.ready && !this.running && this.records.length < 64 &&
      this.records.every((record: CalendarProbeRecord): boolean => record.verified);
    this.result = value;
    this.listener?.(value);
  }

  private async load(): Promise<void> {
    this.running = true;
    this.publish('loading', '正在读取本机日历检查记录。');
    try {
      this.records = await this.store.list();
      this.record = this.records.find((item: CalendarProbeRecord): boolean => !item.verified) ??
        this.records[this.records.length - 1];
      this.ready = true;
      this.publish(this.record === undefined ? 'idle' : 'unknown', this.record === undefined ?
        '填写未来日程，核对后创建。此入口会写入真实系统日历。' :
        '已恢复上次操作。请核查原日程，不会重新创建。');
    } catch (_) {
      this.publish('failed', '无法读取日历检查记录，已停止写入。请保留本机数据排查。');
    } finally {
      this.running = false;
      this.publish(this.result.phase, this.result.message);
    }
  }

  preview(draft: CalendarProbeDraft): void {
    if (!this.ready || this.running || this.record !== undefined) return;
    if (this.records.length >= 64 || this.records.some((item: CalendarProbeRecord): boolean => !item.verified)) return;
    const error = calendarProbeDraftError(draft, this.now());
    if (error.length > 0) { this.draft = undefined; this.publish('failed', error); return; }
    if (this.records.some((item: CalendarProbeRecord): boolean => item.draft.title === draft.title.trim() &&
      item.draft.startAt === draft.startAt && item.draft.endAt === draft.endAt && item.draft.timeZone === draft.timeZone)) {
      this.draft = undefined;
      this.publish('failed', '已有同标题、同时间的操作记录，未重复创建；请在「日程」页的记录中查看或核查原日程。');
      return;
    }
    this.draft = copyDraft(draft);
    this.publish('confirm', '请核对下方日程。确认后将申请日历权限，并写入 Shuvi 专用日历。');
  }

  cancelDraft(): void {
    if (this.running || this.record !== undefined) return;
    this.draft = undefined;
    this.publish('idle', '已取消草稿，没有创建日程。');
  }

  newDraft(): void {
    if (!this.ready || this.running || this.records.length >= 64 ||
      this.records.some((item: CalendarProbeRecord): boolean => !item.verified)) {
      this.publish(this.result.phase, this.result.message);
      return;
    }
    this.record = undefined;
    this.draft = undefined;
    this.publish('idle', '填写新日程，核对后再创建。既有日程与操作记录会保留。');
  }

  select(operationId: string): void {
    if (!this.ready || this.running) return;
    const record = this.records.find((item: CalendarProbeRecord): boolean => item.operationId === operationId);
    if (record === undefined) return;
    this.record = record;
    this.draft = undefined;
    this.publish('restored', record.verified ? '这是上次核查记录，系统中的日程可能已有变化，可再次核查。' :
      '这条操作尚待核查；核清前不能创建新的日程。');
  }

  stop(): void {
    this.stopped = true;
    if (!this.running) {
      if (this.record === undefined) this.cancelDraft();
      return;
    }
    this.publish(this.record === undefined ? 'stopping' : 'unknown', this.record === undefined ?
      '已停止后续创建，正在等待当前系统操作结束。' :
      '已停止后续操作；日程可能已写入，等待结果并保留记录，不会自动重试。');
  }

  async executeAuthorized(draft: CalendarProbeDraft, operationId: string,
    cancelled: () => boolean): Promise<CalendarProbeResult> {
    if (!/^shuvi-calendar-[a-zA-Z0-9-]+$/.test(operationId)) throw new Error('CALENDAR_OPERATION_INVALID');
    if (!this.ready && !this.running) await this.load();
    if (this.running || !this.ready || cancelled()) throw new Error('CALENDAR_NOT_READY');
    const existing = this.records.find((item: CalendarProbeRecord): boolean => item.operationId === operationId);
    if (existing !== undefined) {
      if (JSON.stringify(existing.draft) !== JSON.stringify(copyDraft(draft))) throw new Error('CALENDAR_OPERATION_MISMATCH');
      this.select(operationId);
      return this.toolSnapshot();
    }
    this.newDraft();
    this.preview(draft);
    if (this.result.phase === 'confirm' && !cancelled()) await this.confirm(operationId);
    return this.toolSnapshot();
  }

  private toolSnapshot(): CalendarProbeResult {
    const result: CalendarProbeResult = JSON.parse(JSON.stringify(this.result));
    return result;
  }

  async confirm(operationId?: string): Promise<void> {
    const draft = this.draft;
    if (!this.ready || this.running || this.record !== undefined || draft === undefined || this.result.phase !== 'confirm') return;
    const invalid = calendarProbeDraftError(draft, this.now());
    if (invalid.length > 0) { this.publish('failed', invalid); return; }
    this.running = true;
    this.stopped = false;
    this.publish('working', '正在申请日历权限并准备专用日历。');
    const timer = setTimeout(() => this.stop(), this.timeoutMs);
    try {
      await this.port.authorize();
      if (this.stopped) return;
      await this.port.prepare();
      if (this.stopped) return;
      const error = calendarProbeDraftError(draft, this.now());
      if (error.length > 0) throw new Error(error);
      const record = new CalendarProbeRecord();
      record.operationId = operationId === undefined ? this.newId() : operationId;
      record.draft = copyDraft(draft);
      // Reserve in memory before flushing. Even a failed flush must not permit a second write attempt.
      this.record = record;
      this.records.push(record);
      await this.store.save(record);
      if (this.stopped) return;
      this.publish('working', '正在创建真实日程，请勿重复操作。');
      const id = await this.port.add(record);
      if (!Number.isInteger(id) || id <= 0) throw new Error('系统未返回有效日程 ID。');
      record.eventId = id;
      await this.store.save(record);
      // A late result is still recorded; leaving the page is never treated as rollback.
      if (this.stopped) {
        this.publish('unknown', '系统已返回日程 ID；请核查原日程，不会重复创建。');
        return;
      }
      await this.readback(record);
    } catch (error) {
      this.publish(this.record === undefined ? 'failed' : 'unknown', this.record === undefined ?
        `尚未发送日程创建请求。${error.message}` :
        '操作结果待核查，可能已写入；请核查原日程，不会自动重新创建。');
    } finally {
      clearTimeout(timer);
      this.running = false;
      this.publish(this.result.phase, this.result.message);
    }
  }

  async reconcile(): Promise<void> {
    const record = this.record;
    if (!this.ready || this.running || record === undefined) return;
    this.running = true;
    this.stopped = false;
    this.publish('working', '正在核查原日程，仅查询，不重新创建。');
    const timer = setTimeout(() => this.stop(), this.timeoutMs);
    try {
      // Re-checking invalidates the historical verification before querying the system.
      record.verified = false;
      record.reminderConfigured = false;
      await this.store.save(record);
      await this.port.authorize();
      if (!this.stopped) await this.readback(record, false);
    } catch (error) {
      this.publish('unknown', `暂时无法核查，保留原操作。${error.message}`);
    } finally {
      clearTimeout(timer);
      this.running = false;
      this.publish(this.result.phase, this.result.message);
    }
  }

  /** `created` only changes the wording: a re-check of an old record must not announce a new creation. */
  private async readback(record: CalendarProbeRecord, created: boolean = true): Promise<void> {
    const read = await this.port.read(record);
    if (!read.matches || !Number.isInteger(read.eventId) || read.eventId <= 0) {
      this.publish('unknown', '未找到唯一且字段一致的原日程，请保留记录核查；不会重新创建。');
      return;
    }
    const verified = copyCalendarRecord(record);
    verified.eventId = read.eventId;
    verified.verified = true;
    verified.reminderConfigured = read.reminderConfigured;
    await this.store.save(verified);
    record.eventId = verified.eventId;
    record.verified = true;
    record.reminderConfigured = verified.reminderConfigured;
    if (!created) {
      this.publish(read.reminderConfigured ? 'verified' : 'partial', read.reminderConfigured ?
        '已核查：系统日历中的日程与记录一致，提醒配置也一致。' : '已核查：日程与记录一致，但提醒配置未核对通过。不会重新创建日程。');
      return;
    }
    this.publish(read.reminderConfigured ? 'verified' : 'partial', read.reminderConfigured ?
      '日程已创建并读回一致；提醒配置已核对。提醒是否实际送达仍需观察。' :
      '日程已创建并读回一致，但提醒配置未核对通过。不会重新创建日程。');
  }
}
