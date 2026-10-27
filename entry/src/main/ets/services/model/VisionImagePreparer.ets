import { fileIo, fileUri, ReadOptions } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import cryptoFramework from '@ohos.security.cryptoFramework';
import { ImageHeaderReader } from '../../knowledge/domain/ImageKnowledgePorts';
import { ImageHeaderEvidence, ImageLimits } from '../../knowledge/domain/ImageKnowledgeModels';
import { KnowledgeCancellation } from '../../knowledge/domain/PdfKnowledgeModels';
import { imageInspectHeader } from '../../knowledge/pipeline/ImageHeaderPolicy';
import { VisionChatImage, VISION_CHAT_MAX_IMAGE_BYTES } from './VisionChatProtocol';
import { VisionImageFailure, VisionImagePreparerPort, VisionPreparedImage } from './VisionImagePorts';

const VISION_IMAGE_MAX_SIDE: number = 2048;
const VISION_IMAGE_QUALITY: number = 90;

function exifOrientation(value: string): number {
  const text: string = value.trim();
  if (/^[1-8]$/.test(text)) { return Number(text); }
  const names: string[] = ['Top-left', 'Top-right', 'Bottom-right', 'Bottom-left',
    'Left-top', 'Right-top', 'Right-bottom', 'Left-bottom'];
  const index: number = names.indexOf(text);
  return index >= 0 ? index + 1 : 1;
}

async function applyOrientation(pixel: image.PixelMap, orientation: number): Promise<void> {
  if (orientation === 2) { await pixel.flip(true, false); }
  else if (orientation === 3) { await pixel.rotate(180); }
  else if (orientation === 4) { await pixel.flip(false, true); }
  else if (orientation === 5) { await pixel.flip(true, false); await pixel.rotate(270); }
  else if (orientation === 6) { await pixel.rotate(90); }
  else if (orientation === 7) { await pixel.flip(true, false); await pixel.rotate(90); }
  else if (orientation === 8) { await pixel.rotate(270); }
}

class VisionHeaderReader implements ImageHeaderReader {
  readonly length: number;
  private readonly bytes: Uint8Array;
  constructor(bytes: Uint8Array) { this.bytes = bytes; this.length = bytes.length; }
  async read(offset: number, length: number): Promise<Uint8Array> {
    if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 1 ||
      offset + length > this.bytes.length) { throw new VisionImageFailure('IMAGE_HEADER_RANGE'); }
    return this.bytes.slice(offset, offset + length);
  }
}

function sha256Hex(bytes: Uint8Array): string {
  try {
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: bytes });
    const digest: Uint8Array = md.digestSync().data;
    if (digest.length !== 32) { throw new VisionImageFailure('IMAGE_DIGEST_FAILED'); }
    let result: string = '';
    for (let index: number = 0; index < digest.length; index++) {
      result += digest[index].toString(16).padStart(2, '0');
    }
    return result;
  } catch (error) {
    if (error instanceof VisionImageFailure) { throw error; }
    throw new VisionImageFailure('IMAGE_DIGEST_FAILED');
  }
}

function suffixOf(name: string): string {
  const at: number = name.lastIndexOf('.');
  return at >= 0 ? name.slice(at).toLowerCase() : '';
}

/** Reads a user-selected image, re-encodes it to strip metadata and bounds the transmitted pixel size. */
export class VisionImagePreparer implements VisionImagePreparerPort {
  async prepare(uri: string, displayName: string): Promise<VisionPreparedImage> {
    const name: string = displayName.trim();
    if (typeof uri !== 'string' || uri.length === 0 || name.length < 1 || name.length > 200 ||
      name !== displayName || /[\u0000-\u001f\u007f]/.test(name)) {
      throw new VisionImageFailure('IMAGE_NAME_OR_URI_INVALID');
    }
    const sourceBytes: Uint8Array = await this.readUri(uri);
    try {
      return await this.sanitize(sourceBytes, name);
    } finally {
      sourceBytes.fill(0);
    }
  }

  private async readUri(uri: string): Promise<Uint8Array> {
    try {
      const info: fileUri.FileUri = new fileUri.FileUri(uri);
      if (info.isRemoteUri()) { throw new VisionImageFailure('IMAGE_REMOTE_URI_UNSUPPORTED'); }
    } catch (error) {
      if (error instanceof VisionImageFailure) { throw error; }
      throw new VisionImageFailure('IMAGE_URI_INVALID');
    }
    let file: fileIo.File | undefined = undefined;
    let bytes: Uint8Array = new Uint8Array(0);
    try {
      file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
      const before: fileIo.Stat = await fileIo.stat(file.fd);
      if (!before.isFile() || before.size < 1 || before.size > ImageLimits.bytes) {
        throw new VisionImageFailure('IMAGE_SIZE_OR_TYPE_INVALID');
      }
      bytes = new Uint8Array(before.size);
      let total: number = 0;
      while (total < bytes.length) {
        const block: ArrayBuffer = new ArrayBuffer(Math.min(65536, bytes.length - total));
        const options: ReadOptions = { offset: total, length: block.byteLength };
        const read: number = await fileIo.read(file.fd, block, options);
        if (read < 1 || read > block.byteLength) { throw new VisionImageFailure('IMAGE_READ_INCOMPLETE'); }
        bytes.set(new Uint8Array(block, 0, read), total); total += read;
      }
      const extra: ArrayBuffer = new ArrayBuffer(1);
      const extraOptions: ReadOptions = { offset: total, length: 1 };
      const after: fileIo.Stat = await fileIo.stat(file.fd);
      if (before.size !== after.size || before.mtime !== after.mtime ||
        await fileIo.read(file.fd, extra, extraOptions) !== 0) {
        throw new VisionImageFailure('IMAGE_CHANGED_DURING_READ');
      }
      return bytes;
    } catch (error) {
      bytes.fill(0);
      if (error instanceof VisionImageFailure) { throw error; }
      throw new VisionImageFailure('IMAGE_READ_FAILED');
    } finally {
      if (file !== undefined) {
        try { await fileIo.close(file); } catch { throw new VisionImageFailure('IMAGE_CLOSE_FAILED'); }
      }
    }
  }

  private async sanitize(sourceBytes: Uint8Array, displayName: string): Promise<VisionPreparedImage> {
    const cancel: KnowledgeCancellation = new KnowledgeCancellation();
    let header: ImageHeaderEvidence = new ImageHeaderEvidence();
    try {
      header = await imageInspectHeader(new VisionHeaderReader(sourceBytes), suffixOf(displayName), cancel);
    } catch (error) {
      throw new VisionImageFailure('IMAGE_HEADER_INVALID');
    }
    let source: image.ImageSource | undefined = undefined;
    let pixel: image.PixelMap | undefined = undefined;
    let prepared: VisionPreparedImage | undefined = undefined;
    let failure: VisionImageFailure | undefined = undefined;
    try {
      source = image.createImageSource(sourceBytes.slice().buffer);
      const info: image.ImageInfo = await source.getImageInfo(0);
      cancel.check();
      const frames: number = await source.getFrameCount();
      cancel.check();
      if (!header.staticContainer || frames !== 1 || info.mimeType.toLowerCase() !== header.mime ||
        info.size.width !== header.width || info.size.height !== header.height) {
        throw new VisionImageFailure('IMAGE_SDK_HEADER_CONFLICT');
      }
      let orientation: number = 1;
      try {
        const options: image.ImagePropertyOptions = { index: 0, defaultValue: '1' };
        orientation = exifOrientation(await source.getImageProperty(image.PropertyKey.ORIENTATION, options));
      } catch { orientation = 1; }
      cancel.check();
      const ratio: number = Math.min(1, VISION_IMAGE_MAX_SIDE / Math.max(header.width, header.height));
      const size: image.Size = {
        width: Math.max(1, Math.round(header.width * ratio)),
        height: Math.max(1, Math.round(header.height * ratio))
      };
      const decode: image.DecodingOptions = {
        desiredSize: size, desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        desiredDynamicRange: image.DecodingDynamicRange.SDR, index: 0, sampleSize: 1, rotate: 0, editable: false
      };
      pixel = await source.createPixelMap(decode);
      cancel.check();
      await applyOrientation(pixel, orientation);
      cancel.check();
      const outInfo: image.ImageInfo = await pixel.getImageInfo();
      const packed: ArrayBuffer = await this.pack(pixel, header.mime);
      const sanitized: Uint8Array = new Uint8Array(packed);
      if (sanitized.length < 1 || sanitized.length > VISION_CHAT_MAX_IMAGE_BYTES) {
        sanitized.fill(0); throw new VisionImageFailure('IMAGE_SANITIZED_BUDGET');
      }
      prepared = new VisionPreparedImage(); prepared.displayName = displayName;
      const imageValue: VisionChatImage = new VisionChatImage();
      imageValue.mime = header.mime; imageValue.width = outInfo.size.width; imageValue.height = outInfo.size.height;
      imageValue.sha256 = sha256Hex(sanitized); imageValue.bytes = sanitized;
      prepared.image = imageValue;
    } catch (error) {
      failure = error instanceof VisionImageFailure ? error : new VisionImageFailure('IMAGE_SANITIZE_FAILED');
    }
    if (pixel !== undefined) {
      try { await pixel.release(); } catch { if (failure === undefined) { failure = new VisionImageFailure('IMAGE_RELEASE_FAILED'); } }
    }
    if (source !== undefined) {
      try { await source.release(); } catch { if (failure === undefined) { failure = new VisionImageFailure('IMAGE_RELEASE_FAILED'); } }
    }
    if (failure !== undefined) {
      if (prepared !== undefined) { prepared.image.bytes.fill(0); }
      throw failure;
    }
    if (prepared === undefined) { throw new VisionImageFailure('IMAGE_SANITIZE_FAILED'); }
    return prepared;
  }

  private async pack(pixel: image.PixelMap, format: string): Promise<ArrayBuffer> {
    const packer: image.ImagePacker = image.createImagePacker();
    try {
      const option: image.PackingOption = { format: format, quality: VISION_IMAGE_QUALITY };
      return await packer.packToData(pixel, option);
    } finally {
      try { await packer.release(); } catch { throw new VisionImageFailure('IMAGE_RELEASE_FAILED'); }
    }
  }
}
