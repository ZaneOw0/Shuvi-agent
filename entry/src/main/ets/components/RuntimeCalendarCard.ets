import { CalendarToolPreview } from '../services/calendar/CalendarToolContract';
import { Theme } from './Theme';

@Component
export struct RuntimeCalendarCard {
  @Prop preview: CalendarToolPreview = new CalendarToolPreview();
  @Prop writing: boolean = false;
  @Prop pendingLabel: string = '正在创建并核对…';
  onConfirm: () => void = (): void => {};
  onCancel: () => void = (): void => {};
  onModify: () => void = (): void => {};
  build() {
    Column({ space: 12 }) {
      Text('确认创建日程').fontSize(18).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
      Text(this.preview.draft.title).fontSize(17).fontColor(Theme.ink)
      Text('开始：' + this.preview.draft.startAt.replace('T', ' ').replace(':00+08:00', ''))
        .fontSize(15).fontColor(Theme.ink)
      Text('结束：' + this.preview.draft.endAt.replace('T', ' ').replace(':00+08:00', ''))
        .fontSize(15).fontColor(Theme.ink)
      Text('北京时间 · ' + (this.preview.draft.reminderMinutes === 0 ? '开始时提醒' : '提前 ' + this.preview.draft.reminderMinutes + ' 分钟提醒'))
        .fontSize(14).fontColor(Theme.muted)
      Text('确认后写入本机 Shuvi 日历。通知仍需系统日历允许通知。').fontSize(13).fontColor(Theme.muted)
      Button(this.writing ? this.pendingLabel : '确认创建').enabled(!this.writing).width('100%')
        .constraintSize({ minHeight: 44 }).fontColor(Color.White).backgroundColor(Theme.accent)
        .id('runtime-calendar-confirm').onClick((): void => this.onConfirm())
      Button('取消本次日程').enabled(!this.writing).width('100%').constraintSize({ minHeight: 44 })
        .backgroundColor(Theme.soft).fontColor(Theme.accent).id('runtime-calendar-cancel').onClick((): void => this.onCancel())
      if (!this.writing) {
        Button('返回修改').width('100%').constraintSize({ minHeight: 44 }).backgroundColor(Theme.soft).fontColor(Theme.accent)
          .id('runtime-calendar-modify').onClick((): void => this.onModify())
        Text('返回修改会将安排带回输入框；修改后发送并重新确认。').fontSize(12).fontColor(Theme.muted)
      }
    }.padding(16).width('100%').alignItems(HorizontalAlign.Start).backgroundColor(Theme.surface)
      .borderRadius(16).border({ width: 1, color: Theme.line }).id('runtime-calendar-card')
  }
}
