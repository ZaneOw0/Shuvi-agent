import { common } from '@kit.AbilityKit';
import { KnowledgePlatformIdentity } from './KnowledgeIdentity';
import { KnowledgeReadLease } from '../domain/PdfKnowledgeModels';
import { documentAssetPath, documentHashFile } from './DocumentFileOperations';
import { DocumentParseCancellation } from '../domain/DocumentParseModels';
import { KnowledgeCancellation, PdfSourceBinding, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { PdfPageReferenceService } from '../application/PdfPageReferenceService';
import { EmbeddingCredentialStore } from './EmbeddingCredentialStore';
import { EmbeddingTransportAdapter } from './EmbeddingTransportAdapter';
import { EmbeddingService } from '../application/EmbeddingService';
import { PdfIngestionService } from '../application/PdfIngestionService';
import { PdfArchiveAdapter } from './PdfArchiveAdapter';
import { PdfAssetAdapter } from './PdfAssetAdapter';
import { PdfProcessingAdapter } from './PdfProcessingAdapter';
import { KnowledgeSearchService } from '../application/KnowledgeSearchService';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { TextKnowledgeAssembly } from './TextKnowledgeAssembly';
import { PdfKnowledgeRepository } from './PdfKnowledgeRepository';
import { KnowledgeLifecycleService, KnowledgeDerivedLifecycle, ParsedDocumentLifecycle } from '../application/KnowledgeLifecycleService';
import { VectorRdbRepository } from './VectorRdbRepository';
import { PdfVectorRepository } from './PdfVectorRepository';
import { EmbeddingWorkflow } from '../application/EmbeddingWorkflow';
import { KnowledgeDerivedBudget } from './KnowledgeDerivedBudget';
import { EmbeddingTokenAdapter } from './EmbeddingTokenAdapter';
import { PdfSourceSession } from './PdfSourceSession';
import { KnowledgeCapabilityService } from './KnowledgeCapabilityService';
import { ImageKnowledgeRepository } from './ImageKnowledgeRepository';
import { KnowledgeSourceRegistry } from './KnowledgeSourceRegistry';
import { KnowledgeSqlSourceReader } from './KnowledgeSourceReaders';
import { ImageOriginalAdapter } from './ImageOriginalAdapter';
import { ImageSourceSession } from './ImageSourceSession';
import { ImageVectorRepository } from './ImageVectorRepository';
import { KnowledgeReadDispatcher } from './KnowledgeReadDispatcher';
import { ImageSnapshotAssets } from './ImageSnapshotAssets';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { DocxKnowledgeRepository } from './DocxKnowledgeRepository';
import { DocxSnapshotAssets } from './DocxSnapshotAssets';
import { DocxSourceReader } from './DocxSourceReader';
import { DocxSourceSession } from './DocxSourceSession';
import { DocxVectorRepository } from './DocxVectorRepository';
import { DocumentParseService } from '../application/DocumentParseService';
import { DocxCleanupIntent, DocxOriginal, DocxFailure } from '../domain/DocxKnowledgeModels';
import { ImageKnowledgeFailure } from '../domain/ImageKnowledgeModels';
import { DocumentOriginal, DocumentParseResultEnvelope, DocumentParseCleanup } from '../domain/DocumentParseModels';
import { ParsedDocumentRepository } from './ParsedDocumentRepository';
import { ParsedDocumentAssets } from './ParsedDocumentAssets';
import { ParsedCancellation, ParsedDocument } from '../domain/ParsedDocumentModels';
import { ParsedDocumentIngestionService } from '../application/ParsedDocumentIngestionService';
import { ParsedDocumentImportAdapter } from './ParsedDocumentImportAdapter';
import { VisionCredentialStore } from './VisionCredentialStore';
import { VisionTransportAdapter } from './VisionTransportAdapter';
import { ImageKnowledgeService } from '../application/ImageKnowledgeService';
import { UnifiedVectorRepository } from './UnifiedVectorRepository';
import { UnifiedEmbeddingService } from '../application/UnifiedEmbeddingService';
import { UnifiedProcessingQueue } from '../application/UnifiedProcessingQueue';
import { UnifiedSettingsService } from '../application/UnifiedSettingsService';
import { UnifiedEmbeddingConfigPort } from '../domain/UnifiedEmbeddingPorts';
import { EmbeddingConfig } from '../domain/EmbeddingModels';
import { LegacyParsedDocumentReader } from './LegacyParsedDocumentReader';
import { ParsedDocumentMigrationService } from '../application/ParsedDocumentMigrationService';
import { UnifiedQueryRepository } from './UnifiedQueryRepository';
import { UnifiedQueryService } from '../application/UnifiedQueryService';
import { KnowledgeQuerySession } from '../application/KnowledgeQuerySession';
import { UnifiedKnowledgeHistoryRepository } from './UnifiedKnowledgeHistoryRepository';

export { KnowledgePlatformIdentity } from './KnowledgeIdentity';
class UnifiedAssemblyEmbeddingConfig implements UnifiedEmbeddingConfigPort {
  private service: EmbeddingService;
  constructor(service: EmbeddingService) { this.service=service; }
  currentConfig(): EmbeddingConfig { return this.service.state.config; }
}

export class KnowledgeAssembly {
  sources: PdfSourceSession = new PdfSourceSession();
  private static sessions: KnowledgeAssembly[] = [];
  private static processSession: string = new KnowledgePlatformIdentity().id();
  private scope: string;
  host: KnowledgeStoreHost;
  unified: ParsedDocumentRepository;
  unifiedAssets: ParsedDocumentAssets;
  unifiedIngestion: ParsedDocumentIngestionService;
  unifiedImports: ParsedDocumentImportAdapter;
  imageKnowledge: ImageKnowledgeService;
  unifiedVectors: UnifiedVectorRepository;
  unifiedEmbedding: UnifiedEmbeddingService;
  unifiedQueue: UnifiedProcessingQueue;
  unifiedSettings: UnifiedSettingsService;
  migration: ParsedDocumentMigrationService;
  querySession: KnowledgeQuerySession;
  unifiedHistory: UnifiedKnowledgeHistoryRepository;
  unifiedLifecycle: ParsedDocumentLifecycle;
  unifiedMessage: string = '';
  text: TextKnowledgeAssembly;
  repository: PdfKnowledgeRepository;
  images: ImageKnowledgeRepository; imageSources: ImageSourceSession; sourceRegistry: KnowledgeSourceRegistry;
  docx: DocxKnowledgeRepository; docxSources: DocxSourceSession; docxVectors: DocxVectorRepository;
  lifecycle: KnowledgeLifecycleService;
  embedding: EmbeddingService;
  ingestion: PdfIngestionService;
  search: KnowledgeSearchService;
  derivedLifecycle: KnowledgeDerivedLifecycle;
  assets: PdfAssetAdapter;
  pages: PdfPageReferenceService;
  vectors: VectorRdbRepository; vectorMetadata: PdfVectorRepository; workflow: EmbeddingWorkflow;
  private sessionId: string = KnowledgeAssembly.processSession;
  extensionMessage: string = '';
  private leases: number = 0;
  private initializing: Promise<void> | undefined = undefined;
  private closing: Promise<void> | undefined = undefined;
  private gate: Promise<void> = Promise.resolve();
  private listeners: Array<() => void> = [];
  private constructor(context: common.Context) {
    KnowledgeCapabilityService.attachContext(context);
    this.scope = context.filesDir; this.host = KnowledgeStoreHost.forContext(context);
    this.host.requireUnifiedProtection();
    this.unified = new ParsedDocumentRepository(this.host,new KnowledgePlatformIdentity());
    this.unifiedAssets = new ParsedDocumentAssets(context.filesDir,context.cacheDir,KnowledgeStorageScope.production(),this.unified,new KnowledgePlatformIdentity(),this.sessionId);
    this.unified.attachPublicationVerifier(this.unifiedAssets);
    this.unifiedIngestion = new ParsedDocumentIngestionService(this.unified,this.unifiedAssets,new KnowledgePlatformIdentity());
    this.unifiedImports = new ParsedDocumentImportAdapter(context,this.host,new KnowledgePlatformIdentity(),this.unifiedIngestion);
    this.migration=new ParsedDocumentMigrationService(new LegacyParsedDocumentReader(context,this.host,new KnowledgePlatformIdentity()),this.unified,this.unifiedAssets,new KnowledgePlatformIdentity());
    this.text = new TextKnowledgeAssembly(context, (): void => { this.changed(); }, this.host);
    this.text.service.attachUnifiedImport(async (): Promise<void> => { await this.unifiedImports.importText(); this.changed(); });
    this.text.service.attachBeforeCleanup(async (): Promise<void> => {
      try { await this.unified.open(); await this.unified.recoverReadLeases(this.sessionId); await this.unifiedAssets.reconcile(new ParsedCancellation()); this.unifiedMessage = ''; }
      catch { this.unifiedMessage = '统一布局或资产恢复未完成，旧资产清理已暂停；已有正文保留'; throw new KnowledgeFailure('UnifiedProtectionUnavailable','startup'); }
    });
    this.repository = new PdfKnowledgeRepository(this.host); this.lifecycle = new KnowledgeLifecycleService(this.repository);
    this.lifecycle.attachUnifiedProtection(async (assets: string[]): Promise<void> => { await this.host.assertUnifiedUnheld('DocumentParseService',assets); });
    this.images = new ImageKnowledgeRepository(this.host); this.imageSources = new ImageSourceSession(this.images,new ImageOriginalAdapter(context.filesDir),new KnowledgePlatformIdentity());
    this.images.attachIdentity(new KnowledgePlatformIdentity());
    const imageAssets: ImageSnapshotAssets = new ImageSnapshotAssets(context.filesDir,context.cacheDir,KnowledgeStorageScope.production());
    imageAssets.attachCleanupGuard(async (assets: string[], action: () => Promise<void>): Promise<void> => { await this.host.withUnifiedCleanup<void>('ImageSnapshotAssets',assets,action); });
    this.images.attachSnapshotAssets(imageAssets);
    this.docx = new DocxKnowledgeRepository(this.host); this.docxSources = new DocxSourceSession(this.docx,new KnowledgePlatformIdentity(),async (original: DocxOriginal, cancel: KnowledgeCancellation): Promise<void> => {
      const token: DocumentParseCancellation = new DocumentParseCancellation(); token.deadline = cancel.deadline;
      if (await documentHashFile(documentAssetPath(`${context.filesDir}/knowledge_parse_v1`,original.assetId),20*1024*1024,token) !== original.hash) { throw new KnowledgeFailure('DocxOriginalChangedOrMissing','source'); } cancel.check();
    });
    this.lifecycle.attachDocxProtection(async (assets: string[]): Promise<void> => { if (!this.docx.ready()) { throw new KnowledgeFailure('DocxProtectionUnavailable','cleanup'); } await this.docx.assertUnpinned(assets); });
    this.lifecycle.attachImageProtection(async (assets: string[]): Promise<void> => { if (!this.images.ready()) { throw new KnowledgeFailure('ImageProtectionUnavailable','cleanup'); } await this.images.assertUnpinned(assets); });
    this.sourceRegistry = new KnowledgeSourceRegistry(this.host,new KnowledgePlatformIdentity());
    for (const kind of ['Text','Pdf','Image']) { this.sourceRegistry.register(new KnowledgeSqlSourceReader(kind,this.host,new KnowledgePlatformIdentity(),this.text.repository,this.repository,this.images)); }
    this.sourceRegistry.register(new DocxSourceReader(this.docx,new KnowledgePlatformIdentity(),this.host,async (original: DocxOriginal, cancel: KnowledgeCancellation): Promise<void> => {
      const token: DocumentParseCancellation = new DocumentParseCancellation(); token.deadline = cancel.deadline;
      if (await documentHashFile(documentAssetPath(`${context.filesDir}/knowledge_parse_v1`,original.assetId),20*1024*1024,token) !== original.hash) { throw new KnowledgeFailure('DocxOriginalChangedOrMissing','scope'); } cancel.check();
    }));
    const credential: EmbeddingCredentialStore = new EmbeddingCredentialStore();
    const transport: EmbeddingTransportAdapter = new EmbeddingTransportAdapter(credential,new KnowledgePlatformIdentity());
    transport.attachQueryAdmission(this.sourceRegistry);
    this.embedding = new EmbeddingService(this.repository,credential,transport,new KnowledgePlatformIdentity());
    this.vectors = new VectorRdbRepository(context); this.vectorMetadata = new ImageVectorRepository(this.host,this.repository,this.images);
    const budget: KnowledgeDerivedBudget = new KnowledgeDerivedBudget(context); this.vectorMetadata.attachPhysical(budget); this.repository.attachPhysicalBudget(budget);
    this.unified.attachPhysicalBudget(budget);
    this.images.attachPhysicalBudget(budget);
    const docxAssets: DocxSnapshotAssets = new DocxSnapshotAssets(context.filesDir,context.cacheDir,KnowledgeStorageScope.production(),new KnowledgePlatformIdentity());
    docxAssets.attachCleanupGuard(async (assets: string[], action: () => Promise<void>): Promise<void> => { await this.host.withUnifiedCleanup<void>('DocxSnapshotAssets',assets,action); });
    this.docx.attachAssets(new KnowledgePlatformIdentity(),docxAssets,budget);
    this.docxVectors = new DocxVectorRepository(this.host,this.docx,this.vectorMetadata);
    const counter: EmbeddingTokenAdapter = new EmbeddingTokenAdapter(context,new KnowledgePlatformIdentity()); transport.attachInputPolicy(counter,this.docxVectors);
    transport.attachUnifiedCounter(counter);
    const visionCredential: VisionCredentialStore=new VisionCredentialStore();
    this.imageKnowledge=new ImageKnowledgeService(this.unified,this.unifiedAssets,this.unified,new KnowledgePlatformIdentity(),new VisionTransportAdapter(visionCredential,new KnowledgePlatformIdentity()));
    this.unifiedVectors=new UnifiedVectorRepository(this.unified,this.vectors,new KnowledgePlatformIdentity());
    const unifiedConfig: UnifiedAssemblyEmbeddingConfig=new UnifiedAssemblyEmbeddingConfig(this.embedding);
    this.unifiedEmbedding=new UnifiedEmbeddingService(this.unified,this.unifiedVectors,counter,transport,unifiedConfig,new KnowledgePlatformIdentity());
    this.unifiedQueue=new UnifiedProcessingQueue(this.unified,this.unified,this.unifiedAssets,new KnowledgePlatformIdentity(),this.imageKnowledge,this.unifiedEmbedding);
    this.unifiedSettings=new UnifiedSettingsService(this.unified,visionCredential,unifiedConfig,this.unifiedQueue);
    const queryRepository: UnifiedQueryRepository=new UnifiedQueryRepository(this.host,this.unified,this.vectors,unifiedConfig,new KnowledgePlatformIdentity());
    this.sourceRegistry.attachUnifiedAdmission(queryRepository); transport.attachUnifiedQuery(counter,this.sourceRegistry);
    const queryEngine: UnifiedQueryService=new UnifiedQueryService(queryRepository,queryRepository,this.unified,this.vectors,unifiedConfig,counter,transport,new KnowledgePlatformIdentity());
    this.unifiedHistory=new UnifiedKnowledgeHistoryRepository(this.unified,this.unifiedAssets,queryRepository);
    this.querySession=new KnowledgeQuerySession(queryRepository,queryEngine,unifiedConfig,this.unifiedHistory,new KnowledgePlatformIdentity());
    this.unifiedLifecycle=new ParsedDocumentLifecycle(this.unified,this.unifiedAssets,this.unifiedVectors,(): void=> { this.querySession.invalidate(); },(): void=> { this.changed(); });
    this.unifiedQueue.attachSettled(async (): Promise<void>=> { await this.unifiedLifecycle.sync(); });
    this.unifiedIngestion.attachPublished(async (document: ParsedDocument): Promise<void>=> { await this.unifiedLifecycle.sync(); await this.unifiedQueue.enqueue(document); });
    this.workflow = new EmbeddingWorkflow(this.docxVectors,this.vectors,transport,new KnowledgePlatformIdentity(),this.repository,new KnowledgeReadDispatcher(this.repository,this.images,this.docx,this.host),this.sessionId,counter);
    this.embedding.attachWorkflow(this.workflow);
    this.assets = new PdfAssetAdapter(context.filesDir,context.cacheDir,this.repository);
    this.assets.attachCleanupGuard(async (assets: string[], action: () => Promise<void>): Promise<void> => { await this.host.withUnifiedCleanup<void>('PdfAssetAdapter',assets,action); });
    this.pages = new PdfPageReferenceService(this.repository,this.assets,new KnowledgePlatformIdentity(),this.sessionId,async (binding: PdfSourceBinding,cancel: KnowledgeCancellation): Promise<void> => {
      const token = new DocumentParseCancellation(); token.deadline = cancel.deadline;
      if (await documentHashFile(documentAssetPath(`${context.filesDir}/knowledge_parse_v1`,binding.originalAssetId),20971520,token) !== binding.originalHash) { throw new KnowledgeFailure('PageOriginalUnavailableOrChanged','page'); } cancel.check();
    });
    this.ingestion = new PdfIngestionService(this.repository,this.lifecycle,new PdfArchiveAdapter(context.filesDir),new PdfProcessingAdapter(),this.assets,new KnowledgePlatformIdentity());
    this.ingestion.attachUnifiedConsumer(async (parse: DocumentParseService, result: string): Promise<void> => { await this.unifiedImports.consume(parse,result); });
    this.ingestion.attachSession(this.sessionId);
    this.search = new KnowledgeSearchService(this.text.repository,this.repository,new KnowledgePlatformIdentity());
    this.search.attachScope(this.sourceRegistry);
    this.search.attachLegacyHistory(this.text.repository);
    this.search.attachSemantic(this.workflow);
    this.search.attachPages(this.pages);
    this.search.attachUnifiedSession(this.querySession); this.unifiedHistory.attachLegacy(this.search);
    this.derivedLifecycle = new KnowledgeDerivedLifecycle(this.lifecycle,this.repository,this.assets);
    this.derivedLifecycle.attachVectors(this.vectors);
    this.derivedLifecycle.attachMirror(this.workflow);
  }
  static forContext(context: common.Context): KnowledgeAssembly {
    const existing: KnowledgeAssembly | undefined = KnowledgeAssembly.sessions.find((session: KnowledgeAssembly): boolean => session.scope === context.filesDir);
    if (existing !== undefined) { return existing; }
    const session: KnowledgeAssembly = new KnowledgeAssembly(context); KnowledgeAssembly.sessions.push(session); return session;
  }
  subscribe(listener: () => void): void { if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); } }
  unsubscribe(listener: () => void): void { this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener); }
  changed(): void { for (const listener of this.listeners) { listener(); } }
  sourceReadLease(sourceId: string, generation: string): KnowledgeReadLease {
    const lease: KnowledgeReadLease = new KnowledgeReadLease(); lease.id = new KnowledgePlatformIdentity().id(); lease.sourceId = sourceId; lease.generation = generation; lease.sessionId = this.sessionId; return lease;
  }
  private async start(): Promise<void> {
    await this.text.initialize(true);
    this.extensionMessage = this.unifiedMessage;
    try { await this.repository.open(); await this.images.open(); }
    catch (error) { this.extensionMessage = '资料扩展打开未完成：'+this.localFailure(error); }
    if (this.repository.ready() && this.images.ready()) {
      try { await this.docx.open(); }
      catch (error) { this.extensionMessage = 'DOCX扩展打开未完成：'+this.localFailure(error); }
    }
    if (this.unified.ready() && this.unifiedMessage.length === 0) {
      try { await this.text.service.recoverLocal(); }
      catch { this.extensionMessage = '旧正文恢复未完成，原件与已存正文保留'; }
    }
    if (this.repository.ready() && this.images.ready()) {
      try { await this.vectorMetadata.bootstrap(); await this.repository.reconcile(this.sessionId); await this.assets.reconcile(); await this.ingestion.refreshJobs(); }
      catch (error) { this.extensionMessage = '本机任务恢复待核，原件导入仍可使用：'+this.localFailure(error); }
      try { await this.embedding.initialize(); }
      catch (error) { this.extensionMessage = '嵌入设置初始化未完成，文件解析仍可使用：'+this.localFailure(error); }
    }
    if (this.repository.ready()) { for (const document of await this.repository.list()) { if (!document.tombstone && document.activeVectorGeneration.length > 0) { try { await this.workflow.restoreActive(document.id); } catch { this.extensionMessage = '关键词可用；活动向量读回或镜像恢复未确认，向量路保持降级'; } } } }
    if (this.images.ready()) { for (const document of await this.images.list()) { if (!document.tombstone && document.chunkCount > 0) { try { await this.workflow.restoreActive(document.id); } catch { this.extensionMessage = '图片关键词保留；图片向量读回未确认'; } } } }
    if (this.docx.ready()) { for (const document of await this.docx.list()) { if (!document.tombstone && document.chunkCount > 0) { try { await this.workflow.restoreActive(document.id); } catch { this.extensionMessage = 'DOCX关键词保留；向量镜像读回未确认'; } } } }
    if (this.unified.ready()) { try { await this.unifiedLifecycle.sync(); await this.unifiedQueue.initialize(); } catch { this.unifiedMessage='增强队列恢复失败；正文保留，可重试'; } try { await this.unifiedHistory.recoverPending(); } catch { this.unifiedMessage+='；历史回执恢复待重试，检索不受阻'; } }
  }
  private localFailure(error: Object): string {
    if (error instanceof DocxFailure || error instanceof KnowledgeFailure || error instanceof ImageKnowledgeFailure) {
      return `${error.category} · ${error.stage}`;
    }
    return 'LocalInitializationFailed';
  }
  async ensureDocxReady(): Promise<void> {
    if (!this.repository.ready()) { await this.repository.open(); }
    if (!this.images.ready()) { await this.images.open(); }
    if (!this.docx.ready()) { await this.docx.open(); }
    if (!this.docx.ready()) { throw new DocxFailure('DocxStoreNotReady','docx-open'); }
  }
  async retryUnifiedInitialization(): Promise<void> {
    await this.unified.open(); await this.unifiedAssets.reconcile(new ParsedCancellation());
    await this.text.service.recoverLocal(); this.unifiedMessage = ''; this.extensionMessage = ''; this.changed();
  }
  async retryUnifiedProcessing(): Promise<void> { await this.unifiedQueue.stop(); await this.retryUnifiedInitialization(); await this.unifiedLifecycle.sync(); await this.unifiedQueue.initialize(); await this.unifiedIngestion.refresh(); }
  async acquire(): Promise<void> {
    const operation = this.gate.then(async (): Promise<void> => { if (this.initializing === undefined) { this.initializing = this.start(); } const initializing: Promise<void> = this.initializing; await initializing; this.leases++; }); this.gate = operation.then((): void => {},(_error: Error): void => {}); await operation;
  }
  async release(): Promise<void> {
    const operation = this.gate.then(async (): Promise<void> => { if (this.leases <= 0) { return; } if (this.leases === 1) { this.closing = this.closeSession(); const closing: Promise<void> = this.closing; try { await closing; } finally { this.closing = undefined; } } this.leases--; }); this.gate = operation.then((): void => {},(_error: Error): void => {}); await operation;
  }
  async retrySourceReleases(): Promise<void> { await this.sources.retry(); if (this.repository.ready()) { await this.repository.retrySourceReleases(this.sessionId); this.pages.releaseRetried(); } }
  async cleanupDocx(parse: DocumentParseService): Promise<void> {
    if (parse.state.busy) { throw new KnowledgeFailure('ParseOwnerStillRunning','docx-cleanup'); }
    for (const document of await this.docx.list()) { if (document.tombstone) { await this.docxVectors.cleanupDeleted(document.id,this.vectors); } }
    for (const intent of await this.docx.cleanups()) {
      if (intent.state === 'Done') { continue; }
      const claim: DocxCleanupIntent | undefined = await this.docx.claimCleanup(intent.id); if (claim === undefined) { continue; }
      let failure: string = '';
      try {
        if (claim.owner === 'DocxSnapshotAssets') { await this.docx.removeSnapshotClaim(claim); }
        else if (claim.owner === 'DocumentParseService') {
          const originals: DocumentOriginal[] = parse.viewState().snapshot.originals.filter((o: DocumentOriginal): boolean => o.assetId === claim.assetId);
          if (originals.length > 0) {
            await parse.deleteOriginal(originals[0].id);
            if (parse.viewState().snapshot.originals.some((o: DocumentOriginal): boolean => o.id === originals[0].id)) { throw new KnowledgeFailure('ParseOwnerCleanupPending','docx-cleanup'); }
          } else if (parse.viewState().snapshot.results.some((r: DocumentParseResultEnvelope): boolean => r.assetId === claim.assetId)) { throw new KnowledgeFailure('ParseOriginalCleanupFirst','docx-cleanup'); }
          await parse.retryCleanup();
          if (parse.viewState().snapshot.cleanup.some((c: DocumentParseCleanup): boolean => c.assets.indexOf(claim.assetId) >= 0)) { throw new KnowledgeFailure('ParsePhysicalCleanupPending','docx-cleanup'); }
        } else { throw new KnowledgeFailure('UnknownOwnerQuarantined','docx-cleanup'); }
      } catch (error) { failure = error instanceof Error ? error.message : 'DocxCleanupPending'; }
      await this.docx.finishCleanup(claim,failure);
    }
  }
  private async closeSession(): Promise<void> {
       await this.quiesceUnified();
       await this.retrySourceReleases(); await this.imageSources.close(); await this.docxSources.close();
        this.embedding.pause(); this.ingestion.pause(); this.search.pause(); this.pages.pause();
       if (this.workflow.releasing) { throw new Error('KnowledgeReadLeaseReleaseUnconfirmed'); }
       const deadline: number = Date.now()+120000;
        while (this.embedding.state.busy || this.ingestion.state.busy || this.ingestion.state.releasing || this.search.state.busy || this.pages.reading()) { if (Date.now() >= deadline) { throw new Error('KnowledgeSessionReleaseUnconfirmed'); } await new Promise<void>((resolve: () => void): void => { setTimeout(resolve,20); }); }
        await this.retrySourceReleases();
       this.pages.clearCache(); await this.vectors.close(); await this.docx.close(); await this.images.close(); await this.repository.close(); await this.unified.close(); await this.text.close(); this.initializing = undefined;
  }
   async quiesceUnified(): Promise<void> { this.unifiedIngestion.pause(); this.migration.pause(); await this.querySession.close(); await this.unifiedQueue.stop(); await this.migration.close(); await this.unifiedIngestion.stop(); }
   static foreground(): void { for (const session of KnowledgeAssembly.sessions) { session.unifiedQueue.resumeForeground(); } }
   static background(): void { for (const session of KnowledgeAssembly.sessions) { session.querySession.invalidate(); session.migration.pause(); session.unifiedQueue.background(); session.unifiedIngestion.pause(); session.unifiedIngestion.closePreview().catch((): void => {}); session.docxSources.invalidate(); session.docxSources.close().catch((): void => {}); session.imageSources.pause(); session.imageSources.close().catch((): void => {}); session.sources.background(); session.embedding.pause(); session.ingestion.pause(); session.search.pause(); session.pages.pause(); } }
}
