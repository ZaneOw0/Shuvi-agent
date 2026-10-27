const jobs = new Map();
let active = '', renderTask, renderSequence = 0, pdfjs;
const status = document.getElementById('status');
const limits = { bytes:20*1024*1024, pages:50, canvasPixels:8*1024*1024 };
const fail = (job, error) => { job.state='Failed'; job.error=error; job.data=undefined; if(job.id===active)status.textContent=error; };
const validId = id => typeof id==='string' && /^webpdf-[a-z0-9-]{1,80}$/.test(id);
window.shuviPdf = {
  ready:false, version:'', bootError:'',
  begin(id, bytes) {
    if(!validId(id)||!Number.isSafeInteger(bytes)||bytes<8||bytes>limits.bytes)throw Error('PdfInputBudget');
    for(const old of jobs.values()){ old.task?.destroy();old.doc?.destroy(); }
    jobs.clear();active='';renderSequence++;renderTask?.cancel();
    jobs.set(id,{id,state:'Receiving',bytes,received:0,pages:0,rendered:0,page:0,error:'',data:new Uint8Array(bytes)});return true;
  },
  append(id, encoded) {
    const job=jobs.get(id);if(!job||job.state!=='Receiving'||typeof encoded!=='string'||encoded.length>100000)throw Error('PdfTransferState');
    const raw=atob(encoded);if(job.received+raw.length>job.bytes)throw Error('PdfTransferBudget');
    for(let i=0;i<raw.length;i++)job.data[job.received+i]=raw.charCodeAt(i);job.received+=raw.length;return true;
  },
  open(id) {
    const job=jobs.get(id);if(!job||job.received!==job.bytes||job.state!=='Receiving')throw Error('PdfTransferIncomplete');job.state='Loading';
    (async()=>{
      try {
        const task=pdfjs.getDocument({data:job.data,stopAtErrors:true,isEvalSupported:false,enableXfa:false,useSystemFonts:false,useWorkerFetch:false,cMapUrl:new URL('vendor/cmaps/',location.href).href,cMapPacked:true,standardFontDataUrl:new URL('vendor/standard_fonts/',location.href).href,wasmUrl:new URL('vendor/wasm/',location.href).href,iccUrl:new URL('vendor/iccs/',location.href).href});job.task=task;
        task.onPassword=()=>{fail(job,'EncryptedPdf');task.destroy();};
        const doc=await task.promise;if(job.state==='Failed'||!jobs.has(id)){await doc.destroy();return;}
        const permissions=await doc.getPermissions();const metadata=await doc.getMetadata();
        // Empty-password encryption can open without onPassword. Retain the
        // original policy of rejecting encrypted input, including that case.
        if(permissions!==null||metadata?.info?.EncryptFilterName!==null){fail(job,'EncryptedPdf');await doc.destroy();return;}
        job.data=undefined;job.doc=doc;job.pages=doc.numPages;
        if(!Number.isSafeInteger(job.pages)||job.pages<1||job.pages>limits.pages){fail(job,'PdfPageBudget');await doc.destroy();return;}
        job.state='Loaded';
      }catch(error){if(job.state!=='Failed')fail(job,error?.name==='PasswordException'?'EncryptedPdf':error?.name==='InvalidPDFException'?'InvalidPdf':'PdfLoadFailed');}
    })();return true;
  },
  result(id) {const j=jobs.get(id);return j?{id:j.id,state:j.state,pages:j.pages,bytes:j.bytes,received:j.received,rendered:j.rendered,page:j.page,error:j.error,version:this.version}:{id,state:'Failed',pages:0,bytes:0,received:0,rendered:0,page:0,error:'PdfJobMissing',version:this.version};},
  show(id,title,page=1) {const job=jobs.get(id);if(!job||job.state!=='Loaded')throw Error('PdfNotLoaded');active=id;document.getElementById('title').textContent=String(title).slice(0,200);render(page);return true;},
  release(id) {const job=jobs.get(id);if(id===active){active='';renderSequence++;renderTask?.cancel();document.getElementById('canvas').getContext('2d').clearRect(0,0,1e5,1e5);}job?.task?.destroy();jobs.delete(id);return true;}
};
async function render(page) {
  const job=jobs.get(active);if(!job||job.state!=='Loaded'||page<1||page>job.pages)return;
  const sequence=++renderSequence;renderTask?.cancel();status.textContent='正在渲染原件第 '+page+' 页…';
  try{
    const pdfPage=await job.doc.getPage(page);if(sequence!==renderSequence)return;
    const base=pdfPage.getViewport({scale:1});const width=Math.max(300,Math.min(1400,document.documentElement.clientWidth-20));
    const scale=Math.min(width/base.width,Math.sqrt(limits.canvasPixels/(base.width*base.height)));
    const viewport=pdfPage.getViewport({scale});const canvas=document.getElementById('canvas');canvas.width=Math.ceil(viewport.width);canvas.height=Math.ceil(viewport.height);
    renderTask=pdfPage.render({canvas,canvasContext:canvas.getContext('2d'),viewport});await renderTask.promise;if(sequence!==renderSequence)return;
    job.page=page;job.rendered++;document.getElementById('page').textContent=page+' / '+job.pages;document.getElementById('previous').disabled=page<=1;document.getElementById('next').disabled=page>=job.pages;
    status.textContent='原件第 '+page+' 页 · PDF.js '+window.shuviPdf.version+' · 本机预览';
  }catch(error){if(error?.name!=='RenderingCancelledException')status.textContent='原页渲染失败，原件保留';}
}
document.getElementById('previous').onclick=()=>{const j=jobs.get(active);if(j)render(j.page-1);};
document.getElementById('next').onclick=()=>{const j=jobs.get(active);if(j)render(j.page+1);};
new ResizeObserver(()=>{const j=jobs.get(active);if(j&&document.documentElement.clientWidth>100)render(j.page||1);}).observe(document.documentElement);
try {
  pdfjs=await import('./vendor/pdf.mjs');
  // PDF.js's supported in-page worker handler executes the real parser in this
  // Web instance; no Worker URL, CDN, system PDF viewer, or native PDFKit is used.
  globalThis.pdfjsWorker=await import('./vendor/pdf.worker.mjs');
  pdfjs.GlobalWorkerOptions.workerSrc=new URL('./vendor/pdf.worker.mjs',location.href).href;
  window.shuviPdf.version=pdfjs.version;window.shuviPdf.ready=true;status.textContent='本机 PDF 引擎已就绪';console.info('PDFJS_READY '+pdfjs.version);
}catch(error){window.shuviPdf.bootError='PdfJsBootFailed';status.textContent='本机 PDF 引擎加载失败';console.error('PDFJS_BOOT_FAILED');}
