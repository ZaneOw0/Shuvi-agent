import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { pdfService } from '@kit.PDFKit';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { DocumentOriginal, DocumentParseCancellation, DocumentPreflightStatus, DocumentParseFailure } from '../domain/DocumentParseModels';
import { DocumentPdfPreflight } from '../infra/DocumentPdfPreflight';
import { documentEnsureDirectory, documentHashFile } from '../infra/DocumentFileOperations';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';

export async function documentPdfPreflightCase(context: common.Context, scope: KnowledgeStorageScope): Promise<string> {
  scope.requireTestOwner(scope.key);
  const capability: boolean=canIUse('SystemCapability.OfficeService.PDFService.Core');
  if (!capability) { return 'PDF_PREFLIGHT_PROBE capability=0 expected_unavailable=1 passed=0 requests=0'; }
  const root: string=`${context.cacheDir}/pdf_preflight_${scope.key}`;
  await documentEnsureDirectory(root); await documentEnsureDirectory(root+'/knowledge_parse_v1');
  let text: string='%PDF-1.4\n'; const offsets: number[]=[0];
  const objects: string[]=['<< /Type /Catalog /Pages 2 0 R >>','<< /Type /Pages /Kids [3 0 R] /Count 1 >>','<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 500] /Resources << >> >>'];
  for (let at: number=0;at<objects.length;at++) { offsets.push(text.length); text+=`${at+1} 0 obj\n${objects[at]}\nendobj\n`; }
  const start: number=text.length; text+='xref\n0 4\n0000000000 65535 f \n';
  for (let at: number=1;at<offsets.length;at++) { text+=String(offsets[at]).padStart(10,'0')+' 00000 n \n'; }
  text+=`trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n${start}\n%%EOF\n`;
  const bytes: Uint8Array=pdfCodecUtf8(text); const path: string=root+'/knowledge_parse_v1/original-probe';
  const file: fileIo.File=await fileIo.open(path,fileIo.OpenMode.CREATE|fileIo.OpenMode.READ_WRITE|fileIo.OpenMode.NOFOLLOW);
  try { if (await fileIo.write(file.fd,bytes.buffer)!==bytes.length) { throw new DocumentParseFailure('隔离PDF写入不完整','预检测试'); } await fileIo.fsync(file.fd); }
  finally { await fileIo.close(file); }
  let direct: number=-1; let directPages: number=0;
  const doc: pdfService.PdfDocument=new pdfService.PdfDocument();
  try { direct=doc.loadDocument(path,''); if (direct===0) { directPages=doc.getPageCount(); } } finally { doc.releaseDocument(); }
  const original: DocumentOriginal=new DocumentOriginal(); original.id='probe'; original.assetId='original-probe'; original.bytes=bytes.length; original.hash=await documentHashFile(path,20971520,new DocumentParseCancellation()); original.preflightReason='PDFKit不可用或加载失败；原件保留，外发阻止';
  await new DocumentPdfPreflight(root).inspect(original,new DocumentParseCancellation());
  const line: string=`PDF_PREFLIGHT_PROBE capability=1 direct=${direct} direct_pages=${directPages} pages=${original.pages} passed=${original.preflight===DocumentPreflightStatus.Passed?1:0} requests=0`;
  if (direct!==0 || directPages!==1 || original.pages!==1 || original.preflight!==DocumentPreflightStatus.Passed) { throw new DocumentParseFailure(line+' '+original.preflightReason,'预检测试'); }
  return line;
}
