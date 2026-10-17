import { TextCandidatePort } from '../domain/TextKnowledgePorts';
import { TextHit, TextQueryInput, TextCancellation, TextSearchResult, TextDocument, TextHistory, TextReferenceState } from '../domain/TextKnowledgeModels';
import { KnowledgeStateListener, KnowledgeIdentityPort, KnowledgePageReferencePort } from '../domain/KnowledgePorts';
import { KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { KnowledgeHit, KnowledgeHistory, KnowledgeSearchState, KnowledgeSourceKind, KnowledgeChannel, KnowledgeRoute, KnowledgeRouteState, KnowledgeQueryResult, KnowledgeHistoryCursor, KnowledgeHistoryPage, KnowledgeReferenceState } from '../domain/KnowledgeSearchModels';
import { prepareTextQuery } from '../pipeline/QueryPreparation';
import { knowledgeKeywordList, knowledgeMergeHistory, knowledgeDirectFirst } from '../pipeline/KnowledgeRetrievalPolicy';
import { knowledgeMatch, knowledgeLegacyMatch } from '../pipeline/KnowledgeMatchPolicy';
import { KnowledgeMatchKind } from '../domain/KnowledgeSearchModels';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { ResultPageReference } from '../domain/PdfLocalModels';
import { KnowledgeSemanticSearchPort } from '../domain/VectorWorkflowModels';
import { knowledgeWithin } from './KnowledgeDeadline';

export interface KnowledgeSearchRepository {
  ready(): boolean;
  candidates(input: TextQueryInput, archived: boolean, referenceAside: boolean, cancel: KnowledgeCancellation): Promise<KnowledgeHit[]>;
  directCandidates?(input: TextQueryInput, archived: boolean, referenceAside: boolean, cancel: KnowledgeCancellation): Promise<KnowledgeHit[]>;
  visible(hit: KnowledgeHit, archived: boolean): Promise<boolean>;
  saveHistory(history: KnowledgeHistory): Promise<void>;
  history(cursor: KnowledgeHistoryCursor, limit: number): Promise<KnowledgeHistoryPage>;
}
export interface KnowledgeLegacyHistoryPort { historyBefore(created: number, id: string, limit: number): Promise<TextHistory[]>; }
export function knowledgeTextHit(source: TextHit): KnowledgeHit {
  const hit: KnowledgeHit = new KnowledgeHit(); hit.id = 'text:'+source.chunkId; hit.chunkId = source.chunkId; hit.documentId = source.documentId; hit.sourceKind = KnowledgeSourceKind.Text;
  hit.generation = source.generation; hit.snapshotId = source.snapshotId; hit.originalHash = source.originalHash; hit.originalVersion = source.documentVersion;
  hit.title = source.title; hit.text = source.text; hit.retrievalText = source.retrievalText; hit.locator.textRanges = source.ranges.slice(); hit.keywordScore = source.score; hit.channels = [KnowledgeChannel.Keyword]; return hit;
}
export class KnowledgeSearchService {
  state: KnowledgeSearchState = new KnowledgeSearchState(); private text: TextCandidatePort; private pdf: KnowledgeSearchRepository;
  private identity: KnowledgeIdentityPort; private listeners: KnowledgeStateListener[] = []; private epoch: number = 0;
  private active: KnowledgeCancellation | undefined = undefined;
  private legacyHistory: KnowledgeLegacyHistoryPort | undefined = undefined;
  private pendingHistory: KnowledgeHistory | undefined = undefined;
  private historyWrite: Promise<void> | undefined = undefined;
  private clock: () => number = (): number => Date.now();
  setClock(clock: () => number): void { this.clock = clock; }
  private semantic: KnowledgeSemanticSearchPort | undefined;
  private pageReferences: KnowledgePageReferencePort | undefined;
  attachPages(port: KnowledgePageReferencePort): void { this.pageReferences = port; }
  private async present(hit: KnowledgeHit, input: TextQueryInput, cancel: KnowledgeCancellation): Promise<void> {
    hit.match = knowledgeMatch(hit,input,true); hit.match.textHash = await knowledgeWithin<string>(this.identity.hash(pdfCodecUtf8(hit.text)),cancel);
    if (hit.sourceKind === KnowledgeSourceKind.Pdf && this.pageReferences !== undefined) {
      try { hit.pages = await knowledgeWithin<ResultPageReference>(this.pageReferences.resolve(hit,cancel),cancel); }
      catch { hit.pages = new ResultPageReference(); hit.pages.reason = 'PageSourceUnavailableOrDeadline'; }
    }
  }
  attachSemantic(port: KnowledgeSemanticSearchPort): void { this.semantic = port; }
  private writeHistory(record: KnowledgeHistory): Promise<void> {
    this.pendingHistory = record; this.state.historyPending = true; this.emit();
    const writing = this.pdf.saveHistory(record); this.historyWrite = writing;
    // History settlement belongs to its fixed record, not the query epoch.
    // A backgrounded query must not hide its recoverable pending write.
    writing.then((): void => {
      if (this.pendingHistory === record && this.historyWrite === writing) { this.pendingHistory = undefined; this.historyWrite = undefined; this.state.historyPending = false; this.emit(); }
    },(): void => {
      if (this.pendingHistory === record && this.historyWrite === writing) { this.state.historyPending = true; this.emit(); }
    });
    return writing;
  }
  async retryHistory(): Promise<void> {
    const record: KnowledgeHistory | undefined = this.pendingHistory;
    if (record === undefined || this.state.busy) { return; }
    this.state.busy = true; const cancel = new KnowledgeCancellation(); cancel.now = this.clock; cancel.deadline = this.clock()+10000;
    try { if (this.historyWrite !== undefined) { try { await knowledgeWithin<void>(this.historyWrite,cancel); } catch { cancel.check(); await knowledgeWithin<void>(this.writeHistory(record),cancel); } } else { await knowledgeWithin<void>(this.writeHistory(record),cancel); } this.state.message = this.state.result.notice; }
    catch { this.state.message = this.state.result.notice+'；历史保存仍未完成，可重试；当前结果保留'; }
    finally { this.state.busy = false; this.emit(); }
  }
  attachLegacyHistory(port: KnowledgeLegacyHistoryPort): void { this.legacyHistory = port; }
  async historyPage(cursor: KnowledgeHistoryCursor, limit: number): Promise<KnowledgeHistoryPage> {
    const current: KnowledgeHistoryPage = await this.pdf.history(cursor,limit); const legacy: KnowledgeHistory[] = [];
    if (this.legacyHistory !== undefined) {
      for (const old of await this.legacyHistory.historyBefore(cursor.textCreated,cursor.textId,limit)) {
        const record: KnowledgeHistory = new KnowledgeHistory(); record.id = old.id; record.createdAt = old.createdAt; record.source = 'text'; record.result.input = old.result.input;
        record.result.hits = old.result.hits.map((hit: TextHit): KnowledgeHit => { const converted: KnowledgeHit = knowledgeTextHit(hit); converted.referenceState = hit.referenceState === TextReferenceState.Deleted ? KnowledgeReferenceState.Invalid : hit.referenceState === TextReferenceState.Old ? KnowledgeReferenceState.Old : KnowledgeReferenceState.Current; converted.match = knowledgeLegacyMatch(converted,old.result.input.actualInput); return converted; }); legacy.push(record);
      }
    }
    const merged = knowledgeMergeHistory(current.records,legacy,cursor,limit);
    const cancel = new KnowledgeCancellation(); cancel.now = this.clock; cancel.deadline = this.clock()+10000;
    for (const record of merged.records) { for (const hit of record.result.hits) {
      const actualHash = await knowledgeWithin<string>(this.identity.hash(pdfCodecUtf8(hit.text)),cancel);
      if (hit.match.textHash.length > 0 && hit.match.textHash !== actualHash) { hit.match.ranges = []; hit.match.kind = KnowledgeMatchKind.Unclassified; hit.referenceState = KnowledgeReferenceState.Invalid; hit.pages = new ResultPageReference(); }
      else { hit.match.textHash = actualHash; if (hit.sourceKind === KnowledgeSourceKind.Pdf && this.pageReferences !== undefined && hit.referenceState === KnowledgeReferenceState.Current) { try { hit.pages = await knowledgeWithin<ResultPageReference>(this.pageReferences.resolve(hit,cancel),cancel); } catch { hit.referenceState = KnowledgeReferenceState.Invalid; } } }
    } } return merged;
  }
  constructor(text: TextCandidatePort, pdf: KnowledgeSearchRepository, identity: KnowledgeIdentityPort) { this.text = text; this.pdf = pdf; this.identity = identity; }
  subscribe(listener: KnowledgeStateListener): void { this.listeners.push(listener); }
  unsubscribe(listener: KnowledgeStateListener): void { this.listeners = this.listeners.filter((item: KnowledgeStateListener): boolean => item !== listener); }
  private emit(): void { for (const listener of this.listeners) { listener.changed(); } }
  pause(): void { this.epoch++; this.state.queryConsent = false; this.state.queryFree = false; this.state.queryApproval = undefined; this.semantic?.pause(); if (this.active !== undefined) { this.active.invalid = true; } this.state.historyPending = this.pendingHistory !== undefined; this.emit(); }
  async search(): Promise<void> {
    if (this.state.busy) { return; }
    if (this.pendingHistory !== undefined) { this.state.message = '上一条历史尚未保存，请先重试保存；已有结果保留，未执行新检索'; this.emit(); return; }
    let input: TextQueryInput;
    try { input = prepareTextQuery(this.state.question); } catch { this.state.message = '请输入合法非空关键词；未检索或外发'; this.emit(); return; }
    const epoch: number = ++this.epoch; this.state.busy = true; const cancel: KnowledgeCancellation = new KnowledgeCancellation(); cancel.now = this.clock; cancel.deadline = this.clock()+10000; this.active = cancel;
    const queryConsent: boolean = this.state.queryConsent; const queryFree: boolean = this.state.queryFree; const selectedSpace: string = this.state.selectedSpaceId; this.state.queryConsent = false; this.state.queryFree = false;
    const approval = this.state.queryApproval; this.state.queryApproval = undefined;
    const textCancel: TextCancellation = new TextCancellation(); textCancel.deadline = cancel.deadline;
    const archived: boolean = this.state.includeArchived; const includeExtras: boolean = this.state.includeReferenceAside;
    const result: KnowledgeQueryResult = new KnowledgeQueryResult(); result.input = input; let timelyKeyword: KnowledgeHit[] = [];
    const keyword: KnowledgeRoute = new KnowledgeRoute(); keyword.channel = KnowledgeChannel.Keyword;
    const vector: KnowledgeRoute = new KnowledgeRoute(); vector.channel = KnowledgeChannel.Vector; vector.reason = queryConsent ? 'InputLimitUnverified' : 'QueryConsentOff';
    result.routes = [keyword,vector]; let textHits: KnowledgeHit[] = []; let pdfHits: KnowledgeHit[] = []; let succeeded: number = 0;
    try {
      try { if (this.text.directCandidates === undefined) { throw new KnowledgeFailure('TextDirectPortUnavailable','query'); } const text: TextSearchResult = await knowledgeWithin<TextSearchResult>(this.text.directCandidates(input,archived,textCancel),cancel); textHits = text.hits.map((hit: TextHit): KnowledgeHit => knowledgeTextHit(hit)); succeeded++; keyword.reason = text.channel; }
      catch { keyword.reason = 'M1KeywordFailed'; }
      if (this.pdf.ready()) {
        try { if (this.pdf.directCandidates === undefined) { throw new KnowledgeFailure('PdfDirectPortUnavailable','query'); } pdfHits = await knowledgeWithin<KnowledgeHit[]>(this.pdf.directCandidates(input,archived,includeExtras,cancel),cancel); succeeded++; }
        catch { keyword.reason += ' · PDFKeywordFailed'; }
      } else { keyword.reason += ' · PDFExtensionUnavailable'; }
      cancel.check(); if (epoch !== this.epoch) { throw new KnowledgeFailure('StaleQuery','search'); }
      const combined: KnowledgeHit[] = knowledgeKeywordList(textHits,pdfHits); const visible: KnowledgeHit[] = [];
      for (const hit of combined) {
        cancel.check();
        hit.match = knowledgeMatch(hit,input,false); if (hit.match.kind !== KnowledgeMatchKind.Direct) { continue; }
        if (hit.sourceKind === KnowledgeSourceKind.Pdf) { if (await knowledgeWithin<boolean>(this.pdf.visible(hit,archived),cancel)) { visible.push(hit); } }
        else { const doc: TextDocument | undefined = await knowledgeWithin<TextDocument | undefined>(this.text.get(hit.documentId),cancel); if (doc !== undefined && doc.activeGeneration === hit.generation && doc.original.hash === hit.originalHash && (archived || !doc.archived)) { visible.push(hit); } }
        timelyKeyword = visible.slice();
      }
      let semanticHits: KnowledgeHit[] = [];
      if (visible.length > 0) { vector.reason = 'DirectPresentNoEgress'; }
      else if (succeeded !== 2 || combined.some((hit: KnowledgeHit): boolean => hit.match.kind === KnowledgeMatchKind.Direct)) { vector.reason = 'DirectScopeIncompleteOrChangedNoEgress'; }
      else if (queryConsent && this.semantic !== undefined) {
        try { if (approval === undefined || !approval.approved || !approval.free || approval.purpose !== 'query' || !queryFree || approval.actual !== input.actualInput || approval.space !== selectedSpace || this.semantic.searchReviewed === undefined) { throw new KnowledgeFailure('NoRequestSnapshotUnavailable','query'); } semanticHits = await knowledgeWithin<KnowledgeHit[]>(this.semantic.searchReviewed(approval,archived,includeExtras,cancel),cancel); vector.state = KnowledgeRouteState.Available; vector.reason = 'SameSpaceExactKnn'; vector.actualEgress = this.semantic.queryEgress; }
        catch (error) { vector.state = KnowledgeRouteState.Failed; vector.reason = error instanceof KnowledgeFailure ? error.category : 'VectorRouteFailed'; vector.actualEgress = this.semantic.queryEgress; }
      }
      cancel.check(); if (epoch !== this.epoch) { throw new KnowledgeFailure('StaleQuery','search'); }
      const finalKeyword: KnowledgeHit[] = []; const finalVector: KnowledgeHit[] = [];
      for (const hit of visible) { if (hit.sourceKind === KnowledgeSourceKind.Pdf ? await knowledgeWithin<boolean>(this.pdf.visible(hit,archived),cancel) : await this.textVisible(hit,archived,cancel)) { finalKeyword.push(hit); } }
      timelyKeyword = finalKeyword.slice();
      for (const hit of semanticHits) { if (await knowledgeWithin<boolean>(this.pdf.visible(hit,archived),cancel)) { finalVector.push(hit); } }
      cancel.check();
      result.keywordHits = finalKeyword; result.vectorHits = finalVector;
      result.hits = knowledgeDirectFirst(finalKeyword,finalVector,input,selectedSpace); result.failed = succeeded === 0 && vector.state !== KnowledgeRouteState.Available; keyword.state = succeeded === 2 ? KnowledgeRouteState.Available : KnowledgeRouteState.Failed;
      result.channel = finalKeyword.length > 0 || vector.state !== KnowledgeRouteState.Available ? KnowledgeChannel.Keyword : KnowledgeChannel.Vector;
      result.notice = finalKeyword.length > 0 ? `词条直接命中；未调用问题嵌入${succeeded < 2 ? '；部分资料正文读取失败，范围不完整' : ''}` : succeeded !== 2 || vector.reason === 'DirectScopeIncompleteOrChangedNoEgress' ? '正文检索范围不完整或来源已变化，不是全库无命中；未外发相似查询' : vector.reason === 'DirectPresentNoEgress' ? '正文来源已变化，请重新检索；未调用问题嵌入' : vector.state === KnowledgeRouteState.Failed ? `相似检索不可用：${vector.reason}；未生成回答` : vector.state !== KnowledgeRouteState.Available ? '没有词条直接命中；相似检索未开启或当前授权不可用，未外发' : result.hits.length === 0 ? '没有可展示的同空间相似片段；未生成回答' : '相似结果，仅为同空间候选片段；未生成回答';
      for (const hit of result.hits) { await this.present(hit,input,cancel); }
      const stillVisible: KnowledgeHit[] = [];
      for (const hit of result.hits) { cancel.check(); if (hit.sourceKind === KnowledgeSourceKind.Pdf ? await knowledgeWithin<boolean>(this.pdf.visible(hit,archived),cancel) : await this.textVisible(hit,archived,cancel)) { stillVisible.push(hit); } } result.hits = stillVisible;
      cancel.check(); if (epoch !== this.epoch) { throw new KnowledgeFailure('StaleQuery','history'); }
      const history: KnowledgeHistory = new KnowledgeHistory(); history.id = this.identity.id(); history.createdAt = Date.now(); history.result = result;
      this.state.historyId = history.id; this.state.historyPending = false;
      this.state.result = result; this.state.message = result.notice;
      this.emit();
      if (this.pdf.ready()) {
        try { await knowledgeWithin<void>(this.writeHistory(history),cancel); }
        catch { this.state.historyPending = this.pendingHistory !== undefined; this.emit(); }
      } else { result.notice += '；统一历史不可用，未写旧历史替代'; }
      if (epoch !== this.epoch) { throw new KnowledgeFailure('StaleQuery','result'); }
      if (cancel.now() < cancel.deadline) { this.state.result = result; this.state.message = result.notice+(this.state.historyPending ? '；历史保存失败，当前结果保留，可独立重试' : ''); }
    } catch { if (epoch === this.epoch) { result.keywordHits = timelyKeyword; result.vectorHits = []; result.hits = knowledgeDirectFirst(timelyKeyword,[],input,''); result.channel = KnowledgeChannel.Keyword; result.failed = succeeded === 0; vector.state = KnowledgeRouteState.Failed; vector.reason = 'DeadlineOrCanceled'; result.notice = '查询截止，保留截止前已核正文命中；迟到结果未采纳，原页未核不跳转'; this.state.result = result; this.state.message = result.notice; } }
    finally { if (this.active === cancel) { this.active = undefined; } this.state.busy = false; this.emit(); }
  }
  private async textVisible(hit: KnowledgeHit, archived: boolean, cancel: KnowledgeCancellation): Promise<boolean> { const doc = await knowledgeWithin<TextDocument | undefined>(this.text.get(hit.documentId),cancel); return doc !== undefined && doc.activeGeneration === hit.generation && doc.original.hash === hit.originalHash && (archived || !doc.archived); }
}
