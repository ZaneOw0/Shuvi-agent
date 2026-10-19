import { DocumentRemoteState, DocumentParseFailure, DocumentParseBudget, documentUtf8Bytes, DocumentParseFormat, ParseFailureDetail } from '../domain/DocumentParseModels';
import { documentSafeId } from './DocumentParsePolicy';
import { parseHttpFailure, parseProviderFailure } from './ParseFailurePolicy';

// Exact endpoints and role hosts transcribed from the user-provided official API document.
export const MINERU_ALLOCATION_ENDPOINT: string = 'https://mineru.net/api/v4/file-urls/batch';
export const MINERU_QUERY_ENDPOINT: string = 'https://mineru.net/api/v4/extract-results/batch/';
export const MINERU_UPLOAD_HOST: string = 'mineru.oss-cn-shanghai.aliyuncs.com';
export const MINERU_RESULT_HOST: string = 'cdn-mineru.openxlab.org.cn';
export class MineruAllocationDTO { batchId: string = ''; uploadAddress: string = ''; }
export class MineruInspectionDTO {
  batchId: string = ''; dataId: string = ''; state: DocumentRemoteState = DocumentRemoteState.Unobserved;
  resultAddress: string = ''; extractedPages: number = 0; totalPages: number = 0;
  failureDetail: ParseFailureDetail = new ParseFailureDetail();
}
class MineruJsonField { key: string = ''; node: MineruJsonNode = new MineruJsonNode(); }
class MineruJsonNode {
  kind: string = ''; text: string = ''; numberValue: number = 0;
  fields: MineruJsonField[] = []; elements: MineruJsonNode[] = [];
  required(key: string): MineruJsonNode {
    const field: MineruJsonField | undefined = this.fields.find((f: MineruJsonField): boolean => f.key === key);
    if (this.kind !== 'OBJECT' || field === undefined) { throw new DocumentParseFailure('控制字段缺失或类型错误', '协议'); }
    return field.node;
  }
  optional(key: string): MineruJsonNode | undefined {
    if (this.kind !== 'OBJECT') { throw new DocumentParseFailure('控制字段类型错误', '协议'); }
    return this.fields.find((f: MineruJsonField): boolean => f.key === key)?.node;
  }
  stringValue(): string { if (this.kind !== 'STRING') { throw new DocumentParseFailure('控制字段非字符串', '协议'); } return this.text; }
  integer(): number { if (this.kind !== 'NUMBER' || !Number.isSafeInteger(this.numberValue)) { throw new DocumentParseFailure('控制字段非安全整数', '协议'); } return this.numberValue; }
  single(): MineruJsonNode { if (this.kind !== 'ARRAY' || this.elements.length !== 1) { throw new DocumentParseFailure('本轮批次必须恰为单项', '协议'); } return this.elements[0]; }
}
class MineruJsonReader {
  private raw: string; private at: number = 0; private tokens: number = 0;
  constructor(raw: string) {
    if (raw.length > DocumentParseBudget.jsonBytes || documentUtf8Bytes(raw) > DocumentParseBudget.jsonBytes) { throw new DocumentParseFailure('控制响应实际字节超限', '协议'); }
    this.raw = raw;
  }
  private fail(): void { throw new DocumentParseFailure('控制JSON非法或预算超限', '协议'); }
  private space(): void { while (this.at < this.raw.length && [32,9,10,13].indexOf(this.raw.charCodeAt(this.at)) >= 0) { this.at++; } }
  private token(): void { if (++this.tokens > DocumentParseBudget.jsonTokens) { this.fail(); } }
  private char(): string { return this.raw.charAt(this.at); }
  private take(c: string): void { this.space(); if (this.char() !== c) { this.fail(); } this.at++; }
  private readString(): string {
    this.take('"'); let text: string = '';
    while (this.at < this.raw.length) {
      let c: string = this.raw.charAt(this.at++);
      if (c === '"') { if (documentUtf8Bytes(text) > 16384) { this.fail(); } return text; }
      if (c.charCodeAt(0) < 32) { this.fail(); }
      if (c === '\\') {
        c = this.raw.charAt(this.at++);
        if (c === 'u') {
          const hex: string = this.raw.slice(this.at, this.at + 4);
          if (!new RegExp('^[0-9a-fA-F]{4}$').test(hex)) { this.fail(); }
          this.at += 4; text += String.fromCharCode(Number.parseInt(hex, 16));
        } else if (c === '"' || c === '\\' || c === '/') { text += c; }
        else if (c === 'b') { text += '\b'; } else if (c === 'f') { text += '\f'; }
        else if (c === 'n') { text += '\n'; } else if (c === 'r') { text += '\r'; } else if (c === 't') { text += '\t'; }
        else { this.fail(); }
      } else { text += c; }
      if (text.length > 16384) { this.fail(); }
    }
    this.fail(); return '';
  }
  private readNode(depth: number): MineruJsonNode {
    this.space(); this.token(); if (depth > 16) { this.fail(); }
    const node: MineruJsonNode = new MineruJsonNode(); const c: string = this.char();
    if (c === '{') {
      this.at++; node.kind = 'OBJECT'; this.space(); if (this.char() === '}') { this.at++; return node; }
      while (this.at < this.raw.length) {
        this.token(); const key: string = this.readString(); this.take(':');
        if (node.fields.some((field: MineruJsonField): boolean => field.key === key)) { this.fail(); }
        const field: MineruJsonField = new MineruJsonField(); field.key = key; field.node = this.readNode(depth + 1); node.fields.push(field);
        this.space(); if (this.char() === '}') { this.at++; return node; } this.take(',');
      }
      this.fail(); return node;
    }
    if (c === '[') {
      this.at++; node.kind = 'ARRAY'; this.space(); if (this.char() === ']') { this.at++; return node; }
      while (this.at < this.raw.length) {
        node.elements.push(this.readNode(depth + 1)); this.space();
        if (this.char() === ']') { this.at++; return node; } this.take(',');
      } this.fail(); return node;
    }
    if (c === '"') { node.kind = 'STRING'; node.text = this.readString(); return node; }
    for (const literal of ['true', 'false', 'null']) {
      if (this.raw.slice(this.at, this.at + literal.length) === literal) { this.at += literal.length; node.kind = literal; return node; }
    }
    const start: number = this.at;
    while (this.at < this.raw.length && '-+0123456789.eE'.indexOf(this.char()) >= 0) { this.at++; }
    const numberText: string = this.raw.slice(start, this.at);
    if (!new RegExp('^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$').test(numberText)) { this.fail(); }
    node.kind = 'NUMBER'; node.numberValue = Number(numberText);
    if (!Number.isFinite(node.numberValue)) { this.fail(); } return node;
  }
  read(): MineruJsonNode {
    const root: MineruJsonNode = this.readNode(1); this.space(); if (this.at !== this.raw.length) { this.fail(); } return root;
  }
}
function mineruRoot(raw: string): MineruJsonNode {
  const root: MineruJsonNode = new MineruJsonReader(raw).read(); const code: MineruJsonNode = root.required('code');
  const reason: string = root.required('msg').stringValue();
  if (code.kind === 'STRING') {
    const text: string = code.stringValue();
    throw parseProviderFailure(text,reason,'控制响应');
  }
  const numberCode: number = code.integer();
  if (numberCode !== 0) { throw parseProviderFailure(`${numberCode}`,reason,'控制响应'); }
  return root.required('data');
}
export function mineruHttpStatus(code: number, retryAfter: string | undefined): void {
  if (code !== 200) { throw parseHttpFailure(code,retryAfter); }
}
export function mineruDecodeAllocation(raw: string): MineruAllocationDTO {
  const data: MineruJsonNode = mineruRoot(raw); const dto: MineruAllocationDTO = new MineruAllocationDTO();
  dto.batchId = data.required('batch_id').stringValue(); dto.uploadAddress = data.required('file_urls').single().stringValue();
  if (!documentSafeId(dto.batchId)) { throw new DocumentParseFailure('批次身份非法', '申请'); }
  return dto;
}
export function mineruDecodeInspection(raw: string, batch: string, dataId: string): MineruInspectionDTO {
  const data: MineruJsonNode = mineruRoot(raw); const dto: MineruInspectionDTO = new MineruInspectionDTO();
  dto.batchId = data.required('batch_id').stringValue(); const item: MineruJsonNode = data.required('extract_result').single();
  dto.dataId = item.required('data_id').stringValue(); item.required('file_name').stringValue();
  if (!documentSafeId(dto.batchId) || !documentSafeId(dto.dataId) || dto.batchId !== batch || dto.dataId !== dataId) { throw new DocumentParseFailure('远端批次或数据身份不符', '查询'); }
  const stateText: string = item.required('state').stringValue();
  const states: DocumentRemoteState[] = [DocumentRemoteState.Waiting, DocumentRemoteState.Pending, DocumentRemoteState.Converting, DocumentRemoteState.Running, DocumentRemoteState.Done, DocumentRemoteState.Failed];
  const state: DocumentRemoteState | undefined = states.find((s: DocumentRemoteState): boolean => s === stateText);
  if (state === undefined) { throw new DocumentParseFailure('服务状态不兼容', '查询'); } dto.state = state;
  if (state === DocumentRemoteState.Failed) {
    // Top-level msg is established by the existing control contract. Unknown per-item fields are not guessed.
    const top: MineruJsonNode = new MineruJsonReader(raw).read(); dto.failureDetail = parseProviderFailure('',top.required('msg').stringValue() === 'ok' ? '' : top.required('msg').stringValue(),'云解析').detail;
  }
  const progress: MineruJsonNode | undefined = item.optional('extract_progress');
  if (progress !== undefined) {
    dto.extractedPages = progress.required('extracted_pages').integer(); dto.totalPages = progress.required('total_pages').integer();
    if (dto.extractedPages < 0 || dto.totalPages < 1 || dto.totalPages > 200 || dto.extractedPages > dto.totalPages) { throw new DocumentParseFailure('服务进度字段非法', '查询'); }
    const time: MineruJsonNode | undefined = progress.optional('start_time'); if (time !== undefined) { time.stringValue(); }
  }
  if (dto.state === DocumentRemoteState.Done) { dto.resultAddress = item.required('full_zip_url').stringValue(); mineruValidateDestination(dto.resultAddress, 'RESULT'); }
  return dto;
}
export function mineruValidateDestination(address: string, role: string): void {
  if (address.length > 16384 || !address.startsWith('https://') || new RegExp('[\\x00-\\x20\\x7F\\\\#]').test(address)) { throw new DocumentParseFailure('接收方或地址格式未获核验', '传输'); }
  const hostEnd: number = address.indexOf('/', 8);
  if (hostEnd < 0) { throw new DocumentParseFailure('接收方路径缺失', '传输'); }
  const authority: string = address.slice(8, hostEnd); const host: string = role === 'UPLOAD' ? MINERU_UPLOAD_HOST : role === 'RESULT' ? MINERU_RESULT_HOST : 'mineru.net';
  if (authority !== host && authority !== host + ':443') { throw new DocumentParseFailure('接收方未获核验', '传输'); }
  const pathEnd: number = address.indexOf('?', hostEnd); const path: string = address.slice(hostEnd, pathEnd < 0 ? address.length : pathEnd);
  const prefix: string = role === 'UPLOAD' ? '/api-upload/' : role === 'RESULT' ? '/pdf/' : '/api/v4/';
  if (!path.startsWith(prefix) || path.length <= prefix.length || path.includes('%') || path.includes('//') || path.split('/').some((p: string): boolean => p === '..' || p === '.') ||
    new RegExp('%(0[0-9a-f]|1[0-9a-f]|7f)', 'i').test(address) || role !== 'UPLOAD' && role !== 'RESULT' && role !== 'CONTROL') {
    throw new DocumentParseFailure('目的地角色或路径非法', '传输');
  }
}
export function mineruAllocationPayload(dataId: string, format: DocumentParseFormat): string {
  if (!documentSafeId(dataId)) { throw new DocumentParseFailure('业务身份非法', '申请'); }
  if ([DocumentParseFormat.Pdf,DocumentParseFormat.Docx,DocumentParseFormat.Pptx,DocumentParseFormat.Xlsx,DocumentParseFormat.Jpeg,DocumentParseFormat.Png,DocumentParseFormat.Webp].indexOf(format) < 0) { throw new DocumentParseFailure('未知请求格式','申请'); }
  const suffix: string = format === DocumentParseFormat.Jpeg ? 'jpg' : format.toLowerCase();
  return '{"files":[{"name":' + JSON.stringify(dataId + '.' + suffix) + ',"data_id":' + JSON.stringify(dataId) + ',"is_ocr":false}],"model_version":"vlm","enable_table":true,"enable_formula":true,"language":"ch"}';
}
export class MineruBoundedBytes {
  count: number = 0;
  reserve(bytes: number, maximum: number): void {
    if (!Number.isSafeInteger(bytes) || bytes < 0 || this.count + bytes > maximum) { throw new DocumentParseFailure('实际流字节超限', '传输'); }
    this.count += bytes;
  }
}
