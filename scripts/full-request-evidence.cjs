'use strict';
const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
const logs=path.join(root,'.cache/test-logs');
const sources=[
  '2026-10-17-m2b-round2-full-corpus-observe-04-9f5992c/host.log',
  '2026-10-17-m2b-round2-full-query-result-01-9f5992c/host.log'
];
const requests=new Map();
for(const file of sources)for(const line of fs.readFileSync(path.join(logs,file),'utf8').split('\n')){
  const match=line.match(/^R2_EMBED_REQUEST attempt=([a-f0-9]+) purpose=(PdfCorpus|Query|ModelList|Probe) stage=(Start|Http|Failed) http=(\d+) sdk=(-?\d+) category=([A-Za-z]+)$/);
  if(!match)continue;
  const key=match[2]+':'+match[1];const row=requests.get(key)||{purpose:match[2],start:false,http:0,failed:false};
  if(match[3]==='Start')row.start=true;if(match[3]==='Http')row.http=Number(match[4]);if(match[3]==='Failed')row.failed=true;requests.set(key,row);
}
const rows=[...requests.values()];
const summary={corpus:rows.filter(row=>row.purpose==='PdfCorpus'&&row.start).length,query:rows.filter(row=>row.purpose==='Query'&&row.start).length,models:rows.filter(row=>row.purpose==='ModelList'&&row.start).length,probe:rows.filter(row=>row.purpose==='Probe'&&row.start).length,failed:rows.filter(row=>row.failed||row.http!==200).length};
for(const [action,purpose,cap] of [['fullResume','PdfCorpus',340],['fullQuery','Query',1]]){
  const guard=JSON.parse(fs.readFileSync(path.join(root,'.cache',`r024-20261017-${action}-one-attempt.guard`),'utf8'));
  if(guard.action!==action||guard.cap!==cap)throw new Error('Guard identity mismatch');
  const actual=rows.filter(row=>row.purpose===purpose&&row.start).length;if(actual>cap)throw new Error('Authorized request cap exceeded');
}
if(summary.corpus!==340||summary.query!==1||summary.models!==0||summary.probe!==0||summary.failed!==0)throw new Error('Request receipts incomplete or unauthorized');
const receipt=path.join(root,'.cache','r025-20261017-actual-rpc-receipt.json');
try{fs.writeFileSync(receipt,JSON.stringify({summary,sources,checkedAt:new Date().toISOString()})+'\n',{flag:'wx',mode:0o600});}catch(error){if(error.code!=='EEXIST')throw error;const existing=JSON.parse(fs.readFileSync(receipt,'utf8'));if(JSON.stringify(existing.summary)!==JSON.stringify(summary))throw new Error('Existing receipt differs');}
console.log(`R025_RPC corpus=${summary.corpus} corpus_cap=340 query=${summary.query} query_cap=1 models=${summary.models} probe=${summary.probe} failed=${summary.failed} guard_preserved=1`);
const corpusTimes=[...requests.keys()].filter(key=>key.startsWith('PdfCorpus:')).map(key=>Number.parseInt(key.slice('PdfCorpus:'.length),16));
console.log(`R025_WINDOW corpus_first=${Math.min(...corpusTimes)} corpus_last=${Math.max(...corpusTimes)} start_span_ms=${Math.max(...corpusTimes)-Math.min(...corpusTimes)} limit_ms=900000`);
