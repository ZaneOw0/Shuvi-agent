import { Theme } from './Theme';
import { RuntimeSearchService } from '../services/model/RuntimeSearchService';
import { RuntimeSearchView } from '../services/model/RuntimeSearchSession';
import { ShuviRuntimeState } from '../services/model/ShuviRuntimeController';
import { LiveSearchSource } from '../services/model/SearchTaskSupport';
import { SourceLinkService } from '../services/SourceLinkService';

/**
 * Web search inside the assistant. The session connects with the DeepSeek key saved in 我的 → API Key 管理; every search
 * still asks for consent with the exact keywords before anything is sent.
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
          (this.view.lifecycle === ShuviRuntimeState.FAILED ? '搜索服务没有连接上。' : '搜索还没有连接。'))
          .fontSize(13).fontColor(Theme.muted).width('100%').id('runtime-search-status')
        if (this.disconnected() && !this.connecting) {
          Button(this.view.lifecycle === ShuviRuntimeState.FAILED ? '重新连接' : '连接').fontSize(14).fontColor(Theme.accent)
            .backgroundColor(Theme.soft).borderRadius(Theme.radius).width('100%').constraintSize({ minHeight: Theme.controlHeight })
            .id('runtime-search-connect').onClick((): void => { this.onConnect(); })
        }
      } else if (this.view.preview === undefined && this.view.query.length === 0) {
        Text('输入想查的内容并发送。关键词发给 Tavily 搜索，摘录交给 DeepSeek 整理成回答；每次搜索前都会先请你确认关键词。')
          .fontSize(13).fontColor(Theme.muted).width('100%').lineHeight(20).id('runtime-search-status')
      }
      if (this.disconnected() || this.view.preview === undefined) {
        Button(this.details ? '收起说明 ▴' : '范围与费用 ▾').fontSize(Theme.noteSize).fontColor(Theme.accent)
          .backgroundColor(Color.Transparent).padding({ left: 0, right: 0 }).constraintSize({ minHeight: 32 })
          .id('runtime-search-details').onClick((): void => { this.details = !this.details; })
        if (this.details) {
          Column({ space: 6 }) {
            Text('只发送你确认过的关键词，不读取聊天历史、知识库或日历。')
              .fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
            Text('搜索服务目前运行在开发电脑上。为控制费用，本机暂时只允许一次搜索，重启也不重置；失败或取消也可能占用。费用以 Tavily 和 DeepSeek 账单为准。')
              .fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
          }.width('100%').padding(10).backgroundColor(Theme.inputSurface).borderRadius(Theme.radius)
        }
      }
      if (this.view.preview !== undefined) {
        Text(this.hideQuery ? '允许用这条语音的后台转写搜索？' : '允许发送以下关键词？').fontSize(15).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
        Text(this.hideQuery ? '语音消息（转写内容不显示）' : (this.view.preview?.query ?? '')).fontSize(15).fontColor(Theme.ink).width('100%')
        Text('最多取 3 条结果，摘录会交给 DeepSeek 生成回答。60 秒内有效，可能产生费用。')
          .fontSize(12).fontColor(Theme.muted).width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          Button('拒绝').constraintSize({ minHeight: 44 }).backgroundColor(Theme.soft).fontColor(Theme.accent)
            .margin({ right: 10 })
            .onClick((): void => { void RuntimeSearchService.session.decide(false); }).id('runtime-search-deny')
          Button('允许这一次搜索').constraintSize({ minHeight: 44 }).backgroundColor(Theme.accent).fontColor(Color.White)
            .onClick((): void => { void RuntimeSearchService.session.decide(true); }).id('runtime-search-allow')
        }
      }
      if (this.view.busy) {
        Text(this.view.message).fontSize(13).fontColor(Theme.muted).width('100%')
        Button('取消').constraintSize({ minHeight: 44 }).backgroundColor(Theme.soft).fontColor(Theme.accent)
          .id('runtime-search-cancel').onClick((): void => { void RuntimeSearchService.session.stop(); })
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
      if (this.view.stage === 'answerFailed' && this.view.lifecycle === ShuviRuntimeState.READY) {
        Button('仅重试回答').constraintSize({ minHeight: 44 }).backgroundColor(Theme.soft).fontColor(Theme.accent)
          .onClick((): void => { void RuntimeSearchService.session.retryAnswer(); })
      }
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor(Theme.surface)
      .borderRadius(16).border({ width: 1, color: Theme.line })
  }
}
