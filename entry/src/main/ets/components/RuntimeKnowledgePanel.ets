import { KnowledgeRuntimeCitation } from '../knowledge/domain/KnowledgeRuntimePorts';
import { RuntimeKnowledgeService } from '../services/model/RuntimeKnowledgeService';
import { RuntimeKnowledgeView } from '../services/model/RuntimeKnowledgeSession';
import {
  knowledgeAnswerIsModel, knowledgeAnswerStage, knowledgeCitationChip, knowledgeRequestUsage, knowledgeRetrievalStage,
  knowledgeRetryAvailable
} from '../services/model/RuntimeKnowledgePresentation';
import { ShuviRuntimeState } from '../services/model/ShuviRuntimeController';
import { Theme } from './Theme';

/**
 * Answer first, then numbered source chips; the excerpts fold away once DeepSeek has answered and
 * stay open whenever they are the only result (failed, insufficient or stopped), per contract §4.5.
 */
@Component
export struct RuntimeKnowledgePanel {
  @Prop @Watch('viewChanged') view: RuntimeKnowledgeView = new RuntimeKnowledgeView();
  @State sourcesOpen: boolean = false;
  private shownQuery: string = '';
  onDisable: () => void = (): void => {};

  private viewChanged(): void {
    if (this.view.query !== this.shownQuery) { this.shownQuery = this.view.query; this.sourcesOpen = false; }
  }

  private stopped(): boolean {
    return this.view.lifecycle === ShuviRuntimeState.IDLE || this.view.lifecycle === ShuviRuntimeState.STOPPED ||
      this.view.lifecycle === ShuviRuntimeState.FAILED;
  }

  private sourcesVisible(): boolean { return this.sourcesOpen || !knowledgeAnswerIsModel(this.view); }

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('知识库问答').fontSize(Theme.titleSize).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
        Blank()
        if (this.view.busy || this.view.lifecycle === ShuviRuntimeState.READY || this.view.lifecycle === ShuviRuntimeState.STARTING) {
          Button(this.view.busy ? '取消本次问答' : '关闭知识库').fontSize(13).fontColor(Theme.accent)
            .backgroundColor(Theme.soft).borderRadius(Theme.radius).constraintSize({ minHeight: Theme.controlHeight })
            .id('runtime-knowledge-close')
            .accessibilityText(this.view.busy ? '取消当前知识库问答，已显示的来源会保留' : '关闭知识库，回到普通对话')
            .onClick((): void => {
              if (this.view.busy) { void RuntimeKnowledgeService.session.cancelCurrent(); }
              else { this.onDisable(); }
            })
        }
      }.width('100%')
      if (!knowledgeAnswerIsModel(this.view)) {
        // Once the labelled answer and the stage line are shown, the backend's status sentence only repeats them.
        Text(this.view.message).fontSize(13).fontColor(Theme.muted).width('100%').id('runtime-knowledge-status')
      }
      if (this.stopped()) {
        Text('知识库问答已停止，本次的 DeepSeek 凭据不再可用。要继续使用：停止真实对话后重新输入 Key 启用；如仍不可用，请检查 Embedding 设置与向量数据。')
          .fontSize(13).fontColor(Theme.muted).width('100%').id('runtime-knowledge-restart-hint')
        Button('返回普通对话').constraintSize({ minHeight: Theme.controlHeight }).borderRadius(Theme.radius)
          .backgroundColor(Theme.accent).fontColor(Color.White).id('runtime-knowledge-enable')
          .onClick((): void => { this.onDisable(); })
      }
      if (this.view.query.length > 0) {
        Text('问：' + this.view.query).fontSize(13).fontColor(Theme.muted).width('100%').maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          Text('本机检索 · ' + knowledgeRetrievalStage(this.view)).fontSize(Theme.noteSize).fontColor(Theme.ink)
            .id('runtime-knowledge-retrieval-stage')
          Text('  →  ').fontSize(Theme.noteSize).fontColor(Theme.muted)
          Text('模型回答 · ' + knowledgeAnswerStage(this.view)).fontSize(Theme.noteSize).fontColor(Theme.ink)
            .id('runtime-knowledge-answer-stage')
        }.width('100%').padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor(Theme.inputSurface).borderRadius(Theme.radius)
      }
      if (knowledgeAnswerIsModel(this.view)) {
        Column({ space: 8 }) {
          Text('DeepSeek 整理回答（依据下方片段，不是原始资料）').fontSize(Theme.noteSize).fontColor(Theme.muted)
            .id('runtime-knowledge-answer-label')
          Text(this.view.answer).fontSize(Theme.bodySize).fontColor(Theme.ink).width('100%').lineHeight(22)
            .id('runtime-knowledge-answer')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.view.citations, (citation: KnowledgeRuntimeCitation) => {
              Text(knowledgeCitationChip(citation.citationId, citation.excerpt)).fontSize(Theme.noteSize)
                .fontColor(Theme.accent).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ minHeight: 32 }).padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .margin({ right: 6, bottom: 6 }).backgroundColor(Theme.soft).borderRadius(Theme.radius)
                .accessibilityText('来源 ' + citation.citationId.toString() + '：' + citation.title + '，点按查看原文片段')
                .onClick((): void => { this.sourcesOpen = true; })
            }, (citation: KnowledgeRuntimeCitation): string => 'chip:' + citation.evidenceId)
          }.width('100%')
        }.alignItems(HorizontalAlign.Start).width('100%').padding(12).backgroundColor(Theme.surface)
          .border({ width: 1, color: Theme.line }).borderRadius({ topLeft: 6, topRight: 20, bottomLeft: 20, bottomRight: 20 })
      } else if (this.view.answer.length > 0) {
        Text(this.view.answer).fontSize(Theme.bodySize).fontColor(Theme.ink).width('100%').id('runtime-knowledge-local-answer')
      }
      if (this.view.stage === 'insufficient') {
        Text('资料中没有足够依据。这不是成功的回答；下方是本机检索到的片段，供你核对。')
          .fontSize(14).fontColor(Theme.amber).width('100%').padding(10)
          .backgroundColor(Theme.warning).border({ width: 1, color: Theme.warningLine }).borderRadius(10)
          .id('runtime-knowledge-insufficient')
      }
      if (knowledgeRetryAvailable(this.view)) {
        Button('仅重试回答').constraintSize({ minHeight: Theme.controlHeight }).borderRadius(Theme.radius)
          .backgroundColor(Theme.soft).fontColor(Theme.accent)
          .accessibilityText('仅重试 DeepSeek 回答，复用下方片段，不重新检索本机资料')
          .id('runtime-knowledge-retry')
          .onClick((): void => { void RuntimeKnowledgeService.session.retryAnswer(); })
      }
      if (this.view.citations.length > 0) {
        if (knowledgeAnswerIsModel(this.view)) {
          Button(this.sourcesOpen ? '收起来源原文 ▴' : `查看 ${this.view.citations.length} 条来源原文 ▾`)
            .fontSize(13).fontColor(Theme.accent).backgroundColor(Color.Transparent).padding({ left: 0, right: 0 })
            .constraintSize({ minHeight: Theme.controlHeight }).id('runtime-knowledge-sources')
            .onClick((): void => { this.sourcesOpen = !this.sourcesOpen; })
        } else {
          Text('本机原始片段').fontSize(13).fontColor(Theme.muted).fontWeight(FontWeight.Medium)
        }
      }
      if (this.sourcesVisible()) {
        ForEach(this.view.citations, (citation: KnowledgeRuntimeCitation) => {
          Column({ space: 6 }) {
            Text('[' + citation.citationId.toString() + '] ' + citation.title).fontSize(14).fontColor(Theme.ink)
              .fontWeight(FontWeight.Medium)
            Text(citation.excerpt).fontSize(13).fontColor(Theme.muted).maxLines(6).lineHeight(19)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).width('100%').padding(10)
            .backgroundColor(Theme.inputSurface).borderRadius(Theme.radius)
        }, (citation: KnowledgeRuntimeCitation): string => citation.evidenceId)
      }
      if (this.view.requestCount > 0) {
        Text(knowledgeRequestUsage(this.view)).fontSize(Theme.noteSize).fontColor(Theme.muted).id('runtime-knowledge-usage')
      }
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius).border({ width: 1, color: Theme.line })
  }
}
