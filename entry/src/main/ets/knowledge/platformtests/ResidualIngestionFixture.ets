import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { pdfService } from '@kit.PDFKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { KnowledgeStoreHost } from '../infra/KnowledgeStoreHost';
import { TextRdbRepository } from '../infra/TextRdbRepository';
import { PdfKnowledgeRepository } from '../infra/PdfKnowledgeRepository';
import { PdfArchiveAdapter } from '../infra/PdfArchiveAdapter';
import { PdfAssetAdapter } from '../infra/PdfAssetAdapter';
import { PdfProcessingAdapter } from '../infra/PdfProcessingAdapter';
import { KnowledgePlatformIdentity } from '../infra/KnowledgeAssembly';
import { PdfIngestionService } from '../application/PdfIngestionService';
import { KnowledgeLifecycleService, KnowledgeDerivedLifecycle } from '../application/KnowledgeLifecycleService';
import { DocumentParseService } from '../application/DocumentParseService';
import { DocumentParseRepositoryPort, MineruCredentialPort } from '../domain/DocumentParsePorts';
import { DocumentParseSnapshot, DocumentCredentialStatus, DocumentOriginal, DocumentParseTask, DocumentParseResultEnvelope, DocumentParseCancellation } from '../domain/DocumentParseModels';
import { PdfSourceBinding, PdfZipManifest, KnowledgeCancellation, KnowledgeFailure, PdfKnowledgeDocument, PdfIngestionJob, PdfPartialApproval, PdfStage } from '../domain/PdfKnowledgeModels';
import { documentEnsureDirectory, documentHashFile } from '../infra/DocumentFileOperations';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { pdfFixtureCrc } from './PdfNativeFixtures';

class ResidualParseMetadata implements DocumentParseRepositoryPort {
  async open(): Promise<void> {} async load(): Promise<DocumentParseSnapshot> { return new DocumentParseSnapshot(); }
  async save(_snapshot: DocumentParseSnapshot): Promise<void> {} async close(): Promise<void> {}
}
class ResidualMissingCredential implements MineruCredentialPort {
  async status(): Promise<DocumentCredentialStatus> { return DocumentCredentialStatus.Missing; }
  async save(_input: string,_replace: boolean): Promise<DocumentCredentialStatus> { throw new Error('NoCredentialAccess'); }
  async remove(): Promise<DocumentCredentialStatus> { throw new Error('NoCredentialAccess'); }
  clearTransient(): void {}
}
class ResidualOwnedArchive extends PdfArchiveAdapter {
  failOnce: boolean = false;
  async inspect(binding: PdfSourceBinding,cancel: KnowledgeCancellation): Promise<PdfZipManifest> { if (this.failOnce) { this.failOnce = false; throw new KnowledgeFailure('FixtureReadFailure','fixture'); } return this.inspectForPlatformEvidence(binding,cancel); }
}
class ResidualPublishRepository extends PdfKnowledgeRepository {
  blockNext: boolean = false; blocked: boolean = false; private releaseBlock: () => void = (): void => {};
  unblock(): void { this.releaseBlock(); }
  async publish(document: PdfKnowledgeDocument,job: PdfIngestionJob,approval: PdfPartialApproval,cancel?: KnowledgeCancellation): Promise<boolean> {
    if (this.blockNext) { this.blockNext = false; const gate = new Promise<void>((resolve: () => void): void => { this.releaseBlock = resolve; }); this.blocked = true; await gate; this.blocked = false; }
    return super.publish(document,job,approval,cancel);
  }
}
function residualStoredZip(revision: string): Uint8Array {
  const names: string[] = ['fixture_content_list.json','layout.json','fixture_content_list_v2.json'];
  const payloads: string[] = ['[{"bbox":[1,2,90,30],"page_idx":0}]','{"_version_name":"3.4.4","_backend":"hybrid","_effort":"medium","_ocr_enable":true,"pdf_info":[{"page_idx":0}]}',`[[{"bbox":[1,2,90,30],"type":"paragraph","content":{"paragraph_content":[{"type":"text","content":"synthetic ${revision} evidence"}]}}]]`];
  const entries: Uint8Array[] = []; const directories: Uint8Array[] = []; let offset: number = 0; let directorySize: number = 0;
  for (let at: number = 0; at < names.length; at++) { const name = pdfCodecUtf8(names[at]); const body = pdfCodecUtf8(payloads[at]); const crc = pdfFixtureCrc(body); const local = new Uint8Array(30+name.length+body.length); const l = new DataView(local.buffer); l.setUint32(0,0x04034b50,true); l.setUint16(4,20,true); l.setUint32(14,crc,true); l.setUint32(18,body.length,true); l.setUint32(22,body.length,true); l.setUint16(26,name.length,true); local.set(name,30); local.set(body,30+name.length);
    const central = new Uint8Array(46+name.length); const c = new DataView(central.buffer); c.setUint32(0,0x02014b50,true); c.setUint16(4,20,true); c.setUint16(6,20,true); c.setUint32(16,crc,true); c.setUint32(20,body.length,true); c.setUint32(24,body.length,true); c.setUint16(28,name.length,true); c.setUint32(42,offset,true); central.set(name,46); entries.push(local); directories.push(central); offset += local.length; directorySize += central.length;
  }
  const result = new Uint8Array(offset+directorySize+22); let cursor: number = 0; for (const part of entries.concat(directories)) { result.set(part,cursor); cursor += part.length; } const end = new DataView(result.buffer,cursor,22); end.setUint32(0,0x06054b50,true); end.setUint16(8,3,true); end.setUint16(10,3,true); end.setUint32(12,directorySize,true); end.setUint32(16,offset,true); return result;
}
export class ResidualIngestionFixture {
  context: common.Context; scope: KnowledgeStorageScope; host: KnowledgeStoreHost; text: TextRdbRepository; pdf: ResidualPublishRepository; assets: PdfAssetAdapter; lifecycle: KnowledgeDerivedLifecycle; service: PdfIngestionService; parse: DocumentParseService;
  private archive: ResidualOwnedArchive; private root: string; firstGeneration: string = ''; switchedGeneration: string = ''; private initialJobs: number = 0;
  constructor(context: common.Context,scope: KnowledgeStorageScope) {
    scope.requireTestOwner(scope.key); this.context = context; this.scope = scope; this.root = `${context.cacheDir}/ingestion_r2_${scope.key}`; this.host = KnowledgeStoreHost.forContext(context,scope); this.text = new TextRdbRepository(context,this.host); this.pdf = new ResidualPublishRepository(this.host); this.assets = new PdfAssetAdapter(context.filesDir,context.cacheDir,this.pdf,scope); const coordinator = new KnowledgeLifecycleService(this.pdf); this.lifecycle = new KnowledgeDerivedLifecycle(coordinator,this.pdf,this.assets); this.archive = new ResidualOwnedArchive(this.root); this.service = new PdfIngestionService(this.pdf,coordinator,this.archive,new PdfProcessingAdapter(),this.assets,new KnowledgePlatformIdentity()); this.service.attachSession(scope.key); this.parse = new DocumentParseService(new ResidualMissingCredential(),new ResidualParseMetadata());
  }
  async prepare(): Promise<void> {
    await documentEnsureDirectory(this.root); await documentEnsureDirectory(`${this.root}/knowledge_parse_v1`); const originalPath = `${this.root}/knowledge_parse_v1/original-r007`; const document = new pdfService.PdfDocument(); try { if (!document.createDocument(300,500) || !document.saveDocument(originalPath)) { throw new Error('SyntheticPdfCreate'); } } finally { document.releaseDocument(); }
    const original = new DocumentOriginal(); original.id = 'r007-original'; original.assetId = 'original-r007'; original.title = 'Synthetic R007'; original.hash = await documentHashFile(originalPath,20971520,new DocumentParseCancellation()); original.bytes = (await fileIo.stat(originalPath)).size; original.pages = 1; this.parse.state.snapshot.originals = [original];
    for (const revision of ['A','B']) { const bytes = residualStoredZip(revision); const asset: string = `result-r007-${revision}`; const file = await fileIo.open(`${this.root}/knowledge_parse_v1/${asset}`,fileIo.OpenMode.CREATE|fileIo.OpenMode.READ_WRITE|fileIo.OpenMode.NOFOLLOW); try { const written = await fileIo.write(file.fd,bytes.buffer); if (written !== bytes.length) { throw new Error('FixtureWriteIncomplete'); } await fileIo.fsync(file.fd); } finally { await fileIo.close(file); }
      const task = new DocumentParseTask(); task.id = `r007-task-${revision}`; task.originalId = original.id; task.hash = original.hash; task.version = original.version; task.dataId = `r007-data-${revision}`; const result = new DocumentParseResultEnvelope(); result.assetId = asset; result.taskId = task.id; result.dataId = task.dataId; result.originalHash = original.hash; result.version = original.version; result.bytes = bytes.length; result.hash = await documentHashFile(`${this.root}/knowledge_parse_v1/${asset}`,31457280,new DocumentParseCancellation()); result.completeTransport = true; result.signature = true; this.parse.state.snapshot.tasks.push(task); this.parse.state.snapshot.results.push(result);
    }
    await this.text.open(); await this.pdf.open(); await this.pdf.reconcile(this.scope.key); await this.service.refreshJobs();
  }
  async start(revision: string): Promise<void> { if (!['A','B'].includes(revision)) { throw new Error('FixtureRevision'); } await this.service.prepare(this.parse,`result-r007-${revision}`); }
  failNext(): void { this.archive.failOnce = true; }
  async remember(label: string): Promise<void> {
    const doc = (await this.pdf.list())[0]; if (doc === undefined) { throw new Error('FixtureDocumentMissing'); }
    if (label === 'initial') { if (doc.activeContentGeneration.length === 0 || doc.binding.zipHash !== this.parse.state.snapshot.results[0].hash) { throw new Error('InitialNotPublished'); } this.firstGeneration = doc.activeContentGeneration; this.initialJobs = (await this.pdf.jobs()).length; }
    if (label === 'resumed') { if (doc.activeContentGeneration !== this.firstGeneration || this.service.state.stage !== PdfStage.Published || (await this.pdf.jobs()).length !== this.initialJobs || (await this.pdf.localCounts(this.firstGeneration))[0] !== 1) { throw new Error('PublishedResumeDuplicated'); } }
    if (label === 'candidate') { if (doc.activeContentGeneration !== this.firstGeneration || this.service.state.stage !== PdfStage.Review || this.service.state.job?.binding?.zipHash !== this.parse.state.snapshot.results[1].hash) { throw new Error('OldActiveChangedBeforeApproval'); } }
    if (label === 'switched') { if (doc.activeContentGeneration === this.firstGeneration || doc.binding.zipHash !== this.parse.state.snapshot.results[1].hash) { throw new Error('CandidateNotSwitched'); } this.switchedGeneration = doc.activeContentGeneration; const rows = await this.host.requireStore().querySql('SELECT state FROM kb_content_generation WHERE id=?',[this.firstGeneration]); try { if (!rows.goToNextRow() || rows.getString(0) !== 'Retained') { throw new Error('OldActiveNotRetained'); } } finally { rows.close(); } }
    if (label === 'abandoned') { const job = (await this.pdf.jobs()).find((item: PdfIngestionJob): boolean => item.id === this.service.state.job?.id); if (job === undefined || !job.terminated || doc.activeContentGeneration !== this.switchedGeneration || (await this.pdf.cleanups()).length !== 0) { throw new Error('AbandonLostOldActiveOrCleanup'); } }
    if (label === 'race') { if (!doc.tombstone || doc.activeContentGeneration.length !== 0 || this.pdf.blocked || this.service.state.busy || this.service.state.stage === PdfStage.Published || (await this.pdf.localCounts(this.service.state.job?.generation ?? ''))[3] !== 0) { throw new Error('DeletedCandidateRevived'); } await this.lifecycle.cleanup(); }
    if (label === 'deletedAfter') { if (!doc.tombstone || doc.activeContentGeneration.length !== 0) { throw new Error('PublishedThenDeleteNotHidden'); } }
    await this.audit(label);
  }
  async audit(label: string): Promise<void> {
    for (const original of this.parse.state.snapshot.originals) { if (await documentHashFile(`${this.root}/knowledge_parse_v1/${original.assetId}`,20971520,new DocumentParseCancellation()) !== original.hash) { throw new Error('OriginalChanged'); } }
    for (const result of this.parse.state.snapshot.results) { if (await documentHashFile(`${this.root}/knowledge_parse_v1/${result.assetId}`,31457280,new DocumentParseCancellation()) !== result.hash) { throw new Error('ZipChanged'); } }
    const docs = await this.pdf.list(); const doc = docs[0]; const rows = await this.host.requireStore().querySql('SELECT (SELECT count(*) FROM kb_job),(SELECT count(*) FROM kb_read_lease),(SELECT count(*) FROM kb_cleanup),(SELECT count(*) FROM kb_content_generation WHERE state=?)',['Retained']);
    try { rows.goToNextRow(); hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_R007 case=${label} docs=${docs.length} jobs=${rows.getLong(0)} active=${doc?.activeContentGeneration.length ? 1 : 0} tombstone=${doc?.tombstone ? 1 : 0} retained=${rows.getLong(3)} leases=${rows.getLong(1)} cleanup=${rows.getLong(2)} sources=3 unchanged=1 network=0`); } finally { rows.close(); }
  }
  async retireOld(): Promise<void> { await this.lifecycle.retireContent(this.firstGeneration); if ((await this.pdf.localCounts(this.firstGeneration))[0] !== 0) { throw new Error('RetainedNotCleaned'); } await this.audit('retired'); }
  async deleteCurrent(): Promise<void> { const id = this.service.state.document?.id ?? (await this.pdf.list())[0]?.id; if (id === undefined) { throw new Error('MissingDoc'); } await this.lifecycle.deleteDocument(id); await this.audit('deleted'); }
  blockPublish(): void { this.pdf.blockNext = true; }
  releasePublish(): void { this.pdf.unblock(); }
  async close(): Promise<void> { this.pdf.unblock(); if (this.service.state.busy || this.service.state.releasing) { throw new Error('FixtureStillInFlight'); } this.service.pause(); await this.archive.release(); await this.pdf.close(); await this.text.close(); }
}
