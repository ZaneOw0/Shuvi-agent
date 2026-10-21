import { KnowledgeSourceProtectionPort } from '../domain/KnowledgePorts';
import {
  KnowledgeFailure, PdfKnowledgeDocument, PdfIngestionJob, KnowledgePin, KnowledgeReadLease, KnowledgeCleanupIntent, KnowledgeCleanupTarget
} from '../domain/PdfKnowledgeModels';
import { ParsedLifecycleRepositoryPort, ParsedLifecycleAssetsPort, ParsedLifecycleMirrorPort } from '../domain/ParsedLifecyclePorts';
import { ParsedFailure } from '../domain/ParsedDocumentModels';

export interface KnowledgePinRepository {
  ready(): boolean;
  register(document: PdfKnowledgeDocument, job: PdfIngestionJob, pins: KnowledgePin[]): Promise<PdfIngestionJob>;
  pins(sourceId: string, assetIds: string[]): Promise<KnowledgePin[]>;
  assertNoReaders(assetIds: string[]): Promise<void>;
  acquireRead(lease: KnowledgeReadLease): Promise<void>; releaseRead(id: string): Promise<void>;
}
export class KnowledgeLifecycleService implements KnowledgeSourceProtectionPort {
  private repository: KnowledgePinRepository;
  private imageProtection: ((assets: string[]) => Promise<void>) | undefined = undefined;
  private docxProtection: ((assets: string[]) => Promise<void>) | undefined = undefined;
  private unifiedProtection: ((assets: string[]) => Promise<void>) | undefined = undefined;
  attachUnifiedProtection(check: (assets: string[]) => Promise<void>): void { this.unifiedProtection = check; }
  attachImageProtection(check: (assets: string[]) => Promise<void>): void { this.imageProtection = check; }
  attachDocxProtection(check: (assets: string[]) => Promise<void>): void { this.docxProtection = check; }
  // A single queue is deliberately stronger than per-source locking. Cleanup records
  // may contain several sources; keeping them together prevents lock-order races.
  private tail: Promise<void> = Promise.resolve();
  constructor(repository: KnowledgePinRepository) { this.repository = repository; }
  withSource<T>(_sourceId: string, action: () => Promise<T>): Promise<T> {
    const result: Promise<T> = this.tail.then(action);
    this.tail = result.then((): void => {}, (_error: Error): void => {}); return result;
  }
  private requireReady(): void { if (!this.repository.ready()) { throw new KnowledgeFailure('ProtectionUnavailable', 'source-lifecycle'); } }
  async assertDeletable(sourceId: string, assetIds: string[]): Promise<void> {
    if (this.unifiedProtection !== undefined) { await this.unifiedProtection(assetIds); }
    this.requireReady();
    if (this.imageProtection !== undefined) { await this.imageProtection(assetIds); }
    if (this.docxProtection !== undefined) { await this.docxProtection(assetIds); }
    if ((await this.repository.pins(sourceId, assetIds)).length > 0) { throw new KnowledgeFailure('KnowledgeSourcePinned', 'source-delete'); }
    if (assetIds.length > 0) { await this.repository.assertNoReaders(assetIds); }
  }
  async assertCleanup(assetIds: string[]): Promise<void> { await this.assertDeletable('', assetIds); }
  async prepare(document: PdfKnowledgeDocument, job: PdfIngestionJob, pins: KnowledgePin[], verifySource: () => Promise<void>): Promise<PdfIngestionJob> {
    return this.withSource<PdfIngestionJob>(job.sourceId, async (): Promise<PdfIngestionJob> => {
      this.requireReady(); await verifySource();
      return this.repository.register(document, job, pins);
    });
  }
  async read<T>(lease: KnowledgeReadLease, action: () => Promise<T>): Promise<T> {
    await this.withSource<void>(lease.sourceId, async (): Promise<void> => { this.requireReady(); await this.repository.acquireRead(lease); });
    try { return await action(); } finally { await this.repository.releaseRead(lease.id); }
  }
}

export interface KnowledgeLifecycleRepository extends KnowledgePinRepository {
  archive(id: string, archived: boolean): Promise<void>; deleteDocument(id: string): Promise<void>; abandon(jobId: string): Promise<void>;
  cleanups(): Promise<KnowledgeCleanupIntent[]>; claimCleanup(id: string): Promise<KnowledgeCleanupIntent | undefined>;
  finishCleanup(claim: KnowledgeCleanupIntent, failure: string): Promise<void>;
  finishVectorTarget?(claim: KnowledgeCleanupIntent, target: KnowledgeCleanupTarget, failure: string): Promise<void>;
  retireVectorGeneration?(generation: string): Promise<void>;
  retireContent?(generation: string): Promise<void>;
}
export interface KnowledgeDerivedCleanupPort { remove(claim: KnowledgeCleanupIntent): Promise<void>; }
export interface KnowledgeVectorCleanupPort { open(): Promise<void>; removeTarget(claim: KnowledgeCleanupIntent, spaceId: string, generation: string): Promise<void>; }
export interface KnowledgeVectorMirrorPort { sync(documentId: string): Promise<void>; }
export class KnowledgeDerivedLifecycle {
  private coordinator: KnowledgeLifecycleService; private repository: KnowledgeLifecycleRepository; private assets: KnowledgeDerivedCleanupPort;
  constructor(coordinator: KnowledgeLifecycleService, repository: KnowledgeLifecycleRepository, assets: KnowledgeDerivedCleanupPort) { this.coordinator = coordinator; this.repository = repository; this.assets = assets; }
  private vectors: KnowledgeVectorCleanupPort | undefined;
  private mirror: KnowledgeVectorMirrorPort | undefined;
  attachVectors(vectors: KnowledgeVectorCleanupPort): void { this.vectors = vectors; }
  attachMirror(mirror: KnowledgeVectorMirrorPort): void { this.mirror = mirror; }
  async archive(id: string, archived: boolean): Promise<void> { await this.coordinator.withSource<void>(id,async (): Promise<void> => { await this.repository.archive(id,archived); }); await this.mirror?.sync(id); }
  async deleteDocument(id: string): Promise<void> { await this.coordinator.withSource<void>(id,async (): Promise<void> => { await this.repository.deleteDocument(id); }); await this.cleanup(); }
  async abandon(jobId: string): Promise<void> { await this.coordinator.withSource<void>(jobId,async (): Promise<void> => { await this.repository.abandon(jobId); }); await this.cleanup(); }
  async retireVector(generation: string): Promise<void> { if (this.repository.retireVectorGeneration === undefined) { throw new KnowledgeFailure('VectorRetirementUnavailable','lifecycle'); } await this.repository.retireVectorGeneration(generation); await this.cleanup(); }
  async retireContent(generation: string): Promise<void> { if (this.repository.retireContent === undefined) { throw new KnowledgeFailure('ContentRetirementUnavailable','lifecycle'); } await this.repository.retireContent(generation); await this.cleanup(); }
  async cleanup(): Promise<void> {
    for (const intent of await this.repository.cleanups()) {
      const claim: KnowledgeCleanupIntent | undefined = await this.repository.claimCleanup(intent.id); if (claim === undefined) { continue; }
      let failure: string = '';
      for (const target of claim.vectorTargets) {
        if (target.state === 'Done') { continue; }
        let targetFailure: string = '';
        try { if (this.vectors === undefined || this.repository.finishVectorTarget === undefined) { throw new KnowledgeFailure('VectorCleanupUnavailable','cleanup'); } await this.vectors.open(); await this.vectors.removeTarget(claim,target.spaceId,target.vectorGeneration); }
        catch (error) { targetFailure = error instanceof KnowledgeFailure ? error.category : 'VectorPhysicalCleanupFailed'; failure = targetFailure; }
        if (this.repository.finishVectorTarget !== undefined) { await this.repository.finishVectorTarget(claim,target,targetFailure); }
      }
      if (failure.length > 0) { await this.repository.finishCleanup(claim,failure); continue; }
      try { await this.assets.remove(claim); } catch { failure = 'DerivedCleanupPending'; }
      await this.repository.finishCleanup(claim,failure);
    }
  }
}
export class ParsedDocumentLifecycle {
  private repository: ParsedLifecycleRepositoryPort; private assets: ParsedLifecycleAssetsPort; private mirror: ParsedLifecycleMirrorPort;
  private invalidate: () => void; private changed: () => void;
  message: string='';
  constructor(repository: ParsedLifecycleRepositoryPort, assets: ParsedLifecycleAssetsPort, mirror: ParsedLifecycleMirrorPort, invalidate: () => void, changed: () => void) { this.repository=repository; this.assets=assets; this.mirror=mirror; this.invalidate=invalidate; this.changed=changed; }
  async archive(id: string, archived: boolean): Promise<void> { this.message=''; this.invalidate(); await this.repository.setUnifiedArchived(id,archived); await this.sync(); const detail=this.message; this.message=(archived?'已归档，后续增强停止；本机资料保留':'已恢复本机资料，未重新上传或嵌入')+(detail.length>0?'；'+detail:''); this.changed(); }
  async deleteDocument(id: string, confirmed: boolean): Promise<void> { if (!confirmed) { return; } this.message=''; this.invalidate(); await this.repository.deleteUnified(id); await this.sync(); const mirrorMessage=this.message; await this.cleanup(); const cleanupMessage=this.message; this.message='已删除当前资料；共享资产按其他父来源/读租约/任务持有保留'+(mirrorMessage.length>0?'；'+mirrorMessage:'')+(cleanupMessage.length>0?'；'+cleanupMessage:''); this.changed(); }
  async retire(document: string, generation: string, confirmed: boolean): Promise<void> { if (!confirmed) { return; } await this.repository.retireUnifiedGeneration(document,generation); await this.cleanup(); this.changed(); }
  async retired(document: string): Promise<string[]> { return this.repository.retiredGenerationIds(document); }
  async unknownResources(): Promise<string[]> { const ids: string[]=[]; for (const job of await this.repository.jobs()) { if (job.state==='Unknown' && job.resourcePhase!=='Released' && (await this.repository.get(job.documentKey))?.tombstone) { ids.push(job.id); } } return ids; }
  async releaseUnknown(id: string, confirmed: boolean): Promise<void> { if (!confirmed) { return; } await this.repository.acknowledgeUnknownRelease(id); await this.cleanup(); this.message='已明确放弃已删文档的本机结果追踪；未取消或确认远端请求'; this.changed(); }
  async sync(): Promise<void> { await this.repository.reconcileUnifiedOwners(); try { await this.mirror.reconcileCurrentOwners(); } catch { this.message='本机镜像协调未完成；普通库当前资格已撤，未发送请求'; } }
  async cleanup(): Promise<void> { this.message=''; await this.repository.retryReadReleases(); await this.repository.retryProcessingReleases(); let pending: number=0; for (const id of await this.repository.unifiedCleanupAssets()) { if (!await this.assets.cleanup(id)) { pending++; } } if (pending>0) { this.message=`仍有 ${pending} 个资产待读取/任务释放或清理重试`; } this.changed(); }
}
