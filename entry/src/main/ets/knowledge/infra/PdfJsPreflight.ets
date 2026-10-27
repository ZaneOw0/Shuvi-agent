import { DocumentPreflightPort } from '../domain/DocumentParsePorts';
import { DocumentOriginal, DocumentParseCancellation, DocumentParseFormat, DocumentPreflightStatus, DocumentParseFailure } from '../domain/DocumentParseModels';
import { documentAssetPath, documentContainerPreflight } from './DocumentFileOperations';
import { PdfJsRuntime } from './PdfJsRuntime';

export class PdfJsPreflight implements DocumentPreflightPort {
  private root: string; private active: DocumentParseCancellation | undefined;
  constructor(filesDir: string) { this.root=filesDir+'/knowledge_parse_v1'; }
  cancelLocal(): void { if (this.active!==undefined) { this.active.invalid=true; } }
  async inspect(original: DocumentOriginal, cancel: DocumentParseCancellation): Promise<DocumentOriginal> {
    if (original.format!==DocumentParseFormat.Pdf) { return original; }
    if (this.active!==undefined) { throw new DocumentParseFailure('已有PDF.js预检任务','PDF.js'); }
    this.active=cancel;
    try { const path: string=documentAssetPath(this.root,original.assetId); await documentContainerPreflight(path,original); cancel.check(); const receipt=await PdfJsRuntime.shared.inspect(path,original,cancel); cancel.check(); original.pages=receipt.pages; original.preflight=DocumentPreflightStatus.Passed; original.preflightReason=''; return original; }
    catch (error) { original.pages=0; original.preflight=DocumentPreflightStatus.Blocked; original.preflightReason=error instanceof DocumentParseFailure?error.message:'PDF.js本机预检失败，原件保留'; if (error instanceof DocumentParseFailure) { throw error; } throw new DocumentParseFailure(original.preflightReason,'PDF.js'); }
    finally { this.active=undefined; }
  }
}
