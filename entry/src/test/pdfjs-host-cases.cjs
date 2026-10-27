'use strict';
const assert=require('node:assert/strict'),crypto=require('node:crypto'),vm=require('node:vm');
exports.cases=h=>{
 const D=h.load('domain/DocumentParseModels');const {PdfJsRuntime,pdfJsReceipt}=h.load('infra/PdfJsRuntime');
 const receipt=(extra={})=>JSON.stringify({id:'webpdf-unit',state:'Loaded',pages:1,bytes:20,received:20,rendered:0,page:0,error:'',version:'6.4.299',...extra});
 return [
  ['pdfjs_hidpi_render_and_existing_bridge_share_validated_document',async()=>{
   const cp=require('node:child_process'),path=require('node:path');const result=cp.spawnSync(process.execPath,['--experimental-vm-modules',path.join(__dirname,'pdfjs-render-host-cases.cjs')],{encoding:'utf8',timeout:10000});assert.equal(result.status,0,result.stderr);assert(result.stdout.includes('PDFJS_RENDER_HOST_SUMMARY passed=11 failed=0 requests=0'));console.log(result.stdout.trim());
  }],
  ['pdfjs_page_bridge_rejects_encrypted_bad_and_oversized_input',async()=>{
   const cp=require('node:child_process'),path=require('node:path');const result=cp.spawnSync(process.execPath,['--experimental-vm-modules',path.join(__dirname,'pdfjs-bridge-cases.cjs')],{encoding:'utf8',timeout:10000});assert.equal(result.status,0,result.stderr);assert(result.stdout.includes('cases=8 passed=8 requests=0'));
  }],
  ['pdfjs_receipt_rejects_identity_version_partial_count_and_invented_errors',async()=>{
   assert.equal(pdfJsReceipt(receipt(),'webpdf-unit').pages,1);assert.equal(pdfJsReceipt(JSON.stringify(receipt()),'webpdf-unit').pages,1);
   for(const extra of [{id:'foreign'},{version:'future'},{pages:0},{pages:51},{bytes:20971521},{received:21},{error:'arbitrary'},{state:'Unknown'}])assert.throws(()=>pdfJsReceipt(receipt(extra),'webpdf-unit'));
   assert.equal(pdfJsReceipt(receipt({state:'Failed',pages:51,error:'PdfPageBudget'}),'webpdf-unit').error,'PdfPageBudget');
  }],
  ['pdfjs_transfer_hash_identity_checked_before_open_and_release',async()=>{
   const bytes=Buffer.from('%PDF-1.4\nself-authored-data'),original=Object.assign(new D.DocumentOriginal(),{bytes:bytes.length,hash:crypto.createHash('sha256').update(bytes).digest('hex')});const file='/pdfjs/synthetic';h.memoryFiles.set(file,bytes);const jobs=new Map();let opens=0,releases=0;
   const bridge={ready:true,begin:(id,n)=>{jobs.set(id,{id,state:'Receiving',pages:1,bytes:n,received:0,rendered:0,page:0,error:'',version:'6.4.299'});},append:(id,b64)=>{jobs.get(id).received+=Buffer.from(b64,'base64').length;},open:id=>{opens++;jobs.get(id).state='Loaded';},result:id=>jobs.get(id),release:()=>{releases++;}};
   const runtime=new PdfJsRuntime();runtime.bind({runJavaScript:async code=>{const result=vm.runInNewContext(code,{window:{shuviPdf:bridge}});return typeof result==='string'?result:String(result);}});
   assert.equal((await runtime.inspect(file,original,new D.DocumentParseCancellation())).pages,1);assert.equal(opens,1);assert.equal(releases,1);
   original.hash='0'.repeat(64);await assert.rejects(runtime.inspect(file,original,new D.DocumentParseCancellation()),e=>e.category.includes('摘要'));assert.equal(opens,1);assert.equal(releases,2);runtime.detach();
  }],
  ['pdfjs_cancel_prevents_bytes_from_being_sent_to_web',async()=>{
   const runtime=new PdfJsRuntime();let calls=0;runtime.bind({runJavaScript:async()=>{calls++;return 'true';}});const cancel=new D.DocumentParseCancellation();cancel.invalid=true;await assert.rejects(runtime.inspect('/not-read',new D.DocumentOriginal(),cancel));assert.equal(calls,0);runtime.detach();
  }]
 ];
};
