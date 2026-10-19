import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { KnowledgeReadLease } from '../domain/PdfKnowledgeModels';
import { documentDigestHex, documentAssetPath, documentHashFile } from './DocumentFileOperations';
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
import { KnowledgeLifecycleService, KnowledgeDerivedLifecycle } from '../application/KnowledgeLifecycleService';
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

export class KnowledgePlatformIdentity implements KnowledgeIdentityPort {
  id(): string { return 'kb-' + documentDigestHex(cryptoFramework.createRandom().generateRandomSync(16).data); }
  async hash(bytes: Uint8Array): Promise<string> {
    const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const blob: cryptoFramework.DataBlob = { data: bytes };
    await digest.update(blob); return documentDigestHex((await digest.digest()).data);
  }
}

export class KnowledgeAssembly {
  sources: PdfSourceSession = new PdfSourceSession();
  private static sessions: KnowledgeAssembly[] = [];
  private static processSession: string = new KnowledgePlatformIdentity().id();
  private scope: string;
  host: KnowledgeStoreHost;
  text: TextKnowledgeAssembly;
  repository: PdfKnowledgeRepository;
  images: ImageKnowledgeRepository; imageSources: ImageSourceSession; sourceRegistry: KnowledgeSourceRegistry;
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
    this.text = new TextKnowledgeAssembly(context, (): void => { this.changed(); }, this.host);
    this.repository = new PdfKnowledgeRepository(this.host); this.lifecycle = new KnowledgeLifecycleService(this.repository);
    this.images = new ImageKnowledgeRepository(this.host); this.imageSources = new ImageSourceSession(this.images,new ImageOriginalAdapter(context.filesDir),new KnowledgePlatformIdentity());
    this.images.attachIdentity(new KnowledgePlatformIdentity());
    this.images.attachSnapshotAssets(new ImageSnapshotAssets(context.filesDir,context.cacheDir,KnowledgeStorageScope.production()));
    this.lifecycle.attachImageProtection(async (assets: string[]): Promise<void> => { if (!this.images.ready()) { throw new KnowledgeFailure('ImageProtectionUnavailable','cleanup'); } await this.images.assertUnpinned(assets); });
    this.sourceRegistry = new KnowledgeSourceRegistry(this.host,new KnowledgePlatformIdentity());
    for (const kind of ['Text','Pdf','Image']) { this.sourceRegistry.register(new KnowledgeSqlSourceReader(kind,this.host,new KnowledgePlatformIdentity(),this.text.repository,this.repository,this.images)); }
    const credential: EmbeddingCredentialStore = new EmbeddingCredentialStore();
    const transport: EmbeddingTransportAdapter = new EmbeddingTransportAdapter(credential,new KnowledgePlatformIdentity());
    transport.attachQueryAdmission(this.sourceRegistry);
    this.embedding = new EmbeddingService(this.repository,credential,transport,new KnowledgePlatformIdentity());
    this.vectors = new VectorRdbRepository(context); this.vectorMetadata = new ImageVectorRepository(this.host,this.repository,this.images);
    const budget: KnowledgeDerivedBudget = new KnowledgeDerivedBudget(context); this.vectorMetadata.attachPhysical(budget); this.repository.attachPhysicalBudget(budget);
    this.images.attachPhysicalBudget(budget);
    const counter: EmbeddingTokenAdapter = new EmbeddingTokenAdapter(context,new KnowledgePlatformIdentity()); transport.attachInputPolicy(counter,this.vectorMetadata);
    this.workflow = new EmbeddingWorkflow(this.vectorMetadata,this.vectors,transport,new KnowledgePlatformIdentity(),this.repository,new KnowledgeReadDispatcher(this.repository,this.images),this.sessionId,counter);
    this.embedding.attachWorkflow(this.workflow);
    this.assets = new PdfAssetAdapter(context.filesDir,context.cacheDir,this.repository);
    this.pages = new PdfPageReferenceService(this.repository,this.assets,new KnowledgePlatformIdentity(),this.sessionId,async (binding: PdfSourceBinding,cancel: KnowledgeCancellation): Promise<void> => {
      const token = new DocumentParseCancellation(); token.deadline = cancel.deadline;
      if (await documentHashFile(documentAssetPath(`${context.filesDir}/knowledge_parse_v1`,binding.originalAssetId),20971520,token) !== binding.originalHash) { throw new KnowledgeFailure('PageOriginalUnavailableOrChanged','page'); } cancel.check();
    });
    this.ingestion = new PdfIngestionService(this.repository,this.lifecycle,new PdfArchiveAdapter(context.filesDir),new PdfProcessingAdapter(),this.assets,new KnowledgePlatformIdentity());
    this.ingestion.attachSession(this.sessionId);
    this.search = new KnowledgeSearchService(this.text.repository,this.repository,new KnowledgePlatformIdentity());
    this.search.attachScope(this.sourceRegistry);
    this.search.attachLegacyHistory(this.text.repository);
    this.search.attachSemantic(this.workflow);
    this.search.attachPages(this.pages);
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
    await this.text.initialize();
    try { await this.repository.open(); await this.images.open(); await this.vectorMetadata.bootstrap(); await this.repository.reconcile(this.sessionId); await this.assets.reconcile(); await this.embedding.initialize(); await this.ingestion.refreshJobs(); this.extensionMessage = ''; }
    catch { this.host.extensionReady = false; this.extensionMessage = 'PDF 扩展不可用，M1 保持可读；解析副本删除与清理已保护性暂停'; }
    if (this.repository.ready()) { for (const document of await this.repository.list()) { if (!document.tombstone && document.activeVectorGeneration.length > 0) { try { await this.workflow.restoreActive(document.id); } catch { this.extensionMessage = '关键词可用；活动向量读回或镜像恢复未确认，向量路保持降级'; } } } }
    if (this.images.ready()) { for (const document of await this.images.list()) { if (!document.tombstone && document.chunkCount > 0) { try { await this.workflow.restoreActive(document.id); } catch { this.extensionMessage = '图片关键词保留；图片向量读回未确认'; } } } }
  }
  async acquire(): Promise<void> {
    const operation = this.gate.then(async (): Promise<void> => { if (this.initializing === undefined) { this.initializing = this.start(); } await this.initializing; this.leases++; }); this.gate = operation.then((): void => {},(_error: Error): void => {}); await operation;
  }
  async release(): Promise<void> {
    const operation = this.gate.then(async (): Promise<void> => { if (this.leases <= 0) { return; } if (this.leases === 1) { this.closing = this.closeSession(); try { await this.closing; } finally { this.closing = undefined; } } this.leases--; }); this.gate = operation.then((): void => {},(_error: Error): void => {}); await operation;
  }
  async retrySourceReleases(): Promise<void> { await this.sources.retry(); if (this.repository.ready()) { await this.repository.retrySourceReleases(this.sessionId); this.pages.releaseRetried(); } }
  private async closeSession(): Promise<void> {
       await this.retrySourceReleases(); await this.imageSources.close();
        this.embedding.pause(); this.ingestion.pause(); this.search.pause(); this.pages.pause();
       if (this.workflow.releasing) { throw new Error('KnowledgeReadLeaseReleaseUnconfirmed'); }
       const deadline: number = Date.now()+120000;
        while (this.embedding.state.busy || this.ingestion.state.busy || this.ingestion.state.releasing || this.search.state.busy || this.pages.reading()) { if (Date.now() >= deadline) { throw new Error('KnowledgeSessionReleaseUnconfirmed'); } await new Promise<void>((resolve: () => void): void => { setTimeout(resolve,20); }); }
        await this.retrySourceReleases();
       this.pages.clearCache(); await this.vectors.close(); await this.images.close(); await this.repository.close(); await this.text.close(); this.initializing = undefined;
  }
   static background(): void { for (const session of KnowledgeAssembly.sessions) { session.imageSources.pause(); session.imageSources.close().catch((): void => {}); session.sources.background(); session.embedding.pause(); session.ingestion.pause(); session.search.pause(); session.pages.pause(); } }
}
