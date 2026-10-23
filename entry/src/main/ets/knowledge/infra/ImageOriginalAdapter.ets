import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { ImageHeaderReader, ImageOriginalPort } from '../domain/ImageKnowledgePorts';
import { ImageOriginal, ImageHeaderEvidence, ImageReleaseReceipt, ImageKnowledgeFailure, ImageLimits, ImagePreviewState } from '../domain/ImageKnowledgeModels';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { DocumentParseCancellation } from '../domain/DocumentParseModels';
import { imageInspectHeader } from '../pipeline/ImageHeaderPolicy';
import { documentReadRange, documentHashFile, documentAssetPath } from './DocumentFileOperations';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';

class ImageFileHeaderReader implements ImageHeaderReader {
  length: number; private fd: number;
  constructor(fd: number, length: number) { this.fd = fd; this.length = length; }
  async read(offset: number, length: number): Promise<Uint8Array> {
    if (length > ImageLimits.readBytes || length < 1 || offset < 0 || offset+length > this.length) { throw new ImageKnowledgeFailure('HeaderReadBudget','image-file'); }
    return documentReadRange(this.fd,offset,length);
  }
}
// One process-wide image resource owner, retained even after an uncertain release.
export class ImageDecodePermit {
  private static owner: ImageOriginalAdapter | undefined = undefined;
  static acquire(owner: ImageOriginalAdapter): void {
    if (ImageDecodePermit.owner !== undefined) { throw new ImageKnowledgeFailure('FullDecodeAlreadyHeld','image-decode'); } ImageDecodePermit.owner = owner;
  }
  static release(owner: ImageOriginalAdapter): void {
    if (ImageDecodePermit.owner !== owner) { throw new ImageKnowledgeFailure('DecodePermitOwnerMismatch','image-release'); } ImageDecodePermit.owner = undefined;
  }
}
export class ImageOriginalAdapter implements ImageOriginalPort {
  private root: string; private file: fileIo.File | undefined = undefined;
  private source: image.ImageSource | undefined = undefined; private pixel: image.PixelMap | undefined = undefined;
  private held: boolean = false; private running: Promise<ImageHeaderEvidence> | undefined = undefined;
  private receipt: ImageReleaseReceipt = new ImageReleaseReceipt();
  private previewReady: boolean = false;
  private releasing: Promise<ImageReleaseReceipt> | undefined = undefined;
  constructor(filesDir: string, scope: KnowledgeStorageScope = KnowledgeStorageScope.production()) { this.root = `${filesDir}/${scope.testing ? scope.derivedDirectory : 'knowledge_parse_v1'}`; }
  async verify(original: ImageOriginal, cancel: KnowledgeCancellation): Promise<ImageHeaderEvidence> {
    if (this.running !== undefined || this.held) { throw new ImageKnowledgeFailure('ImageInstanceBusy','image-decode'); }
    ImageDecodePermit.acquire(this); this.held = true; this.receipt = new ImageReleaseReceipt(); this.previewReady = false;
    this.running = this.decode(original,cancel,false);
    try { return await this.running; } finally { this.running = undefined; }
  }
  pixels(): image.PixelMap | undefined { return this.previewReady ? this.pixel : undefined; }
  async preview(original: ImageOriginal, cancel: KnowledgeCancellation): Promise<ImageHeaderEvidence> {
    if (this.running !== undefined || this.held) { throw new ImageKnowledgeFailure('ImageInstanceBusy','image-preview'); }
    ImageDecodePermit.acquire(this); this.held = true; this.receipt = new ImageReleaseReceipt(); this.previewReady = false; this.running = this.decode(original,cancel,true);
    try { return await this.running; } finally { this.running = undefined; }
  }
  private async decode(original: ImageOriginal, cancel: KnowledgeCancellation, preview: boolean): Promise<ImageHeaderEvidence> {
    cancel.check(); const path: string = documentAssetPath(this.root,original.assetId);
    const hashCancel: DocumentParseCancellation = new DocumentParseCancellation(); hashCancel.deadline = cancel.deadline;
    if (await documentHashFile(path,ImageLimits.bytes,hashCancel) !== original.hash) { throw new ImageKnowledgeFailure('OriginalHashChanged','image-decode'); } cancel.check();
    this.file = await fileIo.open(path,fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW); this.receipt.file = 'Held';
    const stat: fileIo.Stat = await fileIo.stat(this.file.fd);
    if (!stat.isFile() || stat.size !== original.bytes) { throw new ImageKnowledgeFailure('OriginalSizeChanged','image-decode'); }
    const evidence: ImageHeaderEvidence = await imageInspectHeader(new ImageFileHeaderReader(this.file.fd,stat.size),original.suffix,cancel);
    original.basicQualified = true;
    if (!preview) { return evidence; }
    try {
    this.source = image.createImageSource(this.file.fd); this.receipt.source = 'Held';
    const info: image.ImageInfo = await this.source.getImageInfo(0); cancel.check();
    const frames: number = await this.source.getFrameCount(); cancel.check();
    if (info.mimeType.toLowerCase() !== evidence.mime || info.size.width !== evidence.width || info.size.height !== evidence.height || frames !== 1) { throw new ImageKnowledgeFailure('SdkContainerEvidenceConflict','image-decode'); }
    const ratio: number = Math.min(1,1024/Math.max(evidence.width,evidence.height));
    const size: image.Size = { width: Math.max(1,Math.round(evidence.width*ratio)), height: Math.max(1,Math.round(evidence.height*ratio)) };
    const options: image.DecodingOptions = { desiredSize: size, desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      desiredDynamicRange: image.DecodingDynamicRange.SDR, index: 0, sampleSize: 1, rotate: 0, editable: true };
    this.pixel = await this.source.createPixelMap(options); this.receipt.pixel = 'Held'; cancel.check();
    original.preview = ImagePreviewState.Ready; original.frames = frames; this.previewReady = true;
    } catch {
      cancel.check(); original.preview = ImagePreviewState.Failed; original.previewReason = '本机预览不可用；基本上传资格不受影响';
    }
    if (await documentHashFile(path,ImageLimits.bytes,hashCancel) !== original.hash) { throw new ImageKnowledgeFailure('OriginalChangedDuringDecode','image-decode'); } cancel.check();
    return evidence;
  }
  async release(): Promise<ImageReleaseReceipt> {
    if (this.releasing !== undefined) { return this.releasing; }
    const pending: Promise<ImageReleaseReceipt> = this.releaseResources(); this.releasing = pending;
    try { return await pending; } finally { if (this.releasing === pending) { this.releasing = undefined; } }
  }
  private async releaseResources(): Promise<ImageReleaseReceipt> {
    this.previewReady = false;
    const running: Promise<ImageHeaderEvidence> | undefined = this.running;
    if (running !== undefined) { try { await Promise.resolve(running); } catch { /* Operation failure does not certify resource release. */ } }
    if (this.pixel !== undefined) { try { await this.pixel.release(); this.pixel = undefined; this.receipt.pixel = 'Released'; } catch { this.receipt.pixel = 'Unknown'; this.receipt.failure = 'PixelReleaseUnconfirmed'; return this.receipt; } }
    if (this.source !== undefined) { try { await this.source.release(); this.source = undefined; this.receipt.source = 'Released'; } catch { this.receipt.source = 'Unknown'; this.receipt.failure = 'SourceReleaseUnconfirmed'; return this.receipt; } }
    if (this.file !== undefined) { try { await fileIo.close(this.file); this.file = undefined; this.receipt.file = 'Released'; } catch { this.receipt.file = 'Unknown'; this.receipt.failure = 'FileCloseUnconfirmed'; return this.receipt; } }
    if (this.held) { ImageDecodePermit.release(this); this.held = false; } this.receipt.failure = ''; return this.receipt;
  }
}
