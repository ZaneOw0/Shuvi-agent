'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'..'),base=path.join(root,'.cache/test-logs');
const scopes=fs.readdirSync(base).filter(name=>/^2026-10-17-closeout-.*-9f5992c(?:-\d+)?$/.test(name));
const known=new Set();
for(const scope of ['2026-10-17-quality-provider-receipt-9f5992c','2026-10-17-m2b-round2-full-corpus-observe-04-9f5992c','2026-10-17-m2b-round2-full-query-result-01-9f5992c']){
 const file=path.join(base,scope,'host.log');if(fs.existsSync(file))for(const line of fs.readFileSync(file,'utf8').split('\n')){const m=line.match(/^R2_EMBED_REQUEST attempt=([a-f0-9]+) purpose=(\w+) stage=Start /);if(m)known.add(m[2]+':'+m[1]);}
}
let files=0,requests=0;for(const scope of scopes){const file=path.join(base,scope,'host.log');if(!fs.existsSync(file))continue;files++;for(const line of fs.readFileSync(file,'utf8').split('\n')){const m=line.match(/^R2_EMBED_REQUEST attempt=([a-f0-9]+) purpose=(\w+) stage=Start /);if(m){requests++;assert(known.has(m[2]+':'+m[1]),'Unapproved new provider attempt');}}}
const read=scope=>fs.readFileSync(path.join(base,`2026-10-17-${scope}-9f5992c/host.log`),'utf8');
const protection=read('closeout-shipped-protection');
assert(protection.includes('verified=343 unknown=0 remaining=0 active=1 eligible=343 stage=SemanticReady mirror=Synced dimension=1024 readback=7fd6351e6ef82270a9e0213928a6c8aa5f784454c4510e583e9a52392b69a1b3'));
assert(protection.includes('R2_CLOSEOUT_RELEASE leases=0 source_pending=0 vector_pending=0'));
assert(protection.includes('R2_QUALITY_REOPEN vectors=24 results=16 candidates=8 requests=0'));
assert(protection.includes('recall=1 mrr=1 paraphrase_recovered=8 negation_correct=4 noanswer_nonempty=4 answers_generated=0 pass=1'));
assert(protection.includes('images=64 read_images=64 excluded=5 chunks=343 assets=65 bytes=1350219 leases=0 published=1'));
assert(protection.includes('m1=f2fc7436d159ff91e162acf62a42e23d3bb3bdfa67d7709e473497ad62e8dd2b parse=f9256feddd56314ea2fbe40e5807831461917bf5ae42ddb6ae5498f31a598308 originals=1 results=1 history=16 original_ok=1 zip_ok=1'));
assert(protection.includes('credential=Configured revision=2 credential_revision=1 pending=0 busy=0 detection=Passed basis=AcceptedEngineeringBaseline'));
for(const [scope,suite,count]of [['closeout-shipped-repair-basis-flow','CLOSEOUT',16],['closeout-shipped-native-local-vector','NATIVE',11],['closeout-shipped-native-local-vector','LOCAL',28],['closeout-shipped-native-local-vector','VECTOR',21],['closeout-shipped-repair-basis-flow','BASIS',33],['closeout-shipped-repair-basis-flow','EMBED',28]]){
 const rows=read(scope).split('\n').filter(line=>line.includes(`suite=R2-${suite}-`));const run=rows.at(-1).match(/run=([a-f0-9]{16})/)[1];const unique=new Map();for(const line of rows.filter(line=>line.includes(`run=${run} `))){const id=line.match(/case=([a-z0-9-]+)/)[1];if(unique.has(id))assert.equal(unique.get(id),line);unique.set(id,line);}const cases=[...unique.values()];assert.equal(cases.length,count);assert(cases.every(line=>line.includes('pass=1')));console.log(`R2_CLOSEOUT_CHECK suite=${suite} cases=${count} failed=0`);
}
const before=read('closeout-pre-dry-protection'),after=read('closeout-post-dry-protection');for(const prefix of ['R2_EMBED_STATE','R2_EMBED_DETECTION'])assert.equal(after.split('\n').filter(line=>line.startsWith(prefix)).at(-1),before.split('\n').filter(line=>line.startsWith(prefix)).at(-1));assert(after.includes('requests=0 vectors=343'));
assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(root,'build-profile.json5'))).digest('hex'),'36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7');
assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(root,'entry/build/default/outputs/default/entry-default-signed.hap'))).digest('hex'),'2109c77a4e700467bc0af0374e6b663daf481aed628632fbb902be6e9314e89a');
console.log(`R2_CLOSEOUT_RPC logs=${files} observed_known_lines=${requests} unexpected_requests=0 network_actions=0`);
console.log('R2_CLOSEOUT_PROTECTION vectors=343 samehash=1 quality=24 images=64 m1_history=16 rev=2 passed=1 basis=1 leases=0 template=1');
