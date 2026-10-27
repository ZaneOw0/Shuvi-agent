'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
async function bridge(options={}) {
 const elements=new Map();const element=id=>{if(!elements.has(id))elements.set(id,{textContent:'',disabled:false,width:0,height:0,getContext:()=>({clearRect(){}})});return elements.get(id);};
 const doc={numPages:options.pages||1,getPermissions:async()=>options.permissions??null,getMetadata:async()=>({info:{EncryptFilterName:options.filter??null}}),destroy:async()=>{},getPage:async()=>{throw Error('NotRenderingInHost');}};
 const sandbox={document:{getElementById:element,documentElement:{clientWidth:400}},location:{href:'https://shuvi-pdf.invalid/index.html'},URL,Uint8Array,Map,Number,Math,Promise,ResizeObserver:class{observe(){}},atob:s=>Buffer.from(s,'base64').toString('binary'),console:{info(){},error(){}},setTimeout};
 const context=vm.createContext(sandbox);vm.runInContext('window=globalThis',context);
 const core=new vm.SyntheticModule(['version','GlobalWorkerOptions','getDocument'],function(){this.setExport('version','6.4.299');this.setExport('GlobalWorkerOptions',{});this.setExport('getDocument',config=>{assert.equal(config.stopAtErrors,true);assert.equal(config.isEvalSupported,false);if(options.invalid)throw {name:'InvalidPDFException'};const task={promise:Promise.resolve(doc),destroy(){}};if(options.password)queueMicrotask(()=>task.onPassword?.(()=>{},1));return task;});},{context});await core.link(()=>{});await core.evaluate();
 const worker=new vm.SyntheticModule(['WorkerMessageHandler'],function(){this.setExport('WorkerMessageHandler',{});},{context});await worker.link(()=>{});await worker.evaluate();
 const source=fs.readFileSync(path.resolve(__dirname,'../main/resources/rawfile/pdfjs/bridge.mjs'),'utf8');
 const module=new vm.SourceTextModule(source,{context,importModuleDynamically:async specifier=>{if(specifier==='./vendor/pdf.mjs')return core;if(specifier==='./vendor/pdf.worker.mjs')return worker;throw Error('UnexpectedImport');}});await module.link(()=>{});await module.evaluate();return sandbox.shuviPdf;
}
async function loaded(options){const b=await bridge(options);b.begin('webpdf-test',8);b.append('webpdf-test',Buffer.from('%PDF-1.4').toString('base64'));b.open('webpdf-test');for(let i=0;i<30;i++){const result=b.result('webpdf-test');if(result.state!=='Loading')return result;await new Promise(r=>setTimeout(r,1));}throw Error('BridgeDidNotSettle');}
(async()=>{
 assert.equal((await loaded({})).state,'Loaded');
 assert.equal((await loaded({permissions:[4,8],filter:'Standard'})).error,'EncryptedPdf','empty-password encrypted PDF must still be rejected');
 assert.equal((await loaded({password:true})).error,'EncryptedPdf');
 assert.equal((await loaded({pages:51})).error,'PdfPageBudget');
 assert.equal((await loaded({invalid:true})).error,'InvalidPdf');
 const b=await bridge();assert.throws(()=>b.begin('../foreign',8));assert.throws(()=>b.begin('webpdf-huge',20971521));b.begin('webpdf-short',9);b.append('webpdf-short',Buffer.from('%PDF-1.4').toString('base64'));assert.throws(()=>b.open('webpdf-short'));
 console.log('PDFJS_BRIDGE cases=8 passed=8 requests=0');
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
