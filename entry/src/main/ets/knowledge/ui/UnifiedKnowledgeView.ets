import { Theme } from '../../components/Theme';
import { AppIcon } from '../../components/AppIcon';
import { FeatureRow } from '../../components/FeaturePages';
import { KnowledgeHeading, KnowledgeNotice, KnowledgeEmpty } from './KnowledgeVisuals';
import { ParsedFailure } from '../domain/ParsedDocumentModels';
import { KnowledgeQuerySession } from '../application/KnowledgeQuerySession';
import { UnifiedSearchCard, UnifiedSearchHistoryPage } from '../domain/UnifiedQueryModels';
import { UnifiedKnowledgeHistoryRepository } from '../infra/UnifiedKnowledgeHistoryRepository';
import { KnowledgeHistoryCursor } from '../domain/KnowledgeSearchModels';
import { UnifiedKnowledgeResultCard } from './KnowledgeResultCard';

@Component
export struct UnifiedKnowledgeView {
  session: KnowledgeQuerySession | undefined=undefined;
  history: UnifiedKnowledgeHistoryRepository | undefined=undefined;
  onOpen: (card: UnifiedSearchCard) => void=(_card: UnifiedSearchCard): void=>{};
  onImport: () => void = (): void => {};
  onDocuments: () => void = (): void => {};
  @State errorDetails: boolean = false;
  @State searchMode: boolean = false;
  @State searched: boolean = false;
  @State question: string='';
  @State archived: boolean=false;
  @State direct: UnifiedSearchCard[]=[];
  @State related: UnifiedSearchCard[]=[];
  @State directBusy: boolean=false;
  @State relatedBusy: boolean=false;
  @State directMore: boolean=false;
  @State relatedMore: boolean=false;
  @State directError: string='';
  @State relatedError: string='';
  @State coverage: string='';
  @State semantic: string='NotRequested';
  @State reviewText: string='';
  @State consent: boolean=false;
  @State cost: boolean=false;
  @State message: string='';
  @State historyRows: UnifiedSearchHistoryPage[]=[];
  @State historyOpen: boolean=false;
  @State historyOffset: number=0;
  @State legacyOpen: boolean=false;
  private queryInputController: TextInputController = new TextInputController();
  private listener: () => void=(): void=> { this.refresh(); };
  aboutToAppear(): void { this.session?.subscribe(this.listener); this.question=this.session?.state.question ?? ''; this.archived=this.session?.state.includeArchived ?? false; this.refresh(); }
  aboutToDisappear(): void { this.session?.unsubscribe(this.listener); this.session?.invalidate(); this.consent=false; this.cost=false; }
  private refresh(): void { const s=this.session?.state; if (s===undefined) { this.message='统一查询尚未就绪，资料保留'; return; } this.direct=s.direct.cards.slice(); this.related=s.related.cards.slice(); this.directBusy=s.direct.busy; this.relatedBusy=s.related.busy; this.directMore=!s.direct.exhausted; this.relatedMore=!s.related.exhausted; this.directError=s.direct.error; this.relatedError=s.related.error; this.coverage=s.coverageMessage; this.semantic=s.semanticState; if (s.direct.error.length > 0 || s.related.error.length > 0) { this.message='资料读取失败，请重试检索'; } }
  private edit(text: string): void { this.question=text; this.consent=false; this.cost=false; this.reviewText=''; this.session?.edit(text,this.archived); }
  private async local(): Promise<void> { this.queryInputController.stopEditing(); try { this.searchMode=true; this.searched=true; this.consent=false; this.cost=false; this.reviewText=''; await this.session?.start(this.question,this.archived); this.message=''; } catch { this.message='本机范围读取失败，未当作无结果'; } }
  private async review(): Promise<void> { try { const a=await this.session?.review(); this.reviewText=a===undefined?'':`本次将发送问题：${a.actual}\n接收方为当前嵌入服务，仅用于此次语义检索，可能产生费用。翻页不会再次发送。`; } catch (error) { this.reviewText=this.reviewFailure(error); } }
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
  private async semanticSearch(): Promise<void> { const consent: boolean=true; const cost: boolean=true; this.consent=false; this.cost=false; try { await this.session?.allowSemantic(consent,cost); } catch { this.message='当前问题许可已变，未发送或未采用旧结果'; } }
  private async page(group: string): Promise<void> { const state=this.session?.state; if (state===undefined) { return; } await this.session?.page(group,group==='Direct'?state.direct.cursor:state.related.cursor); }
  private async loadHistory(reset: boolean=false): Promise<void> { try { if (reset) { this.historyOffset=0; } this.historyRows=await this.session?.historyPage(this.historyOffset) ?? []; this.historyOffset+=this.historyRows.length; this.historyOpen=true; this.legacyOpen=false; } catch { this.message='历史读取失败，不影响当前检索'; } }
  private async legacyHistory(): Promise<void> { try { this.historyRows=await this.history?.legacyPage(new KnowledgeHistoryCursor(),10) ?? []; this.historyOpen=true; this.legacyOpen=true; } catch { this.message='旧历史兼容读取失败，未重封旧记录'; } }
  build() {
    Column({ space: 16 }) {
      if (!this.searchMode) {
      KnowledgeHeading({ title: '让知识，有处可寻', subtitle: '汇集你的资料，在需要时找回灵感。' })
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          AppIcon({ source: $r('app.media.ui_import'), size: 18 })
          Text('导入文件').fontColor(Theme.ink).fontSize(14).fontColor(Color.White)
        }.padding({ left: 18, right: 18, top: 12, bottom: 12 })
      }.id('upd-home-import').backgroundColor(Theme.accent).borderRadius(12)
        .constraintSize({ minHeight: 46 }).accessibilityText('导入文件，选择文档或图片').onClick(this.onImport)
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
          TextInput({ text: this.question, placeholder: '搜索资料中的内容', controller: this.queryInputController }).fontColor(Theme.ink).backgroundColor(Theme.inputSurface).borderRadius(12).border({ width: 1, color: Theme.line })
            .id('upd-query-input').layoutWeight(1).backgroundColor(Color.Transparent)
            .fontSize(15).fontColor(Theme.ink)
            .onChange((v: string): void => { this.edit(v); this.searched = false; })
            .onSubmit((): void => { if (this.question.trim().length > 0 && !this.directBusy && !this.relatedBusy) { this.local(); } })
        }.width('100%').padding({ left: 12, right: 4 }).backgroundColor(Theme.inputSurface).borderRadius(12)
        Button('搜索').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('upd-query-local').width('100%').fontColor(Color.White).backgroundColor(Theme.accent)
          .enabled(this.question.trim().length > 0 && !this.directBusy && !this.relatedBusy).onClick((): void => { this.local(); })
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
          Button(this.historyOpen ? '收起历史' : '搜索历史').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('upd-query-history').backgroundColor(Color.Transparent)
            .onClick((): void => { if (this.historyOpen) { this.historyOpen = false; } else { this.loadHistory(true); } })
          Button(this.archived ? '已包含归档' : '包括归档').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('upd-query-archived').backgroundColor(Color.Transparent)
            .onClick((): void => { this.archived = !this.archived; this.edit(this.question); this.searched = false; })
        }.width('100%')
      }.width('100%').padding(16).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
      if (!this.searchMode) {
      FeatureRow({ title: '我的资料', description: '查看文件、阅读正文与跟进处理进度', icon: $r('app.media.ui_folder'),
        id: 'upd-entry', onOpen: this.onDocuments })
      }
      if (this.message.length > 0) { KnowledgeNotice({ text: this.message, warning: true }) }
      if (this.searched) {
        if (this.directBusy || this.relatedBusy) {
          Row({ space: 10 }) { LoadingProgress().width(24).height(24).color(Theme.accent); Text('正在查找资料…').fontColor(Theme.ink).fontSize(14).fontColor(Theme.muted) }
        }
        if (this.directError.length > 0 || this.relatedError.length > 0) {
          KnowledgeNotice({ text: '检索暂时不可用，已有资料保留。', warning: true })
          Flex({ wrap: FlexWrap.Wrap }) {
            Button('重试检索').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('upd-query-retry').onClick((): void => { this.local(); })
            Button(this.errorDetails ? '收起原因' : '查看原因').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('upd-query-error-details').backgroundColor(Color.Transparent).onClick((): void => { this.errorDetails = !this.errorDetails; })
          }.width('100%')
          if (this.errorDetails) { Text(this.directError || this.relatedError).fontColor(Theme.ink).id('upd-query-error-reason').fontSize(12).fontColor(Theme.muted).width('100%') }
        }
        Text('关键词命中').fontColor(Theme.ink).fontSize(18).fontWeight(FontWeight.Bold).fontColor(Theme.ink).width('100%').margin({ top: 8 })
        ForEach(this.direct, (c: UnifiedSearchCard): void => { UnifiedKnowledgeResultCard({ card: c, onOpen: this.onOpen, id: 'upd-card-' + c.key }) }, (c: UnifiedSearchCard): string => c.key)
        if (this.direct.length === 0 && !this.directBusy && this.directError.length === 0) {
          Text(this.session?.state.lexicalPartial ? '当前已检索范围无命中，可继续检索' : '没有找到相关关键词内容').fontColor(Theme.ink).fontSize(14).fontColor(Theme.muted).width('100%')
        }
        if (this.directMore && !this.directBusy && this.directError.length === 0) { Button('查看更多').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('upd-direct-more').width('100%').onClick((): void => { this.page('Direct'); }) }
        Text('相关资料').fontColor(Theme.ink).fontSize(18).fontWeight(FontWeight.Bold).fontColor(Theme.ink).width('100%').margin({ top: 8 })
        ForEach(this.related, (c: UnifiedSearchCard): void => { UnifiedKnowledgeResultCard({ card: c, onOpen: this.onOpen, id: 'upd-card-' + c.key }) }, (c: UnifiedSearchCard): string => c.key)
        if (this.related.length === 0 && !this.relatedBusy && this.relatedError.length === 0) {
          Text(this.semantic === 'Complete' ? '暂未找到相关资料' : '按标签查找，也可以试试语义搜索。').fontColor(Theme.ink).fontSize(14).fontColor(Theme.muted).width('100%')
        }
        if (this.relatedMore && !this.relatedBusy && this.relatedError.length === 0) { Button('查看更多相关资料').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('upd-related-more').width('100%').onClick((): void => { this.page('Related'); }) }
        if (this.session?.state.semanticError) { KnowledgeNotice({ text: '语义搜索暂不可用，已有内容匹配仍可查看。', warning: true }) }
        if (this.semantic !== 'Loading' && this.semantic !== 'Complete') { Button('试试语义搜索').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('upd-query-review').width('100%').onClick((): void => { this.review(); }) }
        if (this.semantic === 'Loading') {
          Text('正在查找相关内容…').fontColor(Theme.ink).fontSize(14).fontColor(Theme.muted)
          Button('取消').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('upd-query-cancel').onClick((): void => { this.session?.invalidate(); })
        }
        if (this.reviewText.length > 0) {
          Column({ space: 12 }) {
            KnowledgeNotice({ text: this.reviewText, warning: true })
            if (this.session?.state.review !== undefined) {
              Button('同意发送并接受可能费用').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('upd-query-semantic').width('100%').fontColor(Color.White).backgroundColor(Theme.accent)
                .onClick((): void => { this.reviewText = ''; this.semanticSearch(); })
            }
            Button('取消').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).backgroundColor(Color.Transparent).onClick((): void => { this.reviewText = ''; })
          }.width('100%')
        }
      } else if (!this.historyOpen && !this.searchMode) {
        KnowledgeEmpty({ title: '让资料成为随时可查的知识', description: '导入文档或图片后，搜索正文、图片文字与标签。\n语义搜索会在发送问题前征求你的同意。', icon: $r('app.media.chat_book') })
      }
      if (this.session?.state.historyPending ?? false) { Button('重试保存历史').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('upd-query-history-retry').onClick((): void => { this.session?.retryHistory(); }) }
      if (this.historyOpen) {
        Text('搜索历史').fontColor(Theme.ink).fontSize(18).fontColor(Theme.ink).fontWeight(FontWeight.Bold).width('100%')
        if (this.historyRows.length === 0) { Text('暂无搜索记录').fontColor(Theme.ink).fontSize(14).fontColor(Theme.muted).width('100%') }
        ForEach(this.historyRows, (p: UnifiedSearchHistoryPage): void => {
          Button(p.question).fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).width('100%').backgroundColor(Theme.surface).border({ width: 1, color: Theme.line })
            .onClick((): void => { this.edit(p.question); this.historyOpen = false; this.local(); })
        }, (p: UnifiedSearchHistoryPage): string => p.recordId + '-' + p.revision)
        if (this.historyRows.length === 10) { Button('下一页').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).onClick((): void => { this.loadHistory(); }) }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 24 })
  }
}
