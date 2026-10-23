'use strict';
const assert=require('node:assert/strict');const path=require('node:path');const fixtures=require('./image-fixtures.cjs');
exports.run=async function(root,load){
  const {imageInspectHeader}=load(path.join(root,'pipeline/ImageHeaderPolicy.ets'));
  const {KnowledgeCancellation}=load(path.join(root,'domain/PdfKnowledgeModels.ets'));
  const inspect=(b,s,c=new KnowledgeCancellation())=>imageInspectHeader({length:b.length,read:async(at,n)=>{assert(n<=65536);return b.subarray(at,at+n);}},s,c);
  let count=0;const check=async(fn)=>{await fn();count++;};
  for(const suffix of ['.jpg','.jpeg'])await check(async()=>{const e=await inspect(fixtures.jpeg(),suffix);assert.equal(e.encoding,'JPEG');assert.equal(e.width,3);});
  for(let i=1;i<=8;i++)await check(async()=>assert.equal((await inspect(fixtures.jpeg(3,2,i),'.jpg')).orientationEvidence,'Unknown'));
  for(const [b,s,enc]of [[fixtures.png(),'.png','PNG'],[fixtures.webp('VP8L'),'.webp','WEBP'],[fixtures.webp('VP8 '),'.webp','WEBP'],[fixtures.solidWebp(),'.webp','WEBP']])await check(async()=>assert.equal((await inspect(b,s)).encoding,enc));
  await check(async()=>{const e=await inspect(fixtures.solidWebp(32,96,160,0),'.webp');assert.equal(e.alpha,true);});
  await check(async()=>assert((await inspect(fixtures.jpeg(),'.webp')).warnings.includes('SuffixEncodingConflict')));
  await check(async()=>assert.equal((await inspect(Buffer.concat([fixtures.jpeg(),Buffer.from('tail')]),'.jpg')).encoding,'JPEG'));
  for(const [b,s]of [[fixtures.png(3,2,true),'.png'],[fixtures.webp('VP8L',true),'.webp'],[fixtures.png(20001,1000),'.png'],[fixtures.png().subarray(0,24),'.png'],[Buffer.alloc(20971521),'.png']])await check(()=>assert.rejects(inspect(b,s)));
  await check(async()=>{const b=fixtures.png();b[29]^=1;assert.equal((await inspect(b,'.png')).encoding,'PNG');});
  await check(async()=>{const c=new KnowledgeCancellation();c.invalid=true;await assert.rejects(inspect(fixtures.png(),'.png',c));});
  console.log(`M3_PIPELINE_SUMMARY passed=${count} failed=0 imagekit=not-run requests=0`);
  if(process.argv.includes('--inputs')){
    const fs=require('node:fs'),crypto=require('node:crypto');const project=path.resolve(root,'../../../../..');const input=require('./image-host-entry.cjs').inputManifest;let valid=0,conflicts=0,rejected=0,total=0;
    for(const[name,bytes,hash]of input){const file=path.join(project,'.cache/m3-input',name);const stat=fs.lstatSync(file);assert(stat.isFile()&&!stat.isSymbolicLink());const data=fs.readFileSync(file);assert.equal(data.length,bytes);assert.equal(crypto.createHash('sha256').update(data).digest('hex'),hash);try{const e=await inspect(data,path.extname(name));const warning=e.warnings.includes('SuffixEncodingConflict');if(warning)conflicts++;valid++;console.log(`IMAGE_BASIC id=U${String(input.findIndex(i=>i[0]===name)+1).padStart(2,'0')} encoding=${e.encoding} width=${e.width} height=${e.height} bytes=${bytes} hash=${hash} suffix_warning=${warning?1:0} unchanged=1`);}catch(e){rejected++;console.log(`M3_INPUT_REJECT id=${input.findIndex(i=>i[0]===name)+1} category=${typeof e.category==='string'&&/^[A-Za-z]{1,80}$/.test(e.category)?e.category:'LocalFailure'}`);}assert.equal(crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'),hash);total+=data.length;}
    if(process.argv.includes('--structure-diagnostic'))for(let at=0;at<input.length;at++){if(![3,4,5,6,7,9,10].includes(at))continue;const data=fs.readFileSync(path.join(project,'.cache/m3-input',input[at][0]));const eoi=data.lastIndexOf(Buffer.from([255,217]));const tail=eoi<0?Buffer.alloc(0):data.subarray(eoi+2);console.log(`M3_INPUT_JPEG_DIAGNOSTIC id=${at+1} tail_bytes=${tail.length} tail_padding_only=${tail.every(b=>b===0||b===255)?1:0}`);}
    assert.equal(valid,11);assert.equal(rejected,0);assert.equal(conflicts,1);console.log(`M3_INPUT_STRUCTURE accepted=${valid} suffix_warning=${conflicts} other_rejected=${rejected} unchanged=11 bytes=${total} imagekit=not-run content_logged=0 requests=0`);
  }
};
