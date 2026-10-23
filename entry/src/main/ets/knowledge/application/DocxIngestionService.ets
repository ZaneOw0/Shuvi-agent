import { DocumentParseService } from './DocumentParseService';
import { DocumentOriginal, DocumentParseFormat, DocumentParseStage, DocumentParseTask, DocumentParseStateListener, DocumentParseResultEnvelope } from '../domain/DocumentParseModels';
import { DocxPublicationPort, DocxProcessingPort } from '../domain/DocxKnowledgePorts';
import { DocxDocument, DocxOriginal, DocxAssetClaim, DocxFailure, DocxJob, DocxSnapshot, DocxChunk, DocxStage, DocxResultBinding, DocxReadLease, DocxReleaseReceipt } from '../domain/DocxKnowledgeModels';
import { KnowledgeStateListener, KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { docxStructureChunks } from '../pipeline/DocxStructureChunker';

export class DocxIngestionService implements DocumentParseStateListener {
  private static sessions: DocxIngestionService[] = [];
  documents: DocxDocument[] = []; busy: boolean = false; message: string = '';
  jobs: DocxJob[] = []; snapshot: DocxSnapshot | undefined = undefined; currentJob: DocxJob | undefined = undefined;
  private parse: DocumentParseService; private repository: DocxPublicationPort; private listeners: KnowledgeStateListener[] = [];
  private processing: DocxProcessingPort | undefined = undefined; private identity: KnowledgeIdentityPort | undefined = undefined;
  private cancel: KnowledgeCancellation | undefined = undefined;
  private vectorCleanup: ((id: string) => Promise<void>) | undefined = undefined;
  private vectorSync: ((id: string) => Promise<void>) | undefined = undefined;
  private latestOriginal: ((id: string) => Promise<DocxOriginal>) | undefined = undefined;
  private abandonCandidate: ((id: string) => Promise<void>) | undefined = undefined;
  private cleanupAssets: (() => Promise<void>) | undefined = undefined;
  private alive: boolean = true; private epoch: number = 0;
  private heldProcessingLeases: string[] = [];
  private selectedSources: Map<string,string> = new Map<string,string>();
  private sourceBindings: Map<string,string> = new Map<string,string>();
  constructor(parse: DocumentParseService, repository: DocxPublicationPort) { this.parse = parse; this.repository = repository; this.parse.subscribe(this); DocxIngestionService.sessions.push(this); }
  attachManagement(latest: (id: string) => Promise<DocxOriginal>, abandon: (id: string) => Promise<void>, cleanup: () => Promise<void>, vectorCleanup: (id: string) => Promise<void>, sync: (id: string) => Promise<void>): void { this.latestOriginal = latest; this.abandonCandidate = abandon; this.cleanupAssets = cleanup; this.vectorCleanup = vectorCleanup; this.vectorSync = sync; }
  attachProcessing(processing: DocxProcessingPort, identity: KnowledgeIdentityPort): void { this.processing = processing; this.identity = identity; }
  subscribe(listener: KnowledgeStateListener): void { if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); } }
  unsubscribe(listener: KnowledgeStateListener): void { this.listeners = this.listeners.filter((l: KnowledgeStateListener): boolean => l !== listener); }
  changed(): void { if (this.alive) { for (const listener of this.listeners) { listener.changed(); } } }
  authorizationRevision(documentId: string = ''): string { return `${this.parse.state.snapshot.config.credentialRevision}|${this.parse.state.snapshot.config.enabled}|${this.parse.state.credential}|${this.sourceBindings.get(documentId) ?? ''}`; }
  selectedIdentity(documentId: string): string {
    const id: string = this.selectedSources.get(documentId) ?? ''; const o: DocumentOriginal | undefined = this.parse.state.snapshot.originals.find((source: DocumentOriginal): boolean => source.id === id);
    return o === undefined ? '' : `${o.title}\nDOCX · 版本 ${o.version} · ${o.bytes} 字节\n原件 SHA256 ${o.hash}\n${o.preflight} ${o.preflightReason}`;
  }
  async refresh(): Promise<void> {
    this.documents = await this.repository.list(); this.jobs = await this.repository.jobs();
    for (const d of this.documents) {
      const latestForList: ((id: string) => Promise<DocxOriginal>) | undefined = this.latestOriginal;
      const o: DocxOriginal = latestForList === undefined ? await this.repository.original(d.activeOriginal) : await latestForList(d.id); this.selectedSources.set(d.id,o.sourceId); this.sourceBindings.set(d.id,`${o.sourceId}|${o.assetId}|${o.hash}|${o.version}|${d.epoch}|${d.activeGeneration}`);
      if (this.snapshot?.documentId === d.id && (d.tombstone || this.snapshot.original.assetId !== o.assetId || this.snapshot.original.hash !== o.hash || this.snapshot.original.version !== o.version || this.currentJob !== undefined && (this.currentJob.epoch !== d.epoch || this.currentJob.expectedActive !== d.activeGeneration))) { this.snapshot = undefined; this.currentJob = undefined; }
    }
    this.changed();
  }
  private async source(documentId: string): Promise<DocumentOriginal> {
    const document: DocxDocument | undefined = await this.repository.get(documentId);
    if (document === undefined || document.tombstone) { throw new DocxFailure('DocumentUnavailable','docx'); }
    const latestForOpen: ((id: string) => Promise<DocxOriginal>) | undefined = this.latestOriginal;
    const original: DocxOriginal = latestForOpen === undefined ? await this.repository.original(document.activeOriginal) : await latestForOpen(documentId);
    const source: DocumentOriginal | undefined = this.parse.state.snapshot.originals.find((o: DocumentOriginal): boolean => o.id === original.sourceId && o.assetId === original.assetId && o.hash === original.hash && o.version === original.version && o.format === DocumentParseFormat.Docx);
    if (source === undefined) { throw new DocxFailure('ParseOriginalUnavailable','docx'); } return source;
  }
  async importFiles(): Promise<void> {
    if (this.busy) { return; } this.busy = true; this.changed();
    try {
      await this.parse.prepare(false,true);
      await this.adoptPrepared();
      this.message = this.parse.state.message; await this.refresh();
    } catch (error) { this.message = error instanceof Error ? error.message : 'DOCX导入失败，原件保留'; }
    finally { this.busy = false; this.changed(); }
  }
  async adoptPrepared(): Promise<void> {
    for (const source of this.parse.state.snapshot.originals) {
        if (source.format !== DocumentParseFormat.Docx || await this.repository.documentForSource(source.id) !== undefined) { continue; }
        const o: DocxOriginal = new DocxOriginal(); o.documentId = 'docx-'+source.id; o.sourceId = source.id; o.assetId = source.assetId; o.hash = source.hash; o.bytes = source.bytes; o.title = source.title; o.version = source.version; o.savedAt = source.savedAt;
        const claim: DocxAssetClaim = new DocxAssetClaim(); claim.assetId = o.assetId; claim.documentId = o.documentId; claim.owner = 'DocumentParseService'; claim.hash = o.hash; claim.bytes = o.bytes; claim.role = 'Original';
        await this.parse.withDocxOriginal<void>(source.id,async (): Promise<void> => { await this.repository.register(o,[claim]); });
    } await this.refresh();
  }
  private async currentSource(documentId: string, revision: string): Promise<DocumentOriginal> {
    const source: DocumentOriginal = await this.source(documentId); const d: DocxDocument | undefined = await this.repository.get(documentId);
    const actual: string = `${source.id}|${source.assetId}|${source.hash}|${source.version}|${d?.epoch ?? -1}|${d?.activeGeneration ?? ''}`;
    if (revision !== this.authorizationRevision(documentId) || actual !== this.sourceBindings.get(documentId)) { throw new DocxFailure('OriginalOrScopeChangedSinceConfirmation','docx-consent'); } return source;
  }
  async requestParse(documentId: string, fullFile: boolean, free: boolean, revision: string): Promise<void> {
    await this.parseCurrent(documentId,fullFile,free,revision,false);
  }
  async resume(documentId: string, fullFile: boolean, free: boolean, revision: string): Promise<void> {
    await this.parseCurrent(documentId,fullFile,free,revision,true);
  }
  private async parseCurrent(documentId: string, fullFile: boolean, free: boolean, revision: string, resume: boolean): Promise<void> {
    if (this.busy || this.parse.state.busy || !fullFile || !free || revision !== this.authorizationRevision(documentId)) { throw new DocxFailure('CurrentConfirmationExpired','docx-parse'); }
    const epoch: number = ++this.epoch; this.busy = true; this.currentJob = undefined; this.snapshot = undefined; this.changed();
    let received: boolean = false;
    try {
      const source: DocumentOriginal = await this.currentSource(documentId,revision);
      if (epoch !== this.epoch) { return; }
      const task: DocumentParseTask | undefined = this.parse.state.snapshot.tasks.find((t: DocumentParseTask): boolean => t.originalId === source.id);
      if (resume && task === undefined) { throw new DocxFailure('OriginalTaskMissing','docx-resume'); }
      if (task?.stage !== DocumentParseStage.Received) {
        await this.parse.confirmDocx(source.id,fullFile,free);
        if (epoch !== this.epoch || revision !== this.authorizationRevision(documentId)) { return; }
        await this.currentSource(documentId,revision);
        if (epoch !== this.epoch) { return; }
        if (!this.parse.state.snapshot.config.enabled) {
          const enabledRevision: string = `${this.parse.state.snapshot.config.credentialRevision}|true|${this.parse.state.credential}|${this.sourceBindings.get(documentId) ?? ''}`;
          await this.parse.setEnabled(true);
          if (epoch !== this.epoch || enabledRevision !== this.authorizationRevision(documentId)) { return; }
          await this.currentSource(documentId,enabledRevision);
          if (epoch !== this.epoch) { return; }
        }
        if (resume && task !== undefined) { await this.parse.resume(task.id,true); } else { await this.parse.submit(source.id); }
      }
      if (epoch !== this.epoch) { return; }
      this.message = this.parse.state.message;
      received = this.parse.state.snapshot.tasks.some((t: DocumentParseTask): boolean => t.originalId === source.id && t.stage === DocumentParseStage.Received);
    } finally { this.busy = false; this.changed(); }
    if (received && epoch === this.epoch) { await this.prepareResult(documentId); }
  }
  async prepareResult(documentId: string): Promise<void> {
    const processing: DocxProcessingPort | undefined = this.processing; const identity: KnowledgeIdentityPort | undefined = this.identity;
    if (this.busy || processing === undefined || identity === undefined) { throw new DocxFailure('ProcessingUnavailableOrBusy','prepare'); }
    this.busy = true; const epoch: number = ++this.epoch; const cancel: KnowledgeCancellation = new KnowledgeCancellation(); this.cancel = cancel; this.snapshot = undefined; this.currentJob = undefined; this.changed();
    const lease: DocxReadLease = new DocxReadLease();
    let job: DocxJob | undefined = undefined; let candidate: boolean = false;
    let acquired: boolean = false;
    let releasedResources: boolean = true;
    try {
      const source: DocumentOriginal = await this.source(documentId); const document: DocxDocument | undefined = await this.repository.get(documentId);
      const result: DocumentParseResultEnvelope | undefined = this.parse.state.snapshot.results.find((r: DocumentParseResultEnvelope): boolean => r.originalHash === source.hash && r.version === source.version && this.parse.state.snapshot.tasks.some((t: DocumentParseTask): boolean => t.id === r.taskId && t.originalId === source.id && t.stage === DocumentParseStage.Received));
      if (document === undefined || result === undefined) { throw new DocxFailure('ReceivedResultMissing','prepare'); }
      const original: DocxOriginal = await this.repository.original(source.assetId);
      const matching: DocxJob[] = (await this.repository.jobs()).filter((j: DocxJob): boolean => j.documentId === documentId && j.originalAssetId === source.assetId && j.result.taskId === result.taskId && j.result.dataId === result.dataId && j.result.assetId === result.assetId && j.result.hash === result.hash && j.result.bytes === result.bytes && j.result.originalHash === source.hash && j.result.originalVersion === source.version && j.failure !== 'CandidateAbandoned');
      const active: DocxJob | undefined = matching.find((j: DocxJob): boolean => j.generation === document.activeGeneration && j.originalAssetId === document.activeOriginal && j.snapshotHash.length > 0);
      const prior: DocxJob | undefined = matching.find((j: DocxJob): boolean => j.epoch === document.epoch && j.expectedActive === document.activeGeneration && j.generation !== document.activeGeneration);
      cancel.check(); if (epoch !== this.epoch) { throw new DocxFailure('LatePreparationIgnored','prepare'); }
      lease.id = identity.id(); lease.documentId = documentId; lease.assetId = source.assetId; lease.owner = 'DocxProcessing'; lease.epoch = document.epoch;
      await this.parse.withDocxOriginal<void>(source.id,async (): Promise<void> => { await this.repository.acquireRead(lease); }); acquired = true;
      cancel.check();
      // Publication advances document.epoch; the same bound ZIP is now a read, not another candidate.
      if (active !== undefined) {
        const snapshot: DocxSnapshot = await this.repository.snapshot(active.generation); const latest: DocxDocument | undefined = await this.repository.get(documentId);
        cancel.check(); if (epoch !== this.epoch || latest === undefined || latest.tombstone || latest.epoch !== document.epoch || latest.activeGeneration !== active.generation || snapshot.hash !== active.snapshotHash || snapshot.coverage.hash !== active.reportHash || snapshot.original.assetId !== source.assetId || snapshot.original.hash !== source.hash || snapshot.original.version !== source.version || JSON.stringify(snapshot.result) !== JSON.stringify(active.result)) { throw new DocxFailure('ActiveSnapshotChanged','prepare'); }
        this.snapshot = snapshot; this.message = '当前版本已发布，已本机读回正文和覆盖报告；不会重复发布或撤销向量资格'; return;
      }
      job = prior ?? new DocxJob();
      if (prior === undefined) {
        job.id = identity.id(); job.documentId = documentId; job.generation = identity.id(); job.originalAssetId = original.assetId; job.epoch = document.epoch; job.expectedActive = document.activeGeneration;
        const binding: DocxResultBinding = new DocxResultBinding(); binding.taskId = result.taskId; binding.dataId = result.dataId; binding.assetId = result.assetId; binding.hash = result.hash; binding.bytes = result.bytes; binding.originalHash = result.originalHash; binding.originalVersion = result.version; job.result = binding;
        const claim: DocxAssetClaim = new DocxAssetClaim(); claim.assetId = binding.assetId; claim.documentId = documentId; claim.owner = 'DocumentParseService'; claim.hash = binding.hash; claim.bytes = binding.bytes; claim.role = 'Result'; claim.generation = job.generation;
        await this.repository.holdAsset(claim); cancel.check(); await this.repository.begin(job);
      }
      candidate = true; cancel.check();
      if (job.snapshotHash.length > 0 && job.stage === DocxStage.Review) { const snapshot: DocxSnapshot = await this.repository.snapshot(job.generation); cancel.check(); if (epoch !== this.epoch) { throw new DocxFailure('LateCachedReviewIgnored','prepare'); } this.snapshot = snapshot; this.currentJob = job; this.message = '已恢复本机审查快照，零新上传'; return; }
      job.stage = DocxStage.Processing; job.checkpoint = DocxStage.Processing; await this.repository.checkpoint(job);
      cancel.check(); const snapshot: DocxSnapshot = await processing.prepare(original,job.result,job.generation,cancel); cancel.check();
      if (epoch !== this.epoch) { throw new DocxFailure('LateProcessingIgnored','prepare'); }
      const chunks: DocxChunk[] = await docxStructureChunks(snapshot,identity,cancel); job.reportHash = snapshot.coverage.hash; job.snapshotHash = snapshot.hash;
      await this.repository.prepare(job,snapshot,chunks); job.stage = DocxStage.Review; job.checkpoint = DocxStage.Review; await this.repository.checkpoint(job);
      cancel.check(); if (epoch !== this.epoch) { throw new DocxFailure('LateProcessingIgnored','prepare'); }
      this.snapshot = snapshot; this.currentJob = job; this.message = chunks.length === 0 ? '没有可核对的支持文字，原件与ZIP保留；不会生成空向量' : snapshot.coverage.partial ? '部分内容已核，确认报告后仅发布这些原生块' : '正文及结构已准备，等待当前覆盖确认';
    } catch (error) {
      if (error instanceof DocxFailure && error.category === 'ProcessingResourceReleaseUnconfirmed') { releasedResources = false; }
      let failure: string = error instanceof Error ? error.message : 'DOCX本机处理失败';
      if (candidate && job !== undefined && job.stage !== DocxStage.Review) { job.failure = failure; job.stage = DocxStage.Paused; try { await this.repository.checkpoint(job); } catch { failure += '；检查点或世代已失效'; } }
      if (epoch === this.epoch) { this.message = failure; }
    } finally {
      if (acquired) {
        const receipt: DocxReleaseReceipt = new DocxReleaseReceipt(); receipt.leaseId = lease.id; receipt.resource = releasedResources ? 'Released' : 'Unknown'; receipt.failure = releasedResources ? '' : 'ProcessingResourceReleaseUnconfirmed';
        if (!releasedResources) { this.heldProcessingLeases.push(lease.id); }
        try { await this.repository.releaseRead(receipt); } catch { if (this.heldProcessingLeases.indexOf(lease.id) < 0) { this.heldProcessingLeases.push(lease.id); } this.message = 'DOCX读租约释放未确认；可重试，清理仍受保护'; }
      }
      this.cancel = undefined; this.busy = false; await this.refresh();
    }
  }
  async confirmCoverage(reportHash: string): Promise<void> {
    const job: DocxJob | undefined = this.currentJob; const snapshot: DocxSnapshot | undefined = this.snapshot;
    if (this.busy || job === undefined || snapshot === undefined || snapshot.coverage.hash !== reportHash || job.reportHash !== reportHash) { throw new DocxFailure('CurrentCoverageConfirmationRequired','publish'); }
    this.busy = true; this.changed();
    try { if (!(await this.repository.publish(job,reportHash))) { throw new DocxFailure('CoveragePublicationChanged','publish'); } }
    finally { this.busy = false; }
    this.currentJob = undefined; this.snapshot = undefined; this.message = '当前已核原生块已发布，尚未授权文本向量'; await this.refresh();
  }
  async reviewInputs(documentId: string): Promise<DocxChunk[]> {
    const document: DocxDocument | undefined = await this.repository.get(documentId);
    if (document === undefined || document.tombstone || document.activeGeneration.length === 0 || document.chunkCount === 0) { throw new DocxFailure('NoPublishedText','review'); } return this.repository.chunks(document.activeGeneration);
  }
  async replace(documentId: string): Promise<void> {
    if (this.busy) { return; } const d: DocxDocument | undefined = await this.repository.get(documentId); if (d === undefined || d.tombstone) { throw new DocxFailure('DocumentUnavailable','replace'); }
    const active: DocxOriginal = await this.repository.original(d.activeOriginal); const before: string[] = this.parse.state.snapshot.originals.map((o: DocumentOriginal): string => o.id);
    await this.parse.prepare(false,true); const selected: DocumentOriginal[] = this.parse.state.snapshot.originals.filter((o: DocumentOriginal): boolean => o.format === DocumentParseFormat.Docx && before.indexOf(o.id) < 0);
    if (selected.length !== 1) { throw new DocxFailure('ReplacementRequiresOneNewDocx','replace'); }
    const source: DocumentOriginal = await this.parse.assignDocxVersion(selected[0].id,await this.repository.nextVersion(documentId));
    const o: DocxOriginal = new DocxOriginal(); o.documentId = documentId; o.sourceId = source.id; o.assetId = source.assetId; o.hash = source.hash; o.bytes = source.bytes; o.version = source.version; o.title = source.title; o.savedAt = source.savedAt;
    const claim: DocxAssetClaim = new DocxAssetClaim(); claim.documentId = documentId; claim.assetId = o.assetId; claim.hash = o.hash; claim.bytes = o.bytes; claim.owner = 'DocumentParseService'; claim.role = 'Original';
    await this.parse.withDocxOriginal<void>(source.id,async (): Promise<void> => { await this.repository.register(o,[claim]); }); this.pause(); this.message = '新原件候选已保存；旧活动保留，需独立解析及当前覆盖确认'; await this.refresh();
  }
  async archive(id: string, archived: boolean): Promise<void> {
    this.pause(); await this.repository.archive(id,archived);
    const sync: ((id: string) => Promise<void>) | undefined = this.vectorSync;
    if (sync !== undefined) { await sync(id); }
    this.message = archived ? '已归档，不默认参与检索' : '已恢复已有内容，无新上传'; await this.refresh();
  }
  async deleteDocument(id: string, confirmed: boolean): Promise<void> {
    if (!confirmed) { throw new DocxFailure('DeletionConfirmationRequired','manage'); }
    this.pause(); await this.repository.deleteDocument(id);
    const cleanupVector: ((id: string) => Promise<void>) | undefined = this.vectorCleanup;
    if (cleanupVector !== undefined) { await cleanupVector(id); }
    const cleanupFiles: (() => Promise<void>) | undefined = this.cleanupAssets;
    if (cleanupFiles !== undefined) { await cleanupFiles(); }
    this.message = '本机删除已撤资格；原件/ZIP按owner分阶段清理，不代表云删除'; await this.refresh();
  }
  async abandon(id: string): Promise<void> {
    const abandonOriginal: ((id: string) => Promise<void>) | undefined = this.abandonCandidate;
    if (abandonOriginal === undefined) { throw new DocxFailure('CandidateManagementUnavailable','manage'); }
    this.pause(); await abandonOriginal(id);
    const cleanupFiles: (() => Promise<void>) | undefined = this.cleanupAssets;
    if (cleanupFiles !== undefined) { await cleanupFiles(); }
    await this.refresh();
  }
  async retryCleanup(): Promise<void> {
    await this.processing?.retryRelease?.();
    for (const lease of this.heldProcessingLeases.slice()) { const receipt: DocxReleaseReceipt = new DocxReleaseReceipt(); receipt.leaseId = lease; receipt.resource = 'Released'; await this.repository.releaseRead(receipt); this.heldProcessingLeases = this.heldProcessingLeases.filter((id: string): boolean => id !== lease); }
    const cleanupFiles: (() => Promise<void>) | undefined = this.cleanupAssets;
    if (cleanupFiles !== undefined) { await cleanupFiles(); }
    await this.refresh();
  }
  progress(documentId: string): string {
    const id: string = this.selectedSources.get(documentId) ?? (documentId.startsWith('docx-') ? documentId.slice(5) : '');
    const task: DocumentParseTask | undefined = this.parse.state.snapshot.tasks.find((t: DocumentParseTask): boolean => t.originalId === id);
    if (task === undefined) { return '原件已保存，尚未外发'; }
    const result: DocumentParseResultEnvelope | undefined = this.parse.state.snapshot.results.find((r: DocumentParseResultEnvelope): boolean => r.taskId === task.id);
    return `${task.stage}\n本次SDK供给 ${task.uploadBytes} 字节 / ZIP写入 ${task.downloadBytes} 字节\n累计 POST ${task.usage.allocation} / PUT ${task.usage.put} / Query ${task.usage.query} / ZIP ${task.usage.download}\n${task.failure}${result === undefined ? '' : '\n'+this.parse.state.resultDirectory+'/'+result.assetId}`;
  }
  pause(): void { this.epoch++; if (this.cancel !== undefined) { this.cancel.invalid = true; } this.currentJob = undefined; this.snapshot = undefined; this.parse.pauseImmediate(); this.processing?.cancel(); this.changed(); }
  static background(): void { for (const s of DocxIngestionService.sessions) { s.pause(); } }
  async close(): Promise<void> {
    this.pause(); const deadline: number = Date.now()+120000;
    while (this.busy) { if (Date.now() >= deadline) { throw new DocxFailure('ProcessingStillReleasing','close'); } await new Promise<void>((resolve: () => void): void => { setTimeout(resolve,20); }); }
    await this.processing?.retryRelease?.();
    for (const id of this.heldProcessingLeases.slice()) { const receipt: DocxReleaseReceipt = new DocxReleaseReceipt(); receipt.leaseId = id; receipt.resource = 'Released'; await this.repository.releaseRead(receipt); this.heldProcessingLeases = this.heldProcessingLeases.filter((item: string): boolean => item !== id); }
    this.alive = false; this.parse.unsubscribe(this); this.listeners = []; DocxIngestionService.sessions = DocxIngestionService.sessions.filter((s: DocxIngestionService): boolean => s !== this);
  }
}
