import { ParsedDocument, ParsedBlock, ParsedInline, ParsedKind, ParsedTextChunk, ParsedImageOccurrence, ParsedCancellation, ParsedFailure, ParsedLimits } from '../domain/ParsedDocumentModels';
import { ParsedIdentityPort } from '../domain/ParsedDocumentPorts';
import { parsedUtf8 } from './ParsedDocumentCodec';

export function parsedBlockText(block: ParsedBlock): string {
  if (block.kind === ParsedKind.Container || block.kind === ParsedKind.Table || block.kind === ParsedKind.Image || block.kind === ParsedKind.Unknown) { return ''; }
  if (block.evidenceType === 'SourceContextOnly') { return ''; }
  if (block.inlines.length > 0) {
    return block.inlines.map((run: ParsedInline): string => run.kind === ParsedKind.Text ? run.text : run.kind === ParsedKind.Formula ? run.formula.text || run.formula.latex : '').join('');
  }
  return block.kind === ParsedKind.Formula ? block.formula.text || block.formula.latex : block.text;
}
export function parsedChunkSourceText(document: ParsedDocument, chunk: ParsedTextChunk): string {
  if (chunk.blockId.length > 0) {
    const block: ParsedBlock | undefined = document.blocks?.find((b: ParsedBlock): boolean => b.id === chunk.blockId);
    if (block === undefined) { throw new ParsedFailure('ChunkBlockMissing','chunk'); } return parsedBlockText(block);
  }
  if (chunk.occurrenceId.length > 0) { return document.occurrences.find((o: ParsedImageOccurrence): boolean => o.id === chunk.occurrenceId)?.ocr ?? ''; }
  return document.blocks === undefined || document.blocks.length === 0 ? document.markdown : '';
}
async function splitInput(text: string, document: ParsedDocument, block: string, occurrence: string, evidence: string, out: ParsedTextChunk[], identity: ParsedIdentityPort, cancel: ParsedCancellation): Promise<void> {
  for (let start: number = 0; start < text.length;) {
    cancel.check(); let end: number = start; let scalars: number = 0; let bytes: number = 0;
    while (end < text.length && scalars < 512) {
      const cp: number = text.codePointAt(end) ?? 0; const length: number = cp > 65535 ? 2 : 1;
      const n: number = cp < 128 ? 1 : cp < 2048 ? 2 : cp < 65536 ? 3 : 4; if (bytes+n > 2048) { break; }
      bytes += n; end += length; scalars++;
    }
    if (end <= start) { throw new ParsedFailure('ChunkBoundary','chunk'); }
    const actual: string = text.slice(start,end);
    if (actual.trim().length > 0) {
      if (out.length >= ParsedLimits.chunks) { throw new ParsedFailure('DocumentChunkBudget','chunk'); }
      const c: ParsedTextChunk = new ParsedTextChunk(); c.id = `${document.generation}-c${out.length}`; c.documentKey = document.documentKey; c.generation = document.generation;
      c.ordinal = out.length; c.text = actual; c.inputHash = await identity.hash(parsedUtf8(actual)); c.blockId = block; c.occurrenceId = occurrence; c.evidence = evidence; c.start = start; c.end = end; out.push(c);
    }
    start = end;
  }
}
export async function parsedDocumentChunks(document: ParsedDocument, identity: ParsedIdentityPort, cancel: ParsedCancellation): Promise<ParsedTextChunk[]> {
  const chunks: ParsedTextChunk[] = [];
  const blocks: ParsedBlock[] = document.blocks ?? [];
  if (blocks.length === 0 && document.markdown.trim().length > 0) { await splitInput(document.markdown,document,'','','Body',chunks,identity,cancel); }
  for (const block of blocks) {
    const text: string = parsedBlockText(block);
    // A populated container never adds a second copy of its leaves.
    if ((block.kind === ParsedKind.Container || block.kind === ParsedKind.Table) && blocks.some((child: ParsedBlock): boolean => child.parentId === block.id)) { continue; }
    await splitInput(text,document,block.id,block.evidenceType === 'Ocr' ? block.imageOccurrenceId : '',block.evidenceType === 'Ocr' ? 'Ocr' : block.kind === ParsedKind.Formula ? 'Formula' : 'Body',chunks,identity,cancel);
  }
  for (const image of document.occurrences) {
    if (image.ocr.trim().length === 0 || blocks.some((b: ParsedBlock): boolean => b.evidenceType === 'Ocr' && b.imageOccurrenceId === image.id)) { continue; }
    await splitInput(image.ocr,document,image.blockId,image.id,'Ocr',chunks,identity,cancel);
  }
  return chunks;
}
