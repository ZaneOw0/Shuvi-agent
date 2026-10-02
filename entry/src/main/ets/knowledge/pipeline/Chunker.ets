import { ChunkSlice } from '../domain/KnowledgeTypes';

const PARAGRAPH_BREAK: string = '\n\n';
const SENTENCE_BREAKS: string[] = ['。', '！', '？', '；', '.', '!', '?', ';', '\n'];
const MIN_BOUNDARY_RATIO: number = 0.5;

export function chunkText(text: string, size: number, overlapRatio: number): ChunkSlice[] {
  const slices: ChunkSlice[] = [];
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
    cursor = next > cursor ? next : cursor + 1;
  }
  return slices;
}

function leadingWhitespace(value: string): number {
  let index: number = 0;
  while (index < value.length) {
    const code: number = value.charCodeAt(index);
    if (code !== 32 && code !== 9 && code !== 10 && code !== 13) {
      break;
    }
    index++;
  }
  return index;
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
