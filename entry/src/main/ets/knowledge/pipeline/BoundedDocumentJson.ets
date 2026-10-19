import { PdfBudget, KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { pdfStrictUtf8 } from './SafeZipPolicy';
import { documentUtf8Bytes } from '../domain/DocumentParseModels';

export class PdfJsonField { key: string = ''; node: PdfJsonNode = new PdfJsonNode(); }
export class PdfJsonNode {
  kind: string = ''; text: string = ''; numeric: number = 0; fields: PdfJsonField[] = []; items: PdfJsonNode[] = [];
  optional(key: string): PdfJsonNode | undefined {
    if (this.kind !== 'object') { throw new KnowledgeFailure('JsonObjectRequired','pdf-json'); }
    return this.fields.find((field: PdfJsonField): boolean => field.key === key)?.node;
  }
  required(key: string): PdfJsonNode { const node: PdfJsonNode | undefined = this.optional(key); if (node === undefined) { throw new KnowledgeFailure('JsonFieldMissing','pdf-json'); } return node; }
  string(): string { if (this.kind !== 'string') { throw new KnowledgeFailure('JsonStringRequired','pdf-json'); } return this.text; }
  array(): PdfJsonNode[] { if (this.kind !== 'array') { throw new KnowledgeFailure('JsonArrayRequired','pdf-json'); } return this.items; }
  integer(): number { if (this.kind !== 'number' || !Number.isSafeInteger(this.numeric)) { throw new KnowledgeFailure('JsonIntegerRequired','pdf-json'); } return this.numeric; }
}
class PdfJsonCursor {
  private bytes: Uint8Array; private cancel: KnowledgeCancellation;
  private offset: number = 0; private buffer: string = ''; private at: number = 0;
  constructor(bytes: Uint8Array, cancel: KnowledgeCancellation) { this.bytes = bytes; this.cancel = cancel; }
  peek(count: number = 1): string {
    while (this.buffer.length-this.at < count && this.offset < this.bytes.length) {
      this.cancel.check(); this.buffer = this.buffer.slice(this.at); this.at = 0;
      let end: number = Math.min(this.offset+16384,this.bytes.length);
      if (end < this.bytes.length) { while (end > this.offset && (this.bytes[end]&0xc0) === 0x80) { end--; } }
      if (end <= this.offset) { throw new KnowledgeFailure('JsonUtf8Boundary','pdf-json'); }
      this.buffer += pdfStrictUtf8(this.bytes.subarray(this.offset,end)); this.offset = end;
    }
    return this.buffer.slice(this.at,this.at+count);
  }
  take(count: number = 1): string { const value: string = this.peek(count); this.at += value.length; return value; }
}
export class BoundedDocumentJson {
  private raw: PdfJsonCursor; private tokens: number = 0; private cancel: KnowledgeCancellation;
  private stringLimit: number;
  constructor(bytes: Uint8Array, cancel: KnowledgeCancellation, stringLimit: number = 262144) {
    if (bytes.length > PdfBudget.jsonBytes) { throw new KnowledgeFailure('JsonBytes','pdf-json'); }
    this.raw = new PdfJsonCursor(bytes,cancel); this.cancel = cancel; this.stringLimit = stringLimit;
  }
  private fail(): KnowledgeFailure { return new KnowledgeFailure('JsonGrammarOrBudget','pdf-json'); }
  private token(): void { this.cancel.check(); if (++this.tokens > 1000000) { throw this.fail(); } }
  private space(): void { let count: number = 0; while (this.raw.peek().length > 0 && ' \r\n\t'.indexOf(this.raw.peek()) >= 0) { this.raw.take(); if (++count%4096 === 0) { this.cancel.check(); } } }
  private take(c: string): void { this.space(); if (this.raw.take() !== c) { throw this.fail(); } }
  private escapedUnit(): number {
    const hex: string = this.raw.take(4); if (!new RegExp('^[0-9a-fA-F]{4}$').test(hex)) { throw this.fail(); }
    return Number.parseInt(hex,16);
  }
  private text(): string {
    this.take('"'); let output: string = ''; let bytes: number = 0;
    while (this.raw.peek().length > 0) {
      let part: string = this.raw.take();
      if (part === '"') { return output; } if (part.charCodeAt(0) < 32) { throw this.fail(); }
      if (part === '\\') {
        const escape: string = this.raw.take();
        if (escape === 'u') {
          const high: number = this.escapedUnit();
          if (high >= 0xd800 && high <= 0xdbff) {
            if (this.raw.take(2) !== '\\u') { throw this.fail(); }
            const low: number = this.escapedUnit(); if (low < 0xdc00 || low > 0xdfff) { throw this.fail(); }
            part = String.fromCharCode(high,low);
          } else { if (high >= 0xdc00 && high <= 0xdfff) { throw this.fail(); } part = String.fromCharCode(high); }
        } else if (escape === '"' || escape === '\\' || escape === '/') { part = escape; }
        else if (escape === 'n') { part = '\n'; } else if (escape === 'r') { part = '\r'; } else if (escape === 't') { part = '\t'; }
        else if (escape === 'b') { part = '\b'; } else if (escape === 'f') { part = '\f'; } else { throw this.fail(); }
      } else if (part.charCodeAt(0) >= 0xd800 && part.charCodeAt(0) <= 0xdbff) { part += this.raw.take(); }
      const extra: number = documentUtf8Bytes(part); if (extra > this.stringLimit-bytes) { throw this.fail(); } bytes += extra; output += part;
      if (bytes%4096 < 4) { this.cancel.check(); }
    } throw this.fail();
  }
  private node(depth: number): PdfJsonNode {
    this.space(); this.token(); if (depth > 64) { throw this.fail(); }
    const node: PdfJsonNode = new PdfJsonNode(); const c: string = this.raw.peek();
    if (c === '{' || c === '[') {
      this.raw.take(); node.kind = c === '{' ? 'object' : 'array'; this.space(); const end: string = c === '{' ? '}' : ']';
      if (this.raw.peek() === end) { this.raw.take(); return node; }
      while (this.raw.peek().length > 0) {
        if (c === '{') {
          if (node.fields.length >= 256) { throw this.fail(); } this.token(); const key: string = this.text();
          if (node.fields.some((field: PdfJsonField): boolean => field.key === key)) { throw this.fail(); } this.take(':');
          const field: PdfJsonField = new PdfJsonField(); field.key = key; field.node = this.node(depth+1); node.fields.push(field);
        } else { this.token(); node.items.push(this.node(depth+1)); }
        this.space(); if (this.raw.peek() === end) { this.raw.take(); return node; } this.take(',');
      } throw this.fail();
    }
    if (c === '"') { node.kind = 'string'; node.text = this.text(); return node; }
    for (const literal of ['true','false','null']) { if (this.raw.peek(literal.length) === literal) { this.raw.take(literal.length); node.kind = literal; return node; } }
    let numeric: string = '';
    while (this.raw.peek().length > 0 && '-+0123456789.eE'.indexOf(this.raw.peek()) >= 0) { if (numeric.length >= 128) { throw this.fail(); } numeric += this.raw.take(); }
    if (!new RegExp('^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$').test(numeric)) { throw this.fail(); }
    node.kind = 'number'; node.numeric = Number(numeric); if (!Number.isFinite(node.numeric)) { throw this.fail(); } return node;
  }
  read(): PdfJsonNode { const root: PdfJsonNode = this.node(1); this.space(); if (this.raw.peek().length > 0) { throw this.fail(); } return root; }
}
