'use strict';
// Authorized ignored ZIP only. Never logs member names, document text or paths.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const assert = require('node:assert/strict');
module.exports = (outputRoot, project) => {
  const domain = require(path.join(outputRoot,'entry/src/main/ets/knowledge/domain/PdfKnowledgeModels.js'));
  const policy = require(path.join(outputRoot,'entry/src/main/ets/knowledge/pipeline/SafeZipPolicy.js'));
  const { MineruPdfNormalizer } = require(path.join(outputRoot,'entry/src/main/ets/knowledge/pipeline/MineruPdfNormalizer.js'));
  const codec = require(path.join(outputRoot,'entry/src/main/ets/knowledge/pipeline/PdfSnapshotCodec.js'));
  const { BoundedDocumentJson } = require(path.join(outputRoot,'entry/src/main/ets/knowledge/pipeline/BoundedDocumentJson.js'));
  const filename = path.join(project,'.cache/m2-result-analysis/result-m2-7eaa150e269374313fd776f12a2ae9fa.zip');
  const table = Array.from({length:256},(_,n) => { for (let bit=0;bit<8;bit++) n=(n&1)?0xedb88320^(n>>>1):n>>>1; return n>>>0; });
  const crc32 = bytes => { let crc=0xffffffff; for (const byte of bytes) crc=table[(crc^byte)&255]^(crc>>>8); return (crc^0xffffffff)>>>0; };
  let archive;
  async function inspect() {
    const stat = fs.lstatSync(filename); assert(stat.isFile() && !stat.isSymbolicLink()); assert.equal(stat.size,8461084);
    const zip = fs.readFileSync(filename); assert.equal(crypto.createHash('sha256').update(zip).digest('hex'),'548162c5bb0f6a93d0fe76d4a5a17399f87b0a882c84d4510e7c2ead5fc12a05');
    const reader = { length:zip.length, async read(offset,length) { assert(length<=1048576); return new Uint8Array(zip.subarray(offset,offset+length)); }, async close() {} };
    const manifest = await policy.pdfInspectZip(reader,new domain.KnowledgeCancellation());
    let expanded=0; const outputs=new Map();
    for (const member of manifest.members) {
      const compressed=zip.subarray(member.payloadOffset,member.payloadOffset+member.compressedBytes);
      const response=zlib.inflateRawSync(compressed,{maxOutputLength:Math.min(33554432,member.declaredBytes),info:true});
      const bytes=response.buffer; assert.equal(response.engine.bytesWritten,member.compressedBytes); assert.equal(bytes.length,member.declaredBytes); assert.equal(crc32(bytes),member.crc32);
      expanded=policy.pdfZipReserve(expanded,bytes.length,104857600); member.actualBytes=bytes.length; member.actualCrc32=member.crc32; member.verified=true;
      member.sha256=crypto.createHash('sha256').update(bytes).digest('hex'); outputs.set(member.id,new Uint8Array(bytes));
    }
    manifest.hardPassed=true; manifest.zipHash='548162c5bb0f6a93d0fe76d4a5a17399f87b0a882c84d4510e7c2ead5fc12a05'; manifest.expandedBytes=expanded;
    assert.equal(manifest.members.length,70); assert.equal(expanded,11926995);
    console.log('[离线ZIP/host zlib替身] bytes=8461084 members=70 CRC=70 expanded=11926995; NOT native/app validation');
    return { manifest, outputs, async readMember(_manifest,member) { return outputs.get(member.id); } };
  }
  return [
    { name:'中央/本地头篡改重叠截断和不支持flags均拒绝',run:async()=>{
      const original=fs.readFileSync(filename),end=original.length-22,central=original.readUInt32LE(end+16);
      const variants=[];
      for(const edit of [b=>b.writeUInt16LE(1,central+8),b=>b.writeUInt16LE(8,central+8),b=>b.writeUInt16LE(99,central+10),b=>b.writeUInt32LE(0xffffffff,central+24),b=>b.writeUInt32LE(1,central+42),b=>b.writeUInt16LE(1,end+4),b=>b.writeUInt32LE(0,central+16)]){const b=Buffer.from(original);edit(b);variants.push(b);}
      variants.push(original.subarray(0,original.length-1));
      for(const zip of variants){const reader={length:zip.length,async read(at,n){return new Uint8Array(zip.subarray(at,at+n));},async close(){}};await assert.rejects(()=>policy.pdfInspectZip(reader,new domain.KnowledgeCancellation()));}
    } },
    { name:'指定ZIP有界容器/实际字节/70CRC（host解压，非设备）', run:async()=> { archive=await inspect(); } },
    { name:'指定ZIP唯一v2规范化结构与覆盖警告', run:async()=> {
      archive=archive||await inspect(); const binding=new domain.PdfSourceBinding(); binding.zipHash=archive.manifest.zipHash; binding.originalPages=30;
      // Original hash intentionally absent: offline evidence does not invent it or publish.
      const doc=await new MineruPdfNormalizer().normalize(binding,archive.manifest,archive,new domain.KnowledgeCancellation());
      const primary=doc.nodes.filter(n=>!n.parentId); const formulas=primary.filter(n=>n.kind==='formula'); const tables=primary.filter(n=>n.kind==='table');
      const inline=doc.nodes.reduce((n,node)=>n+node.runs.filter(run=>run.kind==='equation_inline').length,0);
      const cells=tables.reduce((n,node)=>n+(node.table?node.table.cells.length:0),0);
      console.log('[离线规范化计数]',JSON.stringify({primary:primary.length,inline,formulas:formulas.length,tables:tables.length,cells,excluded:doc.coverage.excludedNodes,issueCodes:doc.coverage.issues.map(i=>i.code)}));
      assert.equal(primary.length,346); assert.equal(formulas.length,46); assert.equal(tables.length,7); assert.equal(cells,248); assert.equal(inline,340);
      assert.equal(new Set(doc.nodes.flatMap(n=>n.assetIds)).size,64); assert.equal(doc.coverage.issues.filter(i=>i.code==='EmptyText').length,5);
      assert(doc.coverage.unknownPages.includes(29)); assert(doc.coverage.issues.some(i=>i.code==='CrossPageUnverified:16')); assert(doc.coverage.issues.some(i=>i.code==='LinesDeleted:5'));
      assert(doc.nodes.every(n=>n.locators.every(l=>l.tier==='ProviderUnverified')));
      for (const node of doc.nodes) {
        const restored=codec.pdfDecodeSnapshotNode(new BoundedDocumentJson(codec.pdfCodecUtf8(JSON.stringify(node)),new domain.KnowledgeCancellation()).read());
        assert.equal(JSON.stringify(restored),JSON.stringify(node));
      }
      const header=new domain.PdfNormalizedDocument(); header.binding=doc.binding; header.manifest=doc.manifest; header.coverage=doc.coverage;
      assert.equal(JSON.stringify(codec.pdfDecodeSnapshotHeader(codec.pdfCodecUtf8(JSON.stringify(header)),new domain.KnowledgeCancellation())),JSON.stringify(header));
    } }
  ];
};
