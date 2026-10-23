import { ImageOriginalImportService } from './ImageOriginalImportService';
import { DocumentParseService } from './DocumentParseService';
import { ImageRepositoryPort, ImageOriginalPort, ImageContentPort, ImageResultReaderPort } from '../domain/ImageKnowledgePorts';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { ImageSnapshot, ImageJob, ImageOriginal, ImageIngestionStage, ImageKnowledgeFailure, ImageAssetClaim, ImageDocument, ImageChunk } from '../domain/ImageKnowledgeModels';
import { DocumentOriginal, DocumentParseCleanup, DocumentParseTask, DocumentParseResultEnvelope, DocumentParseStateListener, DocumentParseStage, DocumentParseFailure } from '../domain/DocumentParseModels';
import { documentIsImage } from '../pipeline/DocumentParsePolicy';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { imageSnapshotChunks, imageVerifySnapshot } from '../pipeline/ImageSnapshotCodec';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { IMAGE_CONTROLLED_PROFILE, IMAGE_TEXT_PROFILE } from '../pipeline/ImageContentNormalizer';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { parseFailureSummary } from '../pipeline/ParseFailurePolicy';

export class ImageIngestionService extends ImageOriginalImportService implements DocumentParseStateListener {
  private static sessions: ImageIngestionService[] = [];
  static background(): void { for (const service of ImageIngestionService.sessions) { service.pause(); service.pauseCheckpoint().catch((): void => {}); } }
  review: ImageSnapshot | undefined = undefined; jobRows: ImageJob[] = [];
  private content: ImageContentPort; private identity: KnowledgeIdentityPort;
  private scope: KnowledgeStorageScope; private operation: KnowledgeCancellation | undefined = undefined; private epoch: number = 0;
  private consentEpoch: number = 0;
  private vectorCleanup: ((documentId: string) => Promise<void>) | undefined = undefined;
  private vectorSync: ((documentId: string) => Promise<void>) | undefined = undefined;
  private resultReader: ImageResultReaderPort | undefined = undefined;
  private unifiedConsumer: ((parse: DocumentParseService, result: string) => Promise<void>) | undefined;
  attachUnifiedConsumer(consumer: (parse: DocumentParseService, result: string) => Promise<void>): void { this.unifiedConsumer = consumer; }
  attachResults(reader: ImageResultReaderPort): void { this.resultReader = reader; }
  changed(): void { this.emit(); }
  authorizationRevision(): string { const state = this.owner.viewState(); return `${state.snapshot.config.credentialRevision}|${state.snapshot.config.enabled}|${state.credential}|${this.consentEpoch}`; }
  actionBusy(): boolean { return this.busy || this.owner.viewState().busy; }
  parseSummary(documentId: string = ''): string {
    const state = this.owner.viewState(); const lines: string[] = [];
    const document = this.documents.find((row: ImageDocument): boolean => row.id === documentId);
    for (const p of state.snapshot.imagePermits) {
      if (documentId.length > 0 && p.originalId !== document?.parseSourceId) { continue; }
      const t = state.snapshot.tasks.find((row: DocumentParseTask): boolean => row.id === p.taskId);
      const r = state.snapshot.results.find((row: DocumentParseResultEnvelope): boolean => row.taskId === p.taskId);
      lines.push(`${t?.stage ?? '待申请'} · POST/PUT/查询/ZIP ${p.usage.allocation}/${p.usage.put}/${p.usage.query}/${p.usage.download}${r === undefined ? '' : '\nZIP 已保存，正文待本机校验\n'+state.resultDirectory+'/'+r.assetId}`);
      if (t !== undefined && t.failure.length > 0) { lines.push(`${parseFailureSummary(t.failureDetail)}；只恢复原任务/本机包，不重新上传`); }
      if (t !== undefined) { lines.push(`PUT供给SDK ${t.uploadBytes} B · 已确认 ${t.uploaded ? '是' : '否'} · ZIP实际写入 ${t.downloadBytes} B`); }
      const job = this.jobRows.find((row: ImageJob): boolean => row.serviceTaskId === p.taskId);
      if (job !== undefined) { lines.push(`正文/发布 ${job.stage} · ${job.failure || '本机阶段无错误'}`); }
    }
    for (const task of state.snapshot.tasks) {
      if (task.id.startsWith('diagnostic-task-')) { lines.push('隔离合成错误 · 真实请求0\n'+parseFailureSummary(task.failureDetail)); }
    } return lines.join('\n');
  }
  attachVectorCleanup(cleanup: (documentId: string) => Promise<void>): void { this.vectorCleanup = cleanup; }
  attachVectorSync(sync: (documentId: string) => Promise<void>): void { this.vectorSync = sync; }
  constructor(owner: DocumentParseService, repository: ImageRepositoryPort, decoder: ImageOriginalPort, content: ImageContentPort, identity: KnowledgeIdentityPort, scope: KnowledgeStorageScope) {
    super(owner,repository,decoder); this.content = content; this.identity = identity; this.scope = scope; this.owner.subscribe(this); ImageIngestionService.sessions.push(this);
  }
  async initialize(): Promise<void> {
    this.jobRows = await this.repository.jobs();
    for (const job of this.jobRows) {
      if ([ImageIngestionStage.Published,ImageIngestionStage.Empty,ImageIngestionStage.Deleted,ImageIngestionStage.Unknown].indexOf(job.stage) >= 0) { continue; }
      job.stage = ImageIngestionStage.Paused; try { await this.repository.checkpoint(job); } catch { /* Stale/deleted jobs cannot be revived on reopen. */ }
    } await this.refresh();
  }
  pause(): void { super.pause(); this.epoch++; this.consentEpoch++; if (this.operation !== undefined) { this.operation.invalid = true; } this.review = undefined; this.emit(); }
  async pauseCheckpoint(): Promise<void> {
    this.pause();
    this.jobRows = await this.repository.jobs();
    for (const job of this.jobRows) {
      if ([ImageIngestionStage.Published,ImageIngestionStage.Empty,ImageIngestionStage.Deleted,ImageIngestionStage.Unknown].indexOf(job.stage) >= 0) { continue; }
      job.stage = ImageIngestionStage.Paused;
      await this.repository.checkpoint(job);
    }
    this.emit();
  }
  detach(): void { this.pause(); this.owner.unsubscribe(this); ImageIngestionService.sessions = ImageIngestionService.sessions.filter((service: ImageIngestionService): boolean => service !== this); }
  async prepareResult(resultId: string): Promise<void> {
    const consumer: ((parse: DocumentParseService, result: string) => Promise<void>) | undefined = this.unifiedConsumer;
    if (consumer !== undefined) { await consumer(this.owner,resultId); return; }
    if (this.actionBusy()) { return; }
    try {
      const state = this.owner.viewState().snapshot; const result = state.results.find((r: DocumentParseResultEnvelope): boolean => r.assetId === resultId);
      const task = state.tasks.find((t: DocumentParseTask): boolean => t.id === result?.taskId && t.stage === DocumentParseStage.Received);
      const source = state.originals.find((o: DocumentOriginal): boolean => o.id === task?.originalId && o.hash === result?.originalHash && o.version === result?.version && documentIsImage(o.format));
      if (source === undefined || task === undefined) { throw new ImageKnowledgeFailure('ImageReceivedResultBindingMissing','image-result'); }
      await this.refresh();
      let document = this.documents.find((row: ImageDocument): boolean => row.parseSourceId === source.id);
      if (document === undefined) {
        const prior = (await this.repository.jobs()).find((row: ImageJob): boolean => row.serviceTaskId === task.id);
        if (prior !== undefined) { throw new ImageKnowledgeFailure('ImageResultVersionNoLongerCurrent','image-result'); }
        await this.owner.withImageOriginal<void>(source.id,async (): Promise<void> => { await this.verifyOriginal(source); }); await this.refresh();
        document = this.documents.find((row: ImageDocument): boolean => row.parseSourceId === source.id);
      }
      if (document === undefined) { throw new ImageKnowledgeFailure('ImageResultDocumentUnavailable','image-result'); }
      await this.requestOcr(document.id,false,false,document.parseBinding);
    } catch (error) { this.message = error instanceof ImageKnowledgeFailure ? error.message : '本机图片结果审查失败；原 ZIP 保留，未重传'; this.emit(); }
  }
  async requestOcr(documentId: string, fullFile: boolean = false, free: boolean = false, expectedBinding: string = '', expectedRevision: string = ''): Promise<void> {
    if (this.busy || this.owner.viewState().busy) { return; }
    const requestedEpoch: number = this.epoch;
    const document = await this.repository.get(documentId);
    if (document === undefined || document.tombstone || document.archived) { this.message = '原件不可用'; this.emit(); return; }
    const original: ImageOriginal = await this.repository.latestOriginal(document.id);
    if (requestedEpoch !== this.epoch) { return; }
    if (expectedBinding.length > 0 && expectedBinding !== `${original.sourceId}|${original.assetId}|${original.hash}|${original.version}|${original.header.encoding}`) { this.message = '当前原件版本已变，请重新选择并确认'; this.emit(); return; }
    if (expectedRevision.length > 0 && expectedRevision !== this.authorizationRevision()) { this.message = '解析配置已变，请重新确认当前图片许可；未外发'; this.emit(); return; }
    this.review = undefined;
    const epoch: number = ++this.epoch; this.busy = true; this.emit();
    try {
      const prior = this.owner.viewState().snapshot.tasks.find((task: DocumentParseTask): boolean => task.originalId === original.sourceId && task.hash === original.hash && task.version === original.version);
      if (prior === undefined) {
        if (!fullFile || !free) { throw new ImageKnowledgeFailure('需确认当前完整图片及免费资格','image-permit'); }
        await this.owner.confirmImage(original.sourceId,fullFile,free); if (epoch !== this.epoch) { return; }
        await this.owner.setEnabled(true); if (epoch !== this.epoch) { return; } await this.owner.submit(original.sourceId);
      } else if (prior.stage !== DocumentParseStage.Received) {
        if (!fullFile || !free) { throw new ImageKnowledgeFailure('请确认当前完整图片与同账号免费资格后恢复原任务','image-resume'); }
        await this.owner.confirmImage(original.sourceId,fullFile,free);
        if (epoch !== this.epoch) { return; }
        await this.owner.setEnabled(true); if (epoch !== this.epoch) { return; } await this.owner.resume(prior.id,true);
      }
      if (epoch !== this.epoch) { return; }
      const state = this.owner.viewState(); const task = state.snapshot.tasks.find((row: DocumentParseTask): boolean => row.originalId === original.sourceId && row.hash === original.hash && row.version === original.version);
      const result = state.snapshot.results.find((row: DocumentParseResultEnvelope): boolean => row.taskId === task?.id);
      if (task === undefined || result === undefined) { this.message = state.message; return; }
      if (this.resultReader === undefined) { throw new ImageKnowledgeFailure('ImageResultReaderUnavailable','image-result'); }
      const priorJob = (await this.repository.jobs()).find((row: ImageJob): boolean => row.serviceTaskId === task.id);
      if (priorJob !== undefined && [ImageIngestionStage.Published,ImageIngestionStage.Empty].indexOf(priorJob.stage) >= 0) { const snapshot = await this.repository.snapshot(priorJob.generation); await imageVerifySnapshot(snapshot,this.identity,new KnowledgeCancellation()); if (epoch !== this.epoch) { return; } this.review = snapshot; this.message = '本图已发布，已读回正文；未产生请求或重复发布'; return; }
      if (priorJob !== undefined && priorJob.snapshotHash.length > 0) { await this.resumeReview(priorJob.id); if (this.review !== undefined) { return; } }
      const cancel: KnowledgeCancellation = new KnowledgeCancellation(); this.operation = cancel;
      const projection = await this.resultReader.read(original,task.id,cancel); cancel.check(); if (epoch !== this.epoch) { return; }
      const job: ImageJob = priorJob ?? new ImageJob();
      if (priorJob === undefined) {
        job.id = this.identity.id(); job.generation = this.identity.id(); job.documentId = document.id; job.originalAssetId = original.assetId; job.epoch = document.epoch; job.expectedActive = document.activeGeneration;
        job.serviceTaskId = task.id; job.resultAssetId = result.assetId; job.resultHash = result.hash; await this.repository.begin(job);
      }
      await this.process(job,original,pdfCodecUtf8(JSON.stringify(projection)),IMAGE_TEXT_PROFILE);
    } catch (error) { this.message = error instanceof ImageKnowledgeFailure || error instanceof DocumentParseFailure ? error.message+'；原件和已收ZIP保留，不重新上传' : '本机结果处理未完成；原任务和已收ZIP保留，不重新上传'; }
    finally { this.busy = false; this.operation = undefined; await this.refresh(); }
  }
  async reviewInputs(documentId: string): Promise<ImageChunk[]> {
    const document = await this.repository.get(documentId);
    if (document === undefined || document.tombstone || document.archived || document.stage !== ImageIngestionStage.Published || document.chunkCount < 1) { throw new ImageKnowledgeFailure('ImagePublishedTextRequired','image-vector-review'); }
    if ((await this.repository.latestOriginal(documentId)).assetId !== document.activeOriginal) { throw new ImageKnowledgeFailure('ImageCandidateNeedsBodyConfirmation','image-vector-review'); }
    const snapshot = await this.repository.snapshot(document.activeGeneration); await imageVerifySnapshot(snapshot,this.identity,new KnowledgeCancellation());
    return this.repository.chunks(document.activeGeneration);
  }
  // Explicit isolated diagnostic ingress only; production never accepts synthetic OCR.
  async acceptControlled(owner: string, documentId: string, bytes: Uint8Array): Promise<void> {
    this.scope.requireTestOwner(owner); if (this.busy) { throw new ImageKnowledgeFailure('ImageBusy','image-ingestion'); }
    const document = await this.repository.get(documentId); if (document === undefined || document.tombstone || document.archived) { throw new ImageKnowledgeFailure('ImageUnavailable','image-ingestion'); }
    const original = await this.repository.latestOriginal(document.id); const job: ImageJob = new ImageJob();
    job.id = this.identity.id(); job.documentId = document.id; job.originalAssetId = original.assetId; job.epoch = document.epoch; job.expectedActive = document.activeGeneration; job.generation = this.identity.id();
    await this.repository.begin(job); await this.process(job,original,bytes,IMAGE_CONTROLLED_PROFILE);
  }
  async acceptControlledReplacement(owner: string, documentId: string, original: ImageOriginal, bytes: Uint8Array): Promise<void> {
    this.scope.requireTestOwner(owner); const document = await this.repository.get(documentId);
    if (document === undefined || document.tombstone || original.documentId !== documentId || this.busy) { throw new ImageKnowledgeFailure('ReplacementSourceChanged','image-ingestion'); }
    const asset: ImageAssetClaim = new ImageAssetClaim(); asset.assetId = original.assetId; asset.documentId = documentId; asset.owner = 'DocumentParseService'; asset.hash = original.hash; asset.bytes = original.bytes; asset.role = 'Original'; asset.pins = 1;
    await this.repository.register(original,[asset]);
    const job: ImageJob = new ImageJob(); job.id = this.identity.id(); job.generation = this.identity.id(); job.documentId = documentId; job.originalAssetId = original.assetId; job.epoch = document.epoch; job.expectedActive = document.activeGeneration;
    await this.repository.begin(job); await this.process(job,original,bytes,IMAGE_CONTROLLED_PROFILE);
  }
  private async process(job: ImageJob, original: ImageOriginal, bytes: Uint8Array, profile: string): Promise<void> {
    const cancel: KnowledgeCancellation = new KnowledgeCancellation(); const epoch: number = ++this.epoch; this.operation = cancel; this.busy = true; this.emit();
    try {
      const snapshot: ImageSnapshot = await this.content.normalize(original,bytes,profile,job.generation,cancel); cancel.check();
      await imageVerifySnapshot(snapshot,this.identity,cancel);
      if (epoch !== this.epoch) { throw new ImageKnowledgeFailure('StaleImageOperation','image-ingestion'); }
      if (snapshot.coverage.unknown !== 0 || snapshot.coverage.excluded !== 0 || snapshot.coverage.issues.length !== 0) { throw new ImageKnowledgeFailure('CoverageUnknownBlocksPublication','image-review'); }
      job.snapshotHash = snapshot.contentHash; job.reportHash = snapshot.coverage.hash;
      const chunks = await imageSnapshotChunks(snapshot,this.identity,cancel); cancel.check();
      await this.repository.prepare(job,snapshot,chunks); this.review = snapshot; job.stage = ImageIngestionStage.Review; job.checkpoint = job.stage;
      this.message = `覆盖待确认：文字${snapshot.coverage.identified}，明确无字${snapshot.coverage.empty}；未发布`;
    } catch (error) {
      job.stage = cancel.invalid ? ImageIngestionStage.Paused : ImageIngestionStage.Failed; job.failure = error instanceof ImageKnowledgeFailure ? error.category : 'ImageNormalizeFailed';
      try { await this.repository.checkpoint(job); } catch { /* A tombstone/stale epoch wins over late work. */ }
      this.message = `${job.failure}；原件与旧活动保留`;
    } finally { if (this.operation === cancel) { this.operation = undefined; } this.busy = false; this.jobRows = await this.repository.jobs(); this.emit(); }
  }
  async resumeReview(jobId: string): Promise<void> {
    const epoch: number = this.epoch;
    this.review = undefined;
    const job = (await this.repository.jobs()).find((row: ImageJob): boolean => row.id === jobId);
    if (job === undefined || job.stage === ImageIngestionStage.Unknown) { this.message = 'Unknown 不重新上传；需原任务核对'; this.emit(); return; }
    const document = await this.repository.get(job.documentId);
    if (document === undefined || document.tombstone || document.archived || document.epoch !== job.epoch || document.activeGeneration !== job.expectedActive) { this.message = '候选已失效，保留当前活动'; this.emit(); return; }
    const original = await this.repository.latestOriginal(document.id);
    if (original.assetId !== job.originalAssetId) { this.message = '原件版本已变，旧报告不再授权发布'; this.emit(); return; }
    const cancel: KnowledgeCancellation = new KnowledgeCancellation();
    try { const snapshot = await this.repository.snapshot(job.generation); await imageVerifySnapshot(snapshot,this.identity,cancel); if (epoch !== this.epoch) { return; } this.review = snapshot; this.message = '已恢复原检查点覆盖报告，未创建网络请求'; }
    catch { this.message = '本机检查点不可读，原任务身份保留；未重新外发'; } this.emit();
  }
  async confirmCoverage(hash: string): Promise<void> {
    const snapshot = this.review; if (snapshot === undefined || hash !== snapshot.coverage.hash || this.busy) { this.message = '报告已变化，未发布'; this.emit(); return; }
    const epoch: number = this.epoch; this.busy = true; this.emit();
    try {
      const cancel: KnowledgeCancellation = new KnowledgeCancellation(); await imageVerifySnapshot(snapshot,this.identity,cancel);
      const latest = await this.repository.latestOriginal(snapshot.documentId);
      const current = await this.repository.get(snapshot.documentId);
      if (latest.assetId !== snapshot.original.assetId || current === undefined || current.tombstone || current.archived) { throw new ImageKnowledgeFailure('ImageReviewOriginalChanged','image-publish'); }
      const job = (await this.repository.jobs()).find((row: ImageJob): boolean => row.generation === snapshot.generation && row.reportHash === hash);
      if (epoch !== this.epoch) { throw new ImageKnowledgeFailure('ImageReviewPaused','image-publish'); }
      if (job === undefined || !(await this.repository.publish(job,hash))) { throw new ImageKnowledgeFailure('ImagePublicationStale','image-publish'); }
      this.message = snapshot.blocks.length === 0 ? 'OCR 完成，未识别到文字；原图已保存' : '关键词已发布；文档向量未授权'; this.review = undefined;
    } catch (error) { this.message = error instanceof ImageKnowledgeFailure ? error.message : '发布未完成，旧活动保留'; }
    finally { this.busy = false; this.jobRows = await this.repository.jobs(); await this.refresh(); }
  }
  async archive(documentId: string, archived: boolean): Promise<void> {
    this.pause(); await this.repository.archive(documentId,archived); this.message = archived ? '已归档；未重新上传或嵌入' : '已恢复关键词；向量资格需本机读回同步';
    const sync: ((documentId: string) => Promise<void>) | undefined = this.vectorSync;
    try { if (sync !== undefined) { await sync(documentId); } } catch { this.message += '；向量同步待重试'; } await this.refresh();
  }
  async deleteDocument(documentId: string, confirmed: boolean): Promise<void> {
    if (!confirmed) { return; } this.pause(); await this.repository.deleteDocument(documentId); this.message = '已删除索引，原件清理待安全释放；历史保留失效文本'; await this.retryCleanup(); await this.refresh();
  }
  async retryCleanup(): Promise<void> {
    const handled: Set<string> = new Set<string>();
    for (const intent of await this.repository.cleanups()) {
      if (intent.state === 'Done') { continue; }
      if (!handled.has(intent.documentId)) { handled.add(intent.documentId); const cleanupVector: ((documentId: string) => Promise<void>) | undefined = this.vectorCleanup; try { if (cleanupVector !== undefined) { await cleanupVector(intent.documentId); } } catch { this.message = '已删除/待清理：向量或来源仍持有'; continue; } }
      let failure: string = '';
      const claim = await this.repository.claimCleanup(intent.id); if (claim === undefined) { this.message = '已删除/待清理：仍有读租约或向量资产'; continue; }
      try {
        if (claim.owner === 'ImageSnapshotAssets') { await this.repository.removeSnapshotClaim(claim); }
        else {
          const original = await this.repository.original(claim.assetId); await this.owner.deleteOriginal(original.sourceId);
          const state = this.owner.viewState().snapshot;
          if (state.originals.some((o: DocumentOriginal): boolean => o.id === original.sourceId) || state.cleanup.some((c: DocumentParseCleanup): boolean => c.assets.indexOf(claim.assetId) >= 0)) { throw new ImageKnowledgeFailure('ParseOwnerCleanupPending','image-cleanup'); }
        }
      } catch (error) { failure = error instanceof ImageKnowledgeFailure ? error.category : 'OriginalOwnerCleanupPending'; }
      await this.repository.finishCleanup(claim,failure);
      if (failure.length > 0) { this.message = '已删除/待清理：'+failure; }
    } this.emit();
  }
}
