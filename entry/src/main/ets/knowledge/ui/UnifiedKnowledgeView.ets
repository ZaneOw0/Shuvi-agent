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
  onDocuments: () => void = (): void => {};
  @State errorDetails: boolean = false;
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
  private async local(): Promise<void> { this.queryInputController.stopEditing(); try { this.searched=true; this.consent=false; this.cost=false; this.reviewText=''; await this.session?.start(this.question,this.archived); this.message=''; } catch { this.message='本机范围读取失败，未当作无结果'; } }
  private async review(): Promise<void> { try { const a=await this.session?.review(); this.reviewText=a===undefined?'':`当前实际问题：${a.actual}\n统一空间 ${a.spaceId}\n只发送该问题用于一次向量，分页不再发送；接收方为当前嵌入服务，可能收费。`; } catch (error) { this.reviewText=this.reviewFailure(error); } }
  private reviewFailure(error: Object): string {
    if (!(error instanceof ParsedFailure)) { return '本机语义检索准备失败，未发送问题。请重新搜索后重试。'; }
    let message: string = '语义检索准备失败，未发送问题。';
    switch (error.category) {
      case 'UnifiedEmbeddingDisabled': message = '统一自动嵌入尚未启用。请在「我的 → 嵌入模型设置」确认范围与费用后启用，并等待资料向量化完成。'; break;
      case 'UnifiedEmbeddingCostRequired': message = '当前嵌入设置尚未确认可能费用，请到嵌入模型设置确认。'; break;
      case 'UnifiedEmbeddingPaused': message = '嵌入处理已暂停，请先恢复处理。'; break;
      case 'UnifiedEmbeddingBaselineRequired': message = '当前统一嵌入工程基线尚未确认，请到嵌入模型设置确认。'; break;
      case 'UnifiedEmbeddingConfigChanged': message = '模型或凭据配置已变化，请重新确认统一嵌入设置并完成资料向量化。'; break;
      case 'UnifiedSpaceMissing': message = '尚无当前模型的新统一向量空间。请先完成至少一份资料的向量化；保存原件或 OCR 入库还不包含向量。'; break;
      case 'UnifiedTargetsMissing': message = '当前范围没有已完成向量化且有效的资料，请检查资料是否归档、向量任务是否完成。'; break;
      case 'CurrentLocalScopeRequired': message = '请先点击「搜索」建立当前问题，再使用语义搜索。'; break;
      case 'LocalMembershipChangedStartNewSession': message = '资料范围刚发生变化，请重新点击「搜索」。'; break;
      case 'UnifiedQueryCountOrBaseline': message = '当前问题的本机计数、模型或基线校验未通过；当前统一模式要求硅基流动 BAAI/bge-m3，单次输入不超过 8192 tokens。'; break;
      case 'UnifiedScopeIncomplete': message = '本机资料范围读取未完成，请重试搜索。'; break;
    }
    return message + '\n未发送问题。原因：' + error.category;
  }
  private async semanticSearch(): Promise<void> { const consent: boolean=true; const cost: boolean=true; this.consent=false; this.cost=false; try { await this.session?.allowSemantic(consent,cost); } catch { this.message='当前问题许可已变，未发送或未采用旧结果'; } }
  private async page(group: string): Promise<void> { const state=this.session?.state; if (state===undefined) { return; } await this.session?.page(group,group==='Direct'?state.direct.cursor:state.related.cursor); }
  private async loadHistory(reset: boolean=false): Promise<void> { try { if (reset) { this.historyOffset=0; } this.historyRows=await this.session?.historyPage(this.historyOffset) ?? []; this.historyOffset+=this.historyRows.length; this.historyOpen=true; this.legacyOpen=false; } catch { this.message='历史读取失败，不影响当前检索'; } }
  private async legacyHistory(): Promise<void> { try { this.historyRows=await this.history?.legacyPage(new KnowledgeHistoryCursor(),10) ?? []; this.historyOpen=true; this.legacyOpen=true; } catch { this.message='旧历史兼容读取失败，未重封旧记录'; } }
  build() {
    Column({ space: 14 }) {
      Row() {
        Text('知识库').fontSize(24).fontWeight(FontWeight.Medium).layoutWeight(1)
        Button('我的资料').id('upd-entry').onClick(this.onDocuments)
      }.width('100%')
      TextInput({ text: this.question, placeholder: '搜索资料中的内容', controller: this.queryInputController }).id('upd-query-input').onChange((v: string): void => { this.edit(v); this.searched = false; })
      Row({ space: 12 }) {
        Button('搜索').id('upd-query-local').enabled(this.question.trim().length > 0 && !this.directBusy && !this.relatedBusy).onClick((): void => { this.local(); })
        Button('历史记录').id('upd-query-history').onClick((): void => { if (this.historyOpen) { this.historyOpen = false; } else { this.loadHistory(true); } })
        Button(this.archived ? '隐藏归档' : '包括归档').id('upd-query-archived').onClick((): void => { this.archived = !this.archived; this.edit(this.question); this.searched = false; })
      }.width('100%')
      if (this.message.length > 0) { Text(this.message).id('upd-query-status').fontSize(14).width('100%') }
      if (this.searched) {
        if (this.directBusy || this.relatedBusy) { LoadingProgress().width(28).height(28) }
        if (this.directError.length > 0 || this.relatedError.length > 0) {
          Text('检索暂时不可用，请重试。').fontSize(14).width('100%')
          Button(this.errorDetails ? '收起原因' : '查看原因').id('upd-query-error-details').onClick((): void => { this.errorDetails = !this.errorDetails; })
          if (this.errorDetails) { Text(this.directError || this.relatedError).id('upd-query-error-reason').fontSize(12).width('100%') }
          Button('重试检索').id('upd-query-retry').onClick((): void => { this.local(); })
        }
        Text('内容匹配').fontSize(18).fontWeight(FontWeight.Medium).width('100%')
        ForEach(this.direct, (c: UnifiedSearchCard) => { UnifiedKnowledgeResultCard({ card: c, onOpen: this.onOpen }) }, (c: UnifiedSearchCard): string => c.key)
        if (this.direct.length === 0 && !this.directBusy && this.directError.length === 0) { Text('没有找到包含这些文字的内容').fontSize(14).width('100%') }
        if (this.directMore && !this.directBusy && this.directError.length === 0) { Button('查看更多').id('upd-direct-more').onClick((): void => { this.page('Direct'); }) }
        Text('相关资料').fontSize(18).fontWeight(FontWeight.Medium).width('100%')
        ForEach(this.related, (c: UnifiedSearchCard) => { UnifiedKnowledgeResultCard({ card: c, onOpen: this.onOpen }) }, (c: UnifiedSearchCard): string => c.key)
        if (this.relatedMore && !this.relatedBusy && this.relatedError.length === 0) { Button('查看更多相关资料').id('upd-related-more').onClick((): void => { this.page('Related'); }) }
        if (this.session?.state.semanticError) { Text('语义搜索暂不可用，已有内容匹配仍可查看').fontSize(14).width('100%') }
        if (this.semantic !== 'Loading' && this.semantic !== 'Complete') { Button('试试语义搜索').id('upd-query-review').onClick((): void => { this.review(); }) }
        if (this.semantic === 'Loading') { Text('正在查找相关内容…').fontSize(14); Button('取消').id('upd-query-cancel').onClick((): void => { this.session?.invalidate(); }) }
        if (this.reviewText.length > 0) {
          Text(this.reviewText).fontSize(14).width('100%')
          if (this.session?.state.review !== undefined) { Button('同意发送并接受可能费用').id('upd-query-semantic').onClick((): void => { this.reviewText = ''; this.semanticSearch(); }) }
          Button('取消').onClick((): void => { this.reviewText = ''; })
        }
      } else if (!this.historyOpen) {
        Text('搜索已入库的文档和图片文字。\n在「我的资料」中导入新文件。').fontSize(15).fontColor('#666666').width('100%').padding({ top: 24, bottom: 24 })
      }
      if (this.session?.state.historyPending ?? false) { Button('重试保存历史').id('upd-query-history-retry').onClick((): void => { this.session?.retryHistory(); }) }
      if (this.historyOpen) {
        Text('搜索历史').fontSize(18).width('100%')
        if (this.historyRows.length === 0) { Text('暂无搜索记录').fontSize(14).width('100%') }
        ForEach(this.historyRows, (p: UnifiedSearchHistoryPage) => {
          Button(p.question).width('100%').onClick((): void => { this.edit(p.question); this.historyOpen = false; this.local(); })
        }, (p: UnifiedSearchHistoryPage): string => p.recordId + '-' + p.revision)
        if (this.historyRows.length === 10) { Button('下一页').onClick((): void => { this.loadHistory(); }) }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 20 })
  }
}
