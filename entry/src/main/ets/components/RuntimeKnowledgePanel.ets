import { KnowledgeRuntimeCitation } from '../knowledge/domain/KnowledgeRuntimePorts';
import { RuntimeKnowledgeService } from '../services/model/RuntimeKnowledgeService';
import { RuntimeKnowledgeView } from '../services/model/RuntimeKnowledgeSession';
import { ShuviRuntimeState } from '../services/model/ShuviRuntimeController';
import { Theme } from './Theme';

@Component
export struct RuntimeKnowledgePanel {
  @Prop view: RuntimeKnowledgeView = new RuntimeKnowledgeView();
  onStart: () => void = (): void => {};

  build() {
    Column({ space: 10 }) {
      Text('本机知识库检索 · 单次调试').fontSize(16).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
      Text(this.view.message).fontSize(13).fontColor(Theme.muted).width('100%').id('runtime-knowledge-status')
      if (this.view.lifecycle === ShuviRuntimeState.IDLE || this.view.lifecycle === ShuviRuntimeState.STOPPED ||
        this.view.lifecycle === ShuviRuntimeState.FAILED) {
        Text('发送后只读检索当前有效、未归档的本机正文证据。不会联网检索，不会把问题或知识片段发送给外部模型。')
          .fontSize(13).fontColor(Theme.muted).width('100%')
        Text('检索按零费用本机工具处理；启用不读取资料，点击发送才执行一次检索。离开页面或退后台会停止会话。')
          .fontSize(12).fontColor(Theme.muted).width('100%')
        Button('启用本机检索').constraintSize({ minHeight: 44 })
          .backgroundColor(Theme.accent).fontColor(Color.White).id('runtime-knowledge-enable')
          .onClick((): void => { this.onStart(); })
      }
      if (this.view.busy || this.view.lifecycle === ShuviRuntimeState.READY || this.view.lifecycle === ShuviRuntimeState.STARTING) {
        Button(this.view.busy ? '取消并停止会话' : '停止知识库问答').constraintSize({ minHeight: 44 })
          .backgroundColor(Theme.soft).fontColor(Theme.accent)
          .onClick((): void => { void RuntimeKnowledgeService.session.stop(); })
      }
      if (this.view.query.length > 0) { Text('本次问题：' + this.view.query).fontSize(13).fontColor(Theme.ink).width('100%') }
      ForEach(this.view.citations, (citation: KnowledgeRuntimeCitation) => {
        Column({ space: 6 }) {
          Text('[' + citation.citationId.toString() + '] ' + citation.title).fontSize(14).fontColor(Theme.ink)
          Text(citation.excerpt).fontSize(13).fontColor(Theme.muted).maxLines(6)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('本机证据 · ' + citation.kind + ' · ' + citation.evidence).fontSize(11).fontColor(Theme.muted)
        }.alignItems(HorizontalAlign.Start).width('100%').padding(10)
          .border({ width: 1, color: Theme.line }).borderRadius(10)
      }, (citation: KnowledgeRuntimeCitation): string => citation.evidenceId)
      if (this.view.answer.length > 0) {
        Text(this.view.answer).fontSize(15).fontColor(Theme.ink).width('100%').id('runtime-knowledge-answer')
      }
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor(Theme.surface)
      .borderRadius(16).border({ width: 1, color: Theme.line })
  }
}
