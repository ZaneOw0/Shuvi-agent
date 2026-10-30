import { Theme } from './Theme';
import { ChatKnowledgeReply, chatKnowledgeSourceNumbers } from './ChatKnowledgeSources';
import { ChatKnowledgeSource } from '../model/ChatKnowledgeModels';

@Component
export struct AssistantReplyBubble {
  @Prop reply: ChatKnowledgeReply = new ChatKnowledgeReply();
  @State sourcesExpanded: boolean = false;
  onOpenSource: (source: ChatKnowledgeSource) => void = (_source: ChatKnowledgeSource): void => {};

  private visibleSources(): ChatKnowledgeSource[] {
    return this.sourcesExpanded ? this.reply.sources : this.reply.sources.slice(0, 3);
  }

  build() {
    Column({ space: 12 }) {
      Text(this.reply.text).fontSize(Theme.bodySize).fontColor(Theme.ink).lineHeight(22)
        .padding({ left: 14, right: 14, top: 10, bottom: 10 }).backgroundColor(Theme.surface)
        .borderRadius({ topLeft: 6, topRight: 20, bottomLeft: 20, bottomRight: 20 })
        .border({ width: 1, color: Theme.line }).accessibilityText(`休比：${this.reply.text}`)
      if (this.reply.sources.length > 0) {
        Column({ space: 8 }) {
          Text(`个人知识库来源 · ${this.reply.sources.length} 个文件`).fontSize(12).fontColor(Theme.muted)
            .width('100%')
          ForEach(this.visibleSources(), (source: ChatKnowledgeSource) => {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 10 }) {
                Text(source.fileType).fontSize(11).fontWeight(FontWeight.Medium).fontColor(Theme.accent)
                  .padding({ left: 8, right: 8, top: 10, bottom: 10 }).backgroundColor(Theme.soft).borderRadius(9)
                Column({ space: 4 }) {
                  Text(source.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
                    .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(chatKnowledgeSourceNumbers(source) + ' · 查看详情').fontSize(12).fontColor(Theme.muted)
                    .width('100%')
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                Text('›').fontSize(22).fontColor(Theme.muted)
              }.width('100%').padding(12)
            }.width('100%').constraintSize({ minHeight: 64 }).padding(0)
              .backgroundColor(Theme.surface).borderRadius(12).border({ width: 1, color: Theme.line })
              .id('chat-knowledge-source-' + source.documentId + '-' + source.generation)
              .accessibilityText(`${chatKnowledgeSourceNumbers(source)}，${source.title}，${source.fileType}，查看文件详情`)
              .onClick((): void => { this.onOpenSource(source); })
          }, (source: ChatKnowledgeSource): string => source.documentId + ':' + source.generation)
          if (this.reply.sources.length > 3) {
            Button(this.sourcesExpanded ? '收起来源 ▴' : `展开其余 ${this.reply.sources.length - 3} 个文件 ▾`)
              .fontSize(13).fontColor(Theme.accent).backgroundColor(Color.Transparent)
              .constraintSize({ minHeight: 44 }).width('100%').id('chat-knowledge-sources-toggle')
              .onClick((): void => { this.sourcesExpanded = !this.sourcesExpanded; })
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
