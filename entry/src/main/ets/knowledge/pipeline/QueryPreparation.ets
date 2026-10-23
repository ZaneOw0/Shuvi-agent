import { TextBudget, TextFailure, TextQueryInput, TextHit } from '../domain/TextKnowledgeModels';
import { encodeTextUtf8 } from './TextNormalizer';

class TextQueryPart { start: number = 0; end: number = 0; text: string = ''; priority: boolean = false; }
export function prepareTextQuery(question: string): TextQueryInput {
  const result: TextQueryInput = new TextQueryInput(); result.fullQuestion = question;
  if (question.trim().length === 0) { throw new TextFailure('EMPTY', 'query', '请输入非空关键词'); }
  // Validate paired Unicode before persisting. Complete question is never trimmed.
  const bytes: Uint8Array = encodeTextUtf8(question);
  if (bytes.length <= TextBudget.queryBytes && Array.from(question).length <= TextBudget.queryCharacters) {
    result.actualInput = question.trim();
  } else {
    const parts: TextQueryPart[] = [];
    const delimiters: RegExp = new RegExp('[^。！？!?;；\\n]+[。！？!?;；\\n]?', 'g');
    let match: RegExpExecArray | null = delimiters.exec(question);
    while (match !== null) {
      const part: TextQueryPart = new TextQueryPart(); part.start = match.index;
      part.end = match.index + match[0].length; part.text = match[0];
      part.priority = new RegExp('(不|仅|只|排除|范围|之前|之后|以内|期间|[0-9]{4}|\\b(not|only|except|before|after|within)\\b)', 'i').test(part.text);
      const condition: RegExpMatchArray | null = part.text.match(new RegExp('(不|仅|只|排除|范围|之前|之后|以内|期间|[0-9]{4}|\\b(not|only|except|before|after|within)\\b)', 'i'));
      const boundary: number = condition !== null ? (condition.index ?? 0) : 0;
      if (part.priority && boundary > 0) {
        const leading: TextQueryPart = new TextQueryPart(); leading.start = part.start;
        leading.end = part.start + boundary; leading.text = part.text.slice(0, boundary);
        parts.push(leading); part.start += boundary; part.text = part.text.slice(boundary);
      }
      parts.push(part); match = delimiters.exec(question);
    }
    const ordered: TextQueryPart[] = parts.filter((part: TextQueryPart): boolean => part.priority)
      .concat(parts.filter((part: TextQueryPart): boolean => !part.priority));
    let characters: number = 0;
    let usedBytes: number = 0;
    const kept: string[] = [];
    for (const part of ordered) {
      let keptUnits: number = 0;
      let segment: string = '';
      const points: string[] = Array.from(part.text);
      for (const point of points) {
        const length: number = encodeTextUtf8(point).length;
        const separator: number = segment.length === 0 && kept.length > 0 ? 1 : 0;
        if (characters + separator + 1 > TextBudget.queryCharacters || usedBytes + separator + length > TextBudget.queryBytes) { break; }
        characters += 1 + separator; usedBytes += length + separator;
        segment += point; keptUnits += point.length;
      }
      if (segment.length > 0) { kept.push(segment); }
      if (keptUnits < part.text.length) { result.droppedRanges.push(`${part.start + keptUnits}–${part.end}`); }
    }
    result.actualInput = kept.join(' ').trim();
    result.notice = `问题过长，优先保留显式时间/范围/否定片段，取 ${Array.from(result.actualInput).length} 字检索；未保留原问题 UTF-16 范围：${result.droppedRanges.slice(0, 32).join('、')}${result.droppedRanges.length > 32 ? `（另有 ${result.droppedRanges.length - 32} 段未保留，完整问题仍保存）` : ''}。不保证理解全部条件。`;
  }
  // Whitespace-separated literal phrases, not an invented semantic rewrite.
  result.terms = result.actualInput.split(new RegExp('\\s+')).filter((term: string): boolean => term.length > 0);
  if (result.terms.length > 64) {
    result.terms = [result.actualInput];
    result.notice += ' 关键词超过 64 项，实际按完整字面短语检索。';
  }
  return result;
}
export function textLikePattern(term: string): string {
  return '%' + term.replace(new RegExp('\\\\', 'g'), '\\\\')
    .replace(new RegExp('%', 'g'), '\\%').replace(new RegExp('_', 'g'), '\\_') + '%';
}
export function textFtsInput(terms: string[]): string {
  return terms.map((term: string): string => '"' + term.replace(new RegExp('"', 'g'), '""') + '"').join(' OR ');
}
export function textKeywordScore(text: string, terms: string[]): number {
  const body: string = text.toLowerCase();
  let score: number = 0;
  for (const term of terms) {
    const literal: string = term.toLowerCase();
    let cursor: number = body.indexOf(literal);
    let count: number = 0;
    while (cursor >= 0 && count < 32) { count++; cursor = body.indexOf(literal, cursor + Math.max(1, literal.length)); }
    score += count > 0 ? 100 + count : 0;
  }
  return score;
}
export function compareTextHits(left: TextHit, right: TextHit): number {
  if (left.score !== right.score) { return right.score - left.score; }
  return left.documentId.localeCompare(right.documentId) || left.chunkId.localeCompare(right.chunkId);
}
