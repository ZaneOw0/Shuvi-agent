import { KnowledgeRangeReader } from '../domain/KnowledgePorts';
import { KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';

export class PdfFixtureReader implements KnowledgeRangeReader {
  length: number;
  reads: number = 0;
  closed: boolean = false;
  private bytes: Uint8Array;
  constructor(bytes: Uint8Array) { this.bytes = bytes; this.length = bytes.length; }
  async read(offset: number, length: number, cancel: KnowledgeCancellation): Promise<Uint8Array> {
    cancel.check();
    if (this.closed || offset < 0 || length < 0 || length > 65536 || offset+length > this.length) { throw new KnowledgeFailure('FixtureRange','suite'); }
    this.reads++; return this.bytes.slice(offset,offset+length);
  }
  async close(): Promise<void> { this.closed = true; }
}
export function pdfFixtureCrc(bytes: Uint8Array): number {
  let crc: number = 0xffffffff;
  for (const byte of bytes) { crc ^= byte; for (let bit: number = 0; bit < 8; bit++) { crc = (crc>>>1)^((crc&1) === 1 ? 0xedb88320 : 0); } }
  return (crc^0xffffffff)>>>0;
}
export function pdfFixtureSmall(): Uint8Array {
  const hex: string = '0bf20ff5733152c84b2cc92c4b55284a2c5748cbac28292d4ae50a1ac43200';
  const bytes: Uint8Array = new Uint8Array(hex.length/2);
  for (let at: number = 0; at < bytes.length; at++) { bytes[at] = Number.parseInt(hex.substring(at*2,at*2+2),16); }
  return bytes;
}
export function pdfFixtureSmallPlain(): Uint8Array {
  const text: string = 'ROUND2 native raw fixture\n'.repeat(7); const bytes: Uint8Array = new Uint8Array(text.length);
  for (let at: number = 0; at < text.length; at++) { bytes[at] = text.charCodeAt(at); } return bytes;
}
export function pdfFixtureResidual(): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(208);
  bytes.set([237,193,49,1,0,0,0,194,160,108,235,95,202,223,12,64,1]); bytes[206] = 192; bytes[207] = 25;
  return bytes;
}
export function pdfFixtureRawBlocks(plain: Uint8Array): Uint8Array {
  const count: number = Math.ceil(plain.length/32768); const bytes: Uint8Array = new Uint8Array(plain.length+5*count);
  let target: number = 0;
  for (let source: number = 0; source < plain.length; source += 32768) {
    const length: number = Math.min(32768,plain.length-source);
    bytes[target++] = source+length === plain.length ? 1 : 0;
    bytes[target++] = length&255; bytes[target++] = length>>>8;
    bytes[target++] = (~length)&255; bytes[target++] = ((~length)>>>8)&255;
    bytes.set(plain.subarray(source,source+length),target); target += length;
  } return bytes;
}
