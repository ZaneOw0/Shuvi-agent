'use strict';
// Reads exactly the approved ignored ZIP. No body/member names in output or Git fixtures.
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const zlib=require('node:zlib');
const assert=require('node:assert/strict');
module.exports=(outputRoot,project)=>{
  const root=path.join(outputRoot,'entry/src/main/ets/knowledge');
  const d=require(path.join(root,'domain/PdfKnowledgeModels.js'));
  const zipPolicy=require(path.join(root,'pipeline/SafeZipPolicy.js'));
  const worker=require(path.join(root,'pipeline/PdfWorkerPolicy.js'));
  const {MineruPdfNormalizer}=require(path.join(root,'pipeline/MineruPdfNormalizer.js'));
  const digest=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
  return [{name:'approved new ZIP strict CRC false profile codec and 33 footer exclusions',run:async()=>{
    const filename=path.join(project,'.cache/new-pdf-ingestion-diagnosis/result-m2-6fe6c44120d215e2ec1a852235fb97a0.zip');
    const stat=fs.lstatSync(filename);assert(stat.isFile()&&!stat.isSymbolicLink());assert.equal(stat.size,6452636);
    const zip=fs.readFileSync(filename);assert.equal(digest(zip),'ba0e9e429650a88730924f5827adeb13cd836d0427a21f7475b7fe810d716ebb');
    const cancel=new d.KnowledgeCancellation();
    const manifest=await zipPolicy.pdfInspectZip({length:zip.length,async read(at,n,c){c.check();assert(Number.isSafeInteger(at)&&at>=0&&n>=0&&n<=1048576&&at+n<=zip.length);return new Uint8Array(zip.subarray(at,at+n));}},cancel);
    const outputs=new Map();let expanded=0;
    for(const member of manifest.members){
      cancel.check();assert.equal(member.method,8);
      const cap=Math.min(d.PdfBudget.memberBytes,d.PdfBudget.expandedBytes-expanded,member.logicalName.endsWith('.json')?d.PdfBudget.jsonBytes:d.PdfBudget.memberBytes);
      const response=zlib.inflateRawSync(zip.subarray(member.payloadOffset,member.payloadOffset+member.compressedBytes),{maxOutputLength:Math.max(1,cap),info:true});
      const bytes=response.buffer;assert.equal(response.engine.bytesWritten,member.compressedBytes);assert.equal(bytes.length,member.declaredBytes);assert(bytes.length<=cap);
      let crc=0xffffffff;for(const byte of bytes){crc^=byte;for(let bit=0;bit<8;bit++)crc=(crc&1)?0xedb88320^(crc>>>1):crc>>>1;}assert.equal((crc^0xffffffff)>>>0,member.crc32);
      expanded=zipPolicy.pdfZipReserve(expanded,bytes.length,d.PdfBudget.expandedBytes);member.actualBytes=bytes.length;member.actualCrc32=member.crc32;member.sha256=digest(bytes);member.verified=true;outputs.set(member.id,new Uint8Array(bytes));
    }
    assert.equal(manifest.members.length,52);assert.equal(expanded,8482133);manifest.hardPassed=true;manifest.zipHash=digest(zip);manifest.expandedBytes=expanded;
    const binding=new d.PdfSourceBinding();Object.assign(binding,{originalId:'m2-733d25c4e69f5be1cb5094123585c0c0',originalAssetId:'original-m2-733d25c4e69f5be1cb5094123585c0c0',originalHash:'1ed80b011c6a0f98288d617dd776fafe3ec34d317c8875e9d157937568776794',originalVersion:1,originalBytes:6181688,originalPages:33,taskId:'m2-6fe6c44120d215e2ec1a852235fb97a0',dataId:'m2-6fe6c44120d215e2ec1a852235fb97a0',resultAssetId:'result-m2-6fe6c44120d215e2ec1a852235fb97a0',zipHash:manifest.zipHash,zipBytes:zip.length,requestMode:'vlm-table-formula-ch-noocr-v1',backend:'NotRecorded',producerVersion:'NotRecorded'});
    const archive={async readMember(m,member,c){c.check();assert.equal(m,manifest);assert(member.verified);const bytes=outputs.get(member.id);assert.equal(digest(bytes),member.sha256);return bytes;}};
    const doc=await new MineruPdfNormalizer().normalize(binding,manifest,archive,cancel);
    assert.equal(doc.profile,'MINERU-HOSTED-PDF-3.4.4-OCR-FALSE-1');assert(doc.coverage.hardPassed);
    assert.equal(doc.nodes.filter(n=>!n.parentId).length,342);
    const footers=doc.nodes.filter(n=>n.providerType==='page_footer');assert.equal(footers.length,33);assert(footers.every(n=>n.kind==='unsupported'&&!n.verified&&n.excludedReason==='NodeTypeUnsupported'));assert.equal(doc.coverage.issues.filter(i=>i.code==='NodeTypeUnsupported').length,33);
    const restored=worker.pdfWorkerReadSnapshot(worker.pdfWorkerPayload(structuredClone(worker.pdfWorkerSuccess('normalize',worker.pdfWorkerSnapshotParts(doc,cancel))),'normalize',cancel),cancel,'normalize');
    assert.equal(JSON.stringify(restored),JSON.stringify(doc));assert.equal(new Set(doc.nodes.flatMap(n=>n.assetIds)).size,46);
    assert.equal(digest(fs.readFileSync(filename)),manifest.zipHash);
    console.log('ocr_false_offline members=52 crc=52 expanded=8482133 primary=342 nodes='+doc.nodes.length+' validated='+doc.coverage.validatedNodes+' excluded='+doc.coverage.excludedNodes+' footer=33 assets=46 codec=1 imagekit=0 taskpool=0 new_rpc=0');
    console.log('ocr_false_exclusion_counts '+['NodeTypeUnsupported','EmptyText','JsonFieldMissing','NodeInvalid'].map(code=>code+'='+doc.nodes.filter(n=>!n.verified&&n.excludedReason===code).length).join(' '));
  }}];
};
