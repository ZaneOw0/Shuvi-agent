import { PdfArchivePort, PdfNormalizationPort, PdfAssetPort, KnowledgeIdentityPort, KnowledgeStateListener } from '../domain/KnowledgePorts';
import { DocumentParseService } from './DocumentParseService';
import { KnowledgeLifecycleService } from './KnowledgeLifecycleService';
import { DocumentOriginal, DocumentParseTask, DocumentParseResultEnvelope, DocumentParseFormat, DocumentParseCleanup, DocumentParseGrant } from '../domain/DocumentParseModels';
import {
  PdfIngestionState, PdfSourceBinding, PdfKnowledgeDocument, PdfIngestionJob, KnowledgePin, PdfNormalizedDocument,
  PdfStage, PdfPartialApproval, PdfChunk, KnowledgeCancellation, KnowledgeFailure, PdfBudget, PdfZipManifest, PdfCoverageIssue, KnowledgeReadLease
} from '../domain/PdfKnowledgeModels';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { pdfStructureChunks } from '../pipeline/PdfStructureChunker';

export interface PdfIngestionRepository {
  register(document: PdfKnowledgeDocument, job: PdfIngestionJob, pins: KnowledgePin[]): Promise<PdfIngestionJob>;
  list(): Promise<PdfKnowledgeDocument[]>; jobs(): Promise<PdfIngestionJob[]>; checkpoint(job: PdfIngestionJob): Promise<void>;
  prepare(document: PdfKnowledgeDocument, job: PdfIngestionJob, chunks: PdfChunk[], approval: PdfPartialApproval): Promise<void>;
  publish(document: PdfKnowledgeDocument, job: PdfIngestionJob, approval: PdfPartialApproval, cancel?: KnowledgeCancellation): Promise<boolean>;
  get(id: string): Promise<PdfKnowledgeDocument | undefined>; resumeJob(jobId: string): Promise<PdfIngestionJob>;
  acquireRead(lease: KnowledgeReadLease): Promise<void>; releaseRead(id: string): Promise<void>;
  releaseFailure(job: string, failure: string): Promise<void>;
}
export class PdfIngestionService {
  state: PdfIngestionState = new PdfIngestionState(); private listeners: KnowledgeStateListener[] = [];
  pendingJobs: PdfIngestionJob[] = [];
  private repository: PdfIngestionRepository; private lifecycle: KnowledgeLifecycleService; private archive: PdfArchivePort;
  private normalizer: PdfNormalizationPort; private assets: PdfAssetPort; private identity: KnowledgeIdentityPort;
  private active: KnowledgeCancellation | undefined = undefined; private snapshot: PdfNormalizedDocument | undefined = undefined;
  constructor(repository: PdfIngestionRepository, lifecycle: KnowledgeLifecycleService, archive: PdfArchivePort, normalizer: PdfNormalizationPort, assets: PdfAssetPort, identity: KnowledgeIdentityPort) {
    this.repository = repository; this.lifecycle = lifecycle; this.archive = archive; this.normalizer = normalizer; this.assets = assets; this.identity = identity;
  }
  subscribe(listener: KnowledgeStateListener): void { this.listeners.push(listener); }
  unsubscribe(listener: KnowledgeStateListener): void { this.listeners = this.listeners.filter((item: KnowledgeStateListener): boolean => item !== listener); }
  private emit(): void { for (const listener of this.listeners) { listener.changed(); } }
  pause(): void { if (this.active !== undefined) { this.active.invalid = true; this.normalizer.cancel?.(); } this.state.message = '已请求暂停，等待本机资源释放；原件、ZIP 与旧索引保留'; this.emit(); }
  async refreshJobs(): Promise<void> { this.pendingJobs = await this.repository.jobs(); this.emit(); }
  async rebuild(jobId: string): Promise<void> {
    if (this.state.busy || this.state.releasing) { return; }
    const old: PdfIngestionJob | undefined = (await this.repository.jobs()).find((job: PdfIngestionJob): boolean => job.id === jobId);
    if (old === undefined || old.binding === undefined) { this.state.message = '候选来源未记录，不能猜测重建'; this.emit(); return; }
    const document: PdfKnowledgeDocument | undefined = await this.repository.get(old.documentId); if (document === undefined || document.tombstone) { return; }
    const binding: PdfSourceBinding = old.binding; const job: PdfIngestionJob = new PdfIngestionJob();
    job.id = this.identity.id(); job.generation = this.identity.id(); job.documentId = document.id; job.sourceId = old.sourceId; job.binding = binding;
    job.epoch = document.epoch; job.expectedOldGeneration = document.activeContentGeneration; job.ownerSession = this.sessionId; job.attempt = old.attempt+1; job.processingKey = `${old.processingKey}|rebuild:${job.id}`;
    const pins: KnowledgePin[] = [];
    for (let at: number = 0; at < 2; at++) { const pin: KnowledgePin = new KnowledgePin(); pin.id = this.identity.id(); pin.sourceId = job.sourceId; pin.assetId = at === 0 ? binding.originalAssetId : binding.resultAssetId; pin.assetHash = at === 0 ? binding.originalHash : binding.zipHash; pin.ownerId = job.id; pin.documentId = document.id; pin.generation = job.generation; pins.push(pin); }
    await this.lifecycle.prepare(document,job,pins,async (): Promise<void> => {}); await this.refreshJobs(); await this.resume(job.id);
  }
  async publishPartial(reportHash: string): Promise<void> {
    if (this.state.busy || this.snapshot === undefined || this.state.document === undefined || this.state.job === undefined) { return; }
    const snapshot: PdfNormalizedDocument = this.snapshot; const job: PdfIngestionJob = this.state.job;
    if (!snapshot.coverage.hardPassed || reportHash !== snapshot.coverage.hash || snapshot.coverage.snapshotHash !== snapshot.hash || snapshot.coverage.issues.some((issue: PdfCoverageIssue): boolean => issue.hard)) { this.state.message = '硬校验未通过或报告已变化，不允许确认绕过'; this.emit(); return; }
    const approval: PdfPartialApproval = new PdfPartialApproval(); approval.reportHash = reportHash; approval.snapshotHash = snapshot.hash; approval.confirmedAt = Date.now(); approval.limitations = snapshot.coverage.issues.map((issue: PdfCoverageIssue): string => issue.code);
    this.state.busy = true; const cancel: KnowledgeCancellation = new KnowledgeCancellation(); this.active = cancel;
    try {
      const chunks: PdfChunk[] = this.normalizer.chunks === undefined ? pdfStructureChunks(snapshot,job.generation,cancel) : await this.normalizer.chunks(snapshot,job.generation,cancel);
      for (const chunk of chunks) { chunk.inputHash = await this.identity.hash(pdfCodecUtf8(chunk.embeddingText)); }
      await this.repository.prepare(this.state.document,job,chunks,approval); cancel.check();
      if (!await this.repository.publish(this.state.document,job,approval,cancel)) { throw new KnowledgeFailure('StalePublication','keyword'); }
      job.stage = PdfStage.Published; this.state.stage = PdfStage.Published; this.state.message = '关键词部分可用；定位待核验，向量关闭';
    } catch (error) { this.state.message = error instanceof KnowledgeFailure ? error.message : '发布失败，旧索引保持'; }
    finally { this.state.busy = false; this.active = undefined; await this.refreshJobs(); this.emit(); }
  }
  async resume(jobId: string): Promise<void> {
    if (this.state.busy || this.state.releasing) { return; } this.state = new PdfIngestionState(); this.snapshot = undefined; this.state.busy = true;
    const cancel: KnowledgeCancellation = new KnowledgeCancellation(); this.active = cancel;
    let readLeaseId: string = '';
    let currentJob: PdfIngestionJob | undefined = undefined;
    try {
      const job: PdfIngestionJob = await this.repository.resumeJob(jobId); const document: PdfKnowledgeDocument | undefined = await this.repository.get(job.documentId);
      currentJob = job;
      if (document === undefined || document.tombstone) { throw new KnowledgeFailure('DocumentMissing','resume'); }
      this.state.job = job; this.state.document = document;
      const published: boolean = job.stage === PdfStage.Published;
      job.ownerSession = this.sessionId;
      const lease: KnowledgeReadLease = new KnowledgeReadLease(); lease.id = this.identity.id(); lease.sourceId = job.sourceId; lease.generation = job.generation; lease.sessionId = this.sessionId;
      await this.repository.acquireRead(lease); readLeaseId = lease.id;
      if (job.snapshotId.length === 0) {
        if (job.binding === undefined) { throw new KnowledgeFailure('LegacyCandidateBindingNotRecorded','retry'); }
        const recovered: PdfNormalizedDocument | undefined = await this.assets.recoverSnapshot?.(job.generation,cancel);
        if (recovered !== undefined) {
          if (recovered.documentId !== document.id || recovered.generation !== job.generation || recovered.binding.zipHash !== job.binding.zipHash || recovered.binding.originalHash !== job.binding.originalHash) { throw new KnowledgeFailure('RecoveredSnapshotBindingMismatch','resume'); }
          await this.normalizer.verifySnapshot?.(recovered,cancel); job.profile = recovered.profile; job.snapshotId = recovered.id; job.snapshotHash = recovered.hash; job.reportHash = recovered.coverage.hash; job.stage = PdfStage.Review; job.checkpoint = PdfStage.Review; await this.repository.checkpoint(job);
        } else { await this.process(job.binding,document,job,cancel); return; }
      }
      const snapshot: PdfNormalizedDocument = await this.assets.read(job.snapshotId,cancel);
      await this.normalizer.verifySnapshot?.(snapshot,cancel);
      if (snapshot.hash !== job.snapshotHash || snapshot.coverage.hash !== job.reportHash || snapshot.binding.originalHash !== document.binding.originalHash || snapshot.generation !== job.generation || snapshot.documentId !== document.id || (job.binding !== undefined && snapshot.binding.zipHash !== job.binding.zipHash)) { throw new KnowledgeFailure('CheckpointIdentityMismatch','resume'); }
      this.snapshot = snapshot; this.state.report = snapshot.coverage; this.state.snapshotId = snapshot.id; this.state.nativeMembers = snapshot.manifest.members.length; this.state.nativeExpanded = snapshot.manifest.expandedBytes; this.state.decodedImages = snapshot.images.length;
      this.state.stage = published ? PdfStage.Published : PdfStage.Review; this.state.message = published ? '已发布快照与全部图像重读完成，不重复入库；没有云请求' : '检查点已恢复，须重新确认当前覆盖报告；没有云请求';
    } catch (error) {
      this.state.stage = cancel.invalid || (error instanceof KnowledgeFailure && error.category === 'Canceled') ? PdfStage.Paused : PdfStage.Failed; this.state.message = error instanceof KnowledgeFailure ? error.message : 'LocalOperationFailed / resume；原件和旧索引保留';
      if (currentJob !== undefined && currentJob.stage !== PdfStage.Published) { currentJob.stage = this.state.stage; currentJob.failure = this.state.message; try { await this.repository.checkpoint(currentJob); } catch { this.state.message += '；失败状态持久化待核，旧检查点保留'; } }
    }
    finally { await this.finish(readLeaseId); }
  }
  private binding(parse: DocumentParseService, resultId: string): PdfSourceBinding {
    const result: DocumentParseResultEnvelope | undefined = parse.state.snapshot.results.find((item: DocumentParseResultEnvelope): boolean => item.assetId === resultId);
    const task: DocumentParseTask | undefined = parse.state.snapshot.tasks.find((item: DocumentParseTask): boolean => item.id === result?.taskId);
    const original: DocumentOriginal | undefined = parse.state.snapshot.originals.find((item: DocumentOriginal): boolean => item.id === task?.originalId);
    if (result === undefined || task === undefined || original === undefined || original.format !== DocumentParseFormat.Pdf || !result.completeTransport || !result.signature || result.originalHash !== original.hash || task.hash !== original.hash || result.version !== original.version || task.version !== original.version || task.dataId !== result.dataId || original.pages < 1 || original.pages > PdfBudget.pages || original.bytes > PdfBudget.originalBytes) { throw new KnowledgeFailure('SourceResultBindingInvalid','ingestion'); }
    const binding: PdfSourceBinding = new PdfSourceBinding(); binding.originalId = original.id; binding.originalAssetId = original.assetId; binding.originalHash = original.hash;
    binding.originalVersion = original.version; binding.originalBytes = original.bytes; binding.originalPages = original.pages;
    const grant: DocumentParseGrant | undefined = parse.state.snapshot.grants.find((item: DocumentParseGrant): boolean => item.id === task.grantId);
    binding.taskId = task.id; binding.dataId = task.dataId; binding.resultAssetId = result.assetId; binding.zipHash = result.hash; binding.zipBytes = result.bytes; binding.requestMode = grant?.parameters ?? 'NotRecorded'; binding.backend = 'NotRecorded'; binding.producerVersion = 'NotRecorded'; return binding;
  }
  async prepare(parse: DocumentParseService, resultId: string): Promise<void> {
    if (this.state.busy || this.state.releasing) { return; }
    this.state = new PdfIngestionState(); this.snapshot = undefined; this.state.busy = true; this.state.stage = PdfStage.Validating; const cancel: KnowledgeCancellation = new KnowledgeCancellation(); this.active = cancel; this.emit(); let readLeaseId: string = '';
    let currentJob: PdfIngestionJob | undefined = undefined;
    try {
      const binding: PdfSourceBinding = this.binding(parse,resultId); const sourceKey: string = `${binding.originalId}:${binding.originalHash}:${binding.originalVersion}`;
      const existing: PdfKnowledgeDocument | undefined = (await this.repository.list()).find((item: PdfKnowledgeDocument): boolean => item.sourceKey === sourceKey);
      const document: PdfKnowledgeDocument = existing ?? new PdfKnowledgeDocument();
      if (existing === undefined) { document.id = this.identity.id(); document.sourceKey = sourceKey; document.binding = binding; document.createdAt = Date.now(); document.updatedAt = Date.now(); document.title = parse.state.snapshot.originals.find((original: DocumentOriginal): boolean => original.id === binding.originalId)?.title ?? ''; }
      if (document.tombstone) { throw new KnowledgeFailure('SourceDeleted','ingestion'); }
      const job: PdfIngestionJob = new PdfIngestionJob(); job.id = this.identity.id(); job.documentId = document.id; job.sourceId = binding.originalId; job.generation = this.identity.id(); job.epoch = document.epoch; job.expectedOldGeneration = document.activeContentGeneration;
      job.binding = binding; job.ownerSession = this.sessionId;
      job.processingKey = [sourceKey,binding.zipHash,'MINERU-HOSTED-PDF-3.4.4-OBSERVED-1','PDF-NORMALIZE-1','PDF-FILTER-1','PDF-CHUNK-1'].join('|');
      const pins: KnowledgePin[] = [];
      for (let index: number = 0; index < 2; index++) { const pin: KnowledgePin = new KnowledgePin(); pin.id = this.identity.id(); pin.sourceId = binding.originalId; pin.assetId = index === 0 ? binding.originalAssetId : binding.resultAssetId; pin.assetHash = index === 0 ? binding.originalHash : binding.zipHash; pin.ownerId = job.id; pin.documentId = document.id; pin.generation = job.generation; pins.push(pin); }
      const registered: PdfIngestionJob = await this.lifecycle.prepare(document,job,pins,async (): Promise<void> => {
        const current: PdfSourceBinding = this.binding(parse,resultId);
        if (current.originalHash !== binding.originalHash || current.zipHash !== binding.zipHash || parse.state.snapshot.cleanup.some((cleanup: DocumentParseCleanup): boolean => cleanup.assets.indexOf(binding.originalAssetId) >= 0 || cleanup.assets.indexOf(binding.resultAssetId) >= 0)) { throw new KnowledgeFailure('SourceCleanupOrDrift','ingestion'); }
      });
      this.state.document = document; this.state.job = registered; currentJob = registered;
      if (registered.stage === PdfStage.Published) { this.state.stage = PdfStage.Published; this.state.message = '相同处理键已发布，未重复创建'; return; }
      if (registered.terminated) { throw new KnowledgeFailure('TerminatedAttemptRequiresRebuild','ingestion'); }
      if (registered.snapshotId.length > 0) { this.state.message = '已有完整检查点，请从任务列表恢复审查'; return; }
      cancel.check();
      const lease: KnowledgeReadLease = new KnowledgeReadLease(); lease.id = this.identity.id(); lease.sourceId = binding.originalId; lease.generation = registered.generation; lease.sessionId = this.sessionId;
      await this.repository.acquireRead(lease); readLeaseId = lease.id;
      await this.process(binding,document,registered,cancel);
    } catch (error) {
      this.state.stage = cancel.invalid || (error instanceof KnowledgeFailure && error.category === 'Canceled') ? PdfStage.Paused : PdfStage.Failed; this.state.message = error instanceof KnowledgeFailure ? error.message : 'LocalOperationFailed / prepare；原件、ZIP 和旧索引保留';
      if (currentJob !== undefined && !currentJob.terminated && currentJob.stage !== PdfStage.Published) { currentJob.stage = this.state.stage; currentJob.failure = this.state.message; try { await this.repository.checkpoint(currentJob); } catch { this.state.message += '；检查点状态待核，pin 保留'; } }
    } finally { await this.finish(readLeaseId); }
  }
  private async process(binding: PdfSourceBinding, document: PdfKnowledgeDocument, job: PdfIngestionJob, cancel: KnowledgeCancellation): Promise<void> {
    const manifest: PdfZipManifest = await this.archive.inspect(binding,cancel); cancel.check();
    this.state.nativeMembers = manifest.members.length; this.state.nativeExpanded = manifest.expandedBytes; this.emit();
    let snapshot: PdfNormalizedDocument = await this.normalizer.normalize(binding,manifest,this.archive,cancel); snapshot.id = this.identity.id(); snapshot.documentId = document.id; snapshot.generation = job.generation;
    job.profile = snapshot.profile;
    await this.assets.saveImages(snapshot,this.archive,cancel);
    this.state.decodedImages = snapshot.images.length; this.emit();
    if (this.normalizer.sealSnapshot !== undefined) { snapshot = await this.normalizer.sealSnapshot(snapshot,cancel); }
    else {
      const nodeHashes: string[] = [];
      for (const node of snapshot.nodes) { cancel.check(); nodeHashes.push(await this.identity.hash(pdfCodecUtf8(JSON.stringify(node)))); }
      snapshot.hash = await this.identity.hash(pdfCodecUtf8([binding.originalHash,binding.zipHash,snapshot.profile,snapshot.normalizationVersion,snapshot.filterVersion,nodeHashes.join('|')].join('\n'))); snapshot.coverage.snapshotHash = snapshot.hash;
      snapshot.coverage.hash = await this.identity.hash(pdfCodecUtf8(JSON.stringify(snapshot.coverage)));
    }
    await this.assets.save(snapshot,cancel); cancel.check();
    job.profile = snapshot.profile; job.snapshotId = snapshot.id; job.snapshotHash = snapshot.hash; job.reportHash = snapshot.coverage.hash; job.stage = PdfStage.Review; job.checkpoint = PdfStage.Review;
    await this.repository.checkpoint(job); this.snapshot = snapshot; this.state.snapshotId = snapshot.id; this.state.report = snapshot.coverage; this.state.stage = PdfStage.Review; this.state.message = '结构已校验，待审查覆盖限制；尚未发布关键词或向量';
  }
  private async finish(readLeaseId: string): Promise<void> {
    this.state.releasing = true; this.emit(); let failed: boolean = false;
    try { await this.archive.release(); } catch { failed = true; this.state.message += '；解压会话释放未确认'; }
    try { if (readLeaseId.length > 0) { await this.repository.releaseRead(readLeaseId); } } catch { failed = true; this.state.message += '；读取租约释放未确认'; }
    if (this.state.job !== undefined) { try { await this.repository.releaseFailure(this.state.job.id,failed ? this.state.message : ''); } catch { failed = true; } }
    this.state.releasing = failed; this.state.busy = false; this.active = undefined; this.emit();
  }
  private sessionId: string = '';
  attachSession(sessionId: string): void { this.sessionId = sessionId; }
}
