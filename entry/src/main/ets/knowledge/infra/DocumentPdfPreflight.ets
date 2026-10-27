import { taskpool } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { DocumentPreflightPort } from '../domain/DocumentParsePorts';
import { DocumentOriginal, DocumentParseFormat, DocumentParseCancellation, DocumentPreflightStatus, DocumentParseBudget, DocumentParseFailure } from '../domain/DocumentParseModels';
import { documentAssetPath, documentContainerPreflight } from './DocumentFileOperations';
import { documentPdfCountWorker } from './DocumentPdfWorker';

export function documentPdfPreflightReason(result: number[]): string {
  if (result.length!==6 || result.some((n: number): boolean=>!Number.isSafeInteger(n))) { return 'PDFKit预检回执不合法'; }
  const detail: string=` [stage=${result[3]},parse=${result[2]},sdk=${result[4]},release=${result[5]}]`;
  if (result[0]===2) { return '当前设备缺少PDFKit核心能力，未发送请求'+detail; }
  if (result[0]===3) { return 'PDF加密，禁止外发'+detail; }
  if (result[0]===4) { return 'PDFKit文档加载失败'+detail; }
  if (result[0]===5) { return 'PDF原页不在1–50页范围'+detail; }
  if (result[0]===6) { return 'PDF本机预检已取消'+detail; }
  if (result[0]===7) { return 'PDF本机预检超时'+detail; }
  if (result[0]===8) { return 'PDFKit预检操作异常'+detail; }
  if (result[0]===9) { return 'PDFKit资源释放未确认'+detail; }
  return 'PDFKit预检回执不合法'+detail;
}
export class DocumentPdfPreflight implements DocumentPreflightPort {
  private root: string;
  private task: taskpool.GenericsTask<[string,number], number[]> | undefined = undefined;
  cancelLocal(): void { if (this.task !== undefined) { try { taskpool.cancel(this.task); } catch {} } }
  constructor(filesDir: string) { this.root = `${filesDir}/knowledge_parse_v1`; }
  async inspect(original: DocumentOriginal, cancel: DocumentParseCancellation): Promise<DocumentOriginal> {
    if (original.format !== DocumentParseFormat.Pdf) { return original; }
    cancel.check();
    if (this.task !== undefined) { throw new DocumentParseFailure('已有PDF预检任务', '预检'); }
    const path: string=documentAssetPath(this.root, original.assetId);
    await documentContainerPreflight(path,original); cancel.check();
    if (this.task!==undefined) { throw new DocumentParseFailure('已有PDF预检任务','预检'); }
    const deadline: number=Math.min(cancel.deadline,Date.now()+DocumentParseBudget.localMs);
    const task: taskpool.GenericsTask<[string,number], number[]>=new taskpool.GenericsTask<[string,number], number[]>(documentPdfCountWorker,path,deadline);
    this.task=task;
    const timer: number = setTimeout((): void => { try { taskpool.cancel(task); } catch {} }, Math.max(1,deadline-Date.now()));
    let result: number[]=[];
    try { result = await taskpool.execute<[string,number], number[]>(task); }
    catch (error) { const system: BusinessError=error; throw new DocumentParseFailure('PDF预检工作线程执行失败','预检',Number.isSafeInteger(system?.code)?String(system.code):'NotReported'); }
    finally { clearTimeout(timer); if (this.task===task) { this.task = undefined; } }
    cancel.check();
    if (result.length===6 && result.every((n: number): boolean=>Number.isSafeInteger(n)) && result[0]===1 && result[1]>=1 && result[1]<=50 && result[2]===0 && result[5]===0) { original.pages = result[1]; original.preflight = DocumentPreflightStatus.Passed; original.preflightReason=''; }
    else {
      original.preflight = DocumentPreflightStatus.Blocked;
      original.pages=0; original.preflightReason=documentPdfPreflightReason(result);
    }
    return original;
  }
}
