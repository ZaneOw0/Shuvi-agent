import { UnifiedSearchHistoryPage, UnifiedSearchCard, UnifiedSearchParent, UnifiedSearchReason, UnifiedSearchRange } from '../domain/UnifiedQueryModels';
import { PdfJsonNode } from './BoundedDocumentJson';
import { ParsedCancellation, ParsedFailure } from '../domain/ParsedDocumentModels';
import { parsedJson, parsedUtf8 } from './ParsedDocumentCodec';

function hs(n: PdfJsonNode,key: string): string { return n.required(key).string(); }
function hn(n: PdfJsonNode,key: string): number { return n.required(key).integer(); }
export function unifiedHistoryCard(n: PdfJsonNode): UnifiedSearchCard {
  const c: UnifiedSearchCard=new UnifiedSearchCard(); c.key=hs(n,'key'); c.kind=hs(n,'kind'); c.title=hs(n,'title'); c.text=hs(n,'text'); c.imageHash=hs(n,'imageHash'); c.effectiveId=hs(n,'effectiveId'); c.documentKey=hs(n,'documentKey'); c.generation=hs(n,'generation'); c.assetId=hs(n,'assetId'); c.occurrenceId=hs(n,'occurrenceId'); c.current=n.required('current').kind==='true'; c.localRank=hn(n,'localRank'); c.vectorRank=hn(n,'vectorRank'); const score=n.required('score'); if (score.kind!=='number') { throw new ParsedFailure('HistoryScore','history'); } c.score=score.numeric;
  for (const raw of n.required('parents').array()) { const p: UnifiedSearchParent=new UnifiedSearchParent(); p.documentKey=hs(raw,'documentKey'); p.generation=hs(raw,'generation'); p.occurrenceId=hs(raw,'occurrenceId'); p.title=hs(raw,'title'); p.precision=hs(raw,'precision'); c.parents.push(p); }
  for (const raw of n.required('reasons').array()) { const r: UnifiedSearchReason=new UnifiedSearchReason(); r.id=hs(raw,'id'); r.route=hs(raw,'route'); r.text=hs(raw,'text'); r.version=hs(raw,'version'); r.inputId=hs(raw,'inputId'); r.occurrenceId=hs(raw,'occurrenceId'); r.rank=hn(raw,'rank'); const distance=raw.optional('distance'); if (distance!==undefined) { if (distance.kind!=='number' || !Number.isFinite(distance.numeric)) { throw new ParsedFailure('HistoryDistance','history'); } r.distance=distance.numeric; }
    r.savedReason=raw.optional('savedReason')?.string() ?? ''; r.engine=raw.optional('engine')?.string() ?? ''; r.matchKind=raw.optional('matchKind')?.string() ?? ''; r.evidenceType=raw.optional('evidenceType')?.string() ?? ''; for (const term of raw.optional('matchedTerms')?.array() ?? []) { r.matchedTerms.push(term.string()); }
    for (const rawRange of raw.required('ranges').array()) { const range: UnifiedSearchRange=new UnifiedSearchRange(); range.start=hn(rawRange,'start'); range.end=hn(rawRange,'end'); if (range.start<0 || range.end<=range.start || range.end>r.text.length) { throw new ParsedFailure('HistoryRange','history'); } r.ranges.push(range); } c.reasons.push(r);
  } if (c.parents.length>1000 || c.reasons.length>30000) { throw new ParsedFailure('HistoryCardBudget','history'); } return c;
}
export function unifiedHistoryDecode(raw: Uint8Array): UnifiedSearchHistoryPage {
  return unifiedHistoryNode(parsedJson(raw,new ParsedCancellation()));
}
function unifiedHistoryNode(n: PdfJsonNode): UnifiedSearchHistoryPage {
  const p: UnifiedSearchHistoryPage=new UnifiedSearchHistoryPage(); p.wire=hs(n,'wire'); p.recordId=hs(n,'recordId'); p.eventId=hs(n,'eventId'); p.revision=hn(n,'revision'); p.createdAt=hn(n,'createdAt'); p.question=hs(n,'question'); p.policy=hs(n,'policy'); p.space=hs(n,'space'); p.scopeHash=hs(n,'scopeHash'); p.semanticState=hs(n,'semanticState'); p.unupgraded=hn(n,'unupgraded'); p.directCursor=hs(n,'directCursor'); p.relatedCursor=hs(n,'relatedCursor'); p.sortVersion=hs(n,'sortVersion');
  if (p.wire!=='UNIFIED-KNOWLEDGE-HISTORY-1' || p.revision<1 || p.question.length>512) { throw new ParsedFailure('HistoryWire','history'); }
  for (const raw of n.required('direct').array()) { p.direct.push(unifiedHistoryCard(raw)); } for (const raw of n.required('related').array()) { p.related.push(unifiedHistoryCard(raw)); } if (p.direct.length+p.related.length>30000) { throw new ParsedFailure('HistoryPageBudget','history'); } return p;
}
export function unifiedHistoryCopy(page: UnifiedSearchHistoryPage): UnifiedSearchHistoryPage {
  const copy: UnifiedSearchHistoryPage=new UnifiedSearchHistoryPage(); copy.wire=page.wire; copy.recordId=page.recordId; copy.eventId=page.eventId; copy.revision=page.revision; copy.createdAt=page.createdAt; copy.question=page.question; copy.policy=page.policy; copy.space=page.space; copy.scopeHash=page.scopeHash; copy.semanticState=page.semanticState; copy.unupgraded=page.unupgraded; copy.directCursor=page.directCursor; copy.relatedCursor=page.relatedCursor; copy.sortVersion=page.sortVersion;
  for (const card of page.direct) { copy.direct.push(unifiedHistoryCard(parsedJson(parsedUtf8(JSON.stringify(card)),new ParsedCancellation()))); }
  for (const card of page.related) { copy.related.push(unifiedHistoryCard(parsedJson(parsedUtf8(JSON.stringify(card)),new ParsedCancellation()))); } return copy;
}
export class UnifiedHistoryCardRef { asset: string=''; hash: string=''; group: string=''; }
export class UnifiedHistoryManifest {
  wire: string='UNIFIED-KNOWLEDGE-HISTORY-FILES-1'; header: UnifiedSearchHistoryPage=new UnifiedSearchHistoryPage(); refs: UnifiedHistoryCardRef[]=[];
}
export function unifiedHistoryManifestDecode(bytes: Uint8Array): UnifiedHistoryManifest {
  if (bytes.length>1048576) { throw new ParsedFailure('HistoryManifestBudget','history'); } const n=parsedJson(bytes,new ParsedCancellation()); const m: UnifiedHistoryManifest=new UnifiedHistoryManifest();
  if (n.required('wire').string()!==m.wire) { throw new ParsedFailure('HistoryManifestWire','history'); }
  m.header=unifiedHistoryNode(n.required('header'));
  for (const raw of n.required('refs').array()) { const ref: UnifiedHistoryCardRef=new UnifiedHistoryCardRef(); ref.asset=hs(raw,'asset'); ref.hash=hs(raw,'hash'); ref.group=hs(raw,'group'); if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,160}$/.test(ref.asset) || !/^[a-f0-9]{64}$/.test(ref.hash) || ['Direct','Related'].indexOf(ref.group)<0) { throw new ParsedFailure('HistoryRefIdentity','history'); } m.refs.push(ref); }
  if (m.refs.length>30000 || m.header.direct.length+m.header.related.length>0) { throw new ParsedFailure('HistoryManifestShape','history'); }
  return m;
}
