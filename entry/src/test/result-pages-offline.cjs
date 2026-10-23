'use strict';
// Only the two explicitly authorized inputs. No device, network, directory scan or source mutation.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const assert = require('node:assert/strict');
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
async function readAuthorized(project) {
  const root = path.join(project,'.cache/host-tests/entry/src/main/ets/knowledge');
  const domain = require(path.join(root,'domain/PdfKnowledgeModels.js'));
  const policy = require(path.join(root,'pipeline/SafeZipPolicy.js'));
  const { MineruPdfNormalizer } = require(path.join(root,'pipeline/MineruPdfNormalizer.js'));
  const originalPath = path.join(project,'.cache/m2-input/user-pdf/02_第02章_模型评估与选择.pdf');
  const zipPath = path.join(project,'.cache/m2-result-analysis/result-m2-7eaa150e269374313fd776f12a2ae9fa.zip');
  for (const file of [originalPath,zipPath]) { const stat=fs.lstatSync(file); assert(stat.isFile()&&!stat.isSymbolicLink()&&stat.size<=31457280); }
  assert.equal(digest(fs.readFileSync(originalPath)),'7f959de85fdab10b15e2aada044d9f1fbd75dbc90b2fabfca79eb9ecb4b3df3a');
  const zip=fs.readFileSync(zipPath); assert.equal(digest(zip),'548162c5bb0f6a93d0fe76d4a5a17399f87b0a882c84d4510e7c2ead5fc12a05');
  const cancel=new domain.KnowledgeCancellation();
  const manifest=await policy.pdfInspectZip({length:zip.length,async read(at,n){assert(n<=1048576);return new Uint8Array(zip.subarray(at,at+n));},async close(){}},cancel);
  const outputs=new Map(); let expanded=0;
  for(const member of manifest.members){
    const response=zlib.inflateRawSync(zip.subarray(member.payloadOffset,member.payloadOffset+member.compressedBytes),{maxOutputLength:Math.min(33554432,member.declaredBytes),info:true});
    const bytes=response.buffer; assert.equal(response.engine.bytesWritten,member.compressedBytes); assert.equal(bytes.length,member.declaredBytes);
    let crc=0xffffffff;for(const byte of bytes){crc^=byte;for(let bit=0;bit<8;bit++)crc=(crc&1)?0xedb88320^(crc>>>1):crc>>>1;}assert.equal((crc^0xffffffff)>>>0,member.crc32);
    expanded=policy.pdfZipReserve(expanded,bytes.length,104857600);member.actualBytes=bytes.length;member.actualCrc32=member.crc32;member.sha256=digest(bytes);member.verified=true;outputs.set(member.id,new Uint8Array(bytes));
  }
  manifest.hardPassed=true;manifest.zipHash=digest(zip);manifest.expandedBytes=expanded;
  const binding=new domain.PdfSourceBinding();binding.originalHash=digest(fs.readFileSync(originalPath));binding.zipHash=manifest.zipHash;binding.originalVersion=1;binding.originalPages=30;
  const doc=await new MineruPdfNormalizer().normalize(binding,manifest,{async readMember(_m,member){return outputs.get(member.id);}},cancel);
  const layoutMember=manifest.members.find(m=>m.logicalName.endsWith('layout.json'));assert(layoutMember);
  const layout=JSON.parse(Buffer.from(outputs.get(layoutMember.id)).toString('utf8'));
  return {doc,layout,domain,digest};
}
module.exports={readAuthorized,digest};
if(require.main===module){readAuthorized(path.resolve(__dirname,'../../..')).then(({doc,layout})=>{
  if(process.argv[2]==='manifest'){
    const cross=[['node-6','运行完成',1,2],['node-97','必然都被选上了',8,9],['node-178','较大,',15,16],['node-202','[t_{-\\alpha / 2}',17,18],['node-278','真实结果的偏离程度',23,24]];
    const rows=[];
    for(let p=0;p<29;p++){
      const nodes=doc.nodes.filter(n=>n.pageIndex0===p&&n.verified&&n.text.length>0&&!['header','page_number'].includes(n.kind)&&!cross.some(c=>c[0]===n.id));
      const anchor=nodes.find(n=>['title','caption','formula'].includes(n.kind))||nodes[0];
      const structure=nodes.find(n=>n!==anchor&&['caption','formula','table','title'].includes(n.kind))||nodes[nodes.length-1];
      rows.push({providerPage0:p,originalPage1:p+1,nodeIds:nodes.map(n=>n.id),nodeSetHash:digest(JSON.stringify(nodes.map(n=>[n.id,n.pageIndex0,n.text]))),uniqueAnchorHash:digest(anchor.text),structureAnchorHash:digest(structure.text)});
    }
    const crossRows=cross.map(([id,marker,first,second])=>{const n=doc.nodes.find(n=>n.id===id);const at=n.text.indexOf(marker);assert(at>0);return {nodeId:id,providerPage0:n.pageIndex0,nodeHash:digest(n.text),fragments:[{start:0,end:at,originalPage1:first,textHash:digest(n.text.slice(0,at))},{start:at,end:n.text.length,originalPage1:second,textHash:digest(n.text.slice(at))}]};});
    console.log(JSON.stringify({wire:'PAGE-IDENTITY-REVIEW-1',documentId:'kb-60986788281e094aff01063dfcf764f1',generation:'kb-e144c7dff2b309d638cfa10b14604e3b',snapshotId:'kb-68c7504281b1a324817d2390b5c021e6',snapshotHash:'7cc6022572ca890114c4e90e3096ddc5318eaceee755ba44ebcb5e83b847e281',originalHash:doc.binding.originalHash,originalVersion:1,originalPages:30,zipHash:doc.binding.zipHash,protocol:doc.profile,reviewVersion:'ORIGINAL-VISUAL-20261017-1',pages:rows,cross:crossRows},null,2));return;
  }
  if(process.argv[2]==='review'){
    for(let p=0;p<30;p++){
      console.log('PROVIDER_PAGE '+p);
      for(const n of doc.nodes.filter(n=>n.pageIndex0===p)){console.log(n.id+' '+n.kind+' len='+n.text.length+' '+n.text.replace(/\s+/g,' ').slice(0,95)+' [end] '+n.text.replace(/\s+/g,' ').slice(-55));}
    }
    function visit(node,at){if(!node||typeof node!=='object')return;if(node.cross_page===true||node.lines_deleted===true)console.log('RISK '+at+' '+JSON.stringify(node).slice(0,1700));for(const [key,value]of Object.entries(node)){if(typeof value==='object')visit(value,at+'.'+key);}}
    for(const page of layout.pdf_info)visit(page,'page'+page.page_idx);
  }else console.log('authorized_original_zip_read nodes='+doc.nodes.length+' primary='+doc.nodes.filter(n=>!n.parentId).length);
}).catch(()=>{console.error('authorized_offline_read_failed');process.exitCode=1;});}
