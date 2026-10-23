import { ChunkSlice } from '../domain/KnowledgeTypes';

const PARAGRAPH_BREAK: string = '\n\n';
const SENTENCE_BREAKS: string[] = ['。', '！', '？', '；', '.', '!', '?', ';', '\n'];
const MIN_BOUNDARY_RATIO: number = 0.5;
const FENCE_MARKER: string = '```';
const HEADING_MARKER: string = '#';

export function chunkText(text: string, size: number, overlapRatio: number): ChunkSlice[] {
  const slices: ChunkSlice[] = [];
  if (!Number.isFinite(size) || size < 2 || overlapRatio < 0 || overlapRatio >= 1) {
    throw new Error('invalid chunk budget');
  }
  const overlap: number = Math.floor(size * overlapRatio);
  const source: string = text;
  const fenceLineStarts: number[] = fenceLinePositions(source);
  let cursor: number = 0;
  while (cursor < source.length) {
    const limit: number = Math.min(cursor + size, source.length);
    let end: number = limit;
    if (limit < source.length) {
      const window: string = source.substring(cursor, limit);
      const paragraphCut: number = window.lastIndexOf(PARAGRAPH_BREAK);
      if (paragraphCut >= size * MIN_BOUNDARY_RATIO) {
        end = cursor + paragraphCut + PARAGRAPH_BREAK.length;
      } else {
        const sentenceCut: number = lastSentenceCut(window);
        if (sentenceCut >= size * MIN_BOUNDARY_RATIO) {
          end = cursor + sentenceCut;
        }
      }
      end = keepFenceIntact(source, end, cursor, size, overlap, fenceLineStarts);
      end = keepHeadingWithBody(source, end, cursor, size);
    }
    end = safeTextBoundary(source, end);
    if (end < source.length) {
      const candidate: string = source.substring(cursor, end).trimEnd();
      const lastStart: number = candidate.lastIndexOf('\n') + 1;
      if (lastStart > 0 && new RegExp('^ {0,3}#{1,6}\\s').test(candidate.substring(lastStart))) {
        end = cursor + lastStart;
      }
    }
    if (end <= cursor) { end = Math.min(source.length, cursor + size); }
    const raw: string = source.substring(cursor, end);
    const body: string = raw.trim();
    if (body.length > 0) {
      const slice: ChunkSlice = { text: body, charOffset: cursor + leadingWhitespace(raw) };
      slices.push(slice);
    }
    if (end >= source.length) {
      break;
    }
    const next: number = end - overlap;
    const safeNext: number = safeTextBoundary(source, next);
    cursor = safeNext > cursor ? safeNext : safeTextBoundaryForward(source, cursor + 1);
  }
  return slices;
}

function fenceLinePositions(source: string): number[] {
  const positions: number[] = [];
  let index: number = source.indexOf(FENCE_MARKER);
  while (index >= 0) {
    positions.push(lineStartIndex(source, index));
    index = source.indexOf(FENCE_MARKER, index + FENCE_MARKER.length);
  }
  return positions;
}

function keepFenceIntact(source: string, end: number, cursor: number, size: number, overlap: number,
  fenceLineStarts: number[]): number {
  const openIndex: number = enclosingFenceIndex(fenceLineStarts, end);
  if (openIndex < 0) {
    return end;
  }
  const openLineStart: number = fenceLineStarts[openIndex];
  const closeLineStart: number = openIndex + 1 < fenceLineStarts.length
    ? fenceLineStarts[openIndex + 1]
    : source.length;
  const blockLength: number = closeLineStart - openLineStart;
  if (blockLength + overlap + FENCE_MARKER.length <= size) {
    return openLineStart > cursor ? openLineStart : end;
  }
  const lastNewline: number = source.lastIndexOf('\n', end - 1);
  if (lastNewline > cursor && lastNewline < end) {
    return lastNewline;
  }
  return end;
}

function enclosingFenceIndex(fenceLineStarts: number[], end: number): number {
  let index: number = -1;
  for (let i = 0; i < fenceLineStarts.length; i++) {
    if (fenceLineStarts[i] < end) {
      index = i;
    } else {
      break;
    }
  }
  if (index < 0 || index % 2 === 1) {
    return -1;
  }
  return index;
}

function keepHeadingWithBody(source: string, end: number, cursor: number, size: number): number {
  const lastChar: number = lastNonWhitespaceIndex(source, end);
  if (lastChar < cursor) {
    return end;
  }
  const lineStart: number = lineStartIndex(source, lastChar);
  if (lineStart <= cursor || lineStart >= end) {
    return end;
  }
  if (!isHeadingLine(source, lineStart, lastChar + 1)) {
    return end;
  }
  if (lineStart - cursor < size * MIN_BOUNDARY_RATIO) {
    return end;
  }
  return lineStart;
}

function isHeadingLine(source: string, lineStart: number, lineEnd: number): boolean {
  let index: number = lineStart;
  while (index < lineEnd) {
    const code: number = source.charCodeAt(index);
    if (code !== 32 && code !== 9) {
      break;
    }
    index++;
  }
  return index < lineEnd && source.charAt(index) === HEADING_MARKER;
}

function lastNonWhitespaceIndex(source: string, end: number): number {
  let index: number = end - 1;
  while (index >= 0 && isWhitespaceCode(source.charCodeAt(index))) {
    index--;
  }
  return index;
}

function isWhitespaceCode(code: number): boolean {
  return code === 32 || code === 9 || code === 10 || code === 13;
}

function lineStartIndex(source: string, index: number): number {
  const found: number = source.lastIndexOf('\n', index);
  return found < 0 ? 0 : found + 1;
}

function leadingWhitespace(value: string): number {
  return value.length - value.trimStart().length;
}

export function safeTextBoundary(text: string, index: number): number {
  if (index > 0 && index < text.length && text.charCodeAt(index) >= 0xDC00 &&
    text.charCodeAt(index) <= 0xDFFF && text.charCodeAt(index - 1) >= 0xD800 &&
    text.charCodeAt(index - 1) <= 0xDBFF) { return index - 1; }
  return index;
}

function safeTextBoundaryForward(text: string, index: number): number {
  return safeTextBoundary(text, index) < index ? index + 1 : index;
}

function lastSentenceCut(window: string): number {
  let cut: number = -1;
  for (let i = 0; i < SENTENCE_BREAKS.length; i++) {
    const found: number = window.lastIndexOf(SENTENCE_BREAKS[i]);
    if (found > cut) {
      cut = found;
    }
  }
  return cut < 0 ? cut : cut + 1;
}
