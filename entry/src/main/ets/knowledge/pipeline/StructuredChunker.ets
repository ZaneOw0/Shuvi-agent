import {
  TextBudget, TextFailure, TextSnapshot, TextChunk, TextNode, TextNodeKind, TextProcessed,
  TextDocument, TextSourceRange, TextCell, TextRangeRole
} from '../domain/TextKnowledgeModels';
import { normalizeText, encodeTextUtf8, sourceRange } from './TextNormalizer';
import { parseTextStructure } from './MarkdownStructure';
import { chunkText } from './Chunker';

export function structuredChunks(snapshot: TextSnapshot, generation: string): TextChunk[] {
  const chunks: TextChunk[] = [];
  for (const node of snapshot.nodes) {
    if (node.kind === TextNodeKind.Heading || node.kind === TextNodeKind.Image) { continue; }
    let prefix: string = node.headingPath.join(' > ');
    if (prefix.length > 0) { prefix += '\n'; }
    if (node.kind === TextNodeKind.Table) {
      prefix += node.cells.filter((cell: TextCell): boolean => cell.header)
        .map((cell: TextCell): string => cell.text).join(' | ') + '\n';
    }
    // Reject impossible prefixes rather than silently dropping a title/header.
    if (prefix.length >= TextBudget.chunkUnits - 2) {
      throw new TextFailure('BUDGET', 'chunk', '标题路径或表头过长，无法保留完整索引输入');
    }
    const available: number = TextBudget.chunkUnits - prefix.length;
    let evidenceStart: number = node.range.normalizedStart;
    let evidence: string = node.text;
    if (node.kind === TextNodeKind.Table) {
      const headerEnd: number = node.text.indexOf('\n');
      const delimiterEnd: number = headerEnd < 0 ? -1 : node.text.indexOf('\n', headerEnd + 1);
      if (delimiterEnd < 0 || node.cells.every((cell: TextCell): boolean => cell.header)) {
        snapshot.warnings.push('表格没有数据行，保留完整结构但不创建仅表头证据'); continue;
      }
      evidenceStart += delimiterEnd + 1; evidence = node.text.slice(delimiterEnd + 1);
    }
    const slices = chunkText(evidence, available, Math.min(0.4, TextBudget.overlap / available));
    for (const slice of slices) {
      const chunk: TextChunk = new TextChunk();
      chunk.id = `${generation}-c${chunks.length}`; chunk.documentId = snapshot.documentId;
      chunk.snapshotId = snapshot.id; chunk.generation = generation; chunk.ordinal = chunks.length;
      chunk.kind = node.kind; chunk.prefix = prefix; chunk.evidenceText = slice.text;
      chunk.retrievalText = prefix + slice.text; chunk.blockIds = [node.id];
      chunk.ranges = [sourceRange(snapshot.normalized, evidenceStart + slice.charOffset,
        evidenceStart + slice.charOffset + slice.text.length, node.id, node.headingPath)];
      let parentId: string = node.parentId;
      for (let depth: number = 0; parentId.length > 0 && depth < 8; depth++) {
        const parent: TextNode | undefined = snapshot.nodes.find((candidate: TextNode): boolean => candidate.id === parentId);
        if (parent === undefined) { break; }
        if (parent.kind === TextNodeKind.Heading) {
          const headingRange: TextSourceRange = sourceRange(snapshot.normalized, parent.range.normalizedStart,
            parent.range.normalizedEnd, parent.id, parent.headingPath);
          headingRange.role = TextRangeRole.Heading; chunk.ranges.push(headingRange); chunk.blockIds.push(parent.id);
        }
        parentId = parent.parentId;
      }
      if (node.kind === TextNodeKind.Table) {
        for (const cell of node.cells.filter((cell: TextCell): boolean => cell.header)) {
          const headerRange: TextSourceRange = sourceRange(snapshot.normalized, cell.range.normalizedStart,
            cell.range.normalizedEnd, node.id, node.headingPath);
          headerRange.role = TextRangeRole.Header; chunk.ranges.push(headerRange);
        }
      }
      chunks.push(chunk);
      if (chunks.length > TextBudget.activeChunks) { throw new TextFailure('BUDGET', 'chunk', '单篇块数超过 10000'); }
    }
  }
  if (chunks.length === 0) { throw new TextFailure('EMPTY', 'chunk', '没有可支撑检索的正文，原件保留'); }
  return chunks;
}

export function processText(bytes: Uint8Array, document: TextDocument, generation: string): TextProcessed {
  const result: TextProcessed = new TextProcessed();
  result.snapshot.id = `${generation}-snapshot`;
  result.snapshot.documentId = document.id; result.snapshot.documentVersion = document.version;
  result.snapshot.originalHash = document.original.hash; result.snapshot.normalized = normalizeText(bytes);
  parseTextStructure(result.snapshot, document.format);
  result.chunks = structuredChunks(result.snapshot, generation);
  validateProcessed(result, document, generation);
  verifyTextTransferBudget(result);
  return result;
}

export function validateProcessed(result: TextProcessed, document: TextDocument, generation: string): void {
  validateTextHeader(result, document);
  for (const chunk of result.chunks) { validateTextChunk(chunk, result.snapshot, document, generation); }
  for (const node of result.snapshot.nodes) { validateTextNode(node, result.snapshot); }
}
export function verifyTextTransferBudget(result: TextProcessed): void {
  const snapshot: TextSnapshot = result.snapshot;
  // Conservative application guard, not a claim about VM serializer overhead.
  let estimate: number = snapshot.normalized.originalOffsets.length * 8 +
    (snapshot.normalized.originalText.length + snapshot.normalized.text.length) * 2 + snapshot.normalized.lineStarts.length * 8;
  for (const node of snapshot.nodes) {
    estimate += 1024 + node.text.length * 2 + node.headingPath.join(' > ').length * 2;
    for (const cell of node.cells) { estimate += 512 + cell.text.length * 2; }
  }
  for (const chunk of result.chunks) {
    estimate += 1024 + (chunk.retrievalText.length + chunk.evidenceText.length + chunk.prefix.length) * 2;
  }
  if (estimate >= TextBudget.transferEstimateBytes) {
    throw new TextFailure('BUDGET', 'CPU transfer', '线程载荷估算超过 12 MiB 保护线；原件/旧索引保留，未截断');
  }
}
function validateTextHeader(result: TextProcessed, document: TextDocument): void {
  const snapshot: TextSnapshot = result.snapshot;
  if (typeof snapshot.id !== 'string' || typeof snapshot.documentId !== 'string' || typeof snapshot.originalHash !== 'string' ||
    typeof snapshot.normalized.text !== 'string' || typeof snapshot.normalized.originalText !== 'string' ||
    !Array.isArray(snapshot.nodes) || !Array.isArray(result.chunks) || !Array.isArray(snapshot.normalized.originalOffsets) ||
    snapshot.schemaVersion !== 1 || snapshot.parserVersion !== 'text-structure-v1' ||
    snapshot.documentId !== document.id || snapshot.originalHash !== document.original.hash ||
    snapshot.documentVersion !== document.version || snapshot.nodes.length > TextBudget.nodes ||
    snapshot.normalized.originalOffsets.length !== snapshot.normalized.text.length + 1 ||
    result.chunks.length === 0 || result.chunks.length > TextBudget.activeChunks) {
    throw new TextFailure('SCHEMA', 'validate', '文本产物版本或关联不一致');
  }
}
function validateTextChunk(chunk: TextChunk, snapshot: TextSnapshot, document: TextDocument, generation: string): void {
    if (typeof chunk.retrievalText !== 'string' || typeof chunk.evidenceText !== 'string' || typeof chunk.prefix !== 'string' ||
      !Array.isArray(chunk.ranges) || !Array.isArray(chunk.blockIds) ||
      chunk.generation !== generation || chunk.documentId !== document.id || chunk.snapshotId !== snapshot.id ||
      chunk.retrievalText !== chunk.prefix + chunk.evidenceText || chunk.retrievalText.length > TextBudget.chunkUnits ||
      chunk.ranges.length === 0 || (chunk.retrievalText.charCodeAt(0) >= 0xDC00 && chunk.retrievalText.charCodeAt(0) <= 0xDFFF) ||
      (chunk.retrievalText.charCodeAt(chunk.retrievalText.length - 1) >= 0xD800 && chunk.retrievalText.charCodeAt(chunk.retrievalText.length - 1) <= 0xDBFF)) {
      throw new TextFailure('SCHEMA', 'validate', '知识块输入或关联非法');
    }
    for (const range of chunk.ranges) {
      const actual: TextSourceRange = sourceRange(snapshot.normalized, range.normalizedStart, range.normalizedEnd,
        range.nodeId, range.headingPath);
      if (actual.originalStart !== range.originalStart || actual.originalEnd !== range.originalEnd ||
        actual.startLine !== range.startLine || actual.endLine !== range.endLine ||
         (range.role === TextRangeRole.Evidence && snapshot.normalized.text.slice(range.normalizedStart, range.normalizedEnd) !== chunk.evidenceText)) {
        throw new TextFailure('LOCATOR', 'validate', '知识块原文映射校验失败');
      }
    }
}
function validateTextNode(node: TextNode, snapshot: TextSnapshot): void {
    const range: TextSourceRange = sourceRange(snapshot.normalized, node.range.normalizedStart, node.range.normalizedEnd, node.id, node.headingPath);
    if (range.originalStart !== node.range.originalStart || range.originalEnd !== node.range.originalEnd ||
      (node.kind !== TextNodeKind.Heading && snapshot.normalized.text.slice(range.normalizedStart, range.normalizedEnd) !== node.text)) {
      throw new TextFailure('LOCATOR', 'validate', '结构节点定位不一致');
    }
    for (const cell of node.cells) {
      const actual: string = snapshot.normalized.text.slice(cell.range.normalizedStart, cell.range.normalizedEnd);
      if (actual !== cell.text) { throw new TextFailure('LOCATOR', 'validate', '表格单元格定位不一致'); }
    }
}
export async function validateProcessedBounded(result: TextProcessed, document: TextDocument, generation: string): Promise<void> {
  validateTextHeader(result, document);
  for (let start: number = 0; start < result.chunks.length; start += 100) {
    for (const chunk of result.chunks.slice(start, start + 100)) { validateTextChunk(chunk, result.snapshot, document, generation); }
    await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0); });
  }
  for (let start: number = 0; start < result.snapshot.nodes.length; start += 100) {
    for (const node of result.snapshot.nodes.slice(start, start + 100)) { validateTextNode(node, result.snapshot); }
    await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0); });
  }
}

// Versioned, explicit wire records avoid unchecked JSON casts and large RDB rows.
export function packTextFields(fields: string[]): string {
  return fields.map((field: string): string => encodeURIComponent(field)).join('\t');
}
export function unpackTextFields(row: string, count: number): string[] {
  const fields: string[] = row.split('\t').map((field: string): string => decodeURIComponent(field));
  if (fields.length !== count) { throw new TextFailure('SCHEMA', 'wire', '持久化记录字段数不匹配'); }
  return fields;
}
export function wireNumber(field: string): number {
  const parsed: number = Number(field);
  if (!Number.isSafeInteger(parsed) || parsed < 0) { throw new TextFailure('SCHEMA', 'wire', '持久化数字非法'); }
  return parsed;
}
export function encodeRanges(ranges: TextSourceRange[]): string {
  return ranges.map((range: TextSourceRange): string => packTextFields([
    `${range.originalStart}`, `${range.originalEnd}`, `${range.normalizedStart}`, `${range.normalizedEnd}`,
    `${range.startLine}`, `${range.endLine}`, range.nodeId, packTextFields(range.headingPath), range.role
  ])).join('\n');
}
export function decodeRanges(raw: string): TextSourceRange[] {
  if (raw.length > 65536) { throw new TextFailure('SCHEMA', 'wire', '定位记录超限'); }
  if (raw.length === 0) { return []; }
  return raw.split('\n').map((row: string): TextSourceRange => {
    const f: string[] = unpackTextFields(row, 9);
    const range: TextSourceRange = new TextSourceRange();
    range.originalStart = wireNumber(f[0]); range.originalEnd = wireNumber(f[1]);
    range.normalizedStart = wireNumber(f[2]); range.normalizedEnd = wireNumber(f[3]);
    range.startLine = wireNumber(f[4]); range.endLine = wireNumber(f[5]); range.nodeId = f[6];
    range.headingPath = f[7].length > 0 ? f[7].split('\t').map((s: string): string => decodeURIComponent(s)) : [];
    if (f[8] === TextRangeRole.Evidence) { range.role = TextRangeRole.Evidence; }
    else if (f[8] === TextRangeRole.Heading) { range.role = TextRangeRole.Heading; }
    else if (f[8] === TextRangeRole.Header) { range.role = TextRangeRole.Header; }
    else { throw new TextFailure('SCHEMA', 'wire', '未知定位来源角色'); }
    if (range.originalEnd < range.originalStart || range.normalizedEnd < range.normalizedStart || range.startLine < 1 || range.endLine < range.startLine) {
      throw new TextFailure('SCHEMA', 'wire', '定位范围非法');
    }
    return range;
  });
}
export function textNodeKind(raw: string): TextNodeKind {
  const kinds: TextNodeKind[] = [TextNodeKind.Heading, TextNodeKind.Paragraph, TextNodeKind.List,
    TextNodeKind.Code, TextNodeKind.Table, TextNodeKind.Image, TextNodeKind.Raw];
  for (const kind of kinds) { if (raw === kind) { return kind; } }
  throw new TextFailure('SCHEMA', 'wire', '未知节点类型');
}
export function encodeSnapshot(snapshot: TextSnapshot): string {
  const rows: string[] = [packTextFields(['TEXT-SNAPSHOT-1', snapshot.id, snapshot.documentId,
    `${snapshot.documentVersion}`, snapshot.originalHash, snapshot.parserVersion, snapshot.mappingVersion,
    snapshot.strategyVersion, snapshot.normalized.originalText, packTextFields(snapshot.warnings)])];
  for (const node of snapshot.nodes) {
    rows.push(packTextFields(['NODE', node.id, node.parentId, node.kind, `${node.order}`, `${node.level}`,
      node.text, encodeRanges([node.range]), packTextFields(node.references)]));
    for (const cell of node.cells) {
      rows.push(packTextFields(['CELL', `${cell.row}`, `${cell.column}`, cell.header ? '1' : '0', cell.text, encodeRanges([cell.range])]));
    }
  }
  const wire: string = rows.join('\n');
  if (wire.length > TextBudget.snapshotBytes) { throw new TextFailure('BUDGET', 'snapshot', '完整结构快照超过 12 MiB'); }
  return wire;
}
export function decodeSnapshot(raw: string): TextSnapshot {
  const rows: string[] = raw.split('\n');
  const f: string[] = unpackTextFields(rows[0], 10);
  if (f[0] !== 'TEXT-SNAPSHOT-1' || f[5] !== 'text-structure-v1' || f[6] !== 'utf8-utf16-v1' || f[7] !== 'structure-512-51-v1') {
    throw new TextFailure('SCHEMA', 'snapshot', '未知快照版本，不覆盖已有资料');
  }
  const snapshot: TextSnapshot = new TextSnapshot();
  snapshot.id = f[1]; snapshot.documentId = f[2]; snapshot.documentVersion = wireNumber(f[3]); snapshot.originalHash = f[4];
  snapshot.normalized = normalizeText(encodeTextUtf8(f[8]));
  snapshot.warnings = f[9].length > 0 ? f[9].split('\t').map((s: string): string => decodeURIComponent(s)) : [];
  let current: TextNode | undefined = undefined;
  let cellCount: number = 0;
  for (let i: number = 1; i < rows.length; i++) {
    if (rows[i].startsWith('NODE\t')) {
      const n: string[] = unpackTextFields(rows[i], 9);
      current = new TextNode(); current.id = n[1]; current.parentId = n[2]; current.kind = textNodeKind(n[3]);
      current.order = wireNumber(n[4]); current.level = wireNumber(n[5]); current.text = n[6];
      const ranges: TextSourceRange[] = decodeRanges(n[7]);
      if (ranges.length !== 1) { throw new TextFailure('SCHEMA', 'snapshot', '节点定位缺失'); }
      current.range = ranges[0]; current.headingPath = current.range.headingPath;
      current.references = n[8].length > 0 ? n[8].split('\t').map((s: string): string => decodeURIComponent(s)) : [];
      snapshot.nodes.push(current);
    } else if (rows[i].startsWith('CELL\t') && current !== undefined) {
      const c: string[] = unpackTextFields(rows[i], 6);
      const cell: TextCell = new TextCell(); cell.row = wireNumber(c[1]); cell.column = wireNumber(c[2]);
      cell.header = c[3] === '1'; cell.text = c[4];
      const ranges: TextSourceRange[] = decodeRanges(c[5]);
      if (ranges.length !== 1 || (c[3] !== '0' && c[3] !== '1')) { throw new TextFailure('SCHEMA', 'snapshot', '单元格非法'); }
      cell.range = ranges[0]; current.cells.push(cell); cellCount++;
    } else { throw new TextFailure('SCHEMA', 'snapshot', '未知结构记录'); }
    if (snapshot.nodes.length > TextBudget.nodes || cellCount > TextBudget.cells) { throw new TextFailure('BUDGET', 'snapshot', '结构快照超限'); }
  }
  return snapshot;
}
