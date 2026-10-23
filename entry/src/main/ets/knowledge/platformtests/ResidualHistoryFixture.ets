import { KnowledgeSearchService } from '../application/KnowledgeSearchService';
import { PdfKnowledgeRepository } from '../infra/PdfKnowledgeRepository';
import { KnowledgeStoreHost } from '../infra/KnowledgeStoreHost';
import { TextRdbRepository } from '../infra/TextRdbRepository';
import { KnowledgePlatformIdentity } from '../infra/KnowledgeAssembly';
import { KnowledgeHistory, KnowledgeHit, KnowledgeHistoryCursor, KnowledgeSourceKind } from '../domain/KnowledgeSearchModels';
import { KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { TextQueryInput } from '../domain/TextKnowledgeModels';
import { KnowledgeCallbackListener } from '../domain/KnowledgePorts';

export class ResidualDeferredHistoryRepository extends PdfKnowledgeRepository {
  private resolveWrite: () => void = (): void => {};
  private rejectWrite: (error: Object) => void = (_error: Object): void => {};
  entered: Promise<void>; private signalEntered: () => void = (): void => {};
  saves: number = 0; ids: string[] = [];
  constructor(host: KnowledgeStoreHost) { super(host); this.entered = new Promise<void>((resolve: () => void): void => { this.signalEntered = resolve; }); }
  settle(reject: boolean): void { if (reject) { this.rejectWrite(new KnowledgeFailure('DeferredHistoryRejected','fixture')); } else { this.resolveWrite(); } }
  async candidates(input: TextQueryInput,_archived: boolean,_extras: boolean,cancel: KnowledgeCancellation): Promise<KnowledgeHit[]> { cancel.check(); const hit = new KnowledgeHit(); hit.id = 'residual-history-hit'; hit.sourceKind = KnowledgeSourceKind.Pdf; hit.text = input.actualInput; hit.keywordScore = 101; return [hit]; }
  async visible(_hit: KnowledgeHit,_archived: boolean): Promise<boolean> { return true; }
  async saveHistory(record: KnowledgeHistory): Promise<void> {
    this.saves++; this.ids.push(record.id);
    if (this.saves === 1) { const held = new Promise<void>((resolve: () => void,reject: (error: Object) => void): void => { this.resolveWrite = resolve; this.rejectWrite = reject; }); this.signalEntered(); await held; }
    await super.saveHistory(record);
  }
}
export async function residualHistoryPauseCase(host: KnowledgeStoreHost,text: TextRdbRepository,reject: boolean): Promise<void> {
  const pdf = new ResidualDeferredHistoryRepository(host); await pdf.open(); const search = new KnowledgeSearchService(text,pdf,new KnowledgePlatformIdentity()); let notifications: number = 0; const listener = new KnowledgeCallbackListener((): void => { notifications++; }); search.subscribe(listener);
  try {
    search.state.question = reject ? 'history pause reject' : 'history pause resolve'; const pending = search.search(); await pdf.entered; const firstId = search.state.historyId; const firstResult = search.state.result; search.pause();
    if (!search.state.historyPending || firstId.length === 0) { throw new KnowledgeFailure('PauseHidPendingHistory','residual'); }
    search.unsubscribe(listener); search.subscribe(listener); pdf.settle(reject); await pending;
    if (search.state.result !== firstResult || search.state.historyId !== firstId || notifications < 3) { throw new KnowledgeFailure('HistorySettlementOverwroteResult','residual'); }
    if (reject) { if (!search.state.historyPending) { throw new KnowledgeFailure('RejectedHistoryRetryHidden','residual'); } await search.retryHistory(); }
    if (search.state.historyPending || pdf.saves !== (reject ? 2 : 1) || new Set<string>(pdf.ids).size !== 1) { throw new KnowledgeFailure('HistoryRetriedWrongId','residual'); }
    const records = (await pdf.history(new KnowledgeHistoryCursor(),20)).records.filter((row: KnowledgeHistory): boolean => row.id === firstId); if (records.length !== 1) { throw new KnowledgeFailure('HistoryFixedIdNotOnce','residual'); }
    search.state.question = 'following local query'; await search.search(); if (search.state.historyId === firstId || search.state.result.input.actualInput !== 'following local query' || search.state.historyPending) { throw new KnowledgeFailure('NextQueryStillBlocked','residual'); }
  } finally { search.unsubscribe(listener); await pdf.close(); }
}
