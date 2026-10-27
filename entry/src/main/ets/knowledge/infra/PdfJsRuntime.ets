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
  if (r.id!==id || ['Receiving','Loading','Loaded','Failed'].indexOf(r.state)<0 || r.bytes>20971520 || r.received>r.bytes || r.pages>1000000 || (r.state==='Loaded' && (r.pages<1 || r.pages>50 || r.error.length>0)) || ['','EncryptedPdf','InvalidPdf','PdfLoadFailed','PdfPageBudget','PdfJobMissing'].indexOf(r.error)<0 || r.version!=='6.4.299') { throw new DocumentParseFailure('PDF.js回执身份或字段不符','PDF.js'); }
  return r;
}
export class PdfJsRuntime {
  static readonly shared: PdfJsRuntime=new PdfJsRuntime();
  private controller: webview.WebviewController | undefined;
  private listeners: Array<() => void>=[];
  private sequence: number=0; private generation: number=0; private tail: Promise<void>=Promise.resolve();
  private previewId: string=''; private releasePreview: (() => void) | undefined;
  expanded: boolean=false;
  bind(controller: webview.WebviewController): void { this.controller=controller; this.generation++; }
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
  private async load(path: string, original: DocumentOriginal, cancel: DocumentParseCancellation): Promise<PdfJsReceipt> {
    await this.ready(cancel); const generation: number=this.generation; const id: string='webpdf-'+Date.now().toString(36)+'-'+String(++this.sequence);
    const file: fileIo.File=await fileIo.open(path,fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);
    try {
      const stat: fileIo.Stat=await fileIo.stat(file.fd);
      if (!stat.isFile() || stat.size!==original.bytes || stat.size<8 || stat.size>20971520) { throw new DocumentParseFailure('PDF原件大小或身份不符','PDF.js'); }
      const md: cryptoFramework.Md=cryptoFramework.createMd('SHA256'); const base64: util.Base64Helper=new util.Base64Helper();
      await this.script(`window.shuviPdf.begin(${JSON.stringify(id)},${stat.size})`);
      for (let offset: number=0;offset<stat.size;offset+=49152) {
        cancel.check(); if (generation!==this.generation) { throw new DocumentParseFailure('PDF网页会话已变化','PDF.js'); }
        const bytes: Uint8Array=await documentReadRange(file.fd,offset,Math.min(49152,stat.size-offset)); await md.update({data:bytes});
        const encoded: string=await base64.encodeToString(bytes); await this.script(`window.shuviPdf.append(${JSON.stringify(id)},${JSON.stringify(encoded)})`);
      }
      if (documentDigestHex((await md.digest()).data)!==original.hash) { throw new DocumentParseFailure('PDF原件摘要已变化','PDF.js'); }
      await this.script(`window.shuviPdf.open(${JSON.stringify(id)})`);
      while (true) {
        cancel.check(); if (generation!==this.generation) { throw new DocumentParseFailure('PDF网页会话已变化','PDF.js'); }
        const receipt: PdfJsReceipt=pdfJsReceipt(await this.script(`JSON.stringify(window.shuviPdf.result(${JSON.stringify(id)}))`),id);
        if (receipt.state==='Failed') { throw new DocumentParseFailure(receipt.error,'PDF.js'); }
        if (receipt.state==='Loaded') { if (receipt.pages<1 || receipt.received!==original.bytes || receipt.bytes!==original.bytes) { throw new DocumentParseFailure('PDF.js输入或页数回执不完整','PDF.js'); } return receipt; }
        await new Promise<void>((resolve: () => void): void=> { setTimeout(resolve,80); });
      }
    } catch (error) { try { await this.script(`window.shuviPdf.release(${JSON.stringify(id)})`); } catch {} if (error instanceof DocumentParseFailure) { throw error; } throw new DocumentParseFailure('PDF.js本机读取或解析未完成','PDF.js'); }
    finally { await fileIo.close(file); }
  }
  async inspect(path: string, original: DocumentOriginal, cancel: DocumentParseCancellation): Promise<PdfJsReceipt> {
    return this.serialize<PdfJsReceipt>(async (): Promise<PdfJsReceipt>=> { const receipt=await this.load(path,original,cancel); try { return receipt; } finally { await this.script(`window.shuviPdf.release(${JSON.stringify(receipt.id)})`); } });
  }
  async preview(path: string, original: DocumentOriginal, cancel: DocumentParseCancellation): Promise<void> {
    await this.serialize<void>(async (): Promise<void>=> {
      const receipt=await this.load(path,original,cancel); this.previewId=receipt.id;
      const closed: Promise<void>=new Promise<void>((resolve: () => void): void=> { this.releasePreview=resolve; });
      this.expanded=true; this.emit();
      try {
        await this.script(`window.shuviPdf.show(${JSON.stringify(receipt.id)},${JSON.stringify(original.title)},1)`);
        const end: number=Date.now()+25000; let rendered: boolean=false;
        while (Date.now()<end && this.expanded) { const status=pdfJsReceipt(await this.script(`JSON.stringify(window.shuviPdf.result(${JSON.stringify(receipt.id)}))`),receipt.id); if (status.rendered>0 && status.page===1) { rendered=true; hilog.info(0x0001,'SHUVI_PDFJS','%{public}s',`PDFJS_RENDER pages=${status.pages} page=${status.page} rendered=${status.rendered} bytes=${status.bytes}`); break; } await new Promise<void>((resolve: () => void): void=> { setTimeout(resolve,80); }); }
        if (!rendered && this.expanded) { throw new DocumentParseFailure('PDF原页渲染未完成','PDF.js'); }
        await closed;
      }
      finally { this.expanded=false; this.previewId=''; this.releasePreview=undefined; this.emit(); try { await this.script(`window.shuviPdf.release(${JSON.stringify(receipt.id)})`); } catch {} }
    });
  }
  closePreview(): void { const release=this.releasePreview; this.releasePreview=undefined; this.expanded=false; this.emit(); if (release!==undefined) { release(); } }
}
