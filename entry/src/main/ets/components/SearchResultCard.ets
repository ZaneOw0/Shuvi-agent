import { SearchSource, SearchState, SearchTurn, searchDetail, searchIsBusy } from '../model/SearchModels';
import { Theme } from './Theme';
import { AppIcon } from './AppIcon';

@Component
struct SearchSourceItem {
  @Prop source: SearchSource;
  @State expanded: boolean = false;
  onOpen: (source: SearchSource) => void = () => {};

  build() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text(`0${this.source.number}`).fontSize(12).fontColor(Theme.accent)
          .padding(8).borderRadius(8).backgroundColor(Theme.soft)
        Text(this.source.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(Theme.ink).layoutWeight(1)
      }.width('100%')
      Text('developer.huawei.com').fontSize(11).fontColor(Theme.muted)
      Text(this.source.snippet).fontSize(13).fontColor(Theme.muted)
        .maxLines(this.expanded ? 20 : 2).textOverflow({ overflow: TextOverflow.Ellipsis })
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        Button(this.expanded ? '收起摘要' : '展开摘要', { type: ButtonType.Normal })
          .fontSize(12).fontColor(Theme.muted).backgroundColor(Color.Transparent).constraintSize({ minHeight: 44 })
          .accessibilityText(`${this.expanded ? '收起' : '展开'}来源 ${this.source.number} 的摘要`)
          .onClick(() => this.expanded = !this.expanded)
        Button('打开原文 ↗', { type: ButtonType.Normal }).fontSize(12)
          .fontColor(Theme.accent).backgroundColor(Color.Transparent).constraintSize({ minHeight: 44 })
          .accessibilityText(`打开${this.source.title}的外部网页`)
          .onClick(() => this.onOpen(this.source))
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 14, bottom: 4 })
      .border({ width: { top: 1 }, color: Theme.line })
  }
}

@Component
export struct SearchResultCard {
  @Prop @Watch('onTurnChanged') turn: SearchTurn;
  @Prop actionsEnabled: boolean = true;
  @State sourcesExpanded: boolean = true;
  onCancel: () => void = () => {};
  onRetry: (turn: SearchTurn) => void = () => {};
  onRetryAnswer: (turn: SearchTurn) => void = () => {};
  onEdit: (turn: SearchTurn) => void = () => {};
  onOpen: (source: SearchSource) => void = () => {};
  onCitation: (source: SearchSource) => void = () => {};

  aboutToAppear(): void {
    this.sourcesExpanded = this.turn.state !== SearchState.Complete;
  }

  private onTurnChanged(): void {
    this.sourcesExpanded = this.turn.state !== SearchState.Complete;
  }

  @Builder
  sourceList() {
    Column() {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          AppIcon({ source: $r('app.media.chat_book'), size: 18 })
          Column({ space: 4 }) {
            Text('参考来源').fontSize(14).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
            Text(`${this.turn.sources.length} 条 · 华为开发者联盟`).fontSize(11).fontColor(Theme.muted)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text(this.sourcesExpanded ? '收起' : '展开').fontSize(12).fontColor(Theme.accent)
        }.width('100%').constraintSize({ minHeight: 52 })
      }.width('100%').backgroundColor(Color.Transparent).borderRadius(0)
        .accessibilityText(`参考来源，${this.turn.sources.length} 条，${this.sourcesExpanded ? '已展开，点击收起' : '已收起，点击展开'}`)
        .onClick(() => this.sourcesExpanded = !this.sourcesExpanded)
      if (this.sourcesExpanded) {
        ForEach(this.turn.sources, (source: SearchSource) => {
          SearchSourceItem({ source: source, onOpen: this.onOpen })
        }, (source: SearchSource) => source.url)
        Text('固定来源 · 摘录为示意，完整信息以原文为准').fontSize(11).fontColor(Theme.muted)
          .width('100%').padding({ top: 8, bottom: 4 })
      }
    }.width('100%').padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
  }

  @Builder
  sampleAnswer() {
    Column({ space: 12 }) {
      Text('示例回答 · 非模型生成').fontSize(11).fontColor(Theme.accent)
      Text('从这两个入口开始就好。').fontSize(21).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
      Text('先了解框架能做什么，再进入开发入门，会更容易找到方向。').fontSize(14).fontColor(Theme.ink)
      ForEach(this.turn.sources.slice(0, 2), (source: SearchSource) => {
        Column({ space: 6 }) {
          Text(source.number === 1 ? '01  先看框架概览' : '02  再看开发入门')
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
          Text(source.number === 1 ? '了解 ArkUI 的声明式 UI、组件与预览能力。' : '沿开发指引继续查找 API 参考和常见问题。')
            .fontSize(14).fontColor(Theme.ink)
          Button(`来源 [${source.number}]`, { type: ButtonType.Normal }).fontSize(12)
            .constraintSize({ minHeight: 44 }).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(10)
            .accessibilityText(`查看引用来源 ${source.number}，${source.title}`)
            .onClick(() => this.onCitation(source))
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (source: SearchSource) => source.url)
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 6, bottom: 8 })
  }

  build() {
    Column({ space: 14 }) {
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          if (searchIsBusy(this.turn.state)) {
            LoadingProgress().width(24).height(24).color(Theme.accent).accessibilityLevel('no')
          } else {
            AppIcon({ source: $r('app.media.chat_globe'), size: 24 })
          }
          Column({ space: 6 }) {
            Text(this.turn.state).fontSize(16).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
            Text(searchDetail(this.turn)).fontSize(12).fontColor(Theme.muted)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%')
        if (this.turn.state === SearchState.Searching) {
          Text('关键词：HarmonyOS ArkUI 官方开发文档').fontSize(11).fontColor(Theme.muted).width('100%')
        }
        if (searchIsBusy(this.turn.state)) {
          Button(this.turn.state === SearchState.Searching ? '取消搜索' : '停止生成', { type: ButtonType.Normal })
            .constraintSize({ minHeight: 44 }).fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft)
            .borderRadius(12).onClick(this.onCancel)
        }
      }.width('100%').alignItems(HorizontalAlign.Start).padding(16)
        .backgroundColor(Theme.inputSurface).borderRadius(18).border({ width: 1, color: Theme.line })
      if (this.turn.sources.length > 0 || this.turn.state === SearchState.Searching) {
        Text(`${this.turn.sources.length > 0 ? '搜索完成' : '搜索资料'}  →  ${this.turn.state === SearchState.Complete ?
          '回答完成' : this.turn.state === SearchState.Answering ? '整理回答' : this.turn.state === SearchState.Searching ? '等待回答' : '回答未完成'}`)
          .fontSize(12).fontColor(Theme.accent)
      }
      if (this.turn.sources.length > 0) {
        this.sourceList()
      }
      if (this.turn.state === SearchState.Complete) {
        this.sampleAnswer()
      } else if (!searchIsBusy(this.turn.state)) {
        Flex({ wrap: FlexWrap.Wrap }) {
          if (this.turn.sources.length > 0) {
            Button('重新生成回答（演示）').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft)
              .constraintSize({ minHeight: 44 }).margin({ right: 8, bottom: 6 })
              .enabled(this.actionsEnabled).onClick(() => this.onRetryAnswer(this.turn))
          } else if (this.turn.state !== SearchState.Unsupported && this.turn.state !== SearchState.Empty) {
            Button(this.turn.state === SearchState.Denied ? '模拟允许本次搜索' : '重新搜索')
              .fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).constraintSize({ minHeight: 44 })
              .margin({ right: 8, bottom: 6 }).enabled(this.actionsEnabled).onClick(() => this.onRetry(this.turn))
          }
          Button(this.turn.state === SearchState.Unsupported ? '填入搜索样例' : '修改问题')
            .fontSize(13).fontColor(Theme.muted).backgroundColor(Color.Transparent).constraintSize({ minHeight: 44 })
            .enabled(this.actionsEnabled).onClick(() => this.onEdit(this.turn))
        }.width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
