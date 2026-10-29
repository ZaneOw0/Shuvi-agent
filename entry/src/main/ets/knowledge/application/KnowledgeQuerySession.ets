import { KnowledgeLexicalSearchPort, KnowledgeLexicalRequest, KnowledgeLexicalResult } from '../domain/KnowledgeLexicalPorts';
import { UnifiedQueryEnginePort, UnifiedQueryHistoryPort } from '../domain/UnifiedQueryPorts';
import { UnifiedQueryScopePort, UnifiedQueryScope, UnifiedSearchState, UnifiedSearchCard, UnifiedSearchGroup, UnifiedQueryApproval, UnifiedSearchHistoryPage } from '../domain/UnifiedQueryModels';
import { UnifiedEmbeddingConfigPort } from '../domain/UnifiedEmbeddingPorts';
import { ParsedIdentityPort } from '../domain/ParsedDocumentPorts';
import { ParsedCancellation, ParsedFailure } from '../domain/ParsedDocumentModels';
import { prepareTextQuery } from '../pipeline/QueryPreparation';
import { unifiedLocalDirect, unifiedLocalTags, unifiedMergeCard } from '../pipeline/KnowledgeRetrievalPolicy';
import { unifiedHistoryCopy } from '../pipeline/UnifiedHistoryCodec';
import { embeddingConfigBinding } from '../pipeline/EmbeddingBasisPolicy';

export class KnowledgeQuerySession {
  state: UnifiedSearchState=new UnifiedSearchState(); private scopePort: UnifiedQueryScopePort; private engine: UnifiedQueryEnginePort; private config: UnifiedEmbeddingConfigPort; private history: UnifiedQueryHistoryPort; private identity: ParsedIdentityPort;
  private scope: UnifiedQueryScope | undefined; private cancel: ParsedCancellation | undefined; private local: Promise<void> | undefined; private semanticPromise: Promise<void> | undefined;
  private directCandidates: UnifiedSearchCard[]=[]; private relatedCandidates: UnifiedSearchCard[]=[]; private directImages: Set<string>=new Set<string>();
  private registry: Map<string,UnifiedSearchCard>=new Map<string,UnifiedSearchCard>(); private positions: number[]=[0,0]; private pages: Map<string,string>=new Map<string,string>();
  private listeners: Array<() => void>=[]; private historyRevision: number=0; private pendingHistory: UnifiedSearchHistoryPage[]=[]; private historyTail: Promise<void>=Promise.resolve();
  private pageInFlight: Set<string>=new Set<string>();
  private configBinding: string='';
  private lexical?: KnowledgeLexicalSearchPort; private lexicalCursor: string=''; private lexicalMore: boolean=false; private lexicalRevision: string='';
  private workers: Array<Promise<void>>=[];
  private follow<T>(work: Promise<T>): Promise<T> { const settled: Promise<void>=work.then((): void=>{},(): void=>{}); this.workers.push(settled); settled.then((): void=> { this.workers=this.workers.filter((p: Promise<void>): boolean=>p!==settled); }); return work; }
  constructor(scope: UnifiedQueryScopePort, engine: UnifiedQueryEnginePort, config: UnifiedEmbeddingConfigPort, history: UnifiedQueryHistoryPort, identity: ParsedIdentityPort, lexical?: KnowledgeLexicalSearchPort) { this.lexical=lexical; this.scopePort=scope; this.engine=engine; this.config=config; this.history=history; this.identity=identity; }
  subscribe(listener: () => void): void { if (this.listeners.indexOf(listener)<0) { this.listeners.push(listener); } }
  unsubscribe(listener: () => void): void { this.listeners=this.listeners.filter((l: () => void): boolean=>l!==listener); }
  private emit(): void { this.state.direct.cards=this.state.direct.cards.slice(); this.state.related.cards=this.state.related.cards.slice(); for (const l of this.listeners) { l(); } }
  invalidate(): void {
    const session=this.state.session; const epoch=this.state.epoch; if (this.cancel!==undefined) { this.cancel.invalid=true; } if (this.state.review!==undefined) { this.state.review.revoked=true; } this.cancel=undefined; this.state.epoch++;
    this.follow<void>(this.engine.revoke(session,epoch)).catch((): void=>{}); this.state.review=undefined;
    this.state.direct.busy=false; this.state.related.busy=false; if (this.state.semanticState==='Loading') { this.state.semanticState='Canceled'; } this.emit();
  }
  edit(question: string, archived: boolean=this.state.includeArchived): void { this.invalidate(); const epoch=this.state.epoch; this.state=new UnifiedSearchState(); this.state.epoch=epoch; this.state.question=question; this.state.includeArchived=archived; this.emit(); }
  async start(question: string, archived: boolean=false, upstream: ParsedCancellation | undefined=undefined): Promise<void> {
    this.invalidate(); const epoch=this.state.epoch; this.state=new UnifiedSearchState(); this.state.epoch=epoch; this.state.session=this.identity.id(); this.state.historyId=this.identity.id(); this.state.question=prepareTextQuery(question).actualInput; this.state.includeArchived=archived; this.state.direct.id='Direct'; this.state.related.id='Related'; this.state.direct.busy=true; this.state.related.busy=true;
    this.directCandidates=[]; this.relatedCandidates=[]; this.directImages.clear(); this.registry.clear(); this.positions=[0,0]; this.pages.clear(); this.semanticPromise=undefined; this.scope=undefined; this.historyRevision=0; this.lexicalCursor=''; this.lexicalMore=false; this.lexicalRevision='';
    this.configBinding=embeddingConfigBinding(this.config.currentConfig());
    const cancel: ParsedCancellation=upstream ?? new ParsedCancellation(); this.cancel=cancel; this.emit(); const local: Promise<void>=this.follow<void>(this.loadLocal(epoch,cancel)); this.local=local; await local;
  }
  private current(epoch: number, cancel: ParsedCancellation): boolean { if (this.lexical===undefined && this.configBinding!==embeddingConfigBinding(this.config.currentConfig())) { cancel.invalid=true; if (this.state.epoch===epoch) { this.state.semanticState='ConfigChanged'; this.state.direct.busy=false; this.state.related.busy=false; this.emit(); } } return this.state.epoch===epoch && !cancel.invalid; }
  private async loadLocal(epoch: number, cancel: ParsedCancellation): Promise<void> {
    try { if (this.lexical!==undefined) { await this.loadLexical(epoch,cancel); return; } const scope=this.scopePort.captureLocal===undefined?await this.scopePort.capture(this.config.currentConfig(),this.state.includeArchived,cancel):await this.scopePort.captureLocal(this.config.currentConfig(),this.state.includeArchived,cancel); if (!this.current(epoch,cancel)) { return; } this.scope=scope; this.state.unupgraded=scope.unupgraded; this.state.coverageMessage=scope.complete?`未升级或未就绪 ${scope.unupgraded}；语义仅统一空间合格输入`:'范围读取不完整';
      this.directCandidates=unifiedLocalDirect(scope,this.state.question); const tags=unifiedLocalTags(scope,this.state.question);
      for (const card of this.directCandidates) { if (card.kind==='Image') { this.directImages.add(card.key); } this.upsert(card); }
      this.relatedCandidates=this.fuse(tags,[]); for (const card of this.relatedCandidates) { this.upsert(card); }
      this.state.direct.busy=false; this.state.related.busy=false; await this.page('Direct','0'); await this.page('Related','0'); this.emit();
    } catch (error) { if (this.current(epoch,cancel)) { const reason: string=error instanceof ParsedFailure ? error.category+' / '+error.stage : error instanceof Error ? error.message.slice(0,160) : 'LocalStoreReadFailed'; this.state.direct.error='LocalBodyScopeUnavailable · '+reason; this.state.related.error='LocalTagsScopeUnavailable · '+reason; this.state.direct.busy=false; this.state.related.busy=false; this.emit(); } }
  }
  private async fetchLexical(epoch: number, cancel: ParsedCancellation): Promise<void> {
    if (this.lexical===undefined) { return; }
    const request: KnowledgeLexicalRequest=new KnowledgeLexicalRequest(); request.query=this.state.question; request.includeArchived=this.state.includeArchived; request.cursor=this.lexicalCursor; request.scopeRevision=this.lexicalRevision;
    const result: KnowledgeLexicalResult=await this.lexical.search(request,cancel); if (!this.current(epoch,cancel)) { return; }
    this.scope=result.scope; this.state.unupgraded=result.scope.unupgraded; this.lexicalCursor=result.cursor; this.lexicalMore=result.hasMore; this.lexicalRevision=result.scopeRevision;
    this.state.coverageMessage=result.status==='partial'?'关键词检索仅完成部分范围，可继续检索':result.fallbackReason.length>0?'关键词检索使用字面补充或降级':'关键词检索就绪';
    this.state.lexicalPartial=result.status==='partial';
    for (const incoming of result.cards) { const card=this.upsert(incoming); if (!this.directCandidates.some((old: UnifiedSearchCard): boolean=>old.key===card.key)) { this.directCandidates.push(card); } if (card.kind==='Image') { this.directImages.add(card.key); } }
  }
  private async loadLexical(epoch: number, cancel: ParsedCancellation): Promise<void> {
    await this.fetchLexical(epoch,cancel); if (!this.current(epoch,cancel) || this.scope===undefined) { return; }
    this.relatedCandidates=unifiedLocalTags(this.scope,this.state.question); for (const card of this.relatedCandidates) { this.upsert(card); }
    this.state.direct.busy=false; this.state.related.busy=false; await this.page('Direct','0'); await this.page('Related','0'); this.emit();
  }
  private upsert(card: UnifiedSearchCard): UnifiedSearchCard { const prior=this.registry.get(card.key); if (prior!==undefined) { unifiedMergeCard(prior,card); return prior; } this.registry.set(card.key,card); return card; }
  private fuse(tags: UnifiedSearchCard[], vectors: UnifiedSearchCard[]): UnifiedSearchCard[] {
    const cards: Map<string,UnifiedSearchCard>=new Map<string,UnifiedSearchCard>();
    for (let route: number=0;route<2;route++) { const seen: Set<string>=new Set<string>(); let rank: number=0; for (const incoming of route===0?tags:vectors) { let card=cards.get(incoming.key); if (card===undefined) { card=incoming; cards.set(incoming.key,card); } else { unifiedMergeCard(card,incoming); } if (!seen.has(card.key)) { seen.add(card.key); rank++; if (route===0) { card.localRank=rank; } else { card.vectorRank=rank; } } card.score=(card.localRank>0?1/(60+card.localRank):0)+(card.vectorRank>0?1/(60+card.vectorRank):0); } }
    const result: UnifiedSearchCard[]=[]; cards.forEach((c: UnifiedSearchCard): void=> { result.push(c); }); result.sort((a: UnifiedSearchCard,b: UnifiedSearchCard): number=>b.score-a.score || a.key.localeCompare(b.key)); return result;
  }
  async page(groupId: string, cursor: string): Promise<void> {
    await this.follow<void>(this.pageCurrent(groupId,cursor));
  }
  private async pageCurrent(groupId: string, cursor: string): Promise<void> {
    const group=groupId==='Direct'?this.state.direct:this.state.related; const which=groupId==='Direct'?0:1; const event=this.state.session+'|'+groupId+'|'+cursor;
    if (this.pages.has(event) || this.pageInFlight.has(event)) { return; } if (cursor!==group.cursor || group.busy && this.scope===undefined) { return; }
    const epoch=this.state.epoch; const cancel=this.cancel; if (cancel===undefined) { return; } this.pageInFlight.add(event); group.busy=true; this.emit(); let added: number=0;
    try { if (which===0 && this.positions[0]>=this.directCandidates.length && this.lexicalMore) { await this.fetchLexical(epoch,cancel); if (!this.current(epoch,cancel)) { return; } } const candidates=which===0?this.directCandidates:this.relatedCandidates;
      for (const old of this.state.direct.cards.concat(this.state.related.cards)) { const valid=await this.scopePort.visible(old,this.state.includeArchived) && (this.lexical===undefined || await this.lexical.validate([old],this.state.includeArchived,cancel)); if (!this.current(epoch,cancel)) { return; } old.current=valid; }
      while (this.positions[which]<candidates.length && added<10) { const incoming=candidates[this.positions[which]++]; const card=this.upsert(incoming);
        if (which===1 && this.directImages.has(card.key)) { continue; } const visible=await this.scopePort.visible(card,this.state.includeArchived) && (this.lexical===undefined || await this.lexical.validate([card],this.state.includeArchived,cancel)); if (!this.current(epoch,cancel)) { return; } if (!visible) { continue; }
        if (group.cards.some((c: UnifiedSearchCard): boolean=>c.key===card.key)) { continue; } group.cards.push(card); added++;
      }
      group.cursor=String(Number(group.cursor)+1); group.revision++; group.exhausted=this.positions[which]>=candidates.length && (which!==0 || !this.lexicalMore) && (which===0 || this.state.semanticState!=='Loading'); this.pages.set(event,group.cursor); this.saveHistory();
    } finally { this.pageInFlight.delete(event); if (this.current(epoch,cancel)) { group.busy=false; this.emit(); } }
  }
  async review(): Promise<UnifiedQueryApproval> {
    return this.follow<UnifiedQueryApproval>(this.reviewCurrent());
  }
  private async reviewCurrent(): Promise<UnifiedQueryApproval> {
    const local: Promise<void> | undefined=this.local; if (local!==undefined) { await Promise.resolve(local); } const cancel=this.cancel; const epoch=this.state.epoch;
    if (cancel===undefined || this.scope===undefined || !this.scope.complete) { throw new ParsedFailure('CurrentLocalScopeRequired','query-review'); }
    if (this.lexical!==undefined && (await this.lexical.capabilities()).revision!==this.lexicalRevision) { throw new ParsedFailure('LocalMembershipChangedStartNewSession','query-review'); }
    if (this.lexical===undefined && this.scopePort.captureLocal!==undefined) { const current=await this.scopePort.captureLocal(this.config.currentConfig(),this.state.includeArchived,cancel); if (current.localHash!==this.scope.localHash || !this.current(epoch,cancel)) { throw new ParsedFailure('LocalMembershipChangedStartNewSession','query-review'); } }
    if (this.state.review!==undefined) { this.state.review.revoked=true; await this.engine.revoke(this.state.review.session,this.state.review.epoch); this.state.review=undefined; this.emit(); }
    const approval=await this.engine.review(this.state.question,this.state.session,epoch,this.state.includeArchived,cancel); if (!this.current(epoch,cancel)) { await this.engine.revoke(approval.session,approval.epoch); throw new ParsedFailure('StaleReview','query'); }
    if (this.lexical!==undefined && (await this.lexical.capabilities()).revision!==this.lexicalRevision) { await this.engine.revoke(approval.session,approval.epoch); throw new ParsedFailure('LocalMembershipChangedStartNewSession','query-review'); }
    if (this.lexical===undefined && this.scopePort.captureLocal!==undefined) { const current=await this.scopePort.captureLocal(this.config.currentConfig(),this.state.includeArchived,cancel); if (current.localHash!==this.scope.localHash) { await this.engine.revoke(approval.session,approval.epoch); throw new ParsedFailure('LocalMembershipChangedStartNewSession','query-review'); } }
    this.state.review=approval; this.emit(); return approval;
  }
  async allowSemantic(consent: boolean, cost: boolean): Promise<void> {
    if (this.semanticPromise!==undefined) { return this.semanticPromise; } const a=this.state.review; const cancel=this.cancel;
    if (a===undefined || cancel===undefined || !consent || !cost || a.epoch!==this.state.epoch || a.actual!==this.state.question) { throw new ParsedFailure('CurrentQueryConsentRequired','query'); }
    const epoch=this.state.epoch; a.approved=true; a.costAccepted=true;
    const semantic: Promise<void>=this.follow<void>(this.approveAndRun(a,epoch,cancel,cost)); this.semanticPromise=semantic; await semantic;
  }
  private async approveAndRun(a: UnifiedQueryApproval, epoch: number, cancel: ParsedCancellation, cost: boolean): Promise<void> {
    try { await this.engine.approve(a,cost); if (!this.current(epoch,cancel)) { return; } this.state.semanticState='Loading'; this.state.related.exhausted=false; this.emit(); await this.runSemantic(a,epoch,cancel); }
    catch { if (this.current(epoch,cancel)) { this.state.semanticState='NoRequest'; this.state.semanticError='CurrentQuestionApprovalChanged'; this.emit(); } }
  }
  private async runSemantic(a: UnifiedQueryApproval, epoch: number, cancel: ParsedCancellation): Promise<void> {
    try { const semantic=await this.engine.semantic(a,cancel); if (!this.current(epoch,cancel)) { return; }
      const fused=this.fuse(this.relatedCandidates,semantic); for (const card of fused) { this.upsert(card); }
      const consumed=this.relatedCandidates.slice(0,this.positions[1]); const seen: Set<string>=new Set<string>(consumed.map((c: UnifiedSearchCard): string=>c.key)); this.relatedCandidates=consumed;
      for (const card of fused) { if (!seen.has(card.key)) { seen.add(card.key); this.relatedCandidates.push(card); } }
      this.state.semanticState='Complete'; this.state.related.exhausted=false; await this.page('Related',this.state.related.cursor); this.saveHistory(); this.emit();
    } catch { if (this.current(epoch,cancel)) { this.state.semanticState='FailedOrUnknown'; this.state.semanticError='SemanticUnavailableNoAutomaticRetry'; this.state.related.exhausted=this.positions[1]>=this.relatedCandidates.length; this.saveHistory(); this.emit(); } }
  }
  private saveHistory(): void {
    const page: UnifiedSearchHistoryPage=new UnifiedSearchHistoryPage(); page.recordId=this.state.historyId; page.revision=++this.historyRevision; page.eventId='revision-'+page.revision; page.createdAt=Date.now(); page.question=this.state.question; page.scopeHash=this.scope?.hash ?? ''; page.direct=this.state.direct.cards.slice(); page.related=this.state.related.cards.slice(); page.semanticState=this.state.semanticState; page.unupgraded=this.state.unupgraded; page.directCursor=this.state.direct.cursor; page.relatedCursor=this.state.related.cursor;
    let snapshot: UnifiedSearchHistoryPage; try { snapshot=unifiedHistoryCopy(page); } catch { this.state.historyPending=true; return; }
    this.historyTail=this.historyTail.then(async (): Promise<void>=> { try { await this.history.append(snapshot); } catch { this.pendingHistory.push(snapshot); } this.state.historyPending=this.pendingHistory.length>0; this.emit(); });
  }
  async retryHistory(): Promise<void> { await this.historyTail; const pages=this.pendingHistory.slice(); this.pendingHistory=[]; for (const page of pages) { try { await this.history.append(page); } catch { this.pendingHistory.push(page); } } this.state.historyPending=this.pendingHistory.length>0; this.emit(); }
  async historyPage(offset: number): Promise<UnifiedSearchHistoryPage[]> { return this.history.list(offset,10); }
  async close(): Promise<void> { this.invalidate(); while (this.workers.length>0) { await Promise.all<void>(this.workers.slice()); } await this.historyTail; }
}
