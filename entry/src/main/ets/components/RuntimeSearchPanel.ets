import { Theme } from './Theme';
import { DeepSeekKeyField } from './DeepSeekKeyField';
import { RuntimeSearchService } from '../services/model/RuntimeSearchService';
import { RuntimeSearchView } from '../services/model/RuntimeSearchSession';
import { ShuviRuntimeState } from '../services/model/ShuviRuntimeController';
import { LiveSearchSource } from '../services/model/SearchTaskSupport';
import { SourceLinkService } from '../services/SourceLinkService';

@Component
export struct RuntimeSearchPanel {
  @Prop view: RuntimeSearchView = new RuntimeSearchView();
  @State linkMessage: string = '';
  onStart: (key: Uint8Array) => void = (_key: Uint8Array): void => {};
  build() {
    Column({ space: 10 }) {
      Text('真实联网搜索 · 单次调试').fontSize(16).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
      Text(this.view.message).fontSize(13).fontColor(Theme.muted).id('runtime-search-status')
      if (this.view.lifecycle === ShuviRuntimeState.IDLE || this.view.lifecycle === ShuviRuntimeState.STOPPED ||
        this.view.lifecycle === ShuviRuntimeState.FAILED) {
        Text('关键词发送至 Tavily；检索后的摘录发送至 DeepSeek 整理回答。不读取聊天历史、知识库或日历。启用只连接服务，发送后还需确认搜索。')
          .fontSize(13).fontColor(Theme.muted)
        Text('账户 shuvi-dev-tavily · 账单币种 CNY。最多一次未核账搜索，重启不重置；失败、取消也可能占用额度。模型沿用 USD 0.01/次估算准入，实际扣款另核对。')
          .fontSize(12).fontColor(Theme.muted)
        DeepSeekKeyField({ clearEpoch: this.view.clearEpoch, enableLabel: '同意上述范围并连接', idPrefix: 'runtime-search',
          purpose: '搜索回答', onKey: (key: Uint8Array): void => { this.onStart(key); } })
      }
      if (this.view.preview !== undefined) {
        Text('允许发送以下关键词？').fontSize(15).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
        Text(this.view.preview?.query ?? '').fontSize(15).fontColor(Theme.ink).width('100%')
        Text('工具 web_search · Tavily · 最多 3 条结果。授权有效期 60 秒。检索成功后将摘录发给 DeepSeek 生成回答。')
          .fontSize(12).fontColor(Theme.muted)
        Text('本机搜索预算预留 CNY 1.00，仅为调试预留，非供应商报价、实际扣款或计费硬上限。实际金额未知，保留待核账；本轮不自动释放额度。')
          .fontSize(12).fontColor(Theme.muted)
        Flex({ wrap: FlexWrap.Wrap }) {
          Button('拒绝').constraintSize({ minHeight: 44 }).backgroundColor(Theme.soft).fontColor(Theme.accent)
            .onClick((): void => { void RuntimeSearchService.session.decide(false); }).id('runtime-search-deny')
          Button('允许这一次搜索').constraintSize({ minHeight: 44 }).backgroundColor(Theme.accent).fontColor(Color.White)
            .onClick((): void => { void RuntimeSearchService.session.decide(true); }).id('runtime-search-allow')
        }
      }
      if (this.view.busy || this.view.lifecycle === ShuviRuntimeState.READY || this.view.lifecycle === ShuviRuntimeState.STARTING) {
        Button(this.view.busy ? '取消并停止会话' : '停止搜索会话').constraintSize({ minHeight: 44 })
          .backgroundColor(Theme.soft).fontColor(Theme.accent).onClick((): void => { void RuntimeSearchService.session.stop(); })
      }
      if (this.view.query.length > 0) {
        Text('本次关键词：' + this.view.query).fontSize(13).fontColor(Theme.ink)
        Text(this.view.billing).fontSize(12).fontColor(Theme.muted).id('runtime-search-billing')
      }
      ForEach(this.view.sources, (source: LiveSearchSource, index: number) => {
        Column({ space: 6 }) {
          Text('[' + (index + 1).toString() + '] ' + source.title).fontSize(14).fontColor(Theme.ink)
          Text(source.url).fontSize(11).fontColor(Theme.muted)
          Text(source.snippet).fontSize(13).fontColor(Theme.muted).maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis })
          Button('打开此来源').constraintSize({ minHeight: 44 }).backgroundColor(Theme.soft).fontColor(Theme.accent)
            .accessibilityText('打开来源 ' + (index + 1).toString() + '，' + source.title)
            .onClick((): void => {
              this.linkMessage = '';
              void SourceLinkService.openSearchSource(source.url).catch((): void => { this.linkMessage = '无法打开来源，请稍后重试。'; });
            })
        }.alignItems(HorizontalAlign.Start).width('100%').padding(10).border({ width: 1, color: Theme.line }).borderRadius(10)
      }, (_source: LiveSearchSource, index: number): string => this.view.query + '-' + index.toString())
      if (this.linkMessage) { Text(this.linkMessage).fontSize(12).fontColor(Theme.muted) }
      if (this.view.answer) { Text(this.view.answer).fontSize(15).fontColor(Theme.ink).width('100%').id('runtime-search-answer') }
      if (this.view.stage === 'answerFailed' && this.view.lifecycle === ShuviRuntimeState.READY) {
        Button('仅重试回答').constraintSize({ minHeight: 44 }).backgroundColor(Theme.soft).fontColor(Theme.accent)
          .onClick((): void => { void RuntimeSearchService.session.retryAnswer(); })
      }
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor(Theme.surface)
      .borderRadius(16).border({ width: 1, color: Theme.line })
  }
}
