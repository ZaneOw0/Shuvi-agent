import { KnowledgeRuntimeCitation } from '../knowledge/domain/KnowledgeRuntimePorts';
import { RuntimeKnowledgeView } from '../services/model/RuntimeKnowledgeSession';
import { RuntimeKnowledgeService } from '../services/model/RuntimeKnowledgeService';
import { Theme } from './Theme';

/** Authorization status and actual evidence; the answer stays in the ordinary conversation. */
@Component
export struct RuntimeKnowledgePanel {
  @Prop view: RuntimeKnowledgeView = new RuntimeKnowledgeView();
  @State sourcesOpen: boolean = false;
  onDisable: () => void = (): void => {};
  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('个人知识库授权').fontSize(15).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
        Blank()
        Button('撤销授权').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft)
          .constraintSize({ minHeight: 44 }).id('runtime-knowledge-close')
          .onClick((): void => { this.onDisable(); })
      }.width('100%')
      Text('助手按需查询。查询文本可能发送给已配置的 Embedding Provider 并计费；命中片段发送给 DeepSeek。授权不包含入库、重新向量化或其他工具写入。')
        .fontSize(12).fontColor(Theme.muted).width('100%')
      Text(this.view.message).fontSize(13).fontColor(Theme.muted).width('100%').id('runtime-knowledge-status')
      if (this.view.stage === 'answerFailed' && this.view.citations.length > 0) {
        Button('仅重试回答').fontColor(Theme.accent).backgroundColor(Theme.soft).constraintSize({ minHeight: 44 })
          .id('runtime-knowledge-retry').onClick((): void => { void RuntimeKnowledgeService.session.retryAnswer(); })
      }
      if (this.view.citations.length > 0) {
        Button(this.sourcesOpen ? '收起来源原文' : `查看 ${this.view.citations.length} 条实际来源`)
          .fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).constraintSize({ minHeight: 44 })
          .id('runtime-knowledge-sources').onClick((): void => { this.sourcesOpen = !this.sourcesOpen; })
        if (this.sourcesOpen) {
          ForEach(this.view.citations, (hit: KnowledgeRuntimeCitation) => {
            Column({ space: 6 }) {
              Text('[' + hit.citationId.toString() + '] ' + hit.title).fontSize(14).fontColor(Theme.ink)
              Text(hit.kind + ' · ' + (hit.evidence === 'Vector' ? '语义检索' : '字面命中'))
                .fontSize(12).fontColor(Theme.muted)
              Text(hit.excerpt).fontSize(13).fontColor(Theme.muted).lineHeight(19).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%').padding(10)
              .backgroundColor(Theme.inputSurface).borderRadius(Theme.radius)
          }, (hit: KnowledgeRuntimeCitation): string => hit.evidenceId + hit.generation)
        }
      }
    }.alignItems(HorizontalAlign.Start).width('100%').padding(12).backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius).border({ width: 1, color: Theme.line })
  }
}
