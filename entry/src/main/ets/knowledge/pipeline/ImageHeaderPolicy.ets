import { ImageHeaderReader } from '../domain/ImageKnowledgePorts';
import { ImageHeaderEvidence, ImageEncoding, ImageKnowledgeFailure, ImageLimits } from '../domain/ImageKnowledgeModels';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';

// Basic encoding/dimensions only. Metadata, entropy, CRC and trailing bytes are not upload gates.
class ImageBasicCursor {
  reader: ImageHeaderReader; cancel: KnowledgeCancellation; parts: number = 0;
  private buffer: Uint8Array = new Uint8Array(0); private start: number = -1;
  constructor(reader: ImageHeaderReader, cancel: KnowledgeCancellation) { this.reader = reader; this.cancel = cancel; }
  async byte(at: number): Promise<number> {
    this.cancel.check();
    if (!Number.isSafeInteger(at) || at < 0 || at >= this.reader.length) { throw new ImageKnowledgeFailure('HeaderTruncated','image-basic'); }
    if (at < this.start || at >= this.start+this.buffer.length) {
      this.start = at; this.buffer = await this.reader.read(at,Math.min(ImageLimits.readBytes,this.reader.length-at));
    }
    if (at >= this.start+this.buffer.length) { throw new ImageKnowledgeFailure('HeaderReadIncomplete','image-basic'); }
    return this.buffer[at-this.start];
  }
  step(): void { this.cancel.check(); if (++this.parts > ImageLimits.headerParts) { throw new ImageKnowledgeFailure('HeaderPartBudget','image-basic'); } }
  async u16(at: number, little: boolean = false): Promise<number> { const a: number = await this.byte(at); const b: number = await this.byte(at+1); return little ? a+b*256 : a*256+b; }
  async u32(at: number, little: boolean = false): Promise<number> { const a: number = await this.u16(at,little); const b: number = await this.u16(at+2,little); return little ? a+b*65536 : a*65536+b; }
  async tag(at: number): Promise<string> { let s: string = ''; for (let i: number = 0; i < 4; i++) { s += String.fromCharCode(await this.byte(at+i)); } return s; }
}
async function imageBasicJpeg(c: ImageBasicCursor): Promise<ImageHeaderEvidence> {
  const e: ImageHeaderEvidence = new ImageHeaderEvidence(); e.encoding = ImageEncoding.Jpeg; e.mime = 'image/jpeg'; e.variant = 'JPEG-SOF';
  let at: number = 2;
  while (at < c.reader.length) {
    c.step(); if (await c.byte(at++) !== 255) { throw new ImageKnowledgeFailure('JpegMarkerBoundary','image-basic'); }
    while (await c.byte(at) === 255) { at++; c.step(); }
    const marker: number = await c.byte(at++);
    if (marker === 0xda || marker === 0xd9) { break; }
    if (marker === 0x01 || marker >= 0xd0 && marker <= 0xd7) { continue; }
    const length: number = await c.u16(at);
    if (length < 2 || at+length > c.reader.length) { throw new ImageKnowledgeFailure('JpegSegmentLength','image-basic'); }
    if ([0xc0,0xc1,0xc2,0xc3,0xc5,0xc6,0xc7,0xc9,0xca,0xcb,0xcd,0xce,0xcf].indexOf(marker) >= 0) {
      if (length < 8) { throw new ImageKnowledgeFailure('JpegDimensionsMissing','image-basic'); }
      e.height = await c.u16(at+3); e.width = await c.u16(at+5); e.staticContainer = true; return e;
    }
    at += length;
  }
  throw new ImageKnowledgeFailure('JpegDimensionsMissing','image-basic');
}
async function imageBasicPng(c: ImageBasicCursor): Promise<ImageHeaderEvidence> {
  if (await c.u32(8) !== 13 || await c.tag(12) !== 'IHDR' || c.reader.length < 33) { throw new ImageKnowledgeFailure('PngHeaderMissing','image-basic'); }
  const e: ImageHeaderEvidence = new ImageHeaderEvidence(); e.encoding = ImageEncoding.Png; e.mime = 'image/png'; e.variant = 'PNG-IHDR';
  e.width = await c.u32(16); e.height = await c.u32(20); const color: number = await c.byte(25); e.alpha = color === 4 || color === 6;
  // APNG acTL precedes IDAT. Walk only chunk headers, not CRC/payload or full grammar.
  let at: number = 33;
  while (at+8 <= c.reader.length) {
    c.step(); const length: number = await c.u32(at); const tag: string = await c.tag(at+4);
    if (tag === 'acTL' || tag === 'fcTL') { throw new ImageKnowledgeFailure('AnimatedImageOutsideScope','image-basic'); }
    if (tag === 'IDAT' || tag === 'IEND') { break; }
    if (at+12+length > c.reader.length) { break; } at += 12+length;
  }
  e.staticContainer = true; return e;
}
async function imageBasicWebp(c: ImageBasicCursor): Promise<ImageHeaderEvidence> {
  if (await c.tag(8) !== 'WEBP') { throw new ImageKnowledgeFailure('WebpSignature','image-basic'); }
  const e: ImageHeaderEvidence = new ImageHeaderEvidence(); e.encoding = ImageEncoding.Webp; e.mime = 'image/webp';
  const tag: string = await c.tag(12); e.variant = tag;
  if (tag === 'VP8X') {
    const flags: number = await c.byte(20); if ((flags & 2) !== 0) { throw new ImageKnowledgeFailure('AnimatedImageOutsideScope','image-basic'); }
    e.alpha = (flags & 16) !== 0;
    e.width = 1+await c.u16(24,true)+(await c.byte(26))*65536; e.height = 1+await c.u16(27,true)+(await c.byte(29))*65536;
  } else if (tag === 'VP8L') {
    if (await c.byte(20) !== 47) { throw new ImageKnowledgeFailure('WebpLosslessHeader','image-basic'); }
    const bits: number = await c.u32(21,true); e.width = 1+(bits & 16383); e.height = 1+((bits >>> 14) & 16383); e.alpha = (bits & 0x10000000) !== 0;
  } else if (tag === 'VP8 ') {
    if (await c.byte(23) !== 157 || await c.byte(24) !== 1 || await c.byte(25) !== 42) { throw new ImageKnowledgeFailure('WebpFrameHeader','image-basic'); }
    e.width = (await c.u16(26,true)) & 16383; e.height = (await c.u16(28,true)) & 16383;
  } else { throw new ImageKnowledgeFailure('WebpDimensionsMissing','image-basic'); }
  e.staticContainer = true; return e;
}
export async function imageInspectHeader(reader: ImageHeaderReader, suffix: string, cancel: KnowledgeCancellation): Promise<ImageHeaderEvidence> {
  if (!Number.isSafeInteger(reader.length) || reader.length < 12 || reader.length > ImageLimits.bytes) { throw new ImageKnowledgeFailure('ImageByteBudget','image-basic'); }
  const c: ImageBasicCursor = new ImageBasicCursor(reader,cancel); let e: ImageHeaderEvidence;
  if (await c.u16(0) === 0xffd8) { e = await imageBasicJpeg(c); }
  else if (await c.u32(0) === 0x89504e47 && await c.u32(4) === 0x0d0a1a0a) { e = await imageBasicPng(c); }
  else if (await c.tag(0) === 'RIFF') { e = await imageBasicWebp(c); }
  else { throw new ImageKnowledgeFailure('UnsupportedImageEncoding','image-basic'); }
  if (!Number.isSafeInteger(e.width) || !Number.isSafeInteger(e.height) || e.width < 1 || e.height < 1 || e.width*e.height > ImageLimits.pixels) { throw new ImageKnowledgeFailure('ImagePixelBudget','image-basic'); }
  const expected: string[] = e.encoding === ImageEncoding.Jpeg ? ['.jpg','.jpeg'] : e.encoding === ImageEncoding.Png ? ['.png'] : ['.webp'];
  if (expected.indexOf(suffix.toLowerCase()) < 0) { e.warnings.push('SuffixEncodingConflict'); }
  return e;
}
