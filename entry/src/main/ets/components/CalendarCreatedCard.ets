import { CalendarCreatedSummary } from '../services/calendar/CalendarPresentation';
import { Theme } from './Theme';

/** Chat reply for a verified creation: the event details first, the system ID and delivery caveat as a footnote. */
@Component
export struct CalendarCreatedCard {
  @Prop summary: CalendarCreatedSummary = new CalendarCreatedSummary();
  onOpen: () => void = (): void => {};
  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('✓').fontSize(14).fontColor(Color.White).width(22).height(22).textAlign(TextAlign.Center)
          .backgroundColor(Theme.ok).borderRadius(11).accessibilityLevel('no')
        Text('已创建日程').fontSize(Theme.bodySize).fontWeight(FontWeight.Medium).fontColor(Theme.ok)
      }
      Text(this.summary.title).fontSize(Theme.titleSize).fontWeight(FontWeight.Medium).fontColor(Theme.ink).width('100%')
      Text(this.summary.when).fontSize(Theme.bodySize).fontColor(Theme.ink).width('100%')
      Text(this.summary.reminder + (this.summary.reminderConfigured ? '' : ' · 提醒配置待核实'))
        .fontSize(13).fontColor(this.summary.reminderConfigured ? Theme.muted : Theme.amber).width('100%')
      Button('在日程页查看').constraintSize({ minHeight: Theme.controlHeight }).backgroundColor(Theme.soft).fontColor(Theme.accent)
        .borderRadius(Theme.radius).id('runtime-calendar-open-workbench').onClick((): void => this.onOpen())
      Text(`系统日程 ID ${this.summary.eventId} · 已读回核对；实际通知以系统送达为准。离开助手页会结束当前会话。`)
        .fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding(14).backgroundColor(Theme.okSoft)
      .borderRadius(Theme.cardRadius).border({ width: 1, color: Theme.line }).id('runtime-calendar-created')
      .accessibilityText(`已创建日程：${this.summary.title}，${this.summary.when}，${this.summary.reminder}`)
  }
}
