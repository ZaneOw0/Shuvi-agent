import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { CloseoutSourceFixture } from './CloseoutSourceFixture';
import { PdfNativeSuiteResult, PdfNativeCaseResult } from './PdfNativeSuite';
import { KnowledgeCancellation, KnowledgeFailure, KnowledgeReadLease, PdfKnowledgeDocument, PdfIngestionJob, KnowledgePin } from '../domain/PdfKnowledgeModels';
import { KnowledgeOperationSession } from '../application/KnowledgeOperationSession';
import { QueryConsentSession } from '../application/QueryConsentSession';
import { EmbeddingConfig, QueryConsentSnapshot } from '../domain/EmbeddingModels';
import { EmbeddingTokenAdapter } from '../infra/EmbeddingTokenAdapter';
import { KnowledgePlatformIdentity } from '../infra/KnowledgeAssembly';
import { EmbeddingBaselineAcceptance } from '../domain/EmbeddingBasisModels';
import { embeddingFingerprint } from '../pipeline/EmbeddingPolicy';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { KnowledgeCapabilityAudit, CapabilityAuditGate } from '../infra/KnowledgeCapabilityAudit';
import { KnowledgeSearchService } from '../application/KnowledgeSearchService';
import { KnowledgeHit, KnowledgeHistory, KnowledgeHistoryCursor, KnowledgeChannel, KnowledgeSourceKind } from '../domain/KnowledgeSearchModels';
import { PdfKnowledgeRepository } from '../infra/PdfKnowledgeRepository';
import { KnowledgeStoreHost } from '../infra/KnowledgeStoreHost';
import { TextQueryInput } from '../domain/TextKnowledgeModels';
import { KnowledgeSemanticSearchPort } from '../domain/VectorWorkflowModels';
import { EmbeddingSpace } from '../domain/EmbeddingModels';
import { VectorRdbRepository } from '../infra/VectorRdbRepository';
import { PdfVectorRepository } from '../infra/PdfVectorRepository';
import { residualHistoryPauseCase } from './ResidualHistoryFixture';

function closeoutAssert(condition: boolean, category: string): void { if (!condition) { throw new KnowledgeFailure(category,'closeout'); } }
class CloseoutQueryRepository extends PdfKnowledgeRepository {
  clockValue: number = Date.now(); phase: string = ''; visibleCount: number = 0; saves: number = 0;
  testHit: KnowledgeHit = new KnowledgeHit();
  async candidates(_input: TextQueryInput,_archived: boolean,_extras: boolean,cancel: KnowledgeCancellation): Promise<KnowledgeHit[]> { cancel.check(); closeoutAssert(await this.get(this.testHit.documentId) !== undefined,'FixtureDocumentLost'); return [this.testHit]; }
  async visible(hit: KnowledgeHit,_archived: boolean): Promise<boolean> { const result = await this.get(hit.documentId) !== undefined; this.visibleCount++; if (this.phase === 'visibility' && this.visibleCount === 2) { this.clockValue += 10001; } return result; }
  async saveHistory(history: KnowledgeHistory): Promise<void> { this.saves++; if (this.phase === 'history') { this.clockValue += 10001; await new Promise<void>((resolve: () => void): void => { setTimeout(resolve,30); }); } await super.saveHistory(history); }
}
class CloseoutSemantic implements KnowledgeSemanticSearchPort {
  queryEgress: boolean = false; private repository: CloseoutQueryRepository;
  constructor(repository: CloseoutQueryRepository) { this.repository = repository; }
  async spaces(): Promise<EmbeddingSpace[]> { return []; }
  pause(): void {}
  async search(_input: string,_space: string,_consent: boolean,_free: boolean,_archived: boolean,_extras: boolean,_cancel: KnowledgeCancellation): Promise<KnowledgeHit[]> { this.repository.clockValue += 10001; return []; }
  async searchReviewed(_approval: QueryConsentSnapshot,_archived: boolean,_extras: boolean,_cancel: KnowledgeCancellation): Promise<KnowledgeHit[]> { this.repository.clockValue += 10001; return []; }
}
export async function knowledgeRunCloseoutSuite(context: common.Context, scope: KnowledgeStorageScope): Promise<PdfNativeSuiteResult> {
  const result = new PdfNativeSuiteResult(); result.run = scope.key; result.version = 'R2-CLOSEOUT-1'; const fixture = new CloseoutSourceFixture(context,scope); const identity = new KnowledgePlatformIdentity();
  const names: string[] = ['source-fixture','fresh-operation','source-render-regions','source-release-receipt','source-release-reopen','source-late-close','consent-bidirectional','consent-purpose-config','document-task-pages','task-pages','late-vector-fallback','late-final-visibility','late-history-once','history-pause-resolve','history-pause-reject','audit-identity-reopen','audit-env-invalidated','audit-fail-closed'];
  try { for (const name of names) { const row = new PdfNativeCaseResult(); row.id = name;
    try {
      if (name === 'source-fixture') { await fixture.prepare(); await fixture.adapter.openOriginal(fixture.binding,new KnowledgeCancellation()); await fixture.addEvidence(); }
      else if (name === 'fresh-operation') { let now: number = Date.now(); const operations = new KnowledgeOperationSession((): number => now); const old = operations.begin(); now += 120001; let rejected: boolean = false; try { old.check(); } catch { rejected = true; } const fresh = operations.begin(); const pixels = await fixture.adapter.renderPage(0,fresh); operations.current(fresh); closeoutAssert(rejected && (await pixels.getImageInfo()).size.width > 0,'ExpiredOldBlockedFresh'); operations.stop(); rejected = false; try { fresh.check(); } catch { rejected = true; } closeoutAssert(rejected,'LeaveDidNotCancel'); }
      else if (name === 'source-render-regions') { const regions = await fixture.adapter.regions(fixture.snapshot.nodes[0],0); closeoutAssert(regions.length === 2 && Math.abs(regions[0].left-0.1) < 0.00001 && Math.abs(regions[1].right-0.8) < 0.00001,'SourceRegionGold'); closeoutAssert(fixture.snapshot.nodes[1].table?.cells.slice(12,24).length === 12 && fixture.snapshot.nodes[0].rawLatex === 'E=mc^{2}','StructurePaging'); }
      else if (name === 'source-release-receipt') { fixture.pdf.injectLocalFault(scope.key,'ReleaseRead'); await fixture.session.release(fixture.adapter); const rows = await fixture.host.requireStore().querySql('SELECT (SELECT count(*) FROM kb_read_lease),(SELECT count(*) FROM r2s_source_release)'); try { rows.goToNextRow(); closeoutAssert(rows.getLong(0) === 1 && rows.getLong(1) === 1 && fixture.session.state === 'ReleaseUnconfirmed','SourceReceiptLost'); } finally { rows.close(); } }
      else if (name === 'source-release-reopen') { const reopened = new PdfKnowledgeRepository(fixture.host); await reopened.open(); try { const rows = await fixture.host.requireStore().querySql('SELECT count(*) FROM r2s_source_release'); try { rows.goToNextRow(); closeoutAssert(rows.getLong(0) === 1,'SourceReceiptNotDurable'); } finally { rows.close(); } await fixture.session.retry(); await reopened.retrySourceReleases(scope.key); closeoutAssert((await reopened.localCounts(fixture.job.generation))[3] === 0,'SourceLeaseLeaked'); } finally { await reopened.close(); } }
      else if (name === 'source-late-close') { await fixture.adapter.openOriginal(fixture.binding,new KnowledgeCancellation()); const rendering = fixture.adapter.renderPage(0,new KnowledgeCancellation()); const closing = fixture.session.release(fixture.adapter); let late: boolean = false; try { await rendering; } catch { late = true; } await closing; closeoutAssert(late && fixture.adapter.releaseState === 'Released' && (await fixture.pdf.localCounts(fixture.job.generation))[3] === 0,'LateSourceClose'); }
      else if (name.startsWith('consent-')) {
        const config = new EmbeddingConfig(); config.modelId = 'BAAI/bge-m3'; const counter = new EmbeddingTokenAdapter(context,identity); const proof = await counter.evidence(config.modelId,'query','reviewed input',await identity.hash(pdfCodecUtf8('reviewed input'))); const basis = new EmbeddingBaselineAcceptance(); basis.state = 'AcceptedEngineeringBaseline'; basis.acceptedAt = Date.now(); basis.configFingerprint = embeddingFingerprint(config); basis.configRevision = config.revision; proof.baseline = basis;
        for (const mode of ['edit-trial','edit-normal','clear','recount','space','config','purpose','scope']) { const ordinary = new QueryConsentSession(); const trial = new QueryConsentSession(); ordinary.review('reviewed input',proof,config,'query','space'); trial.review('reviewed input',proof,config,'trial','space','trial','a'.repeat(64)); ordinary.approve(true); ordinary.confirmFree(true); trial.approve(true); trial.confirmFree(true);
          if (['edit-trial','edit-normal','clear','recount'].includes(mode)) { ordinary.invalidate(); trial.invalidate(); }
          if (mode === 'config') { config.revision++; }
          let rejected: number = 0; for (const purpose of ['query','trial']) { try { (purpose === 'query' ? ordinary : trial).consume(mode === 'clear' ? '' : mode.startsWith('edit') ? 'adversarial input' : 'reviewed input',proof,config,mode === 'purpose' ? 'wrong' : purpose,mode === 'space' ? 'other' : 'space',purpose === 'trial' ? 'trial' : '',purpose === 'trial' ? mode === 'scope' ? 'b'.repeat(64) : 'a'.repeat(64) : ''); } catch { rejected++; } } closeoutAssert(rejected === (mode === 'scope' ? 1 : 2),'StaleConsentAccepted'); if (mode === 'config') { config.revision--; } }
        row.calls = 0;
      }
      else if (name === 'document-task-pages') { for (let at: number = 0; at < 25; at++) { const doc = new PdfKnowledgeDocument(); doc.id = identity.id(); doc.sourceKey = `page-${at}`; doc.binding = fixture.binding; const job = new PdfIngestionJob(); job.id = identity.id(); job.generation = identity.id(); job.documentId = doc.id; job.sourceId = fixture.binding.originalId; job.binding = fixture.binding; job.processingKey = doc.sourceKey; job.ownerSession = scope.key; const pins: KnowledgePin[] = []; for (let n: number = 0; n < 2; n++) { const pin = new KnowledgePin(); pin.id = identity.id(); pin.ownerId = job.id; pin.documentId = doc.id; pin.generation = job.generation; pin.sourceId = job.sourceId; pin.assetId = n === 0 ? doc.binding.originalAssetId : doc.binding.resultAssetId; pin.assetHash = n === 0 ? doc.binding.originalHash : doc.binding.zipHash; pins.push(pin); } await fixture.pdf.register(doc,job,pins); } const first = await fixture.pdf.listPage(0,12); const next = await fixture.pdf.listPage(12,12); closeoutAssert(first.length === 12 && next.length === 12 && !first.some((doc: PdfKnowledgeDocument): boolean => next.some((item: PdfKnowledgeDocument): boolean => item.id === doc.id)),'PageOverlap'); let rejected: boolean = false; try { await fixture.pdf.listPage(0,10000); } catch { rejected = true; } closeoutAssert(rejected,'UnboundedPage'); }
      else if (name.startsWith('history-pause-')) { await residualHistoryPauseCase(fixture.host,fixture.text,name === 'history-pause-reject'); }
      else if (name.startsWith('late-')) {
        const pdf = new CloseoutQueryRepository(fixture.host); await pdf.open(); try { const search = new KnowledgeSearchService(fixture.text,pdf,identity); search.setClock((): number => pdf.clockValue); search.state.question = 'synthetic';
          const hit = new KnowledgeHit(); hit.id = 'timely'; hit.sourceKind = KnowledgeSourceKind.Pdf; hit.documentId = fixture.job.documentId; hit.generation = fixture.job.generation; hit.originalHash = fixture.binding.originalHash; hit.keywordScore = 101; pdf.testHit = hit;
          // Test repository shares the real ordinary DB; deterministic clock
          // advances at the final awaited boundary, not a ten-second sleep.
          pdf.phase = name === 'late-history-once' ? 'history' : name === 'late-final-visibility' ? 'visibility' : '';
          if (name === 'late-vector-fallback') { search.attachSemantic(new CloseoutSemantic(pdf)); search.state.queryConsent = true; search.state.queryFree = true; const approval = new QueryConsentSnapshot(); approval.actual = 'synthetic'; approval.space = ''; search.state.queryApproval = approval; }
          await search.search(); closeoutAssert(search.state.result.vectorHits.length === 0 && search.state.result.hits.length === 1 && search.state.result.hits[0].id === 'timely','LateBoundaryLostKeyword'); if (name === 'late-history-once') { closeoutAssert(search.state.historyPending,'LateHistoryNotPending'); await search.retryHistory(); closeoutAssert(!search.state.historyPending && pdf.saves === 1,'HistoryDuplicated'); } else { closeoutAssert(pdf.saves === 0,'LateResultWroteHistory'); }
        } finally { await pdf.close(); }
      }
      else if (name === 'task-pages') {
        const store = fixture.host.requireStore(); for (let at: number = 0; at < 25; at++) { const job: string = `page-job-${at.toString().padStart(2,'0')}`; const generation: string = `page-vector-${at}`;
          const chunk: string = `page-chunk-${at}`; const hash: string = 'e'.repeat(64);
          await store.executeSql('INSERT INTO kb_chunk VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',[chunk,fixture.job.documentId,fixture.job.generation,fixture.snapshot.id,fixture.snapshot.hash,fixture.binding.originalHash,1,at,'text','synthetic','synthetic',hash,'[]',1]);
          await store.executeSql('INSERT INTO kb_input_attempt VALUES(?,?,?,?,?,?)',[generation,chunk,hash,'NotSent','',job]);
          await store.executeSql('INSERT INTO kb_vector_generation VALUES(?,?,?,?,?,?,?,?,?,?,?)',[generation,fixture.job.documentId,fixture.job.generation,'page-space',job,0,'Preparing',1,0,0,'']);
          await store.executeSql('INSERT INTO r2v_job VALUES(?,?,?,?,?,?,?,?,?)',[job,generation,fixture.snapshot.hash,'','','fixture',scope.key,Date.now(),'']);
        } const metadata = new PdfVectorRepository(fixture.host,fixture.pdf); const first = await metadata.jobsPage(0,12); const second = await metadata.jobsPage(12,12); closeoutAssert(first.length === 12 && second.length === 12 && !first.some((job): boolean => second.some((item): boolean => item.id === job.id)),'TaskPageOverlap'); let rejected: boolean = false; try { await metadata.jobsPage(0,10000); } catch { rejected = true; } closeoutAssert(rejected,'TaskPageUnbounded');
      }
      else if (name.startsWith('audit-')) { const audit = new KnowledgeCapabilityAudit(context,`shuvi_r2_${scope.key}_audit.db`); const descriptor = await audit.identity('Fixture','CLOSEOUT-1','R2-CLOSEOUT-1'); descriptor.state = 'Available'; await audit.save(descriptor); const read = await new KnowledgeCapabilityAudit(context,`shuvi_r2_${scope.key}_audit.db`).read(descriptor); closeoutAssert(read?.state === descriptor.state && read.app.length > 0 && read.digest.length === 64,'AuditReadback');
        let calls: number = 0; const gate = new CapabilityAuditGate(); await gate.require(audit,descriptor,async (): Promise<void> => { calls++; }); await gate.require(audit,descriptor,async (): Promise<void> => { calls++; }); await new CapabilityAuditGate().require(audit,descriptor,async (): Promise<void> => { calls++; }); closeoutAssert(calls === 2,'DiskAvailableSkippedSelfCheck');
        if (name === 'audit-env-invalidated') { descriptor.environment += '|changed'; closeoutAssert((await audit.read(descriptor))?.state === 'Invalidated','AuditEnvironmentAccepted'); }
        if (name === 'audit-fail-closed') { for (const failure of ['SelfCheckFailed','ReleaseUnconfirmed']) { const failed = new CapabilityAuditGate(); let rejected: number = 0; for (let at: number = 0; at < 2; at++) { try { await failed.require(audit,descriptor,async (): Promise<void> => { throw new KnowledgeFailure(failure,'fixture'); }); } catch { rejected++; } } closeoutAssert(rejected === 2 && (await audit.read(descriptor))?.state === (failure === 'ReleaseUnconfirmed' ? 'Releasing' : 'Failed'),'FailedAuditGrantedCapability'); } const vectors = new VectorRdbRepository(context); await vectors.open(); closeoutAssert(vectors.capability() === 'Available','ActualVectorSelfCheck'); await vectors.close(); }
      }
      row.passed = true; row.reason = 'ok';
    } catch (error) { row.reason = error instanceof KnowledgeFailure ? error.category : 'CloseoutPlatformError'; }
    result.cases.push(row);
  } } finally { await fixture.close(); }
  return result;
}
