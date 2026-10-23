import { ChunkSlice } from '../domain/KnowledgeTypes';

const PARAGRAPH_BREAK: string = '\n\n';
const SENTENCE_BREAKS: string[] = ['。', '！', '？', '；', '.', '!', '?', ';', '\n'];
const MIN_BOUNDARY_RATIO: number = 0.5;

export function chunkText(text: string, size: number, overlapRatio: number): ChunkSlice[] {
  const slices: ChunkSlice[] = [];
  if (!Number.isFinite(size) || size < 2 || overlapRatio < 0 || overlapRatio >= 1) {
    throw new Error('invalid chunk budget');
  }
  const overlap: number = Math.floor(size * overlapRatio);
  const source: string = text;
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
