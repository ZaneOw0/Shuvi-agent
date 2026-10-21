import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { KnowledgeStoreHost } from '../infra/KnowledgeStoreHost';
import { TextRdbRepository } from '../infra/TextRdbRepository';
import { PdfKnowledgeRepository } from '../infra/PdfKnowledgeRepository';
import { ImageKnowledgeRepository } from '../infra/ImageKnowledgeRepository';
import { DocumentFileAdapter } from '../infra/DocumentFileAdapter';
import { DocumentParseRepository } from '../infra/DocumentParseRepository';
import { DocumentParseService } from '../application/DocumentParseService';
import { ImageIngestionService } from '../application/ImageIngestionService';
import { ImageOriginalAdapter } from '../infra/ImageOriginalAdapter';
import { ImageProcessingAdapter } from '../infra/ImageProcessingAdapter';
import { ImageSourceSession } from '../infra/ImageSourceSession';
import { KnowledgeSearchService } from '../application/KnowledgeSearchService';
import { KnowledgePlatformIdentity } from '../infra/KnowledgeAssembly';
import { KnowledgeSourceRegistry } from '../infra/KnowledgeSourceRegistry';
import { KnowledgeSqlSourceReader } from '../infra/KnowledgeSourceReaders';
import { KnowledgeDerivedBudget } from '../infra/KnowledgeDerivedBudget';
import { KnowledgeLifecycleService } from '../application/KnowledgeLifecycleService';
import { DocumentSelectionPort, DocumentPreflightPort, MineruCredentialPort, DocumentParseClockPort } from '../domain/DocumentParsePorts';
import { DocumentCredentialStatus, DocumentFileSelection, DocumentSelectedFile, DocumentOriginal, DocumentParseCancellation } from '../domain/DocumentParseModels';
import { KnowledgeFailure, KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { ImageDocument, ImageJob } from '../domain/ImageKnowledgeModels';
import { KnowledgeHit } from '../domain/KnowledgeSearchModels';
import { documentEnsureDirectory } from '../infra/DocumentFileOperations';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { IMAGE_CONTROLLED_PROFILE } from '../pipeline/ImageContentNormalizer';
import { ImageVectorRepository } from '../infra/ImageVectorRepository';
import { VectorRdbRepository } from '../infra/VectorRdbRepository';
import { EmbeddingTokenAdapter } from '../infra/EmbeddingTokenAdapter';
import { KnowledgeReadDispatcher } from '../infra/KnowledgeReadDispatcher';
import { EmbeddingWorkflow } from '../application/EmbeddingWorkflow';
import { EmbeddingService } from '../application/EmbeddingService';
import { EmbeddingTransportPort, EmbeddingCredentialPort } from '../domain/KnowledgePorts';
import { EmbeddingConfig, EmbeddingGrant, EmbeddingPurpose, EmbeddingVectorResponse, EmbeddingModelInfo, EmbeddingCredentialStatus, EmbeddingDetectionStatus } from '../domain/EmbeddingModels';
import { embeddingFingerprint } from '../pipeline/EmbeddingPolicy';
import { ImageSnapshotAssets } from '../infra/ImageSnapshotAssets';
import { ImageContentPort } from '../domain/ImageKnowledgePorts';
import { ImageOriginal, ImageSnapshot } from '../domain/ImageKnowledgeModels';
import { parseProviderFailure } from '../pipeline/ParseFailurePolicy';

class ImageFixtureSelection implements DocumentSelectionPort {
  uri: string = ''; bytes: number = 0; title: string = 'synthetic.png';
  async select(): Promise<DocumentFileSelection> { const selection: DocumentFileSelection = new DocumentFileSelection(); const file: DocumentSelectedFile = new DocumentSelectedFile(); file.uri = this.uri; file.bytes = this.bytes; file.title = this.title; selection.canceled = false; selection.files = [file]; return selection; }
}
class ImageFixtureCredential implements MineruCredentialPort {
  async status(): Promise<DocumentCredentialStatus> { return DocumentCredentialStatus.Missing; }
  async save(_input: string, _replace: boolean): Promise<DocumentCredentialStatus> { throw new KnowledgeFailure('FixtureCredentialAccessForbidden','fixture'); }
  async remove(): Promise<DocumentCredentialStatus> { throw new KnowledgeFailure('FixtureCredentialAccessForbidden','fixture'); }
  clearTransient(): void {}
}
class ImageFixturePreflight implements DocumentPreflightPort {
  cancelLocal(): void {}
  async inspect(original: DocumentOriginal, cancel: DocumentParseCancellation): Promise<DocumentOriginal> { cancel.check(); return original; }
}
class ImageFixtureClock implements DocumentParseClockPort {
  private identity: KnowledgePlatformIdentity = new KnowledgePlatformIdentity();
  now(): number { return Date.now(); } id(): string { return this.identity.id(); }
  async sleep(ms: number): Promise<void> { await new Promise<void>((resolve: () => void): void => { setTimeout(resolve,ms); }); }
}
class ImageControlledBlock { id: string = 'fixture-body'; ordinal: number = 0; kind: string = 'text'; text: string = '合成图片 Needle needle 证据'; }
class ImageControlledContent { wire: string = IMAGE_CONTROLLED_PROFILE; original_hash: string = ''; original_version: number = 0; complete: boolean = true; blocks: ImageControlledBlock[] = []; }
class ImageFixtureVectorTransport implements EmbeddingTransportPort {
  calls: number = 0; private registry: KnowledgeSourceRegistry;
  constructor(registry: KnowledgeSourceRegistry) { this.registry = registry; }
  cancel(): void {}
  async models(_config: EmbeddingConfig, _grant: EmbeddingGrant, _cancel: KnowledgeCancellation): Promise<EmbeddingModelInfo[]> { throw new KnowledgeFailure('FixtureModelsForbidden','fixture'); }
  async embed(config: EmbeddingConfig, grant: EmbeddingGrant, purpose: EmbeddingPurpose, input: string, cancel: KnowledgeCancellation): Promise<EmbeddingVectorResponse> {
    cancel.check(); if (purpose !== EmbeddingPurpose.ImageCorpus && purpose !== EmbeddingPurpose.Query) { throw new KnowledgeFailure('FixturePurposeForbidden','fixture'); }
    if (purpose === EmbeddingPurpose.Query) { const approval = grant.queryApproval; if (approval === undefined) { throw new KnowledgeFailure('FixtureScopeApprovalMissing','fixture'); } await this.registry.admit(approval,input,cancel,(): void => { this.calls++; }); } else { this.calls++; }
    const response: EmbeddingVectorResponse = new EmbeddingVectorResponse(); response.model = config.modelId; response.index = 0; response.vector = new Float32Array([1,0,0]); return response;
  }
}
class ImageFixtureEmbeddingCredential implements EmbeddingCredentialPort {
  async status(_config: EmbeddingConfig): Promise<EmbeddingCredentialStatus> { return EmbeddingCredentialStatus.Configured; }
  async save(_config: EmbeddingConfig, _input: string, _replace: boolean): Promise<EmbeddingCredentialStatus> { throw new KnowledgeFailure('FixtureCredentialAccessForbidden','fixture'); }
  async remove(_config: EmbeddingConfig): Promise<EmbeddingCredentialStatus> { throw new KnowledgeFailure('FixtureCredentialAccessForbidden','fixture'); }
  clearTransient(): void {}
}
class ImageFixtureDelayedProcessing implements ImageContentPort {
  private actual: ImageProcessingAdapter; private hold: boolean = false; private releaseWork: (() => void) | undefined = undefined;
  constructor(actual: ImageProcessingAdapter) { this.actual = actual; }
  arm(): void { if (this.releaseWork !== undefined) { throw new KnowledgeFailure('FixtureWorkAlreadyHeld','fixture'); } this.hold = true; }
  release(): void { const release = this.releaseWork; this.releaseWork = undefined; release?.(); }
  async normalize(original: ImageOriginal, bytes: Uint8Array, profile: string, generation: string, cancel: KnowledgeCancellation): Promise<ImageSnapshot> {
    if (this.hold) { this.hold = false; await new Promise<void>((resolve: () => void): void => { this.releaseWork = resolve; }); }
    cancel.check(); return this.actual.normalize(original,bytes,profile,generation,cancel);
  }
}

export class ImageIntegrationSuite {
  readonly scope: KnowledgeStorageScope; readonly host: KnowledgeStoreHost; readonly text: TextRdbRepository; readonly pdf: PdfKnowledgeRepository;
  readonly images: ImageKnowledgeRepository; readonly parse: DocumentParseService; readonly source: ImageSourceSession; readonly search: KnowledgeSearchService;
  service: ImageIngestionService; status: string = 'NotPrepared'; caseId: string;
  private static sessions: ImageIntegrationSuite[] = [];
  static background(): void { for (const fixture of ImageIntegrationSuite.sessions) { fixture.service.pause(); fixture.workflow.pause(); fixture.source.pause(); fixture.source.close().catch((): void => {}); } }
  readonly metadata: ImageVectorRepository; readonly vectors: VectorRdbRepository; readonly workflow: EmbeddingWorkflow; readonly embedding: EmbeddingService;
  selectedSpace: string = ''; private transport: ImageFixtureVectorTransport;
  private context: common.Context; private selection: ImageFixtureSelection = new ImageFixtureSelection(); private identity: KnowledgePlatformIdentity = new KnowledgePlatformIdentity();
  private assets: DocumentFileAdapter; private processor: ImageProcessingAdapter = new ImageProcessingAdapter();
  private delayed: ImageFixtureDelayedProcessing = new ImageFixtureDelayedProcessing(this.processor);
  constructor(context: common.Context, scope: KnowledgeStorageScope, caseId: string) {
    scope.requireTestOwner(scope.key); if (['US1','US2','US3','US4','US5'].indexOf(caseId) < 0) { throw new KnowledgeFailure('ImageFixtureCaseUnknown','fixture'); }
    this.scope = scope; this.caseId = caseId; this.context = context; this.host = KnowledgeStoreHost.forContext(context,scope);
    ImageIntegrationSuite.sessions.push(this);
    this.text = new TextRdbRepository(context,this.host); this.pdf = new PdfKnowledgeRepository(this.host); this.images = new ImageKnowledgeRepository(this.host);
    this.images.attachIdentity(this.identity);
    this.images.attachSnapshotAssets(new ImageSnapshotAssets(context.filesDir,context.cacheDir,scope));
    const fixtureBudget: KnowledgeDerivedBudget = new KnowledgeDerivedBudget(context,scope);
    this.assets = new DocumentFileAdapter(context,scope); this.parse = new DocumentParseService(new ImageFixtureCredential(),new DocumentParseRepository(context,scope),scope);
    this.parse.attachLocalCapacity(async (bytes: number): Promise<void> => { if ((await fixtureBudget.usage()).total()+bytes*2+1048576 > 524288000) { throw new KnowledgeFailure('FixtureSharedBudget','fixture'); } });
    this.parse.attachLocal(this.selection,this.assets,new ImageFixturePreflight());
    const protection: KnowledgeLifecycleService = new KnowledgeLifecycleService(this.pdf); protection.attachImageProtection(async (ids: string[]): Promise<void> => { await this.images.assertUnpinned(ids); }); this.parse.attachSourceProtection(protection);
    this.source = new ImageSourceSession(this.images,new ImageOriginalAdapter(context.filesDir,scope),this.identity);
    this.service = this.newService(); this.search = new KnowledgeSearchService(this.text,this.pdf,this.identity);
    const registry: KnowledgeSourceRegistry = new KnowledgeSourceRegistry(this.host,this.identity);
    for (const kind of ['Text','Pdf','Image']) { registry.register(new KnowledgeSqlSourceReader(kind,this.host,this.identity,this.text,this.pdf,this.images)); } this.search.attachScope(registry);
    this.metadata = new ImageVectorRepository(this.host,this.pdf,this.images); this.vectors = new VectorRdbRepository(context,scope); this.transport = new ImageFixtureVectorTransport(registry);
    this.workflow = new EmbeddingWorkflow(this.metadata,this.vectors,this.transport,this.identity,this.pdf,new KnowledgeReadDispatcher(this.pdf,this.images),scope.key,new EmbeddingTokenAdapter(context,this.identity));
    this.embedding = new EmbeddingService(this.pdf,new ImageFixtureEmbeddingCredential(),this.transport,this.identity); this.embedding.attachWorkflow(this.workflow); this.search.attachSemantic(this.workflow);
    this.service.attachVectorCleanup(async (id: string): Promise<void> => { await this.metadata.cleanupDeleted(id,this.vectors); });
    this.service.attachVectorSync(async (id: string): Promise<void> => { await this.workflow.sync(id); });
    // No real transport, credential store, model discovery or probe is ever assembled here.
  }
  private newService(): ImageIngestionService { return new ImageIngestionService(this.parse,this.images,new ImageOriginalAdapter(this.context.filesDir,this.scope),this.delayed,this.identity,this.scope); }
  holdNext(): void { this.delayed.arm(); this.status = '下一次正式规范化将等待显式释放'; }
  releaseLate(): void { this.delayed.release(); this.status = '已释放延后工作；是否采纳由正式epoch/墓碑检查决定'; }
  async prepare(): Promise<void> {
    await this.text.open(); await this.pdf.open(); await this.images.open(); this.images.attachPhysicalBudget(new KnowledgeDerivedBudget(this.context,this.scope)); await this.parse.initialize(); await this.service.initialize();
    this.embedding.state.config.modelId = 'BAAI/bge-m3'; this.embedding.state.credential = EmbeddingCredentialStatus.Configured;
    this.embedding.state.detection.status = EmbeddingDetectionStatus.Passed; this.embedding.state.detection.configFingerprint = embeddingFingerprint(this.embedding.state.config); this.embedding.state.detection.requestedModel = 'BAAI/bge-m3'; this.embedding.state.detection.returnedModel = 'BAAI/bge-m3'; this.embedding.state.detection.dimension = 3;
    await this.embedding.acceptBaseline();
    const root: string = `${this.context.cacheDir}/${this.scope.derivedDirectory}`; await documentEnsureDirectory(root);
    const bytes: Uint8Array = await this.context.resourceManager.getRawFileContent('m3-synthetic.png'); const path: string = `${root}/fixture-input.png`;
    if (await fileIo.access(path)) { throw new KnowledgeFailure('FixtureInputAlreadyExists','fixture'); }
    const file = await fileIo.open(path,fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.NOFOLLOW);
    try { if (await fileIo.write(file.fd,bytes.buffer) !== bytes.length) { throw new KnowledgeFailure('FixtureWriteIncomplete','fixture'); } await fileIo.fsync(file.fd); } finally { await fileIo.close(file); }
    this.selection.uri = path; this.selection.bytes = bytes.length; this.status = `${this.caseId} Ready · 隔离 ${this.scope.key} · 实际网络 0`;
  }
  async conflictNext(): Promise<void> { this.selection.title = 'synthetic.webp'; this.status = '下一次选择为 PNG/WebP 后缀冲突'; }
  async validNext(): Promise<void> { this.selection.title = 'synthetic.png'; this.status = '下一次选择为自制透明无字 PNG'; }
  async controlled(empty: boolean = false, invalid: boolean = false): Promise<void> {
    const document = (await this.images.list()).find((doc: ImageDocument): boolean => !doc.tombstone && !doc.archived); if (document === undefined) { throw new KnowledgeFailure('ImportFixtureFirst','fixture'); }
    const original = await this.images.latestOriginal(document.id); const payload: ImageControlledContent = new ImageControlledContent(); payload.original_hash = original.hash; payload.original_version = original.version;
    const block: ImageControlledBlock = new ImageControlledBlock(); if (empty) { block.kind = 'empty'; block.text = ''; } if (invalid) { block.kind = 'unknown'; } payload.blocks = [block];
    await this.service.acceptControlled(this.scope.key,document.id,pdfCodecUtf8(JSON.stringify(payload))); this.status = '受控 OCR 已处理；结果以正式报告为准，未调用服务';
  }
  async reopen(): Promise<void> { await this.service.pauseCheckpoint(); this.service.detach(); this.processor.cancel(); await this.parse.initialize(); this.service = this.newService(); this.service.attachVectorCleanup(async (id: string): Promise<void> => { await this.metadata.cleanupDeleted(id,this.vectors); }); await this.service.initialize(); this.status = '同一隔离仓储重读parse检查点并重建服务；未创建网络任务'; }
  async restoreReport(): Promise<void> { const jobs: ImageJob[] = await this.images.jobs(); const job = jobs[jobs.length-1]; if (job === undefined) { throw new KnowledgeFailure('CheckpointMissing','fixture'); } await this.service.resumeReview(job.id); }
  async injectParseFailure(): Promise<void> {
    const doc = (await this.images.list()).find((d: ImageDocument): boolean => !d.tombstone);
    if (doc === undefined) { throw new KnowledgeFailure('ImportFixtureFirst','fixture'); }
    const original = await this.images.latestOriginal(doc.id);
    await this.parse.acceptDiagnosticFailure(this.scope.key,original.sourceId,parseProviderFailure('A_TEST_UNKNOWN','unclassified service reason','云解析'));
    this.status = '隔离正式owner错误已落盘；真实请求0，非生产失败证据';
  }
  async controlledVectors(approved: boolean): Promise<void> {
    if (!approved) { throw new KnowledgeFailure('FixtureIndependentVectorConsentRequired','fixture'); }
    const doc = (await this.images.list()).find((d: ImageDocument): boolean => !d.tombstone && !d.archived && d.chunkCount > 0); if (doc === undefined) { throw new KnowledgeFailure('PublishTextFirst','fixture'); }
    await this.embedding.dryReview(doc.id); await this.workflow.vectorize(doc.id,true,true); this.selectedSpace = this.workflow.current?.spaceId ?? ''; this.status = `受控向量 ${this.transport.calls} 次注入调用；真实网络 0，非语义质量`;
  }
  async openSource(document: ImageDocument, hit?: KnowledgeHit): Promise<void> { await this.source.open(document,hit); }
  async close(): Promise<void> { this.service.pause(); this.processor.cancel(); this.workflow.pause(); await this.source.close(); await this.parse.close(); await this.vectors.close(); await this.images.close(); await this.pdf.close(); await this.text.close(); this.status = 'Closed; isolated evidence retained'; }
}
