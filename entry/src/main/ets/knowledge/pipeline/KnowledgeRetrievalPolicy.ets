import { KnowledgeHit, KnowledgeChannel, KnowledgeSearchBudget, KnowledgeHistory, KnowledgeHistoryCursor, KnowledgeHistoryPage, KnowledgeSourceKind } from '../domain/KnowledgeSearchModels';
import { KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { TextQueryInput } from '../domain/TextKnowledgeModels';
import { KnowledgeMatchKind } from '../domain/KnowledgeSearchModels';
import { knowledgeMatch } from './KnowledgeMatchPolicy';

export function knowledgeDirectFirst(direct: KnowledgeHit[], vector: KnowledgeHit[], input: TextQueryInput, space: string): KnowledgeHit[] {
  const hits: KnowledgeHit[] = []; const seen: Set<string> = new Set<string>();
  for (const hit of direct) { hit.match = knowledgeMatch(hit,input,false); if (hit.match.kind === KnowledgeMatchKind.Direct && !seen.has(hit.id)) { seen.add(hit.id); hits.push(hit); } }
  if (hits.length > 0) { return hits.slice(0,5); }
  for (const hit of vector) { hit.match = knowledgeMatch(hit,input,true); if (hit.match.kind === KnowledgeMatchKind.Similar && hit.spaceId === space && !seen.has(hit.id)) { seen.add(hit.id); hit.vectorRank = hits.length+1; hits.push(hit); } }
  return hits.slice(0,5);
}

export function knowledgeKeywordList(text: KnowledgeHit[], pdf: KnowledgeHit[]): KnowledgeHit[] {
  const candidates: KnowledgeHit[] = text.slice(0,20).concat(pdf.slice(0,20));
  candidates.sort((a: KnowledgeHit,b: KnowledgeHit): number => b.keywordScore-a.keywordScore || a.id.localeCompare(b.id));
  const ids: Set<string> = new Set<string>(); const unique: KnowledgeHit[] = [];
  for (const hit of candidates) { if (!ids.has(hit.id)) { ids.add(hit.id); unique.push(hit); } } return unique.slice(0,20);
}
export function knowledgeFuse(keyword: KnowledgeHit[], vector: KnowledgeHit[]): KnowledgeHit[] {
  const spaceId: string = vector[0]?.spaceId ?? '';
  if (vector.some((hit: KnowledgeHit): boolean => hit.sourceKind !== KnowledgeSourceKind.Pdf || hit.spaceId.length === 0 || hit.spaceId !== spaceId)) { throw new KnowledgeFailure('VectorCandidateSpaceMismatch','rrf'); }
  const merged: Map<string,KnowledgeHit> = new Map<string,KnowledgeHit>();
  const routes: KnowledgeHit[][] = [keyword.slice(0,20),vector.slice(0,20)];
  for (let route: number = 0; route < routes.length; route++) {
    const seen: Set<string> = new Set<string>();
    for (let index: number = 0; index < routes[route].length; index++) {
      const candidate: KnowledgeHit = routes[route][index]; if (seen.has(candidate.id)) { continue; } seen.add(candidate.id);
      const existing: KnowledgeHit | undefined = merged.get(candidate.id); const hit: KnowledgeHit = existing ?? candidate;
      if (existing !== undefined && (existing.generation !== candidate.generation || existing.originalHash !== candidate.originalHash || existing.snapshotHash !== candidate.snapshotHash)) { throw new KnowledgeFailure('CandidateGenerationMismatch','rrf'); }
      if (existing === undefined) { hit.rrfScore = 0; hit.channels = []; }
      if (route === 0) { hit.keywordRank = index+1; hit.keywordScore = candidate.keywordScore; }
      else { hit.vectorRank = index+1; hit.spaceId = candidate.spaceId; hit.vectorGeneration = candidate.vectorGeneration; hit.vectorDistance = candidate.vectorDistance; }
      hit.rrfScore += 1/(KnowledgeSearchBudget.rrfK+index+1); hit.channels.push(route === 0 ? KnowledgeChannel.Keyword : KnowledgeChannel.Vector); merged.set(hit.id,hit);
    }
  }
  const results: KnowledgeHit[] = []; merged.forEach((hit: KnowledgeHit): void => { results.push(hit); });
  results.sort((a: KnowledgeHit,b: KnowledgeHit): number => b.rrfScore-a.rrfScore || a.id.localeCompare(b.id)); return results.slice(0,5);
}
export function knowledgeMergeHistory(kb: KnowledgeHistory[], text: KnowledgeHistory[], cursor: KnowledgeHistoryCursor, limit: number): KnowledgeHistoryPage {
  const page: KnowledgeHistoryPage = new KnowledgeHistoryPage(); page.next.kbCreated = cursor.kbCreated; page.next.kbId = cursor.kbId; page.next.textCreated = cursor.textCreated; page.next.textId = cursor.textId;
  const merged: KnowledgeHistory[] = kb.concat(text).sort((a: KnowledgeHistory,b: KnowledgeHistory): number => b.createdAt-a.createdAt || (b.source+':'+b.id).localeCompare(a.source+':'+a.id));
  page.records = merged.slice(0,limit);
  for (const record of page.records) { if (record.source === 'kb') { page.next.kbCreated = record.createdAt; page.next.kbId = record.id; } else { page.next.textCreated = record.createdAt; page.next.textId = record.id; } } return page;
}
