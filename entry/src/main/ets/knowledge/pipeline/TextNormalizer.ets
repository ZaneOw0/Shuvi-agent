import { TextBudget, TextFailure, TextNormalized, TextSourceRange } from '../domain/TextKnowledgeModels';

export function encodeTextUtf8(text: string): Uint8Array {
  const bytes: number[] = [];
  for (let i: number = 0; i < text.length; i++) {
    let code: number = text.charCodeAt(i);
    if (code >= 0xD800 && code <= 0xDBFF) {
      const low: number = text.charCodeAt(++i);
      if (!(low >= 0xDC00 && low <= 0xDFFF)) { throw new TextFailure('ENCODING', 'encode', '非法代理对'); }
      code = 0x10000 + ((code - 0xD800) << 10) + low - 0xDC00;
    } else if (code >= 0xDC00 && code <= 0xDFFF) { throw new TextFailure('ENCODING', 'encode', '孤立低代理'); }
    if (code < 0x80) { bytes.push(code); }
    else if (code < 0x800) { bytes.push(0xC0 | (code >> 6), 0x80 | (code & 63)); }
    else if (code < 0x10000) { bytes.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63)); }
    else { bytes.push(0xF0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63)); }
  }
  return new Uint8Array(bytes);
}

export function normalizeText(bytes: Uint8Array): TextNormalized {
  if (bytes.length === 0 || bytes.length > TextBudget.fileBytes) {
    throw new TextFailure('BUDGET', 'decode', '原件为空或超过 1 MiB');
  }
  const head: string = Array.from(bytes.slice(0, 8)).map((byte: number): string => String.fromCharCode(byte)).join('');
  if (head.startsWith('%PDF-') || head.startsWith('PK\u0003\u0004') || head.startsWith('GIF87a') || head.startsWith('GIF89a') ||
    head.startsWith('\u0089PNG') || head.startsWith('\u007fELF') || (bytes[0] === 0xFF && bytes[1] === 0xD8)) {
    throw new TextFailure('TYPE', 'decode', '检测到非文本容器/图像签名，拒绝类型伪装');
  }
  const parts: string[] = [];
  for (let i: number = 0; i < bytes.length;) {
    const first: number = bytes[i++];
    let code: number = first;
    let following: number = 0;
    let minimum: number = 0;
    if (first >= 0xC2 && first <= 0xDF) { code = first & 31; following = 1; minimum = 0x80; }
    else if (first >= 0xE0 && first <= 0xEF) { code = first & 15; following = 2; minimum = 0x800; }
    else if (first >= 0xF0 && first <= 0xF4) { code = first & 7; following = 3; minimum = 0x10000; }
    else if (first >= 0x80) { throw new TextFailure('ENCODING', 'decode', '非法 UTF-8 起始字节'); }
    for (let n: number = 0; n < following; n++) {
      if (i >= bytes.length || (bytes[i] & 0xC0) !== 0x80) {
        throw new TextFailure('ENCODING', 'decode', 'UTF-8 截断或续字节非法');
      }
      code = (code << 6) | (bytes[i++] & 63);
    }
    if (code < minimum || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) {
      throw new TextFailure('ENCODING', 'decode', 'UTF-8 非最短编码或非法码点');
    }
    if (code === 0 || (code < 32 && code !== 9 && code !== 10 && code !== 13)) {
      throw new TextFailure('TYPE', 'decode', '检测到二进制控制字符，不作为文本导入');
    }
    parts.push(String.fromCodePoint(code));
  }
  const result: TextNormalized = new TextNormalized();
  result.originalText = parts.join('');
  result.bom = result.originalText.charCodeAt(0) === 0xFEFF;
  result.originalOffsets = [];
  const normalized: string[] = [];
  for (let i: number = result.bom ? 1 : 0; i < result.originalText.length; i++) {
    result.originalOffsets.push(i);
    const ch: string = result.originalText.charAt(i);
    if (ch === '\r') {
      normalized.push('\n');
      if (result.originalText.charAt(i + 1) === '\n') { i++; }
    } else { normalized.push(ch); }
  }
  result.originalOffsets.push(result.originalText.length);
  result.text = normalized.join('');
  for (let i: number = 0; i < result.originalText.length; i++) {
    if (result.originalText.charAt(i) === '\r') {
      if (result.originalText.charAt(i + 1) === '\n') { i++; }
      result.lineStarts.push(i + 1);
    } else if (result.originalText.charAt(i) === '\n') { result.lineStarts.push(i + 1); }
  }
  if (result.text.trim().length === 0) { throw new TextFailure('EMPTY', 'decode', '原件仅包含空白'); }
  return result;
}

function sourceLine(starts: number[], index: number): number {
  let low: number = 0;
  let high: number = starts.length;
  while (low + 1 < high) {
    const middle: number = Math.floor((low + high) / 2);
    if (starts[middle] <= index) { low = middle; } else { high = middle; }
  }
  return low + 1;
}
export function sourceRange(normalized: TextNormalized, start: number, end: number,
  nodeId: string, headings: string[]): TextSourceRange {
  if (start < 0 || end < start || end > normalized.text.length) {
    throw new TextFailure('LOCATOR', 'mapping', '规范化范围越界');
  }
  const range: TextSourceRange = new TextSourceRange();
  range.normalizedStart = start;
  range.normalizedEnd = end;
  range.originalStart = normalized.originalOffsets[start];
  range.originalEnd = normalized.originalOffsets[end];
  range.startLine = sourceLine(normalized.lineStarts, range.originalStart);
  range.endLine = sourceLine(normalized.lineStarts, Math.max(range.originalStart, range.originalEnd - 1));
  range.nodeId = nodeId;
  range.headingPath = headings.slice();
  return range;
}
