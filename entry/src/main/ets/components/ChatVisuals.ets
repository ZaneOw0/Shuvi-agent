import { CalendarDraft } from '../model/AssistantModels';
import { Theme } from './Theme';
import { AppIcon } from './AppIcon';
import { BrandAvatar } from './BrandAvatar';

interface DraftVisualOptions {
  draft: CalendarDraft;
  executing: boolean;
  failed: boolean;
}

@Builder
export function AssistantWelcome() {
  Column({ space: 12 }) {
    BrandAvatar({ size: 80 })
    Text('Shuvi').fontSize(36).fontWeight(FontWeight.Medium).fontColor(Theme.accent)
      .margin({ bottom: 6 }).textAlign(TextAlign.Center)
    Text('嗨，今天想做些什么？').fontSize(22).fontWeight(FontWeight.Medium)
      .fontColor(Theme.ink).textAlign(TextAlign.Center).width('100%')
    Text('我是休比，让想法成为行动。').fontSize(13).fontColor(Theme.muted)
      .textAlign(TextAlign.Center).width('100%')
    Text('从下方「日程样例」开始体验').fontSize(11).fontColor(Theme.muted)
      .textAlign(TextAlign.Center).margin({ top: 8 }).width('100%')
  }.width('100%').padding({ top: 24, bottom: 24, left: 12, right: 12 })
}

@Builder
export function CalendarDraftCard($$: DraftVisualOptions) {
  Column() {
    Column({ space: 16 }) {
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center }) {
        Row({ space: 6 }) {
          AppIcon({ source: $r('app.media.chat_calendar'), size: 18})
          Text('日程草稿').fontSize(13).fontColor(Theme.accent)
        }.padding({ top: 4, bottom: 4 })
        Text($$.executing ? '模拟执行中' : ($$.failed ? '待重试' : '待确认'))
          .fontSize(11).fontColor(Theme.amber).padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(Theme.warning).borderRadius(8).border({ width: 1, color: Theme.warningLine })
      }.width('100%')
      Text($$.draft.title).fontSize(24).fontWeight(FontWeight.Medium).fontColor(Theme.ink).width('100%')
      Divider().color(Theme.line)
      Column({ space: 8 }) {
        Text(`${$$.draft.startAt.substring(0, 4)} 年 ${$$.draft.startAt.substring(5, 7)} 月 ${$$.draft.startAt.substring(8, 10)} 日`)
          .fontSize(13).fontColor(Theme.muted)
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          Text($$.draft.startAt.substring(11, 16)).fontSize(28).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
          Text(' — ').fontSize(22).fontColor(Theme.muted)
          Text($$.draft.endAt.substring(11, 16)).fontSize(28).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
        }.width('100%')
        Text(`${$$.draft.timeZone} · UTC${$$.draft.startAt.substring(19)}`)
          .fontSize(11).fontColor(Theme.muted).width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
      Divider().color(Theme.line)
      Row({ space: 8 }) {
        AppIcon({ source: $r('app.media.chat_bell'), size: 18})
        Text(`提前 ${$$.draft.reminderMinutesBefore} 分钟提醒`).fontSize(14).fontColor(Theme.ink).layoutWeight(1)
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding(18)
    Row({ space: 8 }) {
      AppIcon({ source: $r('app.media.chat_info'), size: 16})
      Text($$.executing ? '正在模拟执行，不会写入系统日历或实际提醒。' :
        '尚未创建。确认后仅加入演示列表，不会写入系统日历或实际提醒。')
        .fontSize(12).fontColor(Theme.muted).layoutWeight(1)
    }.width('100%').alignItems(VerticalAlign.Top).padding(14).backgroundColor(Theme.inputSurface)
  }.width('100%').backgroundColor(Theme.surface).borderRadius(22)
    .border({ width: 1, color: Theme.line }).clip(true)
}
