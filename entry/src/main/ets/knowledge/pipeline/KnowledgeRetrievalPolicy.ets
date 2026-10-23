import { KnowledgeHit, KnowledgeChannel, KnowledgeSearchBudget, KnowledgeHistory, KnowledgeHistoryCursor, KnowledgeHistoryPage, KnowledgeSourceKind } from '../domain/KnowledgeSearchModels';
import { KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { TextQueryInput } from '../domain/TextKnowledgeModels';
import { KnowledgeMatchKind } from '../domain/KnowledgeSearchModels';
import { knowledgeMatch } from './KnowledgeMatchPolicy';
import { UnifiedQueryScope, UnifiedSearchCard, UnifiedSearchReason, UnifiedSearchParent, UnifiedQueryImageSource, UnifiedQueryTextSource, UnifiedQueryTarget } from '../domain/UnifiedQueryModels';
import { ParsedTextChunk } from '../domain/ParsedDocumentModels';
import { UnifiedImageRecord } from '../domain/UnifiedKnowledgeModels';
import { KnowledgeVectorCandidate } from '../domain/EmbeddingModels';
import { unifiedDirectRanges } from './KnowledgeMatchPolicy';

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
export function unifiedImageCardKey(hash: string, effective: string): string { return `image:${hash}:${effective}`; }
function unifiedParent(record: UnifiedImageRecord): UnifiedSearchParent { const p: UnifiedSearchParent=new UnifiedSearchParent(); p.documentKey=record.documentKey; p.generation=record.generation; p.occurrenceId=record.occurrenceId; p.title=record.title; p.precision=record.provenance==='IndependentOriginal'?'File':'Block'; return p; }
export function unifiedImageCard(image: UnifiedQueryImageSource, scope: UnifiedQueryScope): UnifiedSearchCard {
  const r=image.record; const c: UnifiedSearchCard=new UnifiedSearchCard(); c.kind='Image'; c.key=unifiedImageCardKey(r.imageHash.length>0?r.imageHash:'Missing-'+r.occurrenceId,r.effectiveId || 'Unknown-'+r.occurrenceId); c.imageHash=r.imageHash; c.effectiveId=r.effectiveId; c.title=r.title; c.documentKey=r.documentKey; c.generation=r.generation; c.occurrenceId=r.occurrenceId; c.assetId=r.assetId; c.text=image.annotation?.description ?? r.ocr;
  for (const parent of scope.images) { if (parent.record.imageHash===r.imageHash && parent.record.effectiveId===r.effectiveId && (r.imageHash.length>0 || parent.record.occurrenceId===r.occurrenceId)) { c.parents.push(unifiedParent(parent.record)); } } return c;
}
export function unifiedBodyCard(chunk: ParsedTextChunk, scope: UnifiedQueryScope): UnifiedSearchCard {
  if (chunk.evidence==='Ocr' && chunk.occurrenceId.length>0) { const image=scope.images.find((i: UnifiedQueryImageSource): boolean=>i.record.occurrenceId===chunk.occurrenceId && i.record.documentKey===chunk.documentKey); if (image!==undefined) { return unifiedImageCard(image,scope); } }
  const c: UnifiedSearchCard=new UnifiedSearchCard(); c.key=`text:${chunk.documentKey}:${chunk.generation}:${chunk.id}`; c.documentKey=chunk.documentKey; c.generation=chunk.generation; c.text=chunk.text; c.title=scope.texts.find((s: UnifiedQueryTextSource): boolean=>s.document.id===chunk.documentKey)?.document.title ?? ''; const p: UnifiedSearchParent=new UnifiedSearchParent(); p.documentKey=c.documentKey; p.generation=c.generation; p.title=c.title; p.precision='Block'; c.parents=[p]; return c;
}
export function unifiedLocalDirect(scope: UnifiedQueryScope, question: string): UnifiedSearchCard[] {
  const out: UnifiedSearchCard[]=[];
  for (const source of scope.texts) { for (const chunk of source.chunks) { const ranges=unifiedDirectRanges(chunk.text,question,chunk.evidence); if (ranges.length===0) { continue; } const card=unifiedBodyCard(chunk,scope); const reason: UnifiedSearchReason=new UnifiedSearchReason(); reason.id='direct:'+chunk.id; reason.route=chunk.evidence==='Ocr'?'OcrDirect':'BodyDirect'; reason.text=chunk.text; reason.version=chunk.generation; reason.inputId=chunk.id; reason.occurrenceId=chunk.occurrenceId; reason.ranges=ranges; card.reasons=[reason]; out.push(card); } }
  out.sort((a: UnifiedSearchCard,b: UnifiedSearchCard): number=>a.documentKey.localeCompare(b.documentKey) || a.key.localeCompare(b.key)); return out;
}
export function unifiedLocalTags(scope: UnifiedQueryScope, question: string): UnifiedSearchCard[] {
  const terms=prepareUnifiedTerms(question); const out: UnifiedSearchCard[]=[];
  for (const image of scope.images) { const matches=image.annotation?.tags.filter((tag: string): boolean=>terms.some((term: string): boolean=>tag.toLowerCase().includes(term))) ?? []; if (matches.length===0) { continue; }
    const card=unifiedImageCard(image,scope); const reason: UnifiedSearchReason=new UnifiedSearchReason(); reason.id='tags:'+image.record.effectiveId; reason.route='Tag'; reason.text=matches.join(' · '); reason.version=image.record.effectiveId; reason.occurrenceId=image.record.occurrenceId; card.reasons=[reason]; out.push(card);
  } return out;
}
function prepareUnifiedTerms(question: string): string[] { return question.trim().toLowerCase().split(/\s+/).filter((t: string): boolean=>t.length>0); }
export function unifiedSemanticCards(scope: UnifiedQueryScope, candidates: KnowledgeVectorCandidate[]): UnifiedSearchCard[] {
  const out: UnifiedSearchCard[]=[];
  for (let rank: number=0;rank<candidates.length;rank++) {
    const candidate=candidates[rank]; const target: UnifiedQueryTarget | undefined=scope.targets.find((t: UnifiedQueryTarget): boolean=>t.input.id===candidate.row.chunkId && t.qualification.vectorGeneration===candidate.row.vectorGeneration && t.qualification.documentId===candidate.row.documentId && t.input.inputHash===candidate.row.inputHash);
    if (target===undefined || candidate.row.spaceId!==scope.space?.id) { continue; } let card: UnifiedSearchCard;
    if (target.input.ownerNamespace==='upd-image') { const image=scope.images.find((i: UnifiedQueryImageSource): boolean=>i.record.effectiveId===target.input.version && i.annotation?.lineage===target.input.ownerId); if (image===undefined) { continue; } card=unifiedImageCard(image,scope); }
    else { const source=scope.texts.find((s: UnifiedQueryTextSource): boolean=>s.document.id===target.input.documentKey); const chunk=source?.chunks.find((c: ParsedTextChunk): boolean=>c.id===target.input.id); if (chunk===undefined) { continue; } card=unifiedBodyCard(chunk,scope); }
    const reason: UnifiedSearchReason=new UnifiedSearchReason(); reason.id='vector:'+target.input.id; reason.route='Vector'; reason.text=target.input.actualText; reason.version=target.input.version; reason.inputId=target.input.id; reason.occurrenceId=target.input.occurrenceId; reason.distance=candidate.distance; reason.rank=rank+1; card.vectorRank=rank+1; card.reasons=[reason]; out.push(card);
  } return out;
}
export function unifiedMergeCard(target: UnifiedSearchCard, incoming: UnifiedSearchCard): void {
  for (const p of incoming.parents) { if (!target.parents.some((old: UnifiedSearchParent): boolean=>old.documentKey===p.documentKey && old.generation===p.generation && old.occurrenceId===p.occurrenceId)) { target.parents.push(p); } }
  for (const r of incoming.reasons) { if (!target.reasons.some((old: UnifiedSearchReason): boolean=>old.id===r.id)) { target.reasons.push(r); } }
  if (target.localRank===0 && incoming.localRank>0) { target.localRank=incoming.localRank; } if (target.vectorRank===0 && incoming.vectorRank>0) { target.vectorRank=incoming.vectorRank; }
  target.score=(target.localRank>0?1/(60+target.localRank):0)+(target.vectorRank>0?1/(60+target.vectorRank):0);
}
