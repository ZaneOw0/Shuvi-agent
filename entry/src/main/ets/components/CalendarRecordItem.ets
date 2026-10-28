import { Theme } from './Theme';
import {
  CALENDAR_STATUS_OK, CALENDAR_STATUS_PENDING, CalendarRecordRow, calendarRecordStatusText
} from '../services/calendar/CalendarPresentation';

/** One schedule in the workbench list: a single line, expanding in place to its details and the re-check action. */
@Component
export struct CalendarRecordItem {
  @Prop row: CalendarRecordRow = new CalendarRecordRow();
  @Prop expanded: boolean = false;
  /** The session's selected record; only it can be re-checked. */
  @Prop selected: boolean = false;
  @Prop disabled: boolean = false;
  @Prop busy: boolean = false;
  /** Result of a re-check started from this row, shown in place instead of at the top of the page. */
  @Prop note: string = '';
  @Prop noteWarning: boolean = false;
  onTap: () => void = (): void => {};
  onReconcile: () => void = (): void => {};

  build() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text(this.row.time).fontSize(14).fontColor(Theme.ink).constraintSize({ minWidth: 96 })
        Text(this.row.title).fontSize(Theme.bodySize).fontColor(Theme.ink).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Circle({ width: 8, height: 8 }).fill(this.row.status === CALENDAR_STATUS_OK ? Theme.ok : Theme.amber)
          .accessibilityLevel('no')
      }.width('100%').constraintSize({ minHeight: Theme.controlHeight }).id(`calendar-record-${this.row.operationId}`)
        .accessibilityText(`${this.row.time} ${this.row.title}，${calendarRecordStatusText(this.row.status)}，${this.expanded ? '点按收起' : '点按查看详情'}`)
        .onClick((): void => { if (!this.disabled) { this.onTap(); } })
      if (this.row.status !== CALENDAR_STATUS_OK && !this.expanded) {
        Text(calendarRecordStatusText(this.row.status)).fontSize(Theme.noteSize).fontColor(Theme.amber).width('100%')
      }
      if (this.expanded) {
        Column({ space: 6 }) {
          Text(this.row.when).fontSize(14).fontColor(Theme.ink)
          Text(this.row.reminder).fontSize(13).fontColor(Theme.muted)
          if (this.note.length === 0) {
            Text(calendarRecordStatusText(this.row.status)).fontSize(13)
              .fontColor(this.row.status === CALENDAR_STATUS_OK ? Theme.muted : Theme.amber)
          } else {
            Text(this.note).fontSize(13).fontColor(this.noteWarning ? Theme.amber : Theme.ok).width('100%')
              .padding(8).backgroundColor(this.noteWarning ? Theme.warning : Theme.okSoft).borderRadius(Theme.radius)
              .id('calendar-record-note')
          }
          if (this.selected) {
            Button(this.busy ? '正在核查…' : '核查原日程').enabled(!this.busy).constraintSize({ minHeight: Theme.controlHeight })
              .backgroundColor(Theme.soft).fontColor(Theme.accent).borderRadius(Theme.radius).id('calendar-probe-reconcile')
              .accessibilityText('只查询系统日历中的这条日程，不会重新创建')
              .onClick((): void => { this.onReconcile(); })
          }
          Text(this.row.eventId > 0 ? `系统日程 ID ${this.row.eventId}` :
            (this.row.status === CALENDAR_STATUS_PENDING ? '尚无可核对的系统日程 ID' : ''))
            .fontSize(Theme.noteSize).fontColor(Theme.muted)
        }.width('100%').alignItems(HorizontalAlign.Start).padding(10)
          .backgroundColor(Theme.inputSurface).borderRadius(Theme.radius)
      }
    }.width('100%').padding({ top: 4, bottom: 4 })
  }
}
