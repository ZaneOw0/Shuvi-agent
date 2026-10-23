import { pdfService, pdfViewManager } from '@kit.PDFKit';
import { image } from '@kit.ImageKit';
import { taskpool } from '@kit.ArkTS';
import { PdfPagePort, KnowledgeSourceReadPort } from '../domain/KnowledgePorts';
import { PdfSourceBinding, PdfLocator, PdfMappingEvidence, PdfMappingTier, KnowledgeCancellation, KnowledgeFailure, KnowledgeReadLease, PdfNormalizedDocument, PdfContentNode, PdfDerivedImage, PdfBox } from '../domain/PdfKnowledgeModels';
import { DocumentParseCancellation } from '../domain/DocumentParseModels';
import { documentAssetPath, documentHashFile } from './DocumentFileOperations';
import { pdfEvidenceLocator, pdfDisplayRegions, pdfEvidenceValid } from '../pipeline/PdfMappingPolicy';
import { PdfEvidenceContext } from '../domain/PdfLocalModels';
import { ResultPageReference, PdfPageReferenceState } from '../domain/PdfLocalModels';
import { PdfAssetAdapter } from './PdfAssetAdapter';
import { PdfKnowledgeRepository } from './PdfKnowledgeRepository';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';

@Concurrent
function pdfOriginalGeometry(path: string): number[] {
  const doc: pdfService.PdfDocument = new pdfService.PdfDocument(); const geometry: number[] = [];
  try {
    if (doc.isEncrypted(path) || doc.loadDocument(path) !== pdfService.ParseResult.PARSE_SUCCESS) { throw new Error('OriginalPdfUnavailable'); }
    const count: number = doc.getPageCount(); if (count < 1 || count > 50) { throw new Error('OriginalPdfPageBudget'); }
    for (let index: number = 0; index < count; index++) {
      if (taskpool.Task.isCanceled()) { throw new Error('Canceled'); } const page: pdfService.PdfPage = doc.getPage(index);
      const media: pdfService.PdfRect = page.getBox(pdfService.BoxType.BOX_MEDIA); const crop: pdfService.PdfRect = page.getBox(pdfService.BoxType.BOX_CROP);
      geometry.push(page.getWidth(),page.getHeight(),page.getRotation(),media.left,media.top,media.right,media.bottom,crop.left,crop.top,crop.right,crop.bottom);
    }
    return geometry;
  } finally { doc.releaseDocument(); }
}
export class PdfPageAdapter implements PdfPagePort {
  private root: string; private controller: pdfViewManager.PdfController = new pdfViewManager.PdfController();
  private opened: boolean = false; private pageCount: number = 0;
  private pixels: image.PixelMap | undefined = undefined;
  private readPort: KnowledgeSourceReadPort | undefined = undefined; private lease: KnowledgeReadLease | undefined = undefined; private leaseAcquired: boolean = false;
  geometry: number[] = [];
  snapshot: PdfNormalizedDocument | undefined = undefined;
  private repository: PdfKnowledgeRepository | undefined = undefined; private assets: PdfAssetAdapter | undefined = undefined;
  private snapshotId: string = ''; private snapshotHash: string = ''; private originalHash: string = '';
  private imagePixels: image.PixelMap | undefined = undefined;
  nodeIds: string[] = [];
  reviewedPages1: number[] = [];
  attachPageReference(reference: ResultPageReference): void { this.reviewedPages1 = reference.state === PdfPageReferenceState.Verified && reference.snapshotId === this.snapshotId && reference.snapshotHash === this.snapshotHash ? reference.physicalPages1Based.slice() : []; }
  private operations: number = 0; private closing: Promise<void> | undefined;
  private tokens: KnowledgeCancellation[] = [];
  releaseState: string = 'Idle';
  attachNodeIds(ids: string[]): void { this.nodeIds = ids; }
  attachSnapshot(repository: PdfKnowledgeRepository, assets: PdfAssetAdapter, id: string, hash: string): void { this.repository = repository; this.assets = assets; this.snapshotId = id; this.snapshotHash = hash; }
  constructor(filesDir: string) { this.root = `${filesDir}/knowledge_parse_v1`; }
  testOriginalRoot(scope: KnowledgeStorageScope, cacheDir: string): void { scope.requireTestOwner(scope.key); this.root = `${cacheDir}/source_r2_${scope.key}`; }
  attachLease(port: KnowledgeSourceReadPort, lease: KnowledgeReadLease): void { if (this.leaseAcquired || this.closing !== undefined) { throw new KnowledgeFailure('SourceLeaseStillOwned','source'); } this.readPort = port; this.lease = lease; }
  capability(): string { return canIUse('SystemCapability.OfficeService.PDFService.Core') ? 'PDFKitRuntimeUnverified' : 'PDFKitUnavailable'; }
  async openOriginal(binding: PdfSourceBinding, cancel: KnowledgeCancellation): Promise<void> {
    if (this.leaseAcquired || this.closing !== undefined) { throw new KnowledgeFailure('SourceAlreadyOwned','source'); } cancel.check(); if (!canIUse('SystemCapability.OfficeService.PDFService.Core')) { throw new KnowledgeFailure('PDFKitUnavailable','source'); }
    if (this.readPort === undefined || this.lease === undefined || this.lease.sourceId !== binding.originalId) { throw new KnowledgeFailure('SourceReadLeaseUnavailable','source'); }
    this.operations++; this.tokens.push(cancel);
    try { await this.readPort.acquireRead(this.lease); this.leaseAcquired = true; this.releaseState = 'Reading';
    if (this.assets !== undefined && this.snapshotId.length > 0) {
      const snapshot: PdfNormalizedDocument = await this.assets.read(this.snapshotId,cancel);
      if (snapshot.hash !== this.snapshotHash || snapshot.binding.originalHash !== binding.originalHash || snapshot.generation !== this.lease.generation) { throw new KnowledgeFailure('SourceSnapshotMismatch','source'); } this.snapshot = snapshot;
    }
    const path: string = documentAssetPath(this.root,binding.originalAssetId); const hashCancel: DocumentParseCancellation = new DocumentParseCancellation(); hashCancel.deadline = cancel.deadline;
    if (await documentHashFile(path,20971520,hashCancel) !== binding.originalHash) { throw new KnowledgeFailure('OriginalHashMismatch','source'); } cancel.check();
    const task: taskpool.GenericsTask<[string],number[]> = new taskpool.GenericsTask<[string],number[]>(pdfOriginalGeometry,path);
    this.geometry = await taskpool.execute<[string],number[]>(task); cancel.check();
    if (this.geometry.length !== binding.originalPages*11) { throw new KnowledgeFailure('OriginalPageCountMismatch','source'); }
    if (await this.controller.loadDocument(path,'',0) !== pdfService.ParseResult.PARSE_SUCCESS) { throw new KnowledgeFailure('OriginalPreviewUnavailable','source'); }
    this.pageCount = binding.originalPages; this.opened = true;
    this.originalHash = binding.originalHash; hilog.info(0x0001,'SHUVI_R2','R2_SOURCE original=%{public}s pages=%{public}d loaded=1',binding.originalHash,this.pageCount);
    } finally { this.operations--; this.tokens = this.tokens.filter((item: KnowledgeCancellation): boolean => item !== cancel); }
  }
  verifiedLocator(locator: PdfLocator, evidence: PdfMappingEvidence[]): PdfLocator { return pdfEvidenceLocator(locator,evidence); }
  evidenceContext(node: PdfContentNode, page: number): PdfEvidenceContext {
    if (this.snapshot === undefined || page < 0 || page >= this.pageCount) { throw new KnowledgeFailure('MappingPageUnavailable','source'); }
    const context: PdfEvidenceContext = new PdfEvidenceContext(); const snapshot: PdfNormalizedDocument = this.snapshot;
    context.originalHash = snapshot.binding.originalHash; context.originalVersion = snapshot.binding.originalVersion; context.zipHash = snapshot.binding.zipHash; context.snapshotHash = snapshot.hash; context.snapshotId = snapshot.id; context.generation = snapshot.generation; context.nodeId = node.id; context.protocol = snapshot.profile; context.providerPage = node.pageIndex0; context.originalPages = this.pageCount;
    const at: number = page*11; context.rotation = this.geometry[at+2];
    context.media.left = this.geometry[at+3]; context.media.top = this.geometry[at+4]; context.media.right = this.geometry[at+5]; context.media.bottom = this.geometry[at+6];
    context.crop.left = this.geometry[at+7]; context.crop.top = this.geometry[at+8]; context.crop.right = this.geometry[at+9]; context.crop.bottom = this.geometry[at+10]; return context;
  }
  async mapping(locator: PdfLocator, node: PdfContentNode): Promise<PdfLocator> {
    if (this.closing !== undefined) { throw new KnowledgeFailure('SourceClosing','source'); } this.operations++;
    try {
    if (this.repository === undefined || this.snapshot === undefined) { return pdfEvidenceLocator(locator,[]); }
    const items: PdfMappingEvidence[] = await this.repository.evidence(this.snapshot.generation,node.id);
    for (const item of items) { const checked: PdfLocator = pdfEvidenceLocator(locator,items,this.evidenceContext(node,item.originalPageIndex0)); if (checked.tier !== PdfMappingTier.Unknown) { return checked; } }
    return pdfEvidenceLocator(locator,[]);
    } finally { this.operations--; }
  }
  async regions(node: PdfContentNode, page: number): Promise<PdfBox[]> {
    if (this.closing !== undefined) { throw new KnowledgeFailure('SourceClosing','source'); } this.operations++;
    try {
    if (this.repository === undefined || this.snapshot === undefined) { return []; } const context: PdfEvidenceContext = this.evidenceContext(node,page); const regions: PdfBox[] = [];
    for (const item of await this.repository.evidence(this.snapshot.generation,node.id)) { if (item.originalPageIndex0 === page && item.tier === PdfMappingTier.Region && pdfEvidenceValid(item,context)) { regions.push(...pdfDisplayRegions(item,context)); } } return regions;
    } finally { this.operations--; }
  }
  async renderImage(member: string, cancel: KnowledgeCancellation): Promise<image.PixelMap> {
    if (this.closing !== undefined) { throw new KnowledgeFailure('SourceClosing','source'); } this.operations++; this.tokens.push(cancel);
    try {
    if (this.snapshot === undefined || this.assets === undefined || !this.leaseAcquired) { throw new KnowledgeFailure('ImageReadLeaseUnavailable','source'); }
    const derived: PdfDerivedImage | undefined = this.snapshot.images.find((item: PdfDerivedImage): boolean => item.memberId === member);
    if (derived === undefined) { throw new KnowledgeFailure('ImageRelationshipMissing','source'); }
    const bytes: Uint8Array = await this.assets.readImage(derived,this.snapshot.generation,cancel); const source: image.ImageSource = image.createImageSource(bytes.slice().buffer);
    try {
      const pixel: image.PixelMap = await source.createPixelMap();
      try { cancel.check(); } catch (error) { await pixel.release(); if (error instanceof Error) { throw error; } throw new KnowledgeFailure('Canceled','source'); }
      await this.imagePixels?.release(); this.imagePixels = pixel; const info: image.ImageInfo = await pixel.getImageInfo();
      hilog.info(0x0001,'SHUVI_R2','R2_IMAGE hash=%{public}s width=%{public}d height=%{public}d rendered=1',derived.sha256,info.size.width,info.size.height); return pixel;
    } finally { await source.release(); }
    } finally { this.operations--; this.tokens = this.tokens.filter((item: KnowledgeCancellation): boolean => item !== cancel); }
  }
  async renderPage(pageIndex0: number, cancel: KnowledgeCancellation): Promise<image.PixelMap> {
    if (this.closing !== undefined) { throw new KnowledgeFailure('SourceClosing','source'); } this.operations++; this.tokens.push(cancel);
    try {
    cancel.check(); if (!this.opened || !Number.isSafeInteger(pageIndex0) || pageIndex0 < 0 || pageIndex0 >= this.pageCount) { throw new KnowledgeFailure('OriginalPageUnavailable','source'); }
    const pixels: image.PixelMap = await this.controller.getPagePixelMap(pageIndex0,false);
    try { cancel.check(); } catch (error) { await pixels.release(); if (error instanceof Error) { throw error; } throw new KnowledgeFailure('Canceled','source'); }
    const old: image.PixelMap | undefined = this.pixels; this.pixels = pixels; await old?.release();
    hilog.info(0x0001,'SHUVI_R2','R2_PAGE original=%{public}s page=%{public}d rendered=1',this.originalHash,pageIndex0); return pixels;
    } finally { this.operations--; this.tokens = this.tokens.filter((item: KnowledgeCancellation): boolean => item !== cancel); }
  }
  async close(): Promise<void> {
    for (const token of this.tokens) { token.invalid = true; }
    if (this.closing !== undefined) { return this.closing; }
    this.closing = this.releaseOwned(); const closing: Promise<void> = this.closing; try { await closing; } finally { this.closing = undefined; }
  }
  private async releaseOwned(): Promise<void> {
    this.releaseState = 'Releasing';
    try {
      const deadline: number = Date.now()+120000; while (this.operations > 0) { if (Date.now() >= deadline) { throw new KnowledgeFailure('SourceLateCloseUnconfirmed','source'); } await new Promise<void>((resolve: () => void): void => { setTimeout(resolve,10); }); }
      if (this.opened) { this.controller.releaseDocument(); this.opened = false; } await this.pixels?.release(); this.pixels = undefined; await this.imagePixels?.release(); this.imagePixels = undefined;
      if (this.leaseAcquired && this.lease !== undefined && this.readPort !== undefined) { await this.readPort.releaseRead(this.lease.id); await this.repository?.sourceRelease(this.lease,''); this.leaseAcquired = false; }
      this.opened = false; this.pageCount = 0; this.snapshot = undefined; this.releaseState = 'Released';
    } catch { this.releaseState = 'ReleaseUnconfirmed'; if (this.lease !== undefined) { await this.repository?.sourceRelease(this.lease,'SourceReleaseUnconfirmed'); } throw new KnowledgeFailure('SourceReleaseUnconfirmed','source'); }
  }
}
