import { DocumentParseService } from './DocumentParseService';
import { DocumentImageEvidence, DocumentOriginal } from '../domain/DocumentParseModels';
import { documentIsImage, imageTestInputId } from '../pipeline/DocumentParsePolicy';
import { ImageOriginalPort, ImageRepositoryPort } from '../domain/ImageKnowledgePorts';
import { ImageOriginal, ImageAssetClaim, ImageKnowledgeFailure, ImageDocument, ImageHeaderEvidence } from '../domain/ImageKnowledgeModels';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { KnowledgeStateListener } from '../domain/KnowledgePorts';

export class ImageOriginalImportService {
  documents: ImageDocument[] = []; message: string = ''; busy: boolean = false;
  protected owner: DocumentParseService; protected repository: ImageRepositoryPort; private decoder: ImageOriginalPort;
  private listeners: KnowledgeStateListener[] = []; private cancel: KnowledgeCancellation | undefined = undefined;
  constructor(owner: DocumentParseService, repository: ImageRepositoryPort, decoder: ImageOriginalPort) { this.owner = owner; this.repository = repository; this.decoder = decoder; }
  subscribe(listener: KnowledgeStateListener): void { if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); } }
  unsubscribe(listener: KnowledgeStateListener): void { this.listeners = this.listeners.filter((item: KnowledgeStateListener): boolean => item !== listener); }
  protected emit(): void { for (const listener of this.listeners) { listener.changed(); } }
  async retryRelease(): Promise<void> { const receipt = await this.decoder.release(); this.message = receipt.failure.length === 0 ? '解码资源释放已确认' : '待释放：'+receipt.failure; this.emit(); }
  async refresh(): Promise<void> {
    this.documents = await this.repository.list();
    for (const document of this.documents) {
      if (document.tombstone) { continue; }
      const original = await this.repository.latestOriginal(document.id);
      document.testInputId = imageTestInputId(original.hash,original.bytes); document.parseControlId = document.testInputId.length > 0 ? 'image-happy-parse-'+document.testInputId : 'm3-image-ocr-'+document.id;
      document.parseSourceId = original.sourceId; document.parseBinding = `${original.sourceId}|${original.assetId}|${original.hash}|${original.version}|${original.header.encoding}`;
      document.originalSummary = `${original.header.encoding} · ${original.header.width}×${original.header.height} · ${original.bytes} B · 方向 ${original.header.orientationEvidence} · 预览 ${original.preview}\n${original.header.warnings.join('；')}`;
    } this.emit();
  }
  pause(): void { if (this.cancel !== undefined) { this.cancel.invalid = true; } this.owner.pauseImmediate(); }
  async adoptPrepared(): Promise<void> {
    if (this.busy || this.owner.viewState().busy) { return; } this.busy = true; this.emit();
    try {
      for (const source of this.owner.viewState().snapshot.originals) {
        if (!documentIsImage(source.format)) { continue; }
        try { await this.repository.original(source.assetId); continue; }
        catch (error) {
          if (error instanceof ImageKnowledgeFailure) {
            if (error.category !== 'OriginalMissing') { throw error; }
          } else {
            throw new ImageKnowledgeFailure('OriginalReadFailed','image-adopt');
          }
        }
        const prior = await this.repository.get(source.id); if (prior?.tombstone) { continue; }
        await this.owner.withImageOriginal<void>(source.id,async (): Promise<void> => { await this.verifyOriginal(source); });
      }
    } catch (error) { this.message = error instanceof ImageKnowledgeFailure ? error.message : '已保存图片登记未完成，原件保留，未外发'; }
    finally { this.cancel = undefined; this.busy = false; await this.refresh(); }
  }
  async importFiles(): Promise<void> {
    if (this.busy) { return; } this.busy = true; this.emit();
    try {
      const before: string[] = this.owner.viewState().snapshot.originals.map((o: DocumentOriginal): string => o.id);
      await this.owner.prepare(true);
      for (const original of this.owner.viewState().snapshot.originals) {
        if (before.indexOf(original.id) >= 0 || !documentIsImage(original.format) || (await this.repository.get(original.id)) !== undefined) { continue; }
        await this.owner.withImageOriginal<void>(original.id,async (): Promise<void> => { await this.verifyOriginal(original); });
      }
      this.message = '原件已保存，未授权外发；未发布关键词';
    } catch (error) { this.message = error instanceof ImageKnowledgeFailure ? error.message : '图片核验失败，原件保留，未索引或外发'; }
    finally { this.cancel = undefined; this.busy = false; await this.refresh(); }
  }
  async verifyOriginal(source: DocumentOriginal, documentId: string = source.id): Promise<void> {
    const cancel: KnowledgeCancellation = new KnowledgeCancellation(); this.cancel = cancel;
    const original: ImageOriginal = new ImageOriginal(); original.documentId = documentId; original.sourceId = source.id; original.assetId = source.assetId;
    original.hash = source.hash; original.bytes = source.bytes; original.version = source.version; original.title = source.title;
    original.suffix = source.title.slice(source.title.lastIndexOf('.')).toLowerCase(); original.savedAt = source.savedAt;
    try {
      const header: ImageHeaderEvidence = await this.decoder.verify(original,cancel); cancel.check();
      const evidence: DocumentImageEvidence = new DocumentImageEvidence(); evidence.originalId = source.id; evidence.assetId = source.assetId; evidence.hash = source.hash; evidence.version = source.version;
      evidence.width = header.width; evidence.height = header.height; evidence.orientation = header.orientation; evidence.orientationEvidence = header.orientationEvidence;
      evidence.frames = original.frames; evidence.staticContainer = header.staticContainer; evidence.sdkVerified = original.sdkVerified; evidence.mime = header.mime; evidence.variant = header.variant; evidence.alpha = header.alpha;
      await this.owner.recordImageEvidence(evidence); cancel.check();
      original.header = header; original.basicQualified = true;
      const asset: ImageAssetClaim = new ImageAssetClaim(); asset.assetId = original.assetId; asset.documentId = original.documentId; asset.owner = 'DocumentParseService'; asset.hash = original.hash; asset.bytes = original.bytes; asset.role = 'Original'; asset.pins = 1;
      await this.repository.register(original,[asset]);
    } finally { const receipt = await this.decoder.release(); if (receipt.failure.length > 0) { throw new ImageKnowledgeFailure(receipt.failure,'image-release'); } }
  }
  async replaceOriginal(documentId: string): Promise<void> {
    if (this.busy) { return; } const document = await this.repository.get(documentId);
    if (document === undefined || document.tombstone || document.archived) { this.message = '图片资料不可替换'; this.emit(); return; }
    const active = await this.repository.latestOriginal(documentId); const before: string[] = this.owner.viewState().snapshot.originals.map((o: DocumentOriginal): string => o.id);
    this.busy = true; this.emit();
    try {
      await this.owner.prepare(true); const candidates = this.owner.viewState().snapshot.originals.filter((o: DocumentOriginal): boolean => before.indexOf(o.id) < 0 && documentIsImage(o.format));
      if (candidates.length !== 1) { throw new ImageKnowledgeFailure('ReplacementRequiresExactlyOneNewImage','image-replace'); }
      const original = await this.owner.assignImageVersion(candidates[0].id,active.version+1);
      await this.owner.withImageOriginal<void>(original.id,async (): Promise<void> => { await this.verifyOriginal(original,documentId); });
      this.message = '候选原件已保存核验；原活动图片与内容保留，待新产物覆盖报告确认';
    } catch (error) { this.message = error instanceof ImageKnowledgeFailure ? error.message : '替换核验失败，旧原件与内容保留'; }
    finally { this.busy = false; await this.refresh(); }
  }
}
