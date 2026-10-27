import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PdfJsRuntime } from '../infra/PdfJsRuntime';
import { Theme } from '../../components/Theme';

const PDF_JS_ORIGIN: string='https://shuvi-pdf.invalid/';

@Component
export struct PdfJsSurface {
  private controller: webview.WebviewController=new webview.WebviewController();
  @State expanded: boolean=false;
  private changed: () => void=(): void=> { this.expanded=PdfJsRuntime.shared.expanded; };
  aboutToAppear(): void { PdfJsRuntime.shared.bind(this.controller); PdfJsRuntime.shared.subscribe(this.changed); }
  aboutToDisappear(): void { PdfJsRuntime.shared.unsubscribe(this.changed); PdfJsRuntime.shared.detach(); }
  private resource(url: string): WebResourceResponse {
    const response: WebResourceResponse=new WebResourceResponse(); response.setResponseEncoding('utf-8');
    try {
      if (!url.startsWith(PDF_JS_ORIGIN)) { throw new Error('ForeignOrigin'); }
      const relative: string=decodeURIComponent(url.slice(PDF_JS_ORIGIN.length).split('?')[0]);
      if (!new RegExp('^[a-zA-Z0-9_./-]+$').test(relative) || relative.includes('..')) { throw new Error('InvalidPath'); }
      const context=this.getUIContext().getHostContext(); if (context===undefined) { throw new Error('NoContext'); }
      const bytes: Uint8Array=context.resourceManager.getRawFileContentSync('pdfjs/'+relative);
      const body: ArrayBuffer=new ArrayBuffer(bytes.length); new Uint8Array(body).set(bytes);
      response.setResponseData(body); response.setResponseCode(200); response.setReasonMessage('OK');
      response.setResponseMimeType(relative.endsWith('.html')?'text/html':relative.endsWith('.mjs')?'text/javascript':relative.endsWith('.wasm')?'application/wasm':'application/octet-stream');
      const headers: Header[]=[{headerKey:'Cache-Control',headerValue:'no-store'},{headerKey:'X-Content-Type-Options',headerValue:'nosniff'}];response.setResponseHeader(headers);
    } catch { response.setResponseCode(403); response.setReasonMessage('Blocked'); response.setResponseMimeType('text/plain'); response.setResponseData('Local PDF resource unavailable'); }
    response.setResponseIsReady(true); return response;
  }
  build() {
    Stack({alignContent:Alignment.TopEnd}) {
      Web({src:PDF_JS_ORIGIN+'index.html',controller:this.controller})
        .javaScriptAccess(true).fileAccess(false).domStorageAccess(false)
        .onInterceptRequest((event: OnInterceptRequestEvent): WebResourceResponse=>this.resource(event.request.getRequestUrl()))
        .onConsole((event: OnConsoleEvent): boolean=> { const message: string=event.message.getMessage(); if (message.startsWith('PDFJS_')) { hilog.info(0x0001,'SHUVI_PDFJS','%{public}s',message.slice(0,160)); } return true; })
        .width('100%').height('100%')
      if (this.expanded) { Button('关闭原件').id('pdfjs-close-preview').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({minHeight:44}).margin({top:8,right:8}).onClick((): void=> { PdfJsRuntime.shared.closePreview(); }) }
    }.id('pdfjs-surface').width('100%').height(this.expanded?'100%':1).opacity(this.expanded?1:0).zIndex(this.expanded?1000:0)
  }
}
