import { pdfService } from '@kit.PDFKit';
import { taskpool } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

// Fixed numeric wire: outcome, pages, ParseResult, operation, SDK code, release code.
// Keep native objects and exceptions inside the worker.
@Concurrent
export function documentPdfCountWorker(path: string, deadline: number): number[] {
  const result: number[] = [0,0,-1,0,0,0];
  let pdf: pdfService.PdfDocument | undefined;
  try {
    if (!canIUse('SystemCapability.OfficeService.PDFService.Core')) { result[0]=2; return result; }
    if (taskpool.Task.isCanceled()) { result[0]=6; return result; }
    if (Date.now()>=deadline) { result[0]=7; return result; }
    result[3]=1; pdf=new pdfService.PdfDocument();
    result[3]=2; if (pdf.isEncrypted(path)) { result[0]=3; return result; }
    result[3]=3;
    // Use the documented synchronous form. Check cancellation on the worker
    // before and after the native call instead of inside a native callback.
    result[2]=pdf.loadDocument(path,'');
    if (result[2]!==pdfService.ParseResult.PARSE_SUCCESS) { result[0]=4; return result; }
    if (taskpool.Task.isCanceled()) { result[0]=6; return result; }
    if (Date.now()>=deadline) { result[0]=7; return result; }
    result[3]=4; const pages: number=pdf.getPageCount();
    if (!Number.isSafeInteger(pages) || pages<1 || pages>50) { result[0]=5; return result; }
    result[1]=pages; result[0]=1;
  } catch (error) {
    const system: BusinessError=error; result[0]=8;
    result[4]=Number.isSafeInteger(system?.code)?system.code:0;
  } finally {
    if (pdf!==undefined) {
      try { pdf.releaseDocument(); }
      catch (error) { const system: BusinessError=error; result[5]=Number.isSafeInteger(system?.code)?system.code:0; if (result[0]===1) { result[0]=9; } }
    }
  }
  return result;
}
