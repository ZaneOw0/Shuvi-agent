import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { calendarManager } from '@kit.CalendarKit';
import {
  CalendarProbePort, CalendarProbeReadback, CalendarProbeRecord, CalendarProbeSession,
  calendarProbeTime
} from './CalendarProbeSession';
import { CalendarJournalStore, CalendarJournalTextPort } from './CalendarJournalStore';

function calendarError(error: BusinessError): Error {
  if (error.code === 201) return new Error('日历权限不足，请在系统设置中检查休比的日历权限。');
  if (error.code === 801) return new Error('当前设备不支持日历能力。');
  if (error.code === 23900003) return new Error('未找到 Shuvi 专用日历，请保留操作记录核查。');
  return new Error(`系统日历操作失败（${Number.isInteger(error.code) ? error.code : 'INTERNAL'}）。`);
}

class DeviceCalendarProbe implements CalendarProbePort {
  private context: common.UIAbilityContext | undefined = undefined;
  private calendar: calendarManager.Calendar | undefined = undefined;
  private readonly account: calendarManager.CalendarAccount = {
    name: 'com.example.shuvi.calendar.probe.v1', type: calendarManager.CalendarType.LOCAL, displayName: 'Shuvi 日程'
  };

  bind(context: common.UIAbilityContext): void { this.context = context; }

  release(): void { this.context = undefined; this.calendar = undefined; }

  private manager(): calendarManager.CalendarManager {
    const context = this.context;
    if (context === undefined) throw new Error('日程服务尚未就绪。');
    return calendarManager.getCalendarManager(context);
  }

  async authorize(): Promise<void> {
    const context = this.context;
    if (context === undefined) throw new Error('日程服务尚未就绪。');
    if (!canIUse('SystemCapability.Applications.CalendarData')) throw new Error('当前设备不支持日历能力。');
    const permissions: Permissions[] = ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR'];
    const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, permissions);
    if (result.authResults.length !== permissions.length || result.authResults.some((value: number) => value !== 0)) {
      throw new Error('日历权限未全部允许。草稿已保留，可在系统设置中授权后重新核对。');
    }
  }

  async prepare(): Promise<void> {
    const manager = this.manager();
    let calendar: calendarManager.Calendar;
    try {
      calendar = await manager.getCalendar(this.account);
    } catch (error) {
      // Only the documented API 23+ "account not found" permits creation.
      if (error.code !== 23900003) throw calendarError(error);
      try {
        calendar = await manager.createCalendar(this.account);
      } catch (createError) { throw calendarError(createError); }
    }
    try {
      const config = calendar.getConfig();
      config.enableReminder = true;
      await calendar.setConfig(config);
      this.calendar = calendar;
    } catch (error) { throw calendarError(error); }
  }

  async add(record: CalendarProbeRecord): Promise<number> {
    const calendar = this.calendar;
    if (calendar === undefined) throw new Error('专用日历未准备好。');
    const event: calendarManager.Event = {
      type: calendarManager.EventType.NORMAL, title: record.draft.title,
      startTime: calendarProbeTime(record.draft.startAt), endTime: calendarProbeTime(record.draft.endAt),
      timeZone: record.draft.timeZone, isAllDay: false, identifier: record.operationId,
      reminderTime: [record.draft.reminderMinutes]
    };
    try { return await calendar.addEvent(event); } catch (error) { throw calendarError(error); }
  }

  async read(record: CalendarProbeRecord): Promise<CalendarProbeReadback> {
    try {
      // Recovery never creates an account, modifies reminders or adds events.
      const calendar = await this.manager().getCalendar(this.account);
      const filter = record.eventId > 0 ? calendarManager.EventFilter.filterById([record.eventId]) :
        calendarManager.EventFilter.filterByTime(calendarProbeTime(record.draft.startAt), calendarProbeTime(record.draft.endAt));
      const keys: (keyof calendarManager.Event)[] = [
        'id', 'type', 'title', 'startTime', 'endTime', 'timeZone', 'isAllDay', 'identifier', 'reminderTime'
      ];
      const events = await calendar.getEvents(filter, keys);
      const matches = events.filter((event: calendarManager.Event) => event.identifier === record.operationId);
      const result = new CalendarProbeReadback();
      if (matches.length !== 1) return result;
      const event = matches[0];
      result.eventId = event.id ?? -1;
      result.matches = event.type === calendarManager.EventType.NORMAL && event.isAllDay === false &&
        event.title === record.draft.title && event.startTime === calendarProbeTime(record.draft.startAt) &&
        event.endTime === calendarProbeTime(record.draft.endAt) && event.timeZone === record.draft.timeZone &&
        (record.eventId < 0 || event.id === record.eventId);
      result.reminderConfigured = calendar.getConfig().enableReminder === true &&
        event.reminderTime !== undefined && event.reminderTime.length === 1 &&
        event.reminderTime[0] === record.draft.reminderMinutes;
      return result;
    } catch (error) { throw calendarError(error); }
  }
}

class DeviceCalendarProbeStore implements CalendarJournalTextPort {
  private context: common.UIAbilityContext | undefined = undefined;
  bind(context: common.UIAbilityContext): void { this.context = context; }
  release(): void { this.context = undefined; }

  private async open(): Promise<preferences.Preferences> {
    const context = this.context;
    if (context === undefined) throw new Error('日历检查存储尚未就绪。');
    return preferences.getPreferences(context, 'shuvi_calendar_probe_v1');
  }

  async read(key: string): Promise<string | undefined> {
    const store = await this.open();
    if (!await store.has(key)) return undefined;
    const raw = await store.get(key, '');
    if (typeof raw !== 'string' || raw.length === 0) throw new Error('日历检查记录损坏。');
    return raw;
  }

  async writeAndFlush(key: string, value: string): Promise<void> {
    const store = await this.open();
    await store.put(key, value);
    await store.flush();
  }
}

export class CalendarProbeService {
  private static readonly device: DeviceCalendarProbe = new DeviceCalendarProbe();
  private static readonly store: DeviceCalendarProbeStore = new DeviceCalendarProbeStore();
  private static readonly journal: CalendarJournalStore = new CalendarJournalStore(CalendarProbeService.store);
  static readonly session: CalendarProbeSession = new CalendarProbeSession(CalendarProbeService.device,
    CalendarProbeService.journal, (): string => `shuvi-calendar-${util.generateRandomUUID()}`);

  static bind(context: common.UIAbilityContext): void {
    CalendarProbeService.device.bind(context);
    CalendarProbeService.store.bind(context);
  }

  static background(): void { CalendarProbeService.session.stop(); }

  static release(): void {
    CalendarProbeService.session.detach();
    CalendarProbeService.device.release();
    CalendarProbeService.store.release();
  }
}
