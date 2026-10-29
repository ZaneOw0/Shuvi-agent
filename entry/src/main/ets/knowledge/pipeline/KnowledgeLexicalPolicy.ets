import { KnowledgeLexicalRequest } from '../domain/KnowledgeLexicalPorts';
import { ParsedFailure } from '../domain/ParsedDocumentModels';
import { UnifiedSearchRange } from '../domain/UnifiedQueryModels';
import { knowledgeMatch } from './KnowledgeMatchPolicy';
import { KnowledgeHit } from '../domain/KnowledgeSearchModels';
import { TextQueryInput, TextBudget } from '../domain/TextKnowledgeModels';
import { parsedUtf8 } from './ParsedDocumentCodec';

export function knowledgeLexicalTerms(request: KnowledgeLexicalRequest): string[] {
  if (typeof request.query !== 'string' || request.query.trim().length < 1 || Array.from(request.query).length > TextBudget.queryCharacters || parsedUtf8(request.query).length > TextBudget.queryBytes ||
    !Array.isArray(request.keywords) || request.keywords.length > 8 ||
    !['keywords','literal'].includes(request.intent)) { throw new ParsedFailure('LexicalQueryInvalid','lexical'); }
  const words: string[] = request.keywords.length > 0 ? request.keywords : request.query.trim().split(new RegExp('[\\s,，。；;！!？?、]+'));
  const terms: string[] = [];
  for (const word of words) {
    if (typeof word !== 'string' || word.trim().length < 1 || word.length > (request.keywords.length > 0 ? 40 : TextBudget.queryCharacters*2)) { throw new ParsedFailure('LexicalTermInvalid','lexical'); }
    if (!terms.includes(word.trim())) { terms.push(word.trim()); }
  }
  if (terms.length === 0 || terms.length > 32) { throw new ParsedFailure('LexicalTermsBudget','lexical'); }
  return terms;
}
export function knowledgeLexicalFts(terms: string[]): string {
  return terms.map((term: string): string => '"' + term.replace(new RegExp('"','g'),'""') + '"').join(' OR ');
}
export function knowledgeLexicalLiteral(request: KnowledgeLexicalRequest): boolean {
  return request.intent === 'literal' || new RegExp('^["“].*["”]$').test(request.query.trim());
}
export function knowledgeLexicalRanges(text: string, terms: string[], evidence: string): UnifiedSearchRange[] {
  const ranges: UnifiedSearchRange[] = [];
  for (const term of terms) {
    const hit: KnowledgeHit=new KnowledgeHit(); hit.text=text;
    const input: TextQueryInput=new TextQueryInput(); input.actualInput=term; input.terms=[term];
    for (const range of knowledgeMatch(hit,input,false).ranges) {
      if (!ranges.some((old: UnifiedSearchRange): boolean => old.start === range.start && old.end === range.end)) { const actual: UnifiedSearchRange=new UnifiedSearchRange(); actual.start=range.start; actual.end=range.end; ranges.push(actual); }
    }
  }
  ranges.sort((a: UnifiedSearchRange,b: UnifiedSearchRange): number => a.start-b.start || a.end-b.end);
  const merged: UnifiedSearchRange[]=[];
  for (const range of ranges) { const prior=merged[merged.length-1]; if (prior!==undefined && range.start<=prior.end) { prior.end=Math.max(prior.end,range.end); } else { merged.push(range); } }
  return merged;
}
