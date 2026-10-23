import { PdfNormalizedDocument, PdfContentNode, PdfNodeKind, PdfChunk, PdfBudget, KnowledgeCancellation, KnowledgeFailure, PdfTableCell } from '../domain/PdfKnowledgeModels';
import { documentUtf8Bytes } from '../domain/DocumentParseModels';

function pdfCodepoints(text: string): number { let count: number = 0; for (const _char of text) { count++; } return count; }
function pdfChunkProjection(source: string, prefix: string, start: number): number {
  let units: number = start; let points: number = pdfCodepoints(prefix); let bytes: number = documentUtf8Bytes(prefix);
  if (points >= 512 || bytes >= 2048) { throw new KnowledgeFailure('PrefixNotBounded','pdf-chunk'); }
  let lastBoundary: number = -1;
  while (units < source.length) {
    const cp: number = source.codePointAt(units) ?? 0; const char: string = String.fromCodePoint(cp); const nextBytes: number = documentUtf8Bytes(char);
    if (points+1 > 512 || bytes+nextBytes > 2048) { break; }
    points++; bytes += nextBytes; units += char.length;
    if (points >= 320 && new RegExp('[\n。！？.!?;；]').test(char)) { lastBoundary = units; }
    if (points >= 384 && lastBoundary > start) { return lastBoundary; }
  }
  return units;
}
export function pdfStructureChunks(snapshot: PdfNormalizedDocument, generation: string, cancel: KnowledgeCancellation): PdfChunk[] {
  if (!snapshot.coverage.hardPassed) { throw new KnowledgeFailure('HardIntegrityRequired','pdf-chunk'); }
  const chunks: PdfChunk[] = []; let headings: string[] = [];
  for (const node of snapshot.nodes) {
    cancel.check(); if (!node.verified || node.kind === PdfNodeKind.Header || node.kind === PdfNodeKind.PageNumber || node.kind === PdfNodeKind.Unsupported) { continue; }
    if (node.kind === PdfNodeKind.Title) { headings = [node.text]; }
    const prefix: string = node.kind === PdfNodeKind.Title || headings.length === 0 ? '' : headings.join(' / ')+'\n';
    const segments: string[] = []; const cellIds: string[][] = [];
    if (node.table !== undefined) {
      // Source cells retain span/row relations in the snapshot. No guessed header,
      // cell bbox or flattened row pretending to reconstruct the original table.
      for (let row: number = 0; row < node.table.rows; row++) {
        const cells: PdfTableCell[] = node.table.cells.filter((cell: PdfTableCell): boolean => cell.row === row);
        segments.push(cells.map((cell: PdfTableCell): string => cell.text).join(' | ')); cellIds.push(cells.map((cell: PdfTableCell): string => cell.id));
      }
    } else { segments.push(node.text); cellIds.push([]); }
    for (let segment: number = 0; segment < segments.length; segment++) {
      cancel.check();
      const source: string = segments[segment];
      for (let start: number = 0; start < source.length;) {
        cancel.check();
        const end: number = pdfChunkProjection(source,prefix,start); if (end <= start) { throw new KnowledgeFailure('CannotLosslesslyChunk','pdf-chunk'); }
        const chunk: PdfChunk = new PdfChunk(); chunk.id = `${generation}-c${chunks.length}`; chunk.documentId = snapshot.documentId; chunk.generation = generation;
        chunk.snapshotId = snapshot.id; chunk.snapshotHash = snapshot.hash; chunk.originalHash = snapshot.binding.originalHash; chunk.originalVersion = snapshot.binding.originalVersion;
        chunk.ordinal = chunks.length; chunk.kind = node.kind; chunk.text = source.slice(start,end); chunk.prefix = prefix; chunk.retrievalText = prefix+chunk.text; chunk.embeddingText = chunk.retrievalText;
        chunk.nodeIds = [node.id]; chunk.cellIds = cellIds[segment]; chunk.assetIds = node.assetIds.slice(); chunk.sourceStart = start; chunk.sourceEnd = end; chunk.locators = node.locators.slice();
        chunk.defaultIncluded = node.kind !== PdfNodeKind.Reference && node.kind !== PdfNodeKind.Aside;
        if (chunks.length >= PdfBudget.documentChunks) { throw new KnowledgeFailure('DocumentChunkBudget','pdf-chunk'); } chunks.push(chunk); start = end;
      }
    }
  }
  if (chunks.length === 0) { throw new KnowledgeFailure('NoPublishableChunks','pdf-chunk'); } return chunks;
}
