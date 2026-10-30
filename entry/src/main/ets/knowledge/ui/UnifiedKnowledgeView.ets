import { Theme } from '../../components/Theme';
import { AppIcon } from '../../components/AppIcon';
import { FeatureRow } from '../../components/FeaturePages';
import { KnowledgeHeading, KnowledgeNotice, KnowledgeEmpty } from './KnowledgeVisuals';
import { ParsedFailure } from '../domain/ParsedDocumentModels';
import { KnowledgeQuerySession } from '../application/KnowledgeQuerySession';
import { UnifiedSearchCard, UnifiedSearchHistoryPage } from '../domain/UnifiedQueryModels';
import { UnifiedKnowledgeResultCard } from './KnowledgeResultCard';
import { KNOWLEDGE_RESULT_PAGE_SIZE, knowledgeSearchTabCards, knowledgeSearchPage, knowledgeHistoryTags } from './KnowledgeSearchPresentation';

@Component
export struct UnifiedKnowledgeView {
  session: KnowledgeQuerySession | undefined = undefined;
  @Prop availableHeight: number = 720;
  onOpen: (card: UnifiedSearchCard) => void = (_card: UnifiedSearchCard): void => {};
  onDocuments: () => void = (): void => {};
  @State errorDetails: boolean = false;
  @State searchMode: boolean = false;
  @State searched: boolean = false;
  @State question: string = '';
  @State archived: boolean = false;
  @State direct: UnifiedSearchCard[] = [];
  @State related: UnifiedSearchCard[] = [];
  @State directBusy: boolean = false;
  @State relatedBusy: boolean = false;
  @State directMore: boolean = false;
  @State relatedMore: boolean = false;
  @State directError: string = '';
  @State relatedError: string = '';
  @State semantic: string = 'NotRequested';
  @State semanticError: string = '';
  @State reviewText: string = '';
  @State message: string = '';
  @State activeTab: number = 0;
  @State directPage: number = 0;
  @State relatedPage: number = 0;
  @State semanticPage: number = 0;
  @State paging: boolean = false;
  @State historyRows: UnifiedSearchHistoryPage[] = [];
  @State historyOpen: boolean = false;
  @State historyMore: boolean = false;
  @State historyBusy: boolean = false;
  @State historyClearing: boolean = false;
  private historyOffset: number = 0;
  private historyEpoch: number = 0;
  private pageEpoch: number = 0;
  private alive: boolean = false;
  private queryInputController: TextInputController = new TextInputController();
  private resultScroller: Scroller = new Scroller();
  private historyScroller: Scroller = new Scroller();
  private listener: () => void = (): void => { this.refresh(); };
  aboutToAppear(): void {
    this.alive = true; this.session?.subscribe(this.listener);
    this.question = this.session?.state.question ?? ''; this.archived = this.session?.state.includeArchived ?? false; this.refresh();
  }
  aboutToDisappear(): void { this.alive = false; this.historyEpoch++; this.pageEpoch++; this.session?.unsubscribe(this.listener); this.session?.invalidate(); }
  private refresh(): void {
    const state = this.session?.state;
    if (state === undefined) { this.message = '资料搜索尚未就绪，请稍后重试'; return; }
    this.direct = state.direct.cards.slice(); this.related = state.related.cards.slice();
    this.directBusy = state.direct.busy; this.relatedBusy = state.related.busy;
    this.directMore = !state.direct.exhausted; this.relatedMore = !state.related.exhausted;
    this.directError = state.direct.error; this.relatedError = state.related.error;
    this.semantic = state.semanticState; this.semanticError = state.semanticError;
    if (state.direct.error.length > 0 || state.related.error.length > 0) { this.message = '资料读取失败，请重试搜索'; }
  }
  private resetPages(): void { this.pageEpoch++; this.directPage = 0; this.relatedPage = 0; this.semanticPage = 0; this.activeTab = 0; this.paging = false; }
  private edit(text: string): void { this.question = text; this.reviewText = ''; this.resetPages(); this.session?.edit(text, this.archived); }
  private async local(): Promise<void> {
    if (this.historyClearing || this.session === undefined) { return; }
    this.queryInputController.stopEditing(); this.resetPages(); this.searchMode = true; this.searched = true; this.reviewText = ''; this.message = '';
    try { await this.session.start(this.question, this.archived); if (this.alive && this.historyOpen) { await this.loadHistory(true); } }
    catch { if (this.alive) { this.message = '本机资料读取失败，请重试搜索'; } }
  }
  private async review(): Promise<void> {
    try { const approval = await this.session?.review(); if (this.alive) { this.reviewText = approval === undefined ? '' : `本次将发送问题：${approval.actual}\n接收方为当前嵌入服务，仅用于此次语义搜索，可能产生费用。翻页不会再次发送。`; } }
    catch (error) { if (this.alive) { this.reviewText = this.reviewFailure(error); } }
  }
  private reviewFailure(error: Object): string {
    if (!(error instanceof ParsedFailure)) { return '本机语义检索准备失败，未发送问题。请重新搜索后重试。'; }
    let message: string = '语义检索准备失败，未发送问题。';
    switch (error.category) {
      case 'UnifiedEmbeddingDisabled': message = '自动入库尚未启用。请到「我的 → 嵌入模型」开启，等资料处理完成后再用语义搜索。'; break;
      case 'UnifiedEmbeddingCostRequired': message = '请先到「我的 → 嵌入模型」确认发送范围与可能费用。'; break;
      case 'UnifiedEmbeddingPaused': message = '资料处理已暂停，请先恢复处理。'; break;
      case 'UnifiedEmbeddingBaselineRequired': message = '请先到「我的 → 嵌入模型」重新开启自动入库。'; break;
      case 'UnifiedEmbeddingConfigChanged': message = 'Key 或模型设置已变化。请到「我的 → 嵌入模型」重新开启自动入库，并等资料处理完成。'; break;
      case 'UnifiedSpaceMissing': message = '尚无当前模型的新统一向量空间。请先完成至少一份资料的向量化；保存原件或 OCR 入库还不包含向量。'; break;
      case 'UnifiedTargetsMissing': message = '当前范围没有已完成向量化且有效的资料，请检查资料是否归档、向量任务是否完成。'; break;
      case 'CurrentLocalScopeRequired': message = '请先点击「搜索」建立当前问题，再使用语义搜索。'; break;
      case 'LocalMembershipChangedStartNewSession': message = '资料范围刚发生变化，请重新点击「搜索」。'; break;
      case 'UnifiedQueryCountOrBaseline': message = '这个问题没能用于语义搜索：可能太长，或嵌入模型设置有变化。请缩短后重试，或到「我的 → 嵌入模型」检查。'; break;
      case 'UnifiedScopeIncomplete': message = '本机资料范围读取未完成，请重试搜索。'; break;
    }
    return message + '\n未发送问题。原因：' + error.category;
  }
  private async semanticSearch(): Promise<void> {
    try { await this.session?.allowSemantic(true, true); } catch { if (this.alive) { this.message = '当前问题授权已变化，请重新搜索后重试'; } }
  }
  private activeCards(): UnifiedSearchCard[] { return knowledgeSearchTabCards(this.direct, this.related, this.activeTab); }
  private pageIndex(): number { return this.activeTab === 0 ? this.directPage : this.activeTab === 1 ? this.relatedPage : this.semanticPage; }
  private setPage(index: number): void {
    if (this.activeTab === 0) { this.directPage = index; } else if (this.activeTab === 1) { this.relatedPage = index; } else { this.semanticPage = index; }
    this.resultScroller.scrollEdge(Edge.Top);
  }
  private pageRows(): UnifiedSearchCard[] { return knowledgeSearchPage(this.activeCards(), this.pageIndex()); }
  private hasMore(): boolean { return this.activeTab === 2 && this.semantic !== 'Complete' ? false : this.activeTab === 0 ? this.directMore : this.relatedMore; }
  private canNext(): boolean { return (this.pageIndex() + 1) * KNOWLEDGE_RESULT_PAGE_SIZE < this.activeCards().length || this.hasMore(); }
  private pageText(): string {
    const count: number = this.activeCards().length;
    return `第 ${this.pageIndex() + 1} 页 · 已找到 ${count} 条${this.hasMore() ? '，可继续查找' : ''}`;
  }
  private switchTab(tab: number): void { if (this.paging) { return; } this.activeTab = tab; this.resultScroller.scrollEdge(Edge.Top); }
  private async nextPage(): Promise<void> {
    if (this.paging || this.directBusy || this.relatedBusy || this.historyClearing || this.session === undefined) { return; }
    const epoch: number = this.pageEpoch; const tab: number = this.activeTab; const target: number = this.pageIndex() + 1;
    const needed: number = target * KNOWLEDGE_RESULT_PAGE_SIZE; this.paging = true;
    try {
      // A bounded continuation may be needed because the existing related stream contains both tags and vectors.
      for (let attempt: number = 0; attempt < 3 && needed >= this.activeCards().length && this.hasMore(); attempt++) {
        const state = this.session.state; const group = tab === 0 ? state.direct : state.related; const cursor: string = group.cursor;
        await this.session.page(tab === 0 ? 'Direct' : 'Related', cursor);
        if (!this.alive || epoch !== this.pageEpoch || tab !== this.activeTab) { return; }
        if (group.cursor === cursor) { break; }
      }
      if (!this.alive || epoch !== this.pageEpoch) { return; }
      if (needed < this.activeCards().length) { this.setPage(target); }
      else { this.message = this.hasMore() ? '本次未找到更多此类结果，可继续查找。' : '已显示此类结果的最后一页。'; }
    } catch { if (this.alive && epoch === this.pageEpoch) { this.message = '下一页读取失败，当前结果已保留，请重试。'; } }
    finally { if (this.alive && epoch === this.pageEpoch) { this.paging = false; } }
  }
  private async loadHistory(reset: boolean = false): Promise<void> {
    if (this.historyBusy || this.historyClearing || this.session === undefined) { return; }
    const epoch: number = ++this.historyEpoch; this.historyBusy = true; this.historyOpen = true;
    try {
      const offset: number = reset ? 0 : this.historyOffset;
      const rows: UnifiedSearchHistoryPage[] = await this.session.historyPage(offset);
      if (!this.alive || epoch !== this.historyEpoch) { return; }
      this.historyOffset = offset + rows.length; this.historyMore = rows.length === 10;
      this.historyRows = knowledgeHistoryTags(reset ? rows : this.historyRows.concat(rows));
      if (reset) { this.historyScroller.scrollEdge(Edge.Top); }
    } catch { if (this.alive && epoch === this.historyEpoch) { this.message = '历史读取失败，不影响当前搜索。'; } }
    finally { if (this.alive && epoch === this.historyEpoch) { this.historyBusy = false; } }
  }
  private async clearHistory(): Promise<void> {
    if (this.historyBusy || this.historyClearing || this.session === undefined) { return; }
    this.historyClearing = true; const epoch: number = ++this.historyEpoch;
    try {
      await this.session.clearHistory();
      if (!this.alive || epoch !== this.historyEpoch) { return; }
      this.historyRows = []; this.historyOffset = 0; this.historyMore = false; this.message = '';
    } catch { if (this.alive && epoch === this.historyEpoch) { this.message = '清空历史未完成，请重试。'; } }
    finally { if (this.alive && epoch === this.historyEpoch) { this.historyClearing = false; } }
  }
  private resultHeight(): number { return Math.max(240, Math.min(520, this.availableHeight > 0 ? this.availableHeight * 0.55 : 400)); }
  private routeFilter(): string { return this.activeTab === 1 ? 'Tag' : this.activeTab === 2 ? 'Vector' : ''; }
  private emptyText(): string {
    if (this.activeTab === 0) { return this.session?.state.lexicalPartial ? '当前范围暂无命中，可继续查找。' : '没有找到相关关键词内容。'; }
    return this.activeTab === 1 ? '没有找到相关标签资料。' : this.semantic === 'Complete' ? '暂未找到语义相关的内容。' : '按意思查找资料，开始前会请你确认发送问题。';
  }
  build() {
    Column({ space: 16 }) {
      if (!this.searchMode) {
        KnowledgeHeading({ title: '让知识，有处可寻', subtitle: '汇集你的资料，在需要时找回灵感。' })
      } else {
        Row({ space: 12 }) {
          Button('返回首页').id('upd-query-home').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 })
            .onClick((): void => { this.edit(''); this.searched = false; this.searchMode = false; this.historyOpen = false; })
          Text('搜索资料').fontSize(22).fontWeight(FontWeight.Medium).fontColor(Theme.ink).layoutWeight(1)
          Button('我的资料').id('upd-entry').fontSize(14).fontColor(Theme.accent).backgroundColor(Color.Transparent).constraintSize({ minHeight: 44 }).onClick(this.onDocuments)
        }.width('100%')
      }
      Column({ space: 12 }) {
        Row({ space: 10 }) {
          AppIcon({ source: $r('app.media.ui_search'), size: 20 })
          TextInput({ text: this.question, placeholder: '搜索资料中的内容', controller: this.queryInputController }).fontColor(Theme.ink).backgroundColor(Color.Transparent)
            .id('upd-query-input').layoutWeight(1).fontSize(15).enabled(!this.historyClearing)
            .onChange((text: string): void => { this.edit(text); this.searched = false; })
            .onSubmit((): void => { if (this.question.trim().length > 0 && !this.directBusy && !this.relatedBusy) { void this.local(); } })
        }.width('100%').padding({ left: 12, right: 4 }).backgroundColor(Theme.inputSurface).borderRadius(12)
        Button('搜索').fontSize(14).fontColor(Color.White).backgroundColor(Theme.accent).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('upd-query-local')
          .enabled(this.question.trim().length > 0 && !this.directBusy && !this.relatedBusy && !this.historyClearing).onClick((): void => { void this.local(); })
        Row() {
          Button(this.historyOpen ? '收起历史' : '搜索历史').fontSize(13).fontColor(Theme.accent).backgroundColor(Color.Transparent).constraintSize({ minHeight: 44 }).id('upd-query-history')
            .onClick((): void => { if (this.historyOpen) { this.historyOpen = false; } else { void this.loadHistory(true); } })
          Blank()
          Button(this.archived ? '已包含归档' : '包括归档').fontSize(13).fontColor(Theme.accent).backgroundColor(Color.Transparent).constraintSize({ minHeight: 44 }).id('upd-query-archived')
            .enabled(!this.historyClearing).onClick((): void => { this.archived = !this.archived; this.edit(this.question); this.searched = false; })
        }.width('100%')
        if (this.historyOpen) {
          Column({ space: 8 }) {
            Row() {
              Text('搜索历史').fontColor(Theme.muted).fontSize(12).layoutWeight(1)
              Button(this.historyClearing ? '正在清空…' : '清空历史').fontSize(12).fontColor(Theme.accent).backgroundColor(Color.Transparent).constraintSize({ minHeight: 32 }).id('upd-query-history-clear')
                .enabled(!this.historyBusy && !this.historyClearing && (this.historyRows.length > 0 || this.historyMore)).onClick((): void => { void this.clearHistory(); })
            }.width('100%')
            Scroll(this.historyScroller) {
              Column({ space: 4 }) {
                Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Start }) {
                  ForEach(this.historyRows, (page: UnifiedSearchHistoryPage): void => {
                    Button({ type: ButtonType.Normal }) {
                      Text(page.question).fontSize(12).fontColor(Theme.accent).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    }.padding({ left: 10, right: 10, top: 6, bottom: 6 }).backgroundColor(Theme.soft).borderRadius(8)
                      .constraintSize({ minHeight: 32, maxWidth: '100%' }).margin({ right: 8, bottom: 8 }).id('upd-history-tag-' + page.recordId).accessibilityText(page.question)
                      .enabled(!this.historyClearing && !this.directBusy && !this.relatedBusy).onClick((): void => { this.edit(page.question); this.historyOpen = false; void this.local(); })
                  }, (page: UnifiedSearchHistoryPage): string => page.recordId)
                }.width('100%')
                if (this.historyBusy) { Text('正在读取历史…').fontColor(Theme.muted).fontSize(12).width('100%') }
                if (this.historyRows.length === 0 && !this.historyBusy) { Text('暂无搜索记录').fontColor(Theme.muted).fontSize(12).width('100%') }
                if (this.historyMore) {
                  Button('更多历史').fontSize(12).fontColor(Theme.accent).backgroundColor(Color.Transparent).constraintSize({ minHeight: 32 }).id('upd-query-history-more')
                    .enabled(!this.historyBusy && !this.historyClearing).onClick((): void => { void this.loadHistory(); })
                }
              }.width('100%').alignItems(HorizontalAlign.Start)
            }.width('100%').constraintSize({ maxHeight: 180 }).scrollBar(BarState.On).scrollBarColor(Theme.line).id('upd-query-history-region')
              .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
          }.width('100%').padding(10).backgroundColor(Theme.inputSurface).borderRadius(12)
        }
      }.width('100%').padding(16).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
      if (!this.searchMode) {
        FeatureRow({ title: '我的资料', description: '查看文件、阅读正文与跟进处理进度', icon: $r('app.media.ui_folder'), id: 'upd-entry', onOpen: this.onDocuments })
      }
      if (this.message.length > 0) { KnowledgeNotice({ text: this.message, warning: true }) }
      if (this.searched) {
        Row({ space: 6 }) {
          Button('关键词命中').fontSize(13).fontColor(this.activeTab === 0 ? Color.White : Theme.accent).backgroundColor(this.activeTab === 0 ? Theme.accent : Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).id('upd-query-tab-direct').onClick((): void => { this.switchTab(0); })
          Button('相关资料').fontSize(13).fontColor(this.activeTab === 1 ? Color.White : Theme.accent).backgroundColor(this.activeTab === 1 ? Theme.accent : Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).id('upd-query-tab-related').onClick((): void => { this.switchTab(1); })
          Button('语义搜索').fontSize(13).fontColor(this.activeTab === 2 ? Color.White : Theme.accent).backgroundColor(this.activeTab === 2 ? Theme.accent : Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).id('upd-query-tab-semantic').onClick((): void => { this.switchTab(2); })
        }.width('100%')
        if (this.directBusy || this.relatedBusy) {
          Row({ space: 10 }) { LoadingProgress().width(24).height(24).color(Theme.accent); Text('正在查找资料…').fontSize(13).fontColor(Theme.muted) }
        }
        if (this.directError.length > 0 || this.relatedError.length > 0) {
          Row({ space: 8 }) {
            Button('重试搜索').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).constraintSize({ minHeight: 44 }).id('upd-query-retry').onClick((): void => { void this.local(); })
            Button(this.errorDetails ? '收起原因' : '查看原因').fontSize(13).fontColor(Theme.accent).backgroundColor(Color.Transparent).constraintSize({ minHeight: 44 }).id('upd-query-error-details').onClick((): void => { this.errorDetails = !this.errorDetails; })
          }
          if (this.errorDetails) { Text(this.directError || this.relatedError).fontSize(12).fontColor(Theme.muted).width('100%').id('upd-query-error-reason') }
        }
        if (this.activeTab === 2) {
          if (this.semanticError.length > 0) { KnowledgeNotice({ text: '语义搜索暂不可用，其他搜索结果仍可查看。', warning: true }) }
          if (this.semantic !== 'Loading' && this.semantic !== 'Complete') {
            Button('开始语义搜索').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('upd-query-review')
              .enabled(!this.directBusy && !this.relatedBusy && !this.historyClearing).onClick((): void => { void this.review(); })
          }
          if (this.semantic === 'Loading') {
            Text('正在查找语义相关内容…').fontSize(13).fontColor(Theme.muted)
            Button('取消').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).constraintSize({ minHeight: 44 }).id('upd-query-cancel').onClick((): void => { this.session?.invalidate(); })
          }
          if (this.reviewText.length > 0) {
            Column({ space: 10 }) {
              KnowledgeNotice({ text: this.reviewText, warning: true })
              if (this.session?.state.review !== undefined) {
                Button('同意发送并接受可能费用').fontSize(14).fontColor(Color.White).backgroundColor(Theme.accent).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('upd-query-semantic')
                  .enabled(!this.historyClearing).onClick((): void => { this.reviewText = ''; void this.semanticSearch(); })
              }
              Button('取消').fontSize(13).fontColor(Theme.accent).backgroundColor(Color.Transparent).constraintSize({ minHeight: 44 }).onClick((): void => { this.reviewText = ''; })
            }.width('100%')
          }
        }
        if (this.activeCards().length > 0) {
          Scroll(this.resultScroller) {
            Column({ space: 12 }) {
              ForEach(this.pageRows(), (card: UnifiedSearchCard): void => {
                UnifiedKnowledgeResultCard({ card: card, reasonRoute: this.routeFilter(), onOpen: this.onOpen, id: 'upd-card-' + card.key })
              }, (card: UnifiedSearchCard): string => card.key)
            }.width('100%').alignItems(HorizontalAlign.Start)
          }.width('100%').height(this.resultHeight()).scrollBar(BarState.Auto).scrollBarColor(Theme.line).id('upd-query-results-region')
            .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        } else if (!this.directBusy && !this.relatedBusy) {
          Text(this.emptyText()).fontColor(Theme.muted).fontSize(13).lineHeight(21).width('100%')
        }
        if (this.activeCards().length > 0 || this.hasMore()) {
          Row({ space: 8 }) {
            Button('上一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).id('upd-query-page-prev')
              .enabled(this.pageIndex() > 0 && !this.paging && !this.directBusy && !this.relatedBusy).onClick((): void => { this.setPage(this.pageIndex() - 1); })
            Text(this.pageText()).fontColor(Theme.muted).fontSize(11).textAlign(TextAlign.Center).layoutWeight(1).id('upd-query-page-label')
            Button(this.paging ? '查找中…' : '下一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).id('upd-query-page-next')
              .enabled(this.canNext() && !this.paging && !this.directBusy && !this.relatedBusy && !this.historyClearing).onClick((): void => { void this.nextPage(); })
          }.width('100%')
        }
      } else if (!this.historyOpen && !this.searchMode) {
        KnowledgeEmpty({ title: '让资料成为随时可查的知识', description: '在「我的资料」中导入文档或图片，再搜索正文、图片文字与标签。', icon: $r('app.media.chat_book') })
      }
      if (this.session?.state.historyPending ?? false) {
        Button('重试保存历史').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).constraintSize({ minHeight: 44 }).id('upd-query-history-retry')
          .enabled(!this.historyClearing).onClick((): void => { void this.session?.retryHistory(); })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 24 })
  }
}
