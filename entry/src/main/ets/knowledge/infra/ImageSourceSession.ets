import { image } from '@kit.ImageKit';
import { ImageOriginalAdapter } from './ImageOriginalAdapter';
import { ImageKnowledgeRepository } from './ImageKnowledgeRepository';
import { ImageDocument, ImageReadLease, ImageReleaseReceipt, ImageLocator, ImageKnowledgeFailure, ImageOcrBlock } from '../domain/ImageKnowledgeModels';
import { KnowledgeIdentityPort, KnowledgeStateListener } from '../domain/KnowledgePorts';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { KnowledgeHit } from '../domain/KnowledgeSearchModels';

export class ImageSourceSession {
  message: string = ''; paragraph: string = ''; metadata: string = ''; released: boolean = true;
  private repository: ImageKnowledgeRepository; private decoder: ImageOriginalAdapter; private identity: KnowledgeIdentityPort;
  private lease: ImageReadLease | undefined = undefined; private cancel: KnowledgeCancellation | undefined = undefined;
  private operation: Promise<void> | undefined = undefined; private epoch: number = 0; private listeners: KnowledgeStateListener[] = [];
  private displayHeld: boolean = false; private viewAttached: boolean = false;
  private display: (pixels: image.PixelMap | undefined) => void = (_pixels: image.PixelMap | undefined): void => {};
  constructor(repository: ImageKnowledgeRepository, decoder: ImageOriginalAdapter, identity: KnowledgeIdentityPort) { this.repository = repository; this.decoder = decoder; this.identity = identity; }
  subscribe(listener: KnowledgeStateListener, display: (pixels: image.PixelMap | undefined) => void): void { this.listeners.push(listener); this.display = display; this.viewAttached = true; if (!this.released && this.decoder.pixels() !== undefined) { this.displayHeld = true; } }
  unsubscribe(listener: KnowledgeStateListener): void { this.listeners = this.listeners.filter((item: KnowledgeStateListener): boolean => item !== listener); this.viewAttached = false; this.display = (_pixels: image.PixelMap | undefined): void => {}; }
  displayDetached(): void { this.displayHeld = false; }
  private emit(): void { for (const listener of this.listeners) { listener.changed(); } }
  pixels(): image.PixelMap | undefined { return this.decoder.pixels(); }
  async open(document: ImageDocument, hit?: KnowledgeHit): Promise<void> {
    const beforeClose: number = this.epoch; await this.close();
    if (this.epoch !== beforeClose+1) { throw new ImageKnowledgeFailure('ImageOpenCanceledDuringRelease','image-source'); }
    const epoch: number = ++this.epoch; const cancel: KnowledgeCancellation = new KnowledgeCancellation(); this.cancel = cancel;
    const operation: Promise<void> = this.openLeased(document,hit,cancel,epoch); this.operation = operation;
    try { await operation; } finally { if (this.operation === operation) { this.operation = undefined; } }
  }
  private async openLeased(document: ImageDocument, hit: KnowledgeHit | undefined, cancel: KnowledgeCancellation, epoch: number): Promise<void> {
    this.paragraph = ''; this.metadata = ''; this.message = '正在核验原图';
    const lease: ImageReadLease = new ImageReadLease(); lease.id = this.identity.id(); lease.owner = 'ImageSourceSession'; lease.documentId = document.id; lease.assetId = document.activeOriginal; lease.epoch = document.epoch;
    await this.repository.acquireRead(lease); this.lease = lease; this.released = false;
    try {
      const original = await this.repository.original(document.activeOriginal);
      if (hit !== undefined) {
        if (!(await this.repository.visible(hit,true))) { throw new ImageKnowledgeFailure('ImageSourceVersionChanged','image-source'); }
        const locator: ImageLocator | undefined = hit.locator.image; const snapshot = await this.repository.snapshot(hit.generation);
        const block = snapshot.blocks.find((b: ImageOcrBlock): boolean => b.id === locator?.blockId);
        if (locator === undefined || block === undefined || block.text.slice(locator.start,locator.end) !== hit.text || locator.originalHash !== original.hash || locator.originalVersion !== original.version) { throw new ImageKnowledgeFailure('ImageParagraphRangeMismatch','image-source'); }
        this.paragraph = `段落 ${locator.paragraph} · UTF16 ${locator.start}–${locator.end}\n${block.text.slice(Math.max(0,locator.start-256),Math.min(block.text.length,locator.end+256))}`;
        if (snapshot.wire === 'IMAGE-NORMALIZED-2' && snapshot.projection.kind.length > 0) { this.paragraph += `\nMinerU 正文投影 · ${snapshot.projection.member} · 成员UTF16 ${block.sourceStart+locator.start}–${block.sourceStart+locator.end}\nZIP SHA256 ${snapshot.resultHash} · 成员 SHA256 ${snapshot.projection.memberHash}`; }
      }
      const header = await this.decoder.preview(original,cancel); cancel.check();
      if (epoch !== this.epoch) { throw new ImageKnowledgeFailure('LateImageSource','image-source'); }
      const current = await this.repository.get(document.id); cancel.check();
      if (current === undefined || current.tombstone || current.epoch !== document.epoch || current.activeOriginal !== document.activeOriginal) { throw new ImageKnowledgeFailure('ImageSourceChangedDuringDecode','image-source'); }
      this.metadata = `${header.encoding} · ${header.width}×${header.height} · 方向 ${header.orientation === 0 ? 'Unknown' : header.orientation}\n版本 ${original.version} · SHA256 ${original.hash}\n${header.warnings.join('；')}`;
      this.message = original.previewReason || '原图预览；方向未核，未提供像素框'; this.displayHeld = this.viewAttached && this.decoder.pixels() !== undefined; this.display(this.decoder.pixels()); this.emit();
    } catch (error) { this.message = error instanceof ImageKnowledgeFailure ? error.message : '原图读取失败，资源等待释放'; this.emit(); if (error instanceof Error) { throw error; } throw new ImageKnowledgeFailure('ImageSourceReadFailed','image-source'); }
  }
  pause(): void { this.epoch++; if (this.cancel !== undefined) { this.cancel.invalid = true; } this.display(undefined); }
  async close(): Promise<void> {
    this.pause(); const operation: Promise<void> | undefined = this.operation;
    if (operation !== undefined) { try { await Promise.resolve(operation); } catch { /* Release still required after failed/late open. */ } }
    const deadline: number = Date.now()+120000;
    while (this.displayHeld) {
      if (Date.now() >= deadline) { this.message = '待释放：UI 像素解绑未确认'; this.emit(); throw new ImageKnowledgeFailure('ImageDisplayDetachUnconfirmed','image-source-release'); }
      await new Promise<void>((resolve: () => void): void => { setTimeout(resolve,10); });
    }
    const receipt: ImageReleaseReceipt = await this.decoder.release();
    if (this.lease !== undefined) { receipt.leaseId = this.lease.id; await this.repository.releaseRead(receipt); if (receipt.failure.length === 0) { this.lease = undefined; } }
    this.released = receipt.failure.length === 0; this.message = this.released ? '来源已关闭' : '待释放：'+receipt.failure; this.emit();
    if (!this.released) { throw new ImageKnowledgeFailure(receipt.failure,'image-source-release'); }
  }
  async retry(): Promise<void> { await this.close(); }
}
