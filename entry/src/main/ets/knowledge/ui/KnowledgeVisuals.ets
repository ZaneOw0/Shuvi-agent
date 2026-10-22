import { Theme } from '../../components/Theme';
import { AppIcon } from '../../components/AppIcon';

interface KnowledgeHeadingOptions {
  title: string;
  subtitle?: string;
}

interface KnowledgeNoticeOptions {
  text: string;
  warning?: boolean;
}

interface KnowledgeEmptyOptions {
  title: string;
  description: string;
  icon: Resource;
}

// Knowledge pages share the app palette and spacing; services remain ordinary references.
@Builder
export function KnowledgeHeading($$: KnowledgeHeadingOptions) {
  Column({ space: 8 }) {
    Text($$.title).fontSize(26).fontWeight(FontWeight.Bold).fontColor(Theme.ink).width('100%')
    if (($$.subtitle ?? '').length > 0) {
      Text($$.subtitle ?? '').fontSize(14).fontColor(Theme.muted).lineHeight(22).width('100%')
    }
  }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 8, bottom: 8 })
}

@Builder
export function KnowledgeNotice($$: KnowledgeNoticeOptions) {
  Row({ space: 10 }) {
    AppIcon({ source: $r('app.media.chat_info'), size: 18 })
    Text($$.text).fontSize(13).fontColor($$.warning ? Theme.amber : Theme.muted)
      .lineHeight(21).layoutWeight(1)
  }.width('100%').alignItems(VerticalAlign.Top).padding(14).borderRadius(14)
    .backgroundColor($$.warning ? Theme.warning : Theme.soft)
    .border({ width: 1, color: $$.warning ? Theme.warningLine : Theme.line })
}

@Builder
export function KnowledgeEmpty($$: KnowledgeEmptyOptions) {
  Column({ space: 12 }) {
    Stack() {
      AppIcon({ source: $$.icon, size: 26 })
    }.width(56).height(56).backgroundColor(Theme.soft).borderRadius(18)
    Text($$.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
      .textAlign(TextAlign.Center).width('100%')
    Text($$.description).fontSize(14).fontColor(Theme.muted).lineHeight(22)
      .textAlign(TextAlign.Center).width('100%')
  }.width('100%').padding({ top: 28, bottom: 28, left: 18, right: 18 })
    .backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
}
