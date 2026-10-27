import { KnowledgeRuntimeCitation } from '../knowledge/domain/KnowledgeRuntimePorts';
import { RuntimeKnowledgeService } from '../services/model/RuntimeKnowledgeService';
import { RuntimeKnowledgeView } from '../services/model/RuntimeKnowledgeSession';
import {
  knowledgeAnswerIsModel, knowledgeAnswerStage, knowledgeRequestUsage, knowledgeRetrievalStage, knowledgeRetryAvailable
} from '../services/model/RuntimeKnowledgePresentation';
import { ShuviRuntimeState } from '../services/model/ShuviRuntimeController';
import { Theme } from './Theme';

@Component
export struct RuntimeKnowledgePanel {
  @Prop view: RuntimeKnowledgeView = new RuntimeKnowledgeView();
  onDisable: () => void = (): void => {};

  build() {
    Column({ space: 10 }) {
      Text('知识库 RAG · 本机检索后由 DeepSeek 整理').fontSize(16).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
      Text(this.view.message).fontSize(13).fontColor(Theme.muted).width('100%').id('runtime-knowledge-status')
      if (this.view.lifecycle === ShuviRuntimeState.IDLE || this.view.lifecycle === ShuviRuntimeState.STOPPED ||
        this.view.lifecycle === ShuviRuntimeState.FAILED) {
        Text('RAG 会话已停止或未就绪，本次会话的 DeepSeek 凭据不再可用。要再次使用知识库问答：返回普通对话 → 停止真实对话 → 重新输入 Key 启用；如仍不可用，请检查 Embedding Provider 与向量数据。')
          .fontSize(13).fontColor(Theme.muted).width('100%').id('runtime-knowledge-restart-hint')
        Text('只有问题向量化会调用已配置的 Embedding Provider；检索结果在本机合并后，最多 5 条片段发送给 DeepSeek。')
          .fontSize(12).fontColor(Theme.muted).width('100%')
        Button('返回普通对话').constraintSize({ minHeight: 44 })
          .backgroundColor(Theme.accent).fontColor(Color.White).id('runtime-knowledge-enable')
          .onClick((): void => { this.onDisable(); })
      }
      if (this.view.busy || this.view.lifecycle === ShuviRuntimeState.READY || this.view.lifecycle === ShuviRuntimeState.STARTING) {
        Button(this.view.busy ? '取消当前 RAG 问答' : '关闭知识库 RAG').constraintSize({ minHeight: 44 })
          .backgroundColor(Theme.soft).fontColor(Theme.accent)
          .onClick((): void => {
            if (this.view.busy) { void RuntimeKnowledgeService.session.cancelCurrent(); }
            else { this.onDisable(); }
          })
      }
      if (this.view.query.length > 0) {
        Text('本次问题：' + this.view.query).fontSize(13).fontColor(Theme.ink).width('100%')
        Column({ space: 4 }) {
          Text('本机检索：' + knowledgeRetrievalStage(this.view)).fontSize(13).fontColor(Theme.ink)
            .id('runtime-knowledge-retrieval-stage')
          Text('模型回答：' + knowledgeAnswerStage(this.view)).fontSize(13).fontColor(Theme.ink)
            .id('runtime-knowledge-answer-stage')
        }.alignItems(HorizontalAlign.Start).width('100%').padding(10).backgroundColor(Theme.inputSurface).borderRadius(10)
      }
      if (this.view.requestCount > 0) {
        Text(knowledgeRequestUsage(this.view)).fontSize(12).fontColor(Theme.muted).id('runtime-knowledge-usage')
      }
      if (knowledgeAnswerIsModel(this.view)) {
        Column({ space: 6 }) {
          Text('DeepSeek 整理回答（依据下方片段，不是原始资料）').fontSize(12).fontColor(Theme.muted)
            .id('runtime-knowledge-answer-label')
          Text(this.view.answer).fontSize(15).fontColor(Theme.ink).width('100%').id('runtime-knowledge-answer')
        }.alignItems(HorizontalAlign.Start).width('100%').padding(12).backgroundColor(Theme.bubble).borderRadius(12)
      } else if (this.view.answer.length > 0) {
        Text(this.view.answer).fontSize(15).fontColor(Theme.ink).width('100%').id('runtime-knowledge-local-answer')
      }
      if (this.view.stage === 'insufficient') {
        Text('资料中没有足够依据。这不是成功的回答；下方是本机检索到的片段，供你核对。')
          .fontSize(14).fontColor(Theme.amber).width('100%').padding(10)
          .backgroundColor(Theme.warning).border({ width: 1, color: Theme.warningLine }).borderRadius(10)
          .id('runtime-knowledge-insufficient')
      }
      if (knowledgeRetryAvailable(this.view)) {
        Button('仅重试回答').constraintSize({ minHeight: 44 }).backgroundColor(Theme.soft).fontColor(Theme.accent)
          .accessibilityText('仅重试 DeepSeek 回答，复用下方片段，不重新检索本机资料')
          .id('runtime-knowledge-retry')
          .onClick((): void => { void RuntimeKnowledgeService.session.retryAnswer(); })
      }
      if (this.view.citations.length > 0) {
        Text('本机原始片段').fontSize(13).fontColor(Theme.muted).fontWeight(FontWeight.Medium)
      }
      ForEach(this.view.citations, (citation: KnowledgeRuntimeCitation) => {
        Column({ space: 6 }) {
          Text('[' + citation.citationId.toString() + '] ' + citation.title).fontSize(14).fontColor(Theme.ink)
          Text(citation.excerpt).fontSize(13).fontColor(Theme.muted).maxLines(6)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('本机证据 · ' + citation.kind + ' · ' + citation.evidence).fontSize(11).fontColor(Theme.muted)
        }.alignItems(HorizontalAlign.Start).width('100%').padding(10)
          .border({ width: 1, color: Theme.line }).borderRadius(10)
      }, (citation: KnowledgeRuntimeCitation): string => citation.evidenceId)
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor(Theme.surface)
      .borderRadius(16).border({ width: 1, color: Theme.line })
  }
}
