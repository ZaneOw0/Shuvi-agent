import { UnifiedQueryHistoryPort } from '../domain/UnifiedQueryPorts';
import { UnifiedSearchHistoryPage, UnifiedQueryScopePort, UnifiedSearchCard, UnifiedSearchReason, UnifiedSearchParent } from '../domain/UnifiedQueryModels';
import { ParsedDocumentRepository } from './ParsedDocumentRepository';
import { ParsedDocumentAssets } from './ParsedDocumentAssets';
import { ParsedCancellation, ParsedFailure } from '../domain/ParsedDocumentModels';
import { UnifiedHistoryRevision } from '../domain/UnifiedKnowledgeModels';
import { unifiedHistoryDecode, unifiedHistoryCopy, unifiedHistoryCard, UnifiedHistoryManifest, UnifiedHistoryCardRef, unifiedHistoryManifestDecode } from '../pipeline/UnifiedHistoryCodec';
import { parsedUtf8, parsedJson } from '../pipeline/ParsedDocumentCodec';
import { KnowledgeHistoryCursor } from '../domain/KnowledgeSearchModels';
import { KnowledgeSearchService } from '../application/KnowledgeSearchService';

export class UnifiedKnowledgeHistoryRepository implements UnifiedQueryHistoryPort {
  private repository: ParsedDocumentRepository; private assets: ParsedDocumentAssets; private scope: UnifiedQueryScopePort;
  private legacy: KnowledgeSearchService | undefined;
  constructor(repository: ParsedDocumentRepository, assets: ParsedDocumentAssets, scope: UnifiedQueryScopePort) { this.repository=repository; this.assets=assets; this.scope=scope; }
  attachLegacy(service: KnowledgeSearchService): void { this.legacy=service; }
  async recoverPending(): Promise<void> {
    for (const id of await this.repository.pendingHistoryAssets()) {
      const bytes=await this.assets.read(id,new ParsedCancellation()); const manifest=unifiedHistoryManifestDecode(bytes); const page=manifest.header;
      if (id!==`${page.recordId}-r${page.revision}`) { throw new ParsedFailure('PendingHistoryIdentity','history'); }
      for (const ref of manifest.refs) { const raw=await this.assets.read(ref.asset,new ParsedCancellation()); if (await this.assets.contentHash(raw)!==ref.hash) { throw new ParsedFailure('PendingHistoryCardHash','history'); } unifiedHistoryCard(parsedJson(raw,new ParsedCancellation())); }
      const row: UnifiedHistoryRevision=new UnifiedHistoryRevision(); row.recordId=page.recordId; row.eventId=page.eventId; row.revision=page.revision; row.snapshotAsset=id; row.snapshotHash=await this.assets.contentHash(bytes); row.createdAt=page.createdAt; await this.repository.appendHistory(row);
    }
  }
  async append(page: UnifiedSearchHistoryPage): Promise<void> {
    const copy=unifiedHistoryCopy(page); const manifest: UnifiedHistoryManifest=new UnifiedHistoryManifest(); const direct=copy.direct; const related=copy.related; copy.direct=[]; copy.related=[]; manifest.header=copy;
    for (const group of ['Direct','Related']) { for (const card of group==='Direct'?direct:related) {
      const bytes=parsedUtf8(JSON.stringify(card)); const key='history-card-'+await this.assets.contentHash(bytes); const hash=await this.assets.saveHistory(key,copy.recordId,bytes,new ParsedCancellation());
      const read=await this.assets.read(key,new ParsedCancellation()); if (JSON.stringify(unifiedHistoryCard(parsedJson(read,new ParsedCancellation())))!==JSON.stringify(card)) { throw new ParsedFailure('HistoryCardReadback','history'); }
      const ref: UnifiedHistoryCardRef=new UnifiedHistoryCardRef(); ref.asset=key; ref.hash=hash; ref.group=group; manifest.refs.push(ref);
    } }
    const bytes=parsedUtf8(JSON.stringify(manifest)); if (bytes.length>1048576) { throw new ParsedFailure('HistoryManifestBudget','history'); } const asset=`${copy.recordId}-r${copy.revision}`;
    const hash=await this.assets.saveHistory(asset,copy.recordId,bytes,new ParsedCancellation()); unifiedHistoryManifestDecode(await this.assets.read(asset,new ParsedCancellation()));
    const revision: UnifiedHistoryRevision=new UnifiedHistoryRevision(); revision.recordId=copy.recordId; revision.eventId=copy.eventId; revision.revision=copy.revision; revision.snapshotAsset=asset; revision.snapshotHash=hash; revision.createdAt=copy.createdAt; await this.repository.appendHistory(revision);
  }
  async list(offset: number, limit: number): Promise<UnifiedSearchHistoryPage[]> {
    await this.recoverPending();
    const pages: UnifiedSearchHistoryPage[]=[];
    for (const row of await this.repository.unifiedHistoryRows(offset,limit)) { const raw=await this.assets.read(row.snapshotAsset,new ParsedCancellation()); const root=parsedJson(raw,new ParsedCancellation()); let page: UnifiedSearchHistoryPage;
      if (root.required('wire').string()==='UNIFIED-KNOWLEDGE-HISTORY-FILES-1') { const manifest=unifiedHistoryManifestDecode(raw); page=manifest.header;
        for (const ref of manifest.refs) { const bytes=await this.assets.read(ref.asset,new ParsedCancellation()); if (await this.assets.contentHash(bytes)!==ref.hash) { throw new ParsedFailure('HistoryCardHash','history'); } const card=unifiedHistoryCard(parsedJson(bytes,new ParsedCancellation())); if (ref.group==='Direct') { page.direct.push(card); } else { page.related.push(card); } }
      } else { page=unifiedHistoryDecode(raw); }
      if (page.recordId!==row.recordId || page.revision!==row.revision || page.eventId!==row.eventId) { throw new ParsedFailure('HistoryRowBinding','history'); }
      for (const card of page.direct.concat(page.related)) { card.current=await this.scope.visible(card,true); } pages.push(page);
    } return pages;
  }
  async clear(): Promise<void> { await this.repository.clearUnifiedHistory(); }
  async legacyPage(cursor: KnowledgeHistoryCursor, limit: number): Promise<UnifiedSearchHistoryPage[]> {
    if (this.legacy===undefined) { return []; } const old=await this.legacy.historyPage(cursor,limit); const pages: UnifiedSearchHistoryPage[]=[];
    for (const saved of old.records) { const page: UnifiedSearchHistoryPage=new UnifiedSearchHistoryPage(); page.wire='LegacyReadOnly'; page.recordId=saved.id; page.question=saved.result.input.actualInput; page.createdAt=saved.createdAt;
      for (const hit of saved.result.hits) { const card: UnifiedSearchCard=new UnifiedSearchCard(); card.key='legacy:'+hit.id; card.kind='Legacy'; card.documentKey=hit.documentId; card.generation=hit.generation; card.title=hit.title; card.text=hit.text; card.current=hit.referenceState==='Current'; const reason: UnifiedSearchReason=new UnifiedSearchReason(); reason.id='legacy-reason:'+hit.id; reason.route='LegacySaved:'+hit.channels.join('+'); reason.savedReason=hit.match===undefined?'OriginalReasonNotReported':JSON.stringify(hit.match); reason.text=hit.text; reason.version=hit.generation; card.reasons=[reason]; const parent: UnifiedSearchParent=new UnifiedSearchParent(); parent.documentKey=hit.documentId; parent.generation=hit.generation; parent.title=hit.title; parent.precision='LegacySaved'; card.parents=[parent]; page.related.push(card); }
      pages.push(page);
    } return pages;
  }
}
