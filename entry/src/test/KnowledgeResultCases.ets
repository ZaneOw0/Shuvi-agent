import { PdfPageIdentityContext, PdfPageIdentityEvidence, PdfReviewedPageFragment, PdfPageReferenceState } from '../main/ets/knowledge/domain/PdfLocalModels';
import { PdfContentNode } from '../main/ets/knowledge/domain/PdfKnowledgeModels';
import { pdfResolveReviewedNodes } from '../main/ets/knowledge/application/PdfPageReferenceService';
import { knowledgeMatch, knowledgeSegments } from '../main/ets/knowledge/pipeline/KnowledgeMatchPolicy';
import { KnowledgeHit, KnowledgeMatchKind, KnowledgeResultSegment } from '../main/ets/knowledge/domain/KnowledgeSearchModels';
import { prepareTextQuery } from '../main/ets/knowledge/pipeline/QueryPreparation';

export interface KnowledgeResultTestCase { name: string; run: () => Promise<void>; }
function resultPageContext(): PdfPageIdentityContext {
  const context: PdfPageIdentityContext = new PdfPageIdentityContext(); context.documentId = 'doc'; context.originalHash = 'a'.repeat(64); context.originalVersion = 1; context.originalPages = 5; context.zipHash = 'b'.repeat(64); context.snapshotId = 'snap'; context.snapshotHash = 'c'.repeat(64); context.generation = 'gen'; context.protocol = 'fixture'; return context;
}
function resultPageEvidence(context: PdfPageIdentityContext, node: PdfContentNode, page: number): PdfPageIdentityEvidence {
  const item: PdfPageIdentityEvidence = new PdfPageIdentityEvidence(); item.id = 'proof-'+page; item.documentId = context.documentId; item.originalHash = context.originalHash; item.originalVersion = context.originalVersion; item.originalPages = context.originalPages; item.zipHash = context.zipHash; item.snapshotId = context.snapshotId; item.snapshotHash = context.snapshotHash; item.generation = context.generation; item.protocol = context.protocol;
  item.nodeId = node.id; item.nodeHash = 'd'.repeat(64); item.providerPage0 = node.pageIndex0; item.reviewVersion = 'review1'; item.reviewRecordHash = 'e'.repeat(64); item.uniqueAnchorHash = 'f'.repeat(64); item.structureAnchorHash = '0'.repeat(64);
  const fragment: PdfReviewedPageFragment = new PdfReviewedPageFragment(); fragment.end = node.text.length; fragment.textHash = item.nodeHash; fragment.originalPage1 = page; item.fragments = [fragment]; return item;
}
export function knowledgeResultCases(): KnowledgeResultTestCase[] { return [
  { name: '正文中文任一term命中且仅ASCII fold保持UTF16与原串',run: async (): Promise<void> => {
    const hit = new KnowledgeHit(); hit.text = '😀 ROC/roc 查全率；ROC İıＡa'; hit.retrievalText = '查准率\n'+hit.text;
    hit.match = knowledgeMatch(hit,prepareTextQuery('roc 查准率'),false);
    if (hit.match.kind !== KnowledgeMatchKind.Direct || hit.match.matchedTerms.join(',') !== 'roc' || hit.match.ranges.length !== 3 || hit.match.ranges[0].start !== 3) { throw new Error('Literal fold/range mismatch'); }
    if (knowledgeSegments(hit).map((s: KnowledgeResultSegment): string => s.text).join('') !== hit.text) { throw new Error('Display string mutated'); }
    if (knowledgeMatch(hit,prepareTextQuery('查准率'),false).kind !== KnowledgeMatchKind.Unclassified || knowledgeMatch(hit,prepareTextQuery('i'),false).ranges.length !== 0) { throw new Error('Prefix or non-ASCII folded'); }
  } },
  { name: '重叠重复合并与代理对边界安全且无vector不冒Similar',run: async (): Promise<void> => {
    const hit = new KnowledgeHit(); hit.text = 'ababa😀😀'; hit.match = knowledgeMatch(hit,prepareTextQuery('aba bab 😀'),false);
    if (hit.match.ranges.length !== 1 || hit.match.ranges[0].start !== 0 || hit.match.ranges[0].end !== hit.text.length) { throw new Error('Overlap union lost'); }
    if (knowledgeMatch(hit,prepareTextQuery('zero'),false).kind !== KnowledgeMatchKind.Unclassified || knowledgeMatch(hit,prepareTextQuery('zero'),true).kind !== KnowledgeMatchKind.Unclassified) { throw new Error('Fabricated similar provenance'); }
  } },
  { name: '页证据独立于geometry且身份漂移拒绝',run: async (): Promise<void> => {
    const c = resultPageContext(); const n = new PdfContentNode(); n.id = 'n'; n.text = 'abc'; n.pageIndex0 = 1; const e = resultPageEvidence(c,n,4);
    if (pdfResolveReviewedNodes(c,[n],['d'.repeat(64)],[[e]]).state !== PdfPageReferenceState.Verified) { throw new Error('Page requires geometry'); }
    e.zipHash = '9'.repeat(64); if (pdfResolveReviewedNodes(c,[n],['d'.repeat(64)],[[e]]).state !== PdfPageReferenceState.Unknown) { throw new Error('Identity drift trusted'); }
  } },
  { name: '页冲突不取第一条且跨节点取完整页集合',run: async (): Promise<void> => {
    const c = resultPageContext(); const a = new PdfContentNode(); a.id = 'a'; a.text = 'abc'; a.pageIndex0 = 1; const b = new PdfContentNode(); b.id = 'b'; b.text = 'xyz'; b.pageIndex0 = 2;
    const ea = resultPageEvidence(c,a,4); const eb = resultPageEvidence(c,b,5);
    const complete = pdfResolveReviewedNodes(c,[a,b],['d'.repeat(64),'d'.repeat(64)],[[ea],[eb]]);
    if (complete.state !== PdfPageReferenceState.Verified || complete.physicalPages1Based.join(',') !== '4,5') { throw new Error('Cross-node pages lost'); }
    if (pdfResolveReviewedNodes(c,[a],['d'.repeat(64)],[[ea,resultPageEvidence(c,a,3)]]).state !== PdfPageReferenceState.Conflict) { throw new Error('First proof wins'); }
    if (pdfResolveReviewedNodes(c,[a,b],['d'.repeat(64),'d'.repeat(64)],[[ea],[]]).state !== PdfPageReferenceState.Partial) { throw new Error('Uncovered node hidden'); }
  } },
  { name: '跨页fragment未覆盖尾部保留Partial不冒唯一页',run: async (): Promise<void> => {
    const c = resultPageContext(); const n = new PdfContentNode(); n.id = 'a'; n.text = 'abcdef'; n.pageIndex0 = 1; const e = resultPageEvidence(c,n,2); e.fragments[0].end = 3;
    const r = pdfResolveReviewedNodes(c,[n],['d'.repeat(64)],[[e]]); if (r.state !== PdfPageReferenceState.Partial || r.physicalPages1Based.join(',') !== '2') { throw new Error('Incomplete fragment accepted'); }
  } }
]; }
