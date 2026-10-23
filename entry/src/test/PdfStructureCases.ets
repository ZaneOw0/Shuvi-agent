import { BoundedDocumentJson, PdfJsonNode } from '../main/ets/knowledge/pipeline/BoundedDocumentJson';
import { PdfTableDecoder } from '../main/ets/knowledge/pipeline/PdfTableDecoder';
import { KnowledgeCancellation, KnowledgeFailure, PdfNormalizedDocument, PdfContentNode, PdfNodeKind, PdfChunk, PdfTable, PdfSourceBinding, PdfZipManifest, PdfZipMember, PdfCoverageIssue } from '../main/ets/knowledge/domain/PdfKnowledgeModels';
import { PdfArchivePort } from '../main/ets/knowledge/domain/KnowledgePorts';
import { MineruPdfNormalizer } from '../main/ets/knowledge/pipeline/MineruPdfNormalizer';
import { pdfStructureChunks } from '../main/ets/knowledge/pipeline/PdfStructureChunker';
import { documentUtf8Bytes } from '../main/ets/knowledge/domain/DocumentParseModels';
export interface PdfStructureTestCase { name: string; run: () => Promise<void>; }
function pdfStructureRejects(action: () => void): void { let rejected: boolean = false; try { action(); } catch { rejected = true; } if (!rejected) { throw new Error('Expected structure rejection'); } }
function pdfAscii(raw: string): Uint8Array { const bytes: number[] = []; for (let at: number = 0; at < raw.length; at++) { bytes.push(raw.charCodeAt(at)); } return new Uint8Array(bytes); }
export class PdfProfileTestArchive implements PdfArchivePort {
  layout: string = '{"_version_name":"3.4.4","_backend":"hybrid","_effort":"medium","_ocr_enable":false,"pdf_info":[{"page_idx":0}]}';
  v1: string = '[{"page_idx":0,"bbox":[1,2,3,4]},{"page_idx":0,"bbox":[1,5,3,6]}]';
  v2: string = '[[{"type":"paragraph","bbox":[1,2,3,4],"content":{"paragraph_content":[{"type":"text","content":"fixture"}]}},{"type":"page_footer","bbox":[1,5,3,6],"content":{"page_footer_content":[]}}]]';
  capability(): string { return 'SyntheticVerifiedFixture'; }
  async inspect(_binding: PdfSourceBinding, _cancel: KnowledgeCancellation): Promise<PdfZipManifest> {
    const manifest: PdfZipManifest = new PdfZipManifest(); manifest.hardPassed = true; manifest.zipHash = 'b'.repeat(64);
    for (const name of ['fixture_content_list.json','layout.json','fixture_content_list_v2.json']) { const member: PdfZipMember = new PdfZipMember(); member.id = name; member.logicalName = name; member.verified = true; member.actualCrc32 = 0; manifest.members.push(member); } return manifest;
  }
  async readMember(_manifest: PdfZipManifest, member: PdfZipMember, cancel: KnowledgeCancellation): Promise<Uint8Array> { cancel.check(); return pdfAscii(member.logicalName === 'layout.json' ? this.layout : member.logicalName.endsWith('_v2.json') ? this.v2 : this.v1); }
  async release(): Promise<void> {}
}
export async function pdfProfileTestNormalize(archive: PdfProfileTestArchive): Promise<PdfNormalizedDocument> {
  const binding: PdfSourceBinding = new PdfSourceBinding(); binding.zipHash = 'b'.repeat(64); binding.originalPages = 1;
  const cancel: KnowledgeCancellation = new KnowledgeCancellation(); return new MineruPdfNormalizer().normalize(binding,await archive.inspect(binding,cancel),archive,cancel);
}
export function pdfStructureCases(): PdfStructureTestCase[] {
  return [
    { name: 'strict true and false profiles retain footer exclusion and unchanged true output', run: async (): Promise<void> => {
      const archive: PdfProfileTestArchive = new PdfProfileTestArchive();
      const negative: PdfNormalizedDocument = await pdfProfileTestNormalize(archive);
      archive.layout = archive.layout.replace('false','true'); const positive: PdfNormalizedDocument = await pdfProfileTestNormalize(archive);
      if (negative.profile !== 'MINERU-HOSTED-PDF-3.4.4-OCR-FALSE-1' || positive.profile !== 'MINERU-HOSTED-PDF-3.4.4-OBSERVED-1' || negative.nodes[1].kind !== PdfNodeKind.Unsupported || negative.nodes[1].excludedReason !== 'NodeTypeUnsupported' || negative.coverage.excludedNodes !== 1 || !negative.coverage.issues.some((issue: PdfCoverageIssue): boolean => issue.code === 'NodeTypeUnsupported')) { throw new Error('Profile or footer contract lost'); }
      negative.profile = positive.profile; if (JSON.stringify(negative) !== JSON.stringify(positive)) { throw new Error('Boolean branch changed content'); }
    } },
    { name: 'missing null numeric string OCR and unknown profile remain rejected', run: async (): Promise<void> => {
      const source: PdfProfileTestArchive = new PdfProfileTestArchive();
      const variants: string[] = [source.layout.replace('"_ocr_enable":false,',''),source.layout.replace('false','null'),source.layout.replace('false','0'),source.layout.replace('false','"false"'),source.layout.replace('3.4.4','3.4.5'),source.layout.replace('hybrid','vlm'),source.layout.replace('medium','high')];
      for (const layout of variants) { const archive: PdfProfileTestArchive = new PdfProfileTestArchive(); archive.layout = layout; let rejected: boolean = false; try { await pdfProfileTestNormalize(archive); } catch (error) { rejected = error instanceof KnowledgeFailure; } if (!rejected) { throw new Error('Invalid profile accepted'); } }
    } },
    { name: 'false profile still rejects page bbox and manifest audit drift', run: async (): Promise<void> => {
      for (const target of ['page','box','order']) { const archive: PdfProfileTestArchive = new PdfProfileTestArchive(); if (target === 'page') { archive.layout = archive.layout.replace('"page_idx":0','"page_idx":1'); } else if (target === 'box') { archive.v2 = archive.v2.replace('[1,2,3,4]','[3,2,1,4]'); } else { archive.v1 = archive.v1.replace('[1,2,3,4]','[2,2,3,4]'); } let rejected: boolean = false; try { await pdfProfileTestNormalize(archive); } catch (error) { rejected = error instanceof KnowledgeFailure; } if (!rejected) { throw new Error('Audit drift accepted'); } }
    } },
    { name: 'PDF分块Unicode/全前缀计量且无丢失', run: async (): Promise<void> => {
      const snapshot: PdfNormalizedDocument = new PdfNormalizedDocument(); snapshot.coverage.hardPassed = true;
      const node: PdfContentNode = new PdfContentNode(); node.id = 'node'; node.kind = PdfNodeKind.Text; node.verified = true; node.text = '😀中文公式x'.repeat(250); snapshot.nodes = [node];
      const chunks: PdfChunk[] = pdfStructureChunks(snapshot,'unit',new KnowledgeCancellation());
      if (chunks.map((chunk: PdfChunk): string => chunk.text).join('') !== node.text || chunks.some((chunk: PdfChunk): boolean => Array.from(chunk.retrievalText).length > 512 || documentUtf8Bytes(chunk.retrievalText) > 2048)) { throw new Error('Lossless Unicode projection'); }
      node.kind = PdfNodeKind.Reference; if (pdfStructureChunks(snapshot,'unit',new KnowledgeCancellation())[0].defaultIncluded) { throw new Error('Reference default included'); }
      node.kind = PdfNodeKind.Header; pdfStructureRejects((): void => { pdfStructureChunks(snapshot,'unit',new KnowledgeCancellation()); });
    } },
    { name: 'JSON重复解码key/超深/数值/代理/尾随语法拒绝', run: async (): Promise<void> => {
      for (const raw of ['{"a":1,"\\u0061":2}','['.repeat(65)+'0'+']'.repeat(65),'1e999','"\\ud800"','[1,]','{"x":0,}','{}{}','01']) { pdfStructureRejects((): void => { new BoundedDocumentJson(pdfAscii(raw),new KnowledgeCancellation()).read(); }); }
      pdfStructureRejects((): void => { new BoundedDocumentJson(pdfAscii('"'+'x'.repeat(262145)+'"'),new KnowledgeCancellation()).read(); });
      const keys: string[] = []; for (let index: number = 0; index < 257; index++) { keys.push(`"k${index}":0`); }
      pdfStructureRejects((): void => { new BoundedDocumentJson(pdfAscii('{'+keys.join(',')+'}'),new KnowledgeCancellation()).read(); });
      const root: PdfJsonNode = new BoundedDocumentJson(pdfAscii('{"x":"\\ud83d\\ude00","n":1}'),new KnowledgeCancellation()).read();
      if (root.required('x').string().length !== 2 || root.required('n').integer() !== 1) { throw new Error('Typed JSON lost value'); }
    } },
    { name: '表格跨度占位/实体惰性且无猜测表头', run: async (): Promise<void> => {
      const table: PdfTable = new PdfTableDecoder('<table><tr><td rowspan="2">&amp;lt;</td><td>x</td></tr><tr><td>y</td></tr></table>').decode('unit');
      if (table.cells.length !== 3 || table.occupancy !== 4 || table.cells[0].text !== '&lt;' || table.headerEvidence !== 'NotReported') { throw new Error('Inert table contract'); }
      for (const raw of ['<table><tr><td onclick="x">a</td></tr></table>','<table><tr><td><script>x</script></td></tr></table>','<table><tr><th>x</th></tr></table>','<table><tr><td rowspan="1001">x</td></tr></table>','<table><tr><td colspan="2" colspan="2">x</td></tr></table>','<table><tr><td rowspan="2">x</td></tr></table>']) { pdfStructureRejects((): void => { new PdfTableDecoder(raw).decode('unit'); }); }
    } }
  ];
}
