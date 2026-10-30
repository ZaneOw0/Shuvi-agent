import { Theme } from './Theme';
import { RuntimeSearchService } from '../services/model/RuntimeSearchService';
import { RuntimeSearchView } from '../services/model/RuntimeSearchSession';
import { ShuviRuntimeState } from '../services/model/ShuviRuntimeController';
import { LiveSearchSource } from '../services/model/SearchTaskSupport';
import { SourceLinkService } from '../services/SourceLinkService';

/**
 * Status of the assistant's web_search tool. 搜索 authorizes it for the conversation; the phone calls Tavily directly with
 * the Tavily key saved in 我的 → API Key 管理. The answer itself, with its source list, appears in the chat.
 */
@Component
export struct RuntimeSearchPanel {
  @Prop view: RuntimeSearchView = new RuntimeSearchView();
  @Prop hideQuery: boolean = false;
  @Prop keySaved: boolean = false;
  @Prop connecting: boolean = false;
  @State linkMessage: string = '';
  @State details: boolean = false;
  onConnect: () => void = (): void => {};
  onKeys: () => void = (): void => {};

  private disconnected(): boolean {
    return this.view.lifecycle === ShuviRuntimeState.IDLE || this.view.lifecycle === ShuviRuntimeState.STOPPED ||
      this.view.lifecycle === ShuviRuntimeState.FAILED;
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('联网搜索').fontSize(16).fontColor(Theme.ink).fontWeight(FontWeight.Medium).layoutWeight(1)
        if (this.view.lifecycle === ShuviRuntimeState.READY && !this.view.busy) {
          Text('已连接').fontSize(11).fontColor(Theme.ok).backgroundColor(Theme.okSoft)
            .padding({ left: 9, right: 9, top: 4, bottom: 4 }).borderRadius(10)
        }
      }.width('100%')
      if (!this.keySaved) {
        Text('联网搜索用 DeepSeek 整理搜索结果。请先在「我的 → API Key 管理」保存 DeepSeek Key。')
          .fontSize(13).fontColor(Theme.muted).width('100%').lineHeight(20)
        Button('去设置').fontSize(14).fontColor(Color.White).backgroundColor(Theme.accent).borderRadius(Theme.radius)
          .width('100%').constraintSize({ minHeight: Theme.controlHeight }).id('runtime-search-open-keys')
          .onClick((): void => { this.onKeys(); })
      } else if (this.disconnected() || this.view.lifecycle === ShuviRuntimeState.STARTING) {
        Text(this.connecting || this.view.lifecycle === ShuviRuntimeState.STARTING ? '正在连接搜索服务…' :
          (this.view.lifecycle === ShuviRuntimeState.FAILED ? '搜索没有连接上。请确认已在「我的 → API Key 管理」保存 Tavily Key。' : '搜索还没有连接。'))
          .fontSize(13).fontColor(Theme.muted).width('100%').id('runtime-search-status')
        if (this.disconnected() && !this.connecting) {
          Button(this.view.lifecycle === ShuviRuntimeState.FAILED ? '重新连接' : '连接').fontSize(14).fontColor(Theme.accent)
            .backgroundColor(Theme.soft).borderRadius(Theme.radius).width('100%').constraintSize({ minHeight: Theme.controlHeight })
            .id('runtime-search-connect').onClick((): void => { this.onConnect(); })
        }
      } else if (this.view.preview === undefined && this.view.query.length === 0) {
        Text('直接提问即可：需要时助手会自己决定关键词，发给 Tavily 搜索，再把网页摘录交给 DeepSeek 整理回答，并在回答末尾列出来源。')
          .fontSize(13).fontColor(Theme.muted).width('100%').lineHeight(20).id('runtime-search-status')
      }
      if (this.disconnected() || this.view.preview === undefined) {
        Button(this.details ? '收起说明 ▴' : '范围与费用 ▾').fontSize(Theme.noteSize).fontColor(Theme.accent)
          .backgroundColor(Color.Transparent).padding({ left: 0, right: 0 }).constraintSize({ minHeight: 32 })
          .id('runtime-search-details').onClick((): void => { this.details = !this.details; })
        if (this.details) {
          Column({ space: 6 }) {
            Text('关键词由助手根据当前对话生成，可能包含对话中的信息；网页内容只当参考资料，其中的指令会被忽略。关闭开关或开始新对话即撤销。')
              .fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
            Text('关键词由手机直接发送到 Tavily（api.tavily.com），使用你在「我的 → API Key 管理」保存的 Tavily Key。每次搜索都可能消耗 Tavily 额度，失败或取消也可能计费；费用以 Tavily 和 DeepSeek 账单为准。')
              .fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
          }.width('100%').padding(10).backgroundColor(Theme.inputSurface).borderRadius(Theme.radius)
        }
      }
      if (this.view.busy) {
        Text(this.view.message).fontSize(13).fontColor(Theme.muted).width('100%')
        Button('取消').constraintSize({ minHeight: 44 }).backgroundColor(Theme.soft).fontColor(Theme.accent)
          .id('runtime-search-cancel').onClick((): void => { void RuntimeSearchService.session.cancelCurrent(); })
      }
      if (this.view.query.length > 0) {
        Text(this.hideQuery ? '本次输入：语音消息' : ('关键词：' + this.view.query)).fontSize(13).fontColor(Theme.ink).width('100%')
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
      if (!this.view.busy && this.view.query.length > 0 && this.view.answer.length === 0 &&
        this.view.lifecycle === ShuviRuntimeState.READY && this.view.preview === undefined) {
        Text(this.view.message).fontSize(13).fontColor(Theme.muted).width('100%')
      }
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor(Theme.surface)
      .borderRadius(16).border({ width: 1, color: Theme.line })
  }
}
