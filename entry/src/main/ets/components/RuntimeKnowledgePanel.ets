import { KnowledgeRuntimeCitation } from '../knowledge/domain/KnowledgeRuntimePorts';
import { RuntimeKnowledgeService } from '../services/model/RuntimeKnowledgeService';
import { RuntimeKnowledgeView } from '../services/model/RuntimeKnowledgeSession';
import {
  knowledgeAnswerStage, knowledgeRequestUsage, knowledgeRetrievalStage
} from '../services/model/RuntimeKnowledgePresentation';
import { ShuviRuntimeState } from '../services/model/ShuviRuntimeController';
import { Theme } from './Theme';

/**
 * PR26 card styling for authorization and numbered source excerpts. The ordinary assistant bubble owns the answer;
 * sources fold after completion and stay visible on failure or insufficient evidence.
 */
@Component
export struct RuntimeKnowledgePanel {
  @Prop @Watch('viewChanged') view: RuntimeKnowledgeView = new RuntimeKnowledgeView();
  @Prop hideQuery: boolean = false;
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

  private sourcesVisible(): boolean { return this.sourcesOpen || this.view.stage !== 'complete'; }

  private statusText(): string {
    return this.view.lifecycle === ShuviRuntimeState.READY && !this.view.busy && this.view.query.length === 0 ?
      '已授权：助手按需查询资料，实际使用时展示来源。' : this.view.message;
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('个人知识库').fontSize(Theme.titleSize).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
        Blank()
        if (this.view.busy || this.view.lifecycle === ShuviRuntimeState.READY || this.view.lifecycle === ShuviRuntimeState.STARTING) {
          Button(this.view.busy ? '取消本轮' : '撤销授权').fontSize(13).fontColor(Theme.accent)
            .backgroundColor(Theme.soft).borderRadius(Theme.radius).constraintSize({ minHeight: Theme.controlHeight })
            .id('runtime-knowledge-close')
            .accessibilityText(this.view.busy ? '取消当前知识库问答，已显示的来源会保留' : '撤销个人知识库授权，继续普通对话')
            .onClick((): void => {
              if (this.view.busy) { void RuntimeKnowledgeService.session.cancelCurrent(); }
              else { this.onDisable(); }
            })
        }
      }.width('100%')
      Text(this.statusText()).fontSize(13).fontColor(Theme.muted).width('100%').id('runtime-knowledge-status')
      if (this.stopped()) {
        Text('个人知识库授权已停止，普通对话可继续。')
          .fontSize(13).fontColor(Theme.muted).width('100%').id('runtime-knowledge-restart-hint')
        Button('返回普通对话').constraintSize({ minHeight: Theme.controlHeight }).borderRadius(Theme.radius)
          .backgroundColor(Theme.accent).fontColor(Color.White).id('runtime-knowledge-enable')
          .onClick((): void => { this.onDisable(); })
      }
      Text('命中片段发送给 DeepSeek；语义查询还可能发送查询到 Embedding Provider 并计费。授权不包含入库或工具写入。').fontSize(12).fontColor(Theme.muted).width('100%')
      if (this.view.query.length > 0) {
        Text(this.hideQuery ? '问：语音消息' : ('问：' + this.view.query)).fontSize(13).fontColor(Theme.muted).width('100%').maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          Text('本机检索 · ' + knowledgeRetrievalStage(this.view)).fontSize(Theme.noteSize).fontColor(Theme.ink)
            .id('runtime-knowledge-retrieval-stage')
          Text('  →  ').fontSize(Theme.noteSize).fontColor(Theme.muted)
          Text('助手处理 · ' + (this.view.stage === 'complete' ? '已完成' : knowledgeAnswerStage(this.view))).fontSize(Theme.noteSize).fontColor(Theme.ink)
            .id('runtime-knowledge-answer-stage')
        }.width('100%').padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor(Theme.inputSurface).borderRadius(Theme.radius)
      }
      if (this.view.stage === 'insufficient') {
        Text('资料中没有足够依据。这不是成功的回答；下方是本机检索到的片段，供你核对。')
          .fontSize(14).fontColor(Theme.amber).width('100%').padding(10)
          .backgroundColor(Theme.warning).border({ width: 1, color: Theme.warningLine }).borderRadius(10)
          .id('runtime-knowledge-insufficient')
      }
      if (this.view.consent && !this.view.busy && this.view.stage === 'answerFailed' && this.view.citations.length > 0) {
        Button('仅重试回答').constraintSize({ minHeight: Theme.controlHeight }).borderRadius(Theme.radius)
          .backgroundColor(Theme.soft).fontColor(Theme.accent)
          .accessibilityText('仅重试 DeepSeek 回答，复用下方片段，不重新检索本机资料')
          .id('runtime-knowledge-retry')
          .onClick((): void => { void RuntimeKnowledgeService.session.retryAnswer(); })
      }
      if (this.view.citations.length > 0) {
        if (this.view.stage === 'complete') {
          Button(this.sourcesOpen ? '收起来源原文 ▴' : `查看 ${this.view.citations.length} 条来源原文 ▾`)
            .fontSize(13).fontColor(Theme.accent).backgroundColor(Color.Transparent).padding({ left: 0, right: 0 })
            .constraintSize({ minHeight: Theme.controlHeight }).id('runtime-knowledge-sources')
            .onClick((): void => { this.sourcesOpen = !this.sourcesOpen; })
        } else {
          Text('本轮来源片段').fontSize(13).fontColor(Theme.muted).fontWeight(FontWeight.Medium)
        }
      }
      if (this.sourcesVisible()) {
        ForEach(this.view.citations, (citation: KnowledgeRuntimeCitation) => {
          Column({ space: 6 }) {
            Text('[' + citation.citationId.toString() + '] ' + citation.title).fontSize(14).fontColor(Theme.ink)
              .fontWeight(FontWeight.Medium)
            Text(citation.evidence === 'Vector' ? '语义命中' : (citation.matchKind === 'Keyword' ? '关键词命中' : '原文字面命中')).fontSize(Theme.noteSize).fontColor(Theme.accent)
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
