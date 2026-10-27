import { CalendarProbeRecord, CalendarProbeStore, copyCalendarRecord, parseCalendarProbeRecord } from './CalendarProbeSession';

// Each entry remains below Preferences' string limit; the ordered index is bounded to 64 IDs.
export interface CalendarJournalTextPort {
  read(key: string): Promise<string | undefined>;
  writeAndFlush(key: string, value: string): Promise<void>;
}

class CalendarJournalIndex {
  schemaVersion: number = 2;
  ids: string[] = [];
}

export class CalendarJournalStore implements CalendarProbeStore {
  private readonly text: CalendarJournalTextPort;
  private writing: boolean = false;
  private failed: boolean = false;
  constructor(text: CalendarJournalTextPort) { this.text = text; }

  private async index(): Promise<CalendarJournalIndex> {
    if (this.failed) throw new Error('日程存储状态待核查，请保留数据并重新打开应用。');
    const raw = await this.text.read('journal-v2');
    if (raw === undefined) {
      const index = new CalendarJournalIndex();
      const legacy = await this.text.read('operation');
      if (legacy !== undefined) {
        const record = parseCalendarProbeRecord(legacy);
        // Preserve the original v1 key. Failed migration must never become an empty journal.
        record.verified = false;
        record.reminderConfigured = false;
        await this.text.writeAndFlush(record.operationId, JSON.stringify(record));
        index.ids.push(record.operationId);
        await this.text.writeAndFlush('journal-v2', JSON.stringify(index));
      }
      return index;
    }
    if (raw.length > 8000) throw new Error('日程索引超出范围。');
    const index: CalendarJournalIndex = JSON.parse(raw);
    if (index === null || typeof index !== 'object' || Array.isArray(index) || index.schemaVersion !== 2 ||
      !Array.isArray(index.ids) || index.ids.length === 0 || index.ids.length > 64) throw new Error('日程索引损坏或版本不兼容。');
    const unique: string[] = [];
    for (const id of index.ids) {
      if (typeof id !== 'string' || id.length > 80 || !/^shuvi-calendar-[a-zA-Z0-9-]+$/.test(id) ||
        unique.indexOf(id) >= 0) throw new Error('日程索引标识无效。');
      unique.push(id);
    }
    return index;
  }

  async list(): Promise<CalendarProbeRecord[]> {
    try {
      const index = await this.index();
      const records: CalendarProbeRecord[] = [];
      for (const id of index.ids) {
        const raw = await this.text.read(id);
        if (raw === undefined || raw.length > 8000) throw new Error('日程记录缺失或过大。');
        const record = parseCalendarProbeRecord(raw);
        if (record.operationId !== id) throw new Error('日程记录与索引不一致。');
        records.push(record);
      }
      return records;
    } catch (_) { this.failed = true; throw new Error('日程记录读取失败，已停止写入，请保留数据排查。'); }
  }

  async load(): Promise<CalendarProbeRecord | undefined> {
    const records = await this.list();
    return records[records.length - 1];
  }

  async save(value: CalendarProbeRecord): Promise<void> {
    if (this.writing || this.failed) throw new Error('日程存储当前不可写入。');
    this.writing = true;
    try {
      const record = copyCalendarRecord(value);
      const records = await this.list();
      const existing = records.find((item: CalendarProbeRecord): boolean => item.operationId === record.operationId);
      if (existing !== undefined && (JSON.stringify(existing.draft) !== JSON.stringify(record.draft) ||
        (existing.eventId > 0 && record.eventId !== existing.eventId))) {
        throw new Error('不能更换既有日程操作的草稿或系统 ID。');
      }
      if (existing === undefined && (records.length >= 64 || records.some((item: CalendarProbeRecord): boolean => !item.verified))) {
        throw new Error('有待核查的操作或记录数量已达上限。');
      }
      const encoded = JSON.stringify(record);
      if (encoded.length > 8000 || record.operationId.length > 80) throw new Error('日程记录超出范围。');
      await this.text.writeAndFlush(record.operationId, encoded);
      if (existing === undefined) {
        const index = new CalendarJournalIndex();
        index.ids = records.map((item: CalendarProbeRecord): string => item.operationId);
        index.ids.push(record.operationId);
        // Dispatch is permitted only after both the intent and its index are durable.
        await this.text.writeAndFlush('journal-v2', JSON.stringify(index));
      }
    } catch (_) { this.failed = true; throw new Error('日程记录保存失败，已停止后续写入。'); }
    finally { this.writing = false; }
  }
}
