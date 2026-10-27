'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
async function createBridge(options={}) {
 const elements=new Map();const element=id=>{if(!elements.has(id))elements.set(id,{textContent:'',style:{},disabled:false,width:0,height:0,getContext:()=>({clearRect(){}})});return elements.get(id);};
 const renderCalls=[],densityQueries=[],windowEvents=new Map(),viewportEvents=new Map();let resizeObserver,documentLoads=0;
 const subscribe=(map,type,listener)=>{if(!map.has(type))map.set(type,new Set());map.get(type).add(listener);};
 const emit=(map,type)=>{for(const listener of [...(map.get(type)||[])])listener();};
 const doc={numPages:options.pages??1,getPermissions:async()=>options.permissions??null,getMetadata:async()=>({info:{EncryptFilterName:options.filter??null}}),destroy:async()=>{},getPage:async page=>{
  if(!options.rendering)throw Error('NotRenderingInHost');return {getViewport:({scale})=>({width:(options.pageWidth||600)*scale,height:(options.pageHeight||800)*scale}),render:params=>{renderCalls.push({page,params});return options.render?options.render(params,page):{promise:Promise.resolve(),cancel(){}};}};
 }};
 const sandbox={document:{getElementById:element,documentElement:{clientWidth:options.clientWidth||380}},location:{href:'https://shuvi-pdf.invalid/index.html'},devicePixelRatio:options.dpr??1,visualViewport:{scale:options.zoom??1,addEventListener:(type,listener)=>subscribe(viewportEvents,type,listener)},addEventListener:(type,listener)=>subscribe(windowEvents,type,listener),matchMedia:media=>{const listeners=new Set();const query={media,addEventListener:(_type,listener)=>listeners.add(listener),removeEventListener:(_type,listener)=>listeners.delete(listener),change:()=>{for(const listener of [...listeners])listener();}};densityQueries.push(query);return query;},URL,Uint8Array,Map,Number,Math,Promise,ResizeObserver:class{constructor(listener){resizeObserver=listener;}observe(){}},atob:s=>Buffer.from(s,'base64').toString('binary'),console:{info(){},error(){}},setTimeout,clearTimeout};
 const context=vm.createContext(sandbox);vm.runInContext('window=globalThis',context);
 const core=new vm.SyntheticModule(['version','GlobalWorkerOptions','getDocument'],function(){this.setExport('version','6.4.299');this.setExport('GlobalWorkerOptions',{});this.setExport('getDocument',config=>{documentLoads++;assert.equal(config.stopAtErrors,true);assert.equal(config.isEvalSupported,false);if(options.invalid)throw {name:'InvalidPDFException'};const task={promise:Promise.resolve(doc),destroy(){}};if(options.password)queueMicrotask(()=>task.onPassword?.(()=>{},1));return task;});},{context});await core.link(()=>{});await core.evaluate();
 const worker=new vm.SyntheticModule(['WorkerMessageHandler'],function(){this.setExport('WorkerMessageHandler',{});},{context});await worker.link(()=>{});await worker.evaluate();
 const source=fs.readFileSync(path.resolve(__dirname,'../main/resources/rawfile/pdfjs/bridge.mjs'),'utf8');
 const module=new vm.SourceTextModule(source,{context,importModuleDynamically:async specifier=>{if(specifier==='./vendor/pdf.mjs')return core;if(specifier==='./vendor/pdf.worker.mjs')return worker;throw Error('UnexpectedImport');}});await module.link(()=>{});await module.evaluate();
 return {api:sandbox.shuviPdf,layout:module.namespace.pdfCanvasLayout,canvas:element('canvas'),elements,renderCalls,sandbox,densityQueries,documentLoads:()=>documentLoads,resize:()=>emit(windowEvents,'resize'),zoom:()=>emit(viewportEvents,'resize'),resizeObserver:()=>resizeObserver()};
}
async function bridge(options){return (await createBridge(options)).api;}
async function loaded(options){const b=await bridge(options);b.begin('webpdf-test',8);b.append('webpdf-test',Buffer.from('%PDF-1.4').toString('base64'));b.open('webpdf-test');for(let i=0;i<30;i++){const result=b.result('webpdf-test');if(result.state!=='Loading')return result;await new Promise(r=>setTimeout(r,1));}throw Error('BridgeDidNotSettle');}
async function run(){
 assert.equal((await loaded({})).state,'Loaded');
 assert.equal((await loaded({permissions:[4,8],filter:'Standard'})).error,'EncryptedPdf','empty-password encrypted PDF must still be rejected');
 assert.equal((await loaded({password:true})).error,'EncryptedPdf');
 assert.equal((await loaded({pages:51})).error,'PdfPageBudget');
 assert.equal((await loaded({invalid:true})).error,'InvalidPdf');
 const b=await bridge();assert.throws(()=>b.begin('../foreign',8));assert.throws(()=>b.begin('webpdf-huge',20971521));b.begin('webpdf-short',9);b.append('webpdf-short',Buffer.from('%PDF-1.4').toString('base64'));assert.throws(()=>b.open('webpdf-short'));
 console.log('PDFJS_BRIDGE cases=8 passed=8 requests=0');
}
module.exports={createBridge};
if(require.main===module)run().catch(e=>{console.error(e.stack);process.exitCode=1;});
