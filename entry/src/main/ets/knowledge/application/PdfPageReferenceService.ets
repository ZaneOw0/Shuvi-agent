import { PdfPageIdentityContext, PdfPageIdentityEvidence, PdfReviewedPageFragment, ResultPageReference, PdfPageReferenceState } from '../domain/PdfLocalModels';
import { PdfContentNode, PdfNormalizedDocument, KnowledgeCancellation, KnowledgeFailure, KnowledgeReadLease, PdfSourceBinding, PdfChunk } from '../domain/PdfKnowledgeModels';
import { KnowledgeHit, KnowledgeResultRange } from '../domain/KnowledgeSearchModels';
import { PdfPageIdentityRepositoryPort, PdfAssetPort, KnowledgeIdentityPort, KnowledgePageReferencePort } from '../domain/KnowledgePorts';
import { BoundedDocumentJson, PdfJsonNode } from '../pipeline/BoundedDocumentJson';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { pdfStructureChunks } from '../pipeline/PdfStructureChunker';

export function pdfCopyPageContext(source: PdfPageIdentityContext, target: PdfPageIdentityContext): void {
  target.documentId = source.documentId; target.originalHash = source.originalHash; target.originalVersion = source.originalVersion; target.originalPages = source.originalPages;
  target.zipHash = source.zipHash; target.snapshotId = source.snapshotId; target.snapshotHash = source.snapshotHash; target.generation = source.generation; target.protocol = source.protocol;
}
export function pdfSamePageContext(a: PdfPageIdentityContext, b: PdfPageIdentityContext): boolean {
  return a.documentId === b.documentId && a.originalHash === b.originalHash && a.originalVersion === b.originalVersion && a.originalPages === b.originalPages && a.zipHash === b.zipHash && a.snapshotId === b.snapshotId && a.snapshotHash === b.snapshotHash && a.generation === b.generation && a.protocol === b.protocol;
}
function pdfPageHashValid(hash: string): boolean { return new RegExp('^[a-f0-9]{64}$').test(hash); }
function pdfPageBoundary(text: string, at: number): boolean { return at >= 0 && at <= text.length && !(at > 0 && at < text.length && text.charCodeAt(at-1) >= 0xd800 && text.charCodeAt(at-1) <= 0xdbff && text.charCodeAt(at) >= 0xdc00 && text.charCodeAt(at) <= 0xdfff); }
export function pdfPageEvidenceValid(item: PdfPageIdentityEvidence, context: PdfPageIdentityContext, node: PdfContentNode, nodeHash: string): boolean {
  return item.wire === 'PAGE-IDENTITY-1' && item.id.length > 0 && pdfSamePageContext(item,context) && item.nodeId === node.id && item.providerPage0 === node.pageIndex0 && item.nodeHash === nodeHash && pdfPageHashValid(nodeHash) && item.reviewVersion.length > 0 && pdfPageHashValid(item.reviewRecordHash) && pdfPageHashValid(item.uniqueAnchorHash) && pdfPageHashValid(item.structureAnchorHash) && item.fragments.length > 0 && item.fragments.length <= 50 && item.fragments.every((f: PdfReviewedPageFragment): boolean => Number.isSafeInteger(f.start) && Number.isSafeInteger(f.end) && f.start < f.end && pdfPageBoundary(node.text,f.start) && pdfPageBoundary(node.text,f.end) && Number.isSafeInteger(f.originalPage1) && f.originalPage1 > 0 && f.originalPage1 <= context.originalPages && pdfPageHashValid(f.textHash));
}
// Union reviewed source fragments, clipped to the unchanged chunk's source range.
export function pdfResolveReviewedNodes(context: PdfPageIdentityContext, nodes: PdfContentNode[], hashes: string[], evidence: PdfPageIdentityEvidence[][], sourceRanges: KnowledgeResultRange[] = []): ResultPageReference {
  const result: ResultPageReference = new ResultPageReference(); pdfCopyPageContext(context,result); let conflict: boolean = false;
  for (let at: number = 0; at < nodes.length; at++) {
    const node: PdfContentNode = nodes[at]; const fragments: PdfReviewedPageFragment[] = [];
    const bounds = sourceRanges[at]; const start: number = bounds?.start ?? 0; const end: number = bounds?.end ?? node.text.length;
    for (const item of evidence[at] ?? []) {
      if (!pdfPageEvidenceValid(item,context,node,hashes[at] ?? '')) { continue; }
      result.evidenceIds.push(item.id); fragments.push(...item.fragments);
    }
    fragments.sort((a: PdfReviewedPageFragment,b: PdfReviewedPageFragment): number => a.start-b.start || a.end-b.end);
    let covered: number = start;
    for (let i: number = 0; i < fragments.length; i++) {
      const f: PdfReviewedPageFragment = fragments[i];
      if (f.start >= end || f.end <= start) { continue; }
      for (let j: number = 0; j < i; j++) { const other = fragments[j]; if (Math.max(f.start,other.start,start) < Math.min(f.end,other.end,end) && f.originalPage1 !== other.originalPage1) { conflict = true; } }
      if (result.physicalPages1Based.indexOf(f.originalPage1) < 0) { result.physicalPages1Based.push(f.originalPage1); }
      if (f.start <= covered) { covered = Math.max(covered,Math.min(f.end,end)); }
    }
    if (covered !== end || end <= start || start < 0 || end > node.text.length) { result.uncoveredNodeIds.push(node.id); }
  }
  result.physicalPages1Based.sort((a: number,b: number): number => a-b);
  result.state = conflict ? PdfPageReferenceState.Conflict : result.physicalPages1Based.length === 0 ? PdfPageReferenceState.Unknown : result.uncoveredNodeIds.length > 0 || nodes.length === 0 ? PdfPageReferenceState.Partial : PdfPageReferenceState.Verified;
  result.reason = conflict ? 'ConflictingReviewedFragments' : result.state === PdfPageReferenceState.Verified ? 'ReviewedOriginalContent' : 'PageEvidenceIncomplete'; return result;
}
export function pdfDecodePageContext(raw: PdfJsonNode): PdfPageIdentityContext {
  const c = new PdfPageIdentityContext(); c.documentId = raw.required('documentId').string(); c.originalHash = raw.required('originalHash').string(); c.originalVersion = raw.required('originalVersion').integer(); c.originalPages = raw.required('originalPages').integer(); c.zipHash = raw.required('zipHash').string(); c.snapshotId = raw.required('snapshotId').string(); c.snapshotHash = raw.required('snapshotHash').string(); c.generation = raw.required('generation').string(); c.protocol = raw.required('protocol').string();
  if (!pdfPageHashValid(c.originalHash) || !pdfPageHashValid(c.zipHash) || !pdfPageHashValid(c.snapshotHash) || c.originalVersion < 1 || c.originalPages < 1 || c.originalPages > 50 || [c.documentId,c.snapshotId,c.generation,c.protocol].some((v: string): boolean => v.length < 1 || v.length > 128)) { throw new KnowledgeFailure('PageIdentitySchema','page'); } return c;
}
function pdfDecodeReviewedFragment(raw: PdfJsonNode): PdfReviewedPageFragment {
  const f = new PdfReviewedPageFragment(); f.start = raw.required('start').integer(); f.end = raw.required('end').integer(); f.textHash = raw.required('textHash').string(); f.originalPage1 = raw.required('originalPage1').integer(); return f;
}
export function pdfDecodePageIdentity(wire: string): PdfPageIdentityEvidence {
  const raw = new BoundedDocumentJson(pdfCodecUtf8(wire),new KnowledgeCancellation()).read(); const item = new PdfPageIdentityEvidence(); pdfCopyPageContext(pdfDecodePageContext(raw),item);
  item.wire = raw.required('wire').string(); item.id = raw.required('id').string(); item.nodeId = raw.required('nodeId').string(); item.nodeHash = raw.required('nodeHash').string(); item.providerPage0 = raw.required('providerPage0').integer(); item.reviewVersion = raw.required('reviewVersion').string(); item.reviewRecordHash = raw.required('reviewRecordHash').string(); item.uniqueAnchorHash = raw.required('uniqueAnchorHash').string(); item.structureAnchorHash = raw.required('structureAnchorHash').string(); item.fragments = raw.required('fragments').array().map((f: PdfJsonNode): PdfReviewedPageFragment => pdfDecodeReviewedFragment(f)); return item;
}
function pdfSnapshotPageContext(snapshot: PdfNormalizedDocument): PdfPageIdentityContext {
  const c = new PdfPageIdentityContext(); c.documentId = snapshot.documentId; c.originalHash = snapshot.binding.originalHash; c.originalVersion = snapshot.binding.originalVersion; c.originalPages = snapshot.binding.originalPages; c.zipHash = snapshot.binding.zipHash; c.snapshotId = snapshot.id; c.snapshotHash = snapshot.hash; c.generation = snapshot.generation; c.protocol = snapshot.profile; return c;
}
export async function pdfReviewedPageItems(bytes: Uint8Array, snapshot: PdfNormalizedDocument, identity: KnowledgeIdentityPort, cancel: KnowledgeCancellation): Promise<PdfPageIdentityEvidence[]> {
  if (bytes.length > 131072) { throw new KnowledgeFailure('PageReviewBudget','page'); }
  const raw = new BoundedDocumentJson(bytes,cancel).read(); if (raw.required('wire').string() !== 'PAGE-IDENTITY-REVIEW-1' || !pdfSamePageContext(pdfDecodePageContext(raw),pdfSnapshotPageContext(snapshot))) { throw new KnowledgeFailure('PageReviewIdentityMismatch','page'); }
  const recordHash: string = await identity.hash(bytes); const items: PdfPageIdentityEvidence[] = []; const seen = new Set<string>();
  for (const row of raw.required('pages').array()) {
    cancel.check(); const fields = row.array(); if (fields.length !== 6) { throw new KnowledgeFailure('PageReviewSchema','page'); }
    const nodes: PdfContentNode[] = []; const serialized: string[] = [];
    for (const id of fields[2].string().split(' ')) { const node = snapshot.nodes.find((n: PdfContentNode): boolean => n.id === id); if (node === undefined || seen.has(id) || !node.verified || node.text.length === 0 || node.pageIndex0 !== fields[0].integer()) { throw new KnowledgeFailure('PageReviewNodeMismatch','page'); } seen.add(id); nodes.push(node); serialized.push(`[${JSON.stringify(node.id)},${node.pageIndex0},${JSON.stringify(node.text)}]`); }
    if (await identity.hash(pdfCodecUtf8('['+serialized.join(',')+']')) !== fields[3].string()) { throw new KnowledgeFailure('PageReviewNodeSetHashMismatch','page'); }
    for (const node of nodes) {
      const item = new PdfPageIdentityEvidence(); pdfCopyPageContext(pdfSnapshotPageContext(snapshot),item); item.id = recordHash+':'+node.id; item.nodeId = node.id; item.providerPage0 = node.pageIndex0; item.nodeHash = await identity.hash(pdfCodecUtf8(node.text)); item.reviewRecordHash = recordHash; item.reviewVersion = raw.required('reviewVersion').string(); item.uniqueAnchorHash = fields[4].string(); item.structureAnchorHash = fields[5].string();
      const f = new PdfReviewedPageFragment(); f.end = node.text.length; f.textHash = item.nodeHash; f.originalPage1 = fields[1].integer(); item.fragments = [f]; if (!pdfPageEvidenceValid(item,item,node,item.nodeHash)) { throw new KnowledgeFailure('PageReviewEvidenceInvalid','page'); } items.push(item);
    }
  }
  for (const row of raw.required('cross').array()) {
    const f = row.array(); if (f.length !== 11) { throw new KnowledgeFailure('PageReviewCrossSchema','page'); } const node = snapshot.nodes.find((n: PdfContentNode): boolean => n.id === f[0].string());
    if (node === undefined || seen.has(node.id) || node.pageIndex0 !== f[1].integer() || await identity.hash(pdfCodecUtf8(node.text)) !== f[2].string()) { throw new KnowledgeFailure('PageReviewCrossNodeMismatch','page'); } seen.add(node.id);
    const item = new PdfPageIdentityEvidence(); pdfCopyPageContext(pdfSnapshotPageContext(snapshot),item); item.id = recordHash+':'+node.id; item.nodeId = node.id; item.providerPage0 = node.pageIndex0; item.nodeHash = f[2].string(); item.reviewRecordHash = recordHash; item.reviewVersion = raw.required('reviewVersion').string(); item.uniqueAnchorHash = item.nodeHash; item.structureAnchorHash = recordHash;
    for (let at: number = 3; at < 11; at += 4) { const fragment = new PdfReviewedPageFragment(); fragment.start = f[at].integer(); fragment.end = f[at+1].integer(); fragment.originalPage1 = f[at+2].integer(); fragment.textHash = f[at+3].string(); if (await identity.hash(pdfCodecUtf8(node.text.slice(fragment.start,fragment.end))) !== fragment.textHash) { throw new KnowledgeFailure('PageReviewCrossFragmentHash','page'); } item.fragments.push(fragment); }
    if (!pdfPageEvidenceValid(item,item,node,item.nodeHash)) { throw new KnowledgeFailure('PageReviewCrossInvalid','page'); } items.push(item);
  }
  if (items.length < 1 || items.length > 20000 || raw.required('pages').array().length > 50) { throw new KnowledgeFailure('PageReviewCount','page'); } return items;
}
export class PdfPageReferenceService implements KnowledgePageReferencePort {
  private repository: PdfPageIdentityRepositoryPort; private assets: PdfAssetPort; private identity: KnowledgeIdentityPort; private session: string;
  private cached: PdfNormalizedDocument | undefined;
  private releaseUnconfirmed: boolean = false;
  private originalToken: KnowledgeCancellation | undefined;
  private originalIdentity: string = '';
  private operations: number = 0; private tokens: KnowledgeCancellation[] = [];
  reading(): boolean { return this.operations > 0; }
  pause(): void { for (const token of this.tokens) { token.invalid = true; } this.clearCache(); }
  private verifyOriginal: (binding: PdfSourceBinding, cancel: KnowledgeCancellation) => Promise<void>;
  constructor(repository: PdfPageIdentityRepositoryPort, assets: PdfAssetPort, identity: KnowledgeIdentityPort, session: string, verifyOriginal: (binding: PdfSourceBinding, cancel: KnowledgeCancellation) => Promise<void>) { this.repository = repository; this.assets = assets; this.identity = identity; this.session = session; this.verifyOriginal = verifyOriginal; }
  private async withSnapshot<T>(hit: KnowledgeHit, cancel: KnowledgeCancellation, action: (snapshot: PdfNormalizedDocument) => Promise<T>): Promise<T> {
    this.operations++; this.tokens.push(cancel);
    try { return await this.readSnapshot<T>(hit,cancel,action); } finally { this.operations--; this.tokens = this.tokens.filter((token: KnowledgeCancellation): boolean => token !== cancel); }
  }
  private async readSnapshot<T>(hit: KnowledgeHit, cancel: KnowledgeCancellation, action: (snapshot: PdfNormalizedDocument) => Promise<T>): Promise<T> {
    if (this.releaseUnconfirmed) { throw new KnowledgeFailure('PageReferenceReleaseUnconfirmed','page'); }
    cancel.check();
    const doc = await this.repository.get(hit.documentId); const job = await this.repository.generationJob(hit.generation);
    if (doc === undefined || doc.tombstone || doc.activeContentGeneration !== hit.generation || doc.binding.originalHash !== hit.originalHash || doc.binding.originalVersion !== hit.originalVersion || job.snapshotId !== hit.snapshotId || job.snapshotHash !== hit.snapshotHash || job.binding === undefined) { throw new KnowledgeFailure('PageSourceNotCurrent','page'); }
    const lease = new KnowledgeReadLease(); lease.id = this.identity.id(); lease.generation = hit.generation; lease.sourceId = job.binding.originalId; lease.sessionId = this.session;
    await this.repository.acquireRead(lease);
    try {
      cancel.check(); const originalIdentity: string = `${job.binding.originalHash}:${job.binding.originalVersion}:${job.binding.originalAssetId}`;
      if (this.originalToken !== cancel || this.originalIdentity !== originalIdentity) { await this.verifyOriginal(job.binding,cancel); this.originalToken = cancel; this.originalIdentity = originalIdentity; }
      let snapshot = this.cached; if (snapshot === undefined || snapshot.id !== hit.snapshotId || snapshot.hash !== hit.snapshotHash) { snapshot = await this.assets.read(hit.snapshotId,cancel); this.cached = snapshot; }
      if (snapshot.hash !== hit.snapshotHash || snapshot.generation !== hit.generation || snapshot.binding.originalHash !== hit.originalHash || snapshot.documentId !== hit.documentId || snapshot.binding.zipHash !== job.binding.zipHash || snapshot.binding.originalVersion !== hit.originalVersion) { this.cached = undefined; throw new KnowledgeFailure('PageSnapshotMismatch','page'); }
      const result = await action(snapshot); cancel.check(); const current = await this.repository.get(hit.documentId); if (current === undefined || current.tombstone || current.epoch !== doc.epoch || current.activeContentGeneration !== hit.generation) { throw new KnowledgeFailure('PageSourceChanged','page'); } return result;
    } finally { try { await this.repository.releaseRead(lease.id); await this.repository.sourceRelease(lease,''); } catch { this.releaseUnconfirmed = true; await this.repository.sourceRelease(lease,'PageReferenceReleaseUnconfirmed'); throw new KnowledgeFailure('PageReferenceReleaseUnconfirmed','page'); } }
  }
  clearCache(): void { this.cached = undefined; this.originalToken = undefined; this.originalIdentity = ''; }
  releaseRetried(): void { this.releaseUnconfirmed = false; this.clearCache(); }
  async registerReview(bytes: Uint8Array, approvedReviewHash: string, hit: KnowledgeHit, cancel: KnowledgeCancellation): Promise<number> {
    if (!pdfPageHashValid(approvedReviewHash) || await this.identity.hash(bytes) !== approvedReviewHash) { throw new KnowledgeFailure('PageReviewNotApproved','page'); }
    return this.withSnapshot<number>(hit,cancel,async (snapshot: PdfNormalizedDocument): Promise<number> => { const items = await pdfReviewedPageItems(bytes,snapshot,this.identity,cancel); for (const item of items) { cancel.check(); await this.repository.appendPageIdentity(item); } return items.length; });
  }
  async resolve(hit: KnowledgeHit, cancel: KnowledgeCancellation): Promise<ResultPageReference> {
    return this.withSnapshot<ResultPageReference>(hit,cancel,async (snapshot: PdfNormalizedDocument): Promise<ResultPageReference> => {
      const ids = await this.repository.chunkSources(hit.chunkId,hit.generation); const nodes: PdfContentNode[] = []; const hashes: string[] = []; const evidence: PdfPageIdentityEvidence[][] = []; const ranges: KnowledgeResultRange[] = [];
      const chunk: PdfChunk | undefined = pdfStructureChunks(snapshot,hit.generation,cancel).find((c: PdfChunk): boolean => c.id === hit.chunkId);
      if (chunk === undefined || chunk.text !== hit.text || chunk.retrievalText !== hit.retrievalText || chunk.nodeIds.join('\t') !== ids.join('\t')) { throw new KnowledgeFailure('PageChunkSourceMismatch','page'); }
      for (const id of ids) {
        cancel.check(); const node = snapshot.nodes.find((n: PdfContentNode): boolean => n.id === id); if (node === undefined) { throw new KnowledgeFailure('PageSourceNodeMissing','page'); }
        const hash = await this.identity.hash(pdfCodecUtf8(node.text)); const checked: PdfPageIdentityEvidence[] = [];
        for (const item of await this.repository.pageIdentities(hit.generation,id)) { let valid = pdfPageEvidenceValid(item,pdfSnapshotPageContext(snapshot),node,hash); for (const f of item.fragments) { if (await this.identity.hash(pdfCodecUtf8(node.text.slice(f.start,f.end))) !== f.textHash) { valid = false; } } if (valid) { checked.push(item); } }
        nodes.push(node); hashes.push(hash); evidence.push(checked);
        const range = new KnowledgeResultRange(); range.start = node.table === undefined && ids.length === 1 ? chunk.sourceStart : 0; range.end = node.table === undefined && ids.length === 1 ? chunk.sourceEnd : node.text.length; ranges.push(range);
      }
      return pdfResolveReviewedNodes(pdfSnapshotPageContext(snapshot),nodes,hashes,evidence,ranges);
    });
  }
}
