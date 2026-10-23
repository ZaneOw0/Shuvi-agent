import { DocxSnapshot, DocxChunk, DocxCorrespondence, DocxLocator, DocxFailure, DocxLimits, DocxHeadingIdentity, DocxTextFragment } from '../domain/DocxKnowledgeModels';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { documentUtf8Bytes } from '../domain/DocumentParseModels';
import { docxReadLocator } from './DocxSnapshotCodec';
import { BoundedDocumentJson } from './BoundedDocumentJson';
import { pdfCodecUtf8 } from './PdfSnapshotCodec';

export async function docxStructureChunks(s: DocxSnapshot, identity: KnowledgeIdentityPort, cancel: KnowledgeCancellation): Promise<DocxChunk[]> {
  const chunks: DocxChunk[] = [];
  for (const node of s.nodes) {
    if (!s.correspondence.some((c: DocxCorrespondence): boolean => c.nodeId === node.id)) { continue; }
    const heading: string = node.locator.headings.filter((h: DocxHeadingIdentity): boolean => h.nodeId !== node.id && s.correspondence.some((c: DocxCorrespondence): boolean => c.nodeId === h.nodeId)).map((h: DocxHeadingIdentity): string => h.text).join(' / ');
    const prefix: string = heading.length > 0 ? heading+'\n' : '';
    if (documentUtf8Bytes(prefix) >= 2048 || Array.from(prefix).length >= 512) { throw new DocxFailure('HeadingPrefixInputBudget','chunk'); }
    let at: number = 0;
    while (at < node.text.length) {
      cancel.check(); let end: number = at; let scalars: number = Array.from(prefix).length; let bytes: number = documentUtf8Bytes(prefix);
      while (end < node.text.length) {
        const code: number = node.text.charCodeAt(end); const length: number = code >= 0xd800 && code <= 0xdbff ? 2 : 1; const next: string = node.text.slice(end,end+length); const n: number = documentUtf8Bytes(next);
        if (scalars+1 > 512 || bytes+n > 2048) { break; } end += length; scalars++; bytes += n;
      }
      if (end === at || chunks.length >= DocxLimits.chunks) { throw new DocxFailure('DocumentChunkBudget','chunk'); }
      const c: DocxChunk = new DocxChunk(); c.documentId = s.documentId; c.generation = s.generation; c.ordinal = chunks.length; c.id = s.generation+'-'+c.ordinal; c.text = node.text.slice(at,end); c.embeddingText = prefix+c.text;
      c.inputHash = await identity.hash(pdfCodecUtf8(c.embeddingText));
      const locator: DocxLocator = docxReadLocator(new BoundedDocumentJson(pdfCodecUtf8(JSON.stringify(node.locator)),cancel).read()); locator.start = at; locator.end = end;
      locator.fragments = locator.fragments.filter((f: DocxTextFragment): boolean => f.end > at && f.start < end);
      for (const f of locator.fragments) { const start: number = Math.max(at,f.start); const finish: number = Math.min(end,f.end); f.rawStart += start-f.start; f.rawEnd -= f.end-finish; f.start = start; f.end = finish; }
      c.locator = locator; chunks.push(c); at = end;
    }
  } return chunks;
}
