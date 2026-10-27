import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { DocumentOriginal, DocumentParseCancellation, DocumentParseFailure, DocumentPreflightStatus } from '../domain/DocumentParseModels';
import { documentEnsureDirectory, documentHashFile, documentAssetPath } from '../infra/DocumentFileOperations';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { PdfJsPreflight } from '../infra/PdfJsPreflight';
import { PdfJsRuntime } from '../infra/PdfJsRuntime';

export function pdfJsFixtureBytes(): Uint8Array {
  const content: string='BT /F1 20 Tf 40 430 Td (SHUVI PDFJS E2E) Tj 0 -40 Td /F1 12 Tf (Local original pages remain visible on Windows.) Tj 0 -28 Td (MinerU extracts this text for semantic indexing.) Tj ET';
  const objects: string[]=['<< /Type /Catalog /Pages 2 0 R >>','<< /Type /Pages /Kids [3 0 R] /Count 1 >>','<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',`<< /Length ${content.length} >>\nstream\n${content}\nendstream`,'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'];
  let text: string='%PDF-1.4\n'; const offsets: number[]=[0];
  for (let i: number=0;i<objects.length;i++) { offsets.push(text.length); text+=`${i+1} 0 obj\n${objects[i]}\nendobj\n`; }
  const start: number=text.length; text+=`xref\n0 ${objects.length+1}\n0000000000 65535 f \n`;
  for (let i: number=1;i<offsets.length;i++) { text+=String(offsets[i]).padStart(10,'0')+' 00000 n \n'; }
  text+=`trailer\n<< /Size ${objects.length+1} /Root 1 0 R >>\nstartxref\n${start}\n%%EOF\n`; return pdfCodecUtf8(text);
}
export async function pdfJsLocalCase(context: common.Context, report: (line: string) => void): Promise<void> {
  const root: string=context.cacheDir+'/pdfjs-local-'+Date.now(); await documentEnsureDirectory(root); await documentEnsureDirectory(root+'/knowledge_parse_v1');
  const bytes: Uint8Array=pdfJsFixtureBytes(); const original: DocumentOriginal=new DocumentOriginal(); original.id='pdfjs-local'; original.assetId='original-pdfjs-local'; original.title='shuvi-pdfjs-e2e-20261027.pdf'; original.bytes=bytes.length;
  const path: string=documentAssetPath(root+'/knowledge_parse_v1',original.assetId); const file: fileIo.File=await fileIo.open(path,fileIo.OpenMode.CREATE|fileIo.OpenMode.READ_WRITE|fileIo.OpenMode.NOFOLLOW);
  try { if (await fileIo.write(file.fd,bytes.buffer)!==bytes.length) { throw new DocumentParseFailure('隔离PDF写入不完整','PDF.js测试'); } await fileIo.fsync(file.fd); } finally { await fileIo.close(file); }
  original.hash=await documentHashFile(path,20971520,new DocumentParseCancellation()); await new PdfJsPreflight(root).inspect(original,new DocumentParseCancellation());
  if (original.preflight!==DocumentPreflightStatus.Passed || original.pages!==1) { throw new DocumentParseFailure('隔离PDF真实预检失败','PDF.js测试'); }
  report(`PDFJS_LOCAL pages=1 bytes=${bytes.length} hash=${original.hash} engine=6.4.299 requests=0`);
  await PdfJsRuntime.shared.preview(path,original,new DocumentParseCancellation());
}
