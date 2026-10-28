import { webview } from '@kit.ArkWeb';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DocumentOriginal, DocumentParseCancellation, DocumentParseFailure } from '../domain/DocumentParseModels';
import { ParsedCancellation } from '../domain/ParsedDocumentModels';
import { parsedJson, parsedUtf8 } from '../pipeline/ParsedDocumentCodec';
import { PdfJsonNode } from '../pipeline/BoundedDocumentJson';
import { documentReadRange, documentDigestHex } from './DocumentFileOperations';

export class PdfJsReceipt {
  id: string=''; state: string=''; pages: number=0; bytes: number=0; received: number=0; rendered: number=0; page: number=0; error: string=''; version: string='';
}
export function pdfJsReceipt(raw: string, id: string): PdfJsReceipt {
  const cancel: ParsedCancellation=new ParsedCancellation();
  let n: PdfJsonNode=parsedJson(parsedUtf8(raw),cancel,16384);
  if (n.kind==='string') { n=parsedJson(parsedUtf8(n.string()),cancel,16384); }
  const r: PdfJsReceipt=new PdfJsReceipt(); r.id=n.required('id').string(); r.state=n.required('state').string(); r.pages=n.required('pages').integer(); r.bytes=n.required('bytes').integer(); r.received=n.required('received').integer(); r.rendered=n.required('rendered').integer(); r.page=n.required('page').integer(); r.error=n.required('error').string(); r.version=n.required('version').string();
  if (r.id!==id || ['Receiving','Loading','Loaded','Failed'].indexOf(r.state)<0 || r.bytes<0 || r.bytes>20971520 || r.received<0 || r.received>r.bytes || r.pages<0 || r.pages>1000000 || r.page<0 || r.page>r.pages || r.rendered<0 || (r.state==='Loaded' && (r.pages<1 || r.error.length>0)) || ['','EncryptedPdf','InvalidPdf','PdfLoadFailed','PdfPageBudget','PdfJobMissing'].indexOf(r.error)<0 || r.version!=='6.4.299') { throw new DocumentParseFailure('PDF.js回执身份或字段不符','PDF.js'); }
  return r;
}
export class PdfJsRuntime {
  static readonly shared: PdfJsRuntime=new PdfJsRuntime();
  private controller: webview.WebviewController | undefined;
  private listeners: Array<() => void>=[];
  private sequence: number=0; private generation: number=0; private tail: Promise<void>=Promise.resolve();
  private releasePreview: (() => void) | undefined;
  private previewCancel: DocumentParseCancellation | undefined;
  private operations: number=0;
  expanded: boolean=false;
  loading: boolean=false;
  bind(controller: webview.WebviewController): void { this.closePreview(); this.controller=controller; this.generation++; }
  reset(): void { const cancel=this.previewCancel; this.closePreview(); if (cancel!==undefined) { cancel.reason='ENGINE_RESET'; } this.generation++; }
  detach(): void { this.closePreview(); this.controller=undefined; this.generation++; }
  subscribe(listener: () => void): void { this.listeners.push(listener); }
  unsubscribe(listener: () => void): void { this.listeners=this.listeners.filter((l: () => void): boolean=>l!==listener); }
  private emit(): void { for (const l of this.listeners) { l(); } }
  private async script(code: string): Promise<string> { const controller=this.controller; if (controller===undefined) { throw new DocumentParseFailure('PDF网页引擎尚未就绪','PDF.js'); } return controller.runJavaScript(code); }
  private async ready(cancel: DocumentParseCancellation): Promise<void> {
    const end: number=Math.min(cancel.deadline,Date.now()+25000);
    while (Date.now()<end) { cancel.check(); try { if ((await this.script('Boolean(window.shuviPdf && window.shuviPdf.ready)'))==='true') { return; } } catch {} await new Promise<void>((resolve: () => void): void=> { setTimeout(resolve,100); }); }
    throw new DocumentParseFailure('PDF.js网页引擎初始化超时','PDF.js');
  }
  private serialize<T>(action: () => Promise<T>): Promise<T> { const pending: Promise<T>=this.tail.then(action); this.tail=pending.then((): void=>{},(): void=>{}); return pending; }
  private async release(id: string, generation: number): Promise<void> {
    if (generation!==this.generation) { return; }
    await this.script(`window.shuviPdf.release(${JSON.stringify(id)})`);
    const end: number=Date.now()+5000;
    while (generation===this.generation && Date.now()<end) {
      // ArkWeb JSON-encodes string results. Compare the enum inside Web and
      // return only a numeric acknowledgement across the bridge.
      const state: string=await this.script(`(()=>{const state=window.shuviPdf.releaseStatus(${JSON.stringify(id)});return state==='Released'?1:state==='Releasing'?0:state==='Failed'?-1:-2;})()`);
      if (state==='1') { return; } if (state!=='0') { break; }
      await new Promise<void>((resolve: () => void): void=> { setTimeout(resolve,20); });
    }
    if (generation===this.generation) { throw new DocumentParseFailure('PDF预览资源释放未确认，请重新打开页面','PDF.js'); }
  }
  private async load(path: string, original: DocumentOriginal, cancel: DocumentParseCancellation): Promise<PdfJsReceipt> {
    cancel.check(); const generation: number=this.generation; await this.ready(cancel); cancel.check(); if (generation!==this.generation) { throw new DocumentParseFailure('PDF网页会话已变化','PDF.js'); }
    const id: string='webpdf-'+Date.now().toString(36)+'-'+String(++this.sequence);
    const file: fileIo.File=await fileIo.open(path,fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);
    try {
      const stat: fileIo.Stat=await fileIo.stat(file.fd);
      if (!stat.isFile() || stat.size!==original.bytes || stat.size<8 || stat.size>20971520) { throw new DocumentParseFailure('PDF原件大小或身份不符','PDF.js'); }
      cancel.check(); if (generation!==this.generation) { throw new DocumentParseFailure('PDF网页会话已变化','PDF.js'); }
      const md: cryptoFramework.Md=cryptoFramework.createMd('SHA256'); const base64: util.Base64Helper=new util.Base64Helper();
      await this.script(`window.shuviPdf.begin(${JSON.stringify(id)},${stat.size})`);
      for (let offset: number=0;offset<stat.size;offset+=49152) {
        cancel.check(); if (generation!==this.generation) { throw new DocumentParseFailure('PDF网页会话已变化','PDF.js'); }
        const bytes: Uint8Array=await documentReadRange(file.fd,offset,Math.min(49152,stat.size-offset)); await md.update({data:bytes});
        const encoded: string=await base64.encodeToString(bytes); cancel.check(); if (generation!==this.generation) { throw new DocumentParseFailure('PDF网页会话已变化','PDF.js'); } await this.script(`window.shuviPdf.append(${JSON.stringify(id)},${JSON.stringify(encoded)})`);
      }
      if (documentDigestHex((await md.digest()).data)!==original.hash) { throw new DocumentParseFailure('PDF原件摘要已变化','PDF.js'); }
      cancel.check(); if (generation!==this.generation) { throw new DocumentParseFailure('PDF网页会话已变化','PDF.js'); }
      await this.script(`window.shuviPdf.open(${JSON.stringify(id)})`);
      while (true) {
        cancel.check(); if (generation!==this.generation) { throw new DocumentParseFailure('PDF网页会话已变化','PDF.js'); }
        const receipt: PdfJsReceipt=pdfJsReceipt(await this.script(`JSON.stringify(window.shuviPdf.result(${JSON.stringify(id)}))`),id);
        cancel.check(); if (generation!==this.generation) { throw new DocumentParseFailure('PDF网页会话已变化','PDF.js'); }
        if (receipt.state==='Failed') { throw new DocumentParseFailure(receipt.error,'PDF.js'); }
        if (receipt.state==='Loaded') { if (receipt.pages<1 || receipt.received!==original.bytes || receipt.bytes!==original.bytes) { throw new DocumentParseFailure('PDF.js输入或页数回执不完整','PDF.js'); } return receipt; }
        await new Promise<void>((resolve: () => void): void=> { setTimeout(resolve,80); });
      }
    } catch (error) { await this.release(id,generation); if (error instanceof DocumentParseFailure) { throw error; } throw new DocumentParseFailure('PDF.js本机读取或解析未完成','PDF.js'); }
    finally { await fileIo.close(file); }
  }
  // Reserve the visible/cancellable session before acquiring any source lock.
  async open(action: (cancel: DocumentParseCancellation) => Promise<void>): Promise<void> {
    this.closePreview(); const cancel: DocumentParseCancellation=new DocumentParseCancellation(); this.previewCancel=cancel;
    this.operations++;
    this.expanded=true; this.loading=true; this.emit();
    try { await action(cancel); if (cancel.reason==='ENGINE_RESET') { throw new DocumentParseFailure('PDF网页引擎已重建，请重新打开原件','PDF.js'); } }
    catch (error) { if (!(cancel.invalid && cancel.reason!=='ENGINE_RESET' && error instanceof DocumentParseFailure && error.category==='已暂停或世代失效')) { if (error instanceof Error) { throw error; } throw new DocumentParseFailure('PDF原件预览未完成','PDF.js'); } }
    finally { this.operations--; if (this.previewCancel===cancel) { this.previewCancel=undefined; this.releasePreview=undefined; this.expanded=false; this.loading=false; this.emit(); } }
  }
  async closeAndWait(): Promise<void> {
    this.closePreview(); const deadline: number=Date.now()+120000;
    while (this.operations>0) { if (Date.now()>=deadline) { throw new DocumentParseFailure('PDF预览会话释放未确认','PDF.js'); } await new Promise<void>((resolve: () => void): void=> { setTimeout(resolve,20); }); }
  }
  async preview(path: string, original: DocumentOriginal, cancel: DocumentParseCancellation, page: number=1, expectedPages: number=0): Promise<void> {
    await this.serialize<void>(async (): Promise<void>=> {
      cancel.check(); if (this.previewCancel!==cancel) { throw new DocumentParseFailure('PDF预览会话已失效','PDF.js'); }
      const receipt=await this.load(path,original,cancel); const generation: number=this.generation;
      try {
        cancel.check(); if (!Number.isSafeInteger(page) || page<1 || page>receipt.pages || expectedPages>0 && receipt.pages!==expectedPages) { throw new DocumentParseFailure('原件页码依据已变化','PDF.js'); }
        const closed: Promise<void>=new Promise<void>((resolve: () => void): void=> { this.releasePreview=resolve; });
        await this.script(`window.shuviPdf.show(${JSON.stringify(receipt.id)},${JSON.stringify(original.title)},${page})`);
        const end: number=Date.now()+25000; let rendered: boolean=false;
        while (Date.now()<end) { cancel.check(); if (generation!==this.generation) { throw new DocumentParseFailure('PDF网页会话已变化','PDF.js'); } const status=pdfJsReceipt(await this.script(`JSON.stringify(window.shuviPdf.result(${JSON.stringify(receipt.id)}))`),receipt.id); cancel.check(); if (generation!==this.generation) { throw new DocumentParseFailure('PDF网页会话已变化','PDF.js'); } if (status.state==='Failed') { throw new DocumentParseFailure(status.error,'PDF.js'); } if (status.rendered>0 && status.page===page) { rendered=true; hilog.info(0x0001,'SHUVI_PDFJS','%{public}s',`PDFJS_RENDER pages=${status.pages} page=${status.page} rendered=${status.rendered} bytes=${status.bytes}`); break; } await new Promise<void>((resolve: () => void): void=> { setTimeout(resolve,80); }); }
        if (!rendered) { throw new DocumentParseFailure('PDF原页渲染未完成','PDF.js'); }
        this.loading=false; this.emit();
        await closed;
      }
      finally { if (this.previewCancel===cancel) { this.releasePreview=undefined; } await this.release(receipt.id,generation); }
    });
  }
  closePreview(): void { if (this.previewCancel!==undefined) { this.previewCancel.invalid=true; } const release=this.releasePreview; this.releasePreview=undefined; this.expanded=false; this.loading=false; this.emit(); if (release!==undefined) { release(); } }
}
