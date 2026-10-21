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
  private listener: () => void=(): void=> { this.refresh(); };
  aboutToAppear(): void { this.session?.subscribe(this.listener); this.question=this.session?.state.question ?? ''; this.archived=this.session?.state.includeArchived ?? false; this.refresh(); }
  aboutToDisappear(): void { this.session?.unsubscribe(this.listener); this.session?.invalidate(); this.consent=false; this.cost=false; }
  private refresh(): void { const s=this.session?.state; if (s===undefined) { this.message='统一查询尚未就绪，资料保留'; return; } this.direct=s.direct.cards.slice(); this.related=s.related.cards.slice(); this.directBusy=s.direct.busy; this.relatedBusy=s.related.busy; this.directMore=!s.direct.exhausted; this.relatedMore=!s.related.exhausted; this.directError=s.direct.error; this.relatedError=s.related.error || s.semanticError; this.coverage=s.coverageMessage; this.semantic=s.semanticState; }
  private edit(text: string): void { this.question=text; this.consent=false; this.cost=false; this.reviewText=''; this.session?.edit(text,this.archived); }
  private async local(): Promise<void> { try { this.consent=false; this.cost=false; this.reviewText=''; await this.session?.start(this.question,this.archived); this.message='本机正文/OCR与标签；未生成回答'; } catch { this.message='本机范围读取失败，未当作无结果'; } }
  private async review(): Promise<void> { try { const a=await this.session?.review(); this.reviewText=a===undefined?'':`当前实际问题：${a.actual}\n统一空间 ${a.spaceId}\n只发送该问题用于一次向量，分页不再发送；接收方为当前嵌入服务，可能收费。`; } catch { this.reviewText='当前问题/新空间/设置或计数未就绪；未发送'; } }
  private async semanticSearch(): Promise<void> { const consent=this.consent; const cost=this.cost; this.consent=false; this.cost=false; try { await this.session?.allowSemantic(consent,cost); } catch { this.message='当前问题许可已变，未发送或未采用旧结果'; } }
  private async page(group: string): Promise<void> { const state=this.session?.state; if (state===undefined) { return; } await this.session?.page(group,group==='Direct'?state.direct.cursor:state.related.cursor); }
  private async loadHistory(reset: boolean=false): Promise<void> { try { if (reset) { this.historyOffset=0; } this.historyRows=await this.session?.historyPage(this.historyOffset) ?? []; this.historyOffset+=this.historyRows.length; this.historyOpen=true; this.legacyOpen=false; } catch { this.message='历史读取失败，不影响当前检索'; } }
  private async legacyHistory(): Promise<void> { try { this.historyRows=await this.history?.legacyPage(new KnowledgeHistoryCursor(),10) ?? []; this.historyOpen=true; this.legacyOpen=true; } catch { this.message='旧历史兼容读取失败，未重封旧记录'; } }
  build() {
    Column({space:12}) {
      Text('知识库').fontSize(22).width('100%')
      TextInput({text:this.question,placeholder:'检索正文、OCR、图片标签与语义候选'}).id('upd-query-input').onChange((v: string): void=> { this.edit(v); })
      Row() { Button('清空').id('upd-query-clear').onClick((): void=> { this.edit(''); }); Checkbox().id('upd-query-archived').select(this.archived).onChange((v: boolean): void=> { this.archived=v; this.edit(this.question); }); Text('包括归档').fontSize(13) }.width('100%')
      Button('本机检索').id('upd-query-local').onClick((): void=> { this.local(); })
      Text(this.coverage).id('upd-query-coverage').fontSize(12).width('100%')
      Button('核对本次语义问题').id('upd-query-review').onClick((): void=> { this.review(); })
      Text(this.reviewText).fontSize(12).width('100%')
      Row() { Checkbox().id('upd-query-consent').select(this.consent).onChange((v: boolean): void=> { this.consent=v; }); Text('仅同意当前问题发送一次').fontSize(13).layoutWeight(1) }.width('100%')
      Row() { Checkbox().id('upd-query-cost').select(this.cost).onChange((v: boolean): void=> { this.cost=v; }); Text('接受本次可能费用，不保证免费').fontSize(13).layoutWeight(1) }.width('100%')
      Button('加载统一语义候选').id('upd-query-semantic').enabled(this.consent && this.cost && this.semantic!=='Loading').onClick((): void=> { this.semanticSearch(); })
      Button('取消当前问题').id('upd-query-cancel').onClick((): void=> { this.session?.invalidate(); this.consent=false; this.cost=false; })
      Text(this.message).id('upd-query-status').fontSize(13).width('100%')
      Text('正文 / OCR 直接命中').fontSize(18).width('100%')
      if (this.directBusy) { LoadingProgress().width(24).height(24) }
      Text(this.directError).id('upd-direct-error').fontSize(12).width('100%')
      ForEach(this.direct,(c: UnifiedSearchCard)=> { UnifiedKnowledgeResultCard({card:c,onOpen:this.onOpen}) },(c: UnifiedSearchCard): string=>c.key)
      Button('更多直接命中').id('upd-direct-more').enabled(!this.directBusy && this.directMore).onClick((): void=> { this.page('Direct'); })
      Text('标签与统一语义候选').fontSize(18).width('100%')
      Text(this.semantic).id('upd-semantic-state').fontSize(12).width('100%')
      if (this.relatedBusy || this.semantic==='Loading') { LoadingProgress().width(24).height(24) }
      Text(this.relatedError).id('upd-related-error').fontSize(12).width('100%')
      ForEach(this.related,(c: UnifiedSearchCard)=> { UnifiedKnowledgeResultCard({card:c,onOpen:this.onOpen}) },(c: UnifiedSearchCard): string=>c.key)
      Button('更多标签 / 语义').id('upd-related-more').enabled(!this.relatedBusy && this.relatedMore).onClick((): void=> { this.page('Related'); })
      Row() { Button('历史').id('upd-query-history').onClick((): void=> { this.loadHistory(true); }); Button('旧历史只读').id('upd-query-legacy-history').onClick((): void=> { this.legacyHistory(); }) }.width('100%')
      if (this.session?.state.historyPending ?? false) { Button('重试保存历史').id('upd-query-history-retry').onClick((): void=> { this.session?.retryHistory(); }) }
      if (this.historyOpen) {
        ForEach(this.historyRows,(p: UnifiedSearchHistoryPage)=> {
          Column() { Text(p.question).fontSize(16).width('100%'); Text(`${p.wire} · revision ${p.revision} · ${p.semanticState}`).fontSize(11).width('100%'); ForEach(p.direct.concat(p.related),(c: UnifiedSearchCard)=> { UnifiedKnowledgeResultCard({card:c,onOpen:this.onOpen}) },(c: UnifiedSearchCard): string=>c.key) }.width('100%')
        },(p: UnifiedSearchHistoryPage): string=>p.recordId+'-'+p.revision)
        if (!this.legacyOpen) { Button('下一页历史').onClick((): void=> { this.loadHistory(); }) }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({top:12,bottom:20})
  }
}
