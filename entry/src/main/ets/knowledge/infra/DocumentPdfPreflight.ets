import { pdfService } from '@kit.PDFKit';
import { taskpool } from '@kit.ArkTS';
import { DocumentPreflightPort } from '../domain/DocumentParsePorts';
import { DocumentOriginal, DocumentParseFormat, DocumentParseCancellation, DocumentPreflightStatus, DocumentParseBudget, DocumentParseFailure } from '../domain/DocumentParseModels';
import { documentAssetPath } from './DocumentFileOperations';

@Concurrent
function documentPdfCountWorker(path: string): number {
  if (!canIUse('SystemCapability.OfficeService.PDFService.Core')) { return -1; }
  const pdf: pdfService.PdfDocument = new pdfService.PdfDocument(); const started: number = Date.now();
  try {
    if (pdf.isEncrypted(path)) { return -2; }
    const loaded: pdfService.ParseResult = pdf.loadDocument(path, '', (_progress: number): number => {
      if (taskpool.Task.isCanceled() || Date.now() - started >= DocumentParseBudget.localMs) { throw new DocumentParseFailure('PDF本地预检取消或超时', '预检'); }
      return 0;
    });
    if (loaded !== pdfService.ParseResult.PARSE_SUCCESS || Date.now() - started >= DocumentParseBudget.localMs) { return -3; }
    const pages: number = pdf.getPageCount(); return Number.isSafeInteger(pages) && pages >= 1 && pages <= 50 ? pages : -4;
  } catch { return -5; } finally { pdf.releaseDocument(); }
}
export class DocumentPdfPreflight implements DocumentPreflightPort {
  private root: string;
  private task: taskpool.GenericsTask<[string], number> | undefined = undefined;
  cancelLocal(): void { if (this.task !== undefined) { try { taskpool.cancel(this.task); } catch {} } }
  constructor(filesDir: string) { this.root = `${filesDir}/knowledge_parse_v1`; }
  async inspect(original: DocumentOriginal, cancel: DocumentParseCancellation): Promise<DocumentOriginal> {
    if (original.format !== DocumentParseFormat.Pdf || original.preflightReason.length > 0) { return original; }
    cancel.check();
    if (this.task !== undefined) { throw new DocumentParseFailure('已有PDF预检任务', '预检'); }
    this.task = new taskpool.GenericsTask<[string], number>(documentPdfCountWorker, documentAssetPath(this.root, original.assetId));
    const timer: number = setTimeout((): void => { this.cancelLocal(); }, DocumentParseBudget.localMs);
    let pages: number = -5;
    try { pages = await taskpool.execute<[string], number>(this.task); }
    finally { clearTimeout(timer); this.task = undefined; }
    cancel.check();
    if (pages >= 1 && pages <= 50) { original.pages = pages; original.preflight = DocumentPreflightStatus.Passed; }
    else {
      original.preflight = DocumentPreflightStatus.Blocked;
      original.preflightReason = pages === -2 ? 'PDF加密，禁止外发' : pages === -4 ? 'PDF原页不在1–50页范围' : 'PDFKit不可用或加载失败；原件保留，外发阻止';
    }
    return original;
  }
}
