import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { KnowledgeIdentityPort, KnowledgeScopePort, KnowledgeQueryAdmissionPort, KnowledgeSearchSourcePort, KnowledgeSourceScan } from '../domain/KnowledgePorts';
import { KnowledgeScopeReceipt, KnowledgeScopeSourceReceipt } from '../domain/ImageKnowledgeModels';
import { KnowledgeHit } from '../domain/KnowledgeSearchModels';
import { QueryConsentSnapshot } from '../domain/EmbeddingModels';
import { KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { TextQueryInput } from '../domain/TextKnowledgeModels';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { prepareTextQuery } from '../pipeline/QueryPreparation';
import { UnifiedQueryAdmissionPort, UnifiedQueryApproval } from '../domain/UnifiedQueryModels';
import { ParsedCancellation } from '../domain/ParsedDocumentModels';

export class KnowledgeSourceRegistry implements KnowledgeScopePort, KnowledgeQueryAdmissionPort, UnifiedQueryAdmissionPort {
  private unified: UnifiedQueryAdmissionPort | undefined;
  attachUnifiedAdmission(port: UnifiedQueryAdmissionPort): void { this.unified=port; }
  async admitUnified(approval: UnifiedQueryApproval, input: string, cancel: ParsedCancellation, launch: () => void): Promise<void> {
    if (this.unified===undefined) { throw new KnowledgeFailure('UnifiedQueryAdmissionUnavailable','query'); } await this.unified.admitUnified(approval,input,cancel,launch);
  }
  private host: KnowledgeStoreHost; private identity: KnowledgeIdentityPort; private sources: KnowledgeSearchSourcePort[] = [];
  private lastHits: KnowledgeHit[] = []; private receipts: KnowledgeScopeReceipt[] = [];
  private hitSets: Map<string,KnowledgeHit[]> = new Map<string,KnowledgeHit[]>();
  constructor(host: KnowledgeStoreHost, identity: KnowledgeIdentityPort) { this.host = host; this.identity = identity; }
  register(source: KnowledgeSearchSourcePort): void {
    if (['Text','Pdf','Image','Docx'].indexOf(source.kind) < 0 || this.sources.some((p: KnowledgeSearchSourcePort): boolean => p.kind === source.kind)) { throw new KnowledgeFailure('UnknownOrDuplicateSource','scope'); } this.sources.push(source);
  }
  hits(receiptId: string): KnowledgeHit[] { const hits: KnowledgeHit[] | undefined = this.hitSets.get(receiptId); if (hits === undefined) { throw new KnowledgeFailure('ScopeHitSetMissing','scope'); } return hits.slice(); }
  async visible(hit: KnowledgeHit, archived: boolean): Promise<boolean> {
    const source: KnowledgeSearchSourcePort | undefined = this.sources.find((p: KnowledgeSearchSourcePort): boolean => p.kind === hit.sourceKind);
    if (source === undefined) { return false; }
    return await source.visible(hit,archived);
  }
  private async scanLocked(input: TextQueryInput, archived: boolean, extras: boolean, cancel: KnowledgeCancellation): Promise<KnowledgeScopeReceipt> {
    this.lastHits = []; const receipt: KnowledgeScopeReceipt = new KnowledgeScopeReceipt(); receipt.id = this.identity.id(); receipt.archived = archived; receipt.extras = extras;
    receipt.queryHash = await this.identity.hash(pdfCodecUtf8(input.actualInput)); let complete: boolean = true;
    const registered = await this.host.requireStore().querySql('SELECT kind,state FROM kb_source_registry ORDER BY kind'); const enabled: string[] = [];
    try { while (registered.goToNextRow()) { const kind: string = registered.getString(0); if (registered.getString(1) !== 'Enabled' || ['Text','Pdf','Image','Docx'].indexOf(kind) < 0) { throw new KnowledgeFailure('UnknownOrUnavailableSourceRegistration','scope'); } enabled.push(kind); } } finally { registered.close(); }
    if (enabled.length === 0 || enabled.some((kind: string): boolean => !this.sources.some((source: KnowledgeSearchSourcePort): boolean => source.kind === kind)) || this.sources.some((source: KnowledgeSearchSourcePort): boolean => enabled.indexOf(source.kind) < 0)) { complete = false; }
    for (const source of this.sources) {
      const part: KnowledgeScopeSourceReceipt = new KnowledgeScopeSourceReceipt(); part.kind = source.kind;
      try { const scan: KnowledgeSourceScan = await source.scan(input,archived,extras,cancel); part.count = scan.count; part.revision = scan.revision; part.complete = scan.complete; this.lastHits = this.lastHits.concat(scan.hits); if (!scan.complete) { complete = false; } }
      catch { complete = false; part.complete = false; part.revision = 'Unavailable'; } receipt.sources.push(part);
    }
    cancel.check(); receipt.complete = complete; receipt.noDirect = complete && this.lastHits.length === 0;
    receipt.scopeHash = await this.identity.hash(pdfCodecUtf8(JSON.stringify([receipt.queryHash,archived,extras,receipt.sources]))); this.hitSets.set(receipt.id,this.lastHits.slice()); return receipt;
  }
  async scan(input: TextQueryInput, archived: boolean, extras: boolean, cancel: KnowledgeCancellation): Promise<KnowledgeScopeReceipt> {
    return this.host.enqueue<KnowledgeScopeReceipt>(async (): Promise<KnowledgeScopeReceipt> => {
      const receipt = await this.scanLocked(input,archived,extras,cancel); this.receipts = this.receipts.filter((r: KnowledgeScopeReceipt): boolean => !r.consumed).slice(-15); this.receipts.push(receipt);
      const retained: Set<string> = new Set<string>(this.receipts.map((r: KnowledgeScopeReceipt): string => r.id)); this.hitSets.forEach((_hits: KnowledgeHit[],id: string): void => { if (!retained.has(id)) { this.hitSets.delete(id); } }); return receipt;
    });
  }
  async admit(approval: QueryConsentSnapshot, input: string, cancel: KnowledgeCancellation, launch: () => void): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => {
      cancel.check();
      const receipt = this.receipts.find((r: KnowledgeScopeReceipt): boolean => r.scopeHash === approval.scopeHash && !r.consumed && r.complete && r.noDirect);
      if (receipt === undefined || !approval.approved || !approval.free || approval.purpose !== 'query' || approval.actual !== input) { throw new KnowledgeFailure('NoRequestScopeOrApprovalMissing','query-admission'); }
      const current = await this.scanLocked(prepareTextQuery(input),receipt.archived,receipt.extras,cancel);
      this.hitSets.delete(current.id);
      if (!current.complete || !current.noDirect || current.scopeHash !== receipt.scopeHash || current.queryHash !== approval.inputHash) { throw new KnowledgeFailure('NoRequestScopeChangedOrDirect','query-admission'); }
      cancel.check();
      if (!approval.approved || !approval.free || approval.purpose !== 'query' || approval.actual !== input || approval.scopeHash !== current.scopeHash) { throw new KnowledgeFailure('NoRequestConsentRevokedDuringAdmission','query-admission'); }
      receipt.consumed = true; launch();
      // The network Promise is created inside admission but is never awaited in the write queue.
    });
  }
}
