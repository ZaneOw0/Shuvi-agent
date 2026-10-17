import { KnowledgeHit, KnowledgeResultMatch, KnowledgeResultRange, KnowledgeResultSegment, KnowledgeMatchKind, KnowledgeChannel, KnowledgeSourceKind } from '../domain/KnowledgeSearchModels';
import { TextQueryInput } from '../domain/TextKnowledgeModels';
import { prepareTextQuery } from './QueryPreparation';

export function knowledgeAsciiFold(text: string): string {
  let output: string = ''; for (let at: number = 0; at < text.length; at++) { const code: number = text.charCodeAt(at); output += code >= 65 && code <= 90 ? String.fromCharCode(code+32) : text.charAt(at); } return output;
}
function knowledgeRangeBoundary(text: string, at: number): boolean { return !(at > 0 && at < text.length && text.charCodeAt(at-1) >= 0xd800 && text.charCodeAt(at-1) <= 0xdbff && text.charCodeAt(at) >= 0xdc00 && text.charCodeAt(at) <= 0xdfff); }
export function knowledgeMatch(hit: KnowledgeHit, input: TextQueryInput, allowSimilar: boolean): KnowledgeResultMatch {
  const match: KnowledgeResultMatch = new KnowledgeResultMatch(); match.actualInput = input.actualInput; match.terms = input.terms.slice(); const body = knowledgeAsciiFold(hit.text); const ranges: KnowledgeResultRange[] = [];
  for (const term of input.terms) {
    const literal = knowledgeAsciiFold(term); if (literal.length === 0) { continue; } let cursor: number = body.indexOf(literal); let found: boolean = false;
    while (cursor >= 0) { const end: number = cursor+literal.length; if (knowledgeRangeBoundary(hit.text,cursor) && knowledgeRangeBoundary(hit.text,end)) { const range = new KnowledgeResultRange(); range.start = cursor; range.end = end; ranges.push(range); found = true; } cursor = body.indexOf(literal,cursor+1); }
    if (found && match.matchedTerms.indexOf(term) < 0) { match.matchedTerms.push(term); }
  }
  ranges.sort((a: KnowledgeResultRange,b: KnowledgeResultRange): number => a.start-b.start || a.end-b.end);
  for (const range of ranges) { const last = match.ranges[match.ranges.length-1]; if (last !== undefined && range.start <= last.end) { last.end = Math.max(last.end,range.end); } else { match.ranges.push(range); } }
  match.kind = match.ranges.length > 0 ? KnowledgeMatchKind.Direct : allowSimilar && hit.sourceKind === KnowledgeSourceKind.Pdf && hit.channels.indexOf(KnowledgeChannel.Vector) >= 0 && hit.spaceId.length > 0 && hit.vectorGeneration.length > 0 && hit.vectorDistance !== undefined && Number.isFinite(hit.vectorDistance) ? KnowledgeMatchKind.Similar : KnowledgeMatchKind.Unclassified; return match;
}
export function knowledgeLiteralScore(text: string, input: TextQueryInput): number {
  const hit = new KnowledgeHit(); hit.text = text; const match = knowledgeMatch(hit,input,false); return match.matchedTerms.length*100+match.ranges.length;
}
export function knowledgeLegacyMatch(hit: KnowledgeHit, actualInput: string): KnowledgeResultMatch {
  let input = new TextQueryInput(); try { input = prepareTextQuery(actualInput); } catch { input.actualInput = actualInput; }
  const match = knowledgeMatch(hit,input,true); match.compatibility = true; return match;
}
export function knowledgeSegments(hit: KnowledgeHit): KnowledgeResultSegment[] {
  const result: KnowledgeResultSegment[] = []; let cursor: number = 0;
  const ranges: KnowledgeResultRange[] = hit.match.kind === KnowledgeMatchKind.Direct ? hit.match.ranges : [];
  for (const range of ranges) {
    if (!Number.isSafeInteger(range.start) || !Number.isSafeInteger(range.end) || range.start < cursor || range.end <= range.start || range.end > hit.text.length || !knowledgeRangeBoundary(hit.text,range.start) || !knowledgeRangeBoundary(hit.text,range.end)) { const plain = new KnowledgeResultSegment(); plain.id = 'plain'; plain.text = hit.text; return [plain]; }
    if (range.start > cursor) { const plain = new KnowledgeResultSegment(); plain.id = `${cursor}:${range.start}:plain`; plain.text = hit.text.slice(cursor,range.start); result.push(plain); }
    const marked = new KnowledgeResultSegment(); marked.id = `${range.start}:${range.end}:match`; marked.text = hit.text.slice(range.start,range.end); marked.matched = true; result.push(marked); cursor = range.end;
  }
  if (cursor < hit.text.length) { const plain = new KnowledgeResultSegment(); plain.id = `${cursor}:end`; plain.text = hit.text.slice(cursor); result.push(plain); } return result;
}
