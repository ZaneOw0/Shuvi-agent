import { BoundedDocumentJson, PdfJsonNode } from '../main/ets/knowledge/pipeline/BoundedDocumentJson';
import { PdfTableDecoder } from '../main/ets/knowledge/pipeline/PdfTableDecoder';
import { KnowledgeCancellation, PdfNormalizedDocument, PdfContentNode, PdfNodeKind, PdfChunk, PdfTable } from '../main/ets/knowledge/domain/PdfKnowledgeModels';
import { pdfStructureChunks } from '../main/ets/knowledge/pipeline/PdfStructureChunker';
import { documentUtf8Bytes } from '../main/ets/knowledge/domain/DocumentParseModels';
export interface PdfStructureTestCase { name: string; run: () => Promise<void>; }
function pdfStructureRejects(action: () => void): void { let rejected: boolean = false; try { action(); } catch { rejected = true; } if (!rejected) { throw new Error('Expected structure rejection'); } }
function pdfAscii(raw: string): Uint8Array { const bytes: number[] = []; for (let at: number = 0; at < raw.length; at++) { bytes.push(raw.charCodeAt(at)); } return new Uint8Array(bytes); }
export function pdfStructureCases(): PdfStructureTestCase[] {
  return [
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
