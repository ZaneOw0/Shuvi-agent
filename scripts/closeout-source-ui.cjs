'use strict';
const cp=require('node:child_process');
const device='127.0.0.1:5555';
const allowed=new Set(['r2-source-structure','r2-source-node-source-formula','r2-source-node-source-table','r2-source-cell-source-cell-0','r2-source-cell-source-cell-12','r2-source-selected','r2-source-node-raw','r2-source-cells-next','r2-source-cells-prev','r2-source-page-canvas','r2-source-back']);
allowed.add('r2-source-cell-detail-source-cell-0');allowed.add('r2-source-cell-raw');
function cli(args){const r=cp.spawnSync('devecocli',['ui',...args,'--device',device],{encoding:'utf8',timeout:30000,maxBuffer:1024*1024});if(r.status!==0)return undefined;return r.stdout;}
function node(id){const raw=cli(['layout','--id',id,'--format','json']);if(!raw)return;let data;try{data=JSON.parse(raw);}catch{return;}const visit=n=>n.id===id?n:(n.children||[]).map(visit).find(Boolean);return(Array.isArray(data)?data:[data]).map(visit).find(Boolean);}
const action=process.argv[2];const id=process.argv[3];if(!allowed.has(id))throw new Error('Synthetic control rejected');
for(let pass=0;pass<2;pass++)for(let at=0;at<8;at++){const n=node(id);if(n&&n.bounds[1]>=528&&n.bounds[3]<=2515&&n.bounds[3]>n.bounds[1]){if(action==='click'){if(cli(['click','--id',id])===undefined)throw new Error('Click failed');console.log(`R2_SOURCE_UI control=${id} clicked=1`);}else if(action==='check'){const expected=process.argv[4];if(expected&&!(n.text||'').includes(expected))throw new Error('Synthetic text mismatch');console.log(`R2_SOURCE_UI control=${id} verified=1 bounds=${n.bounds.join(',')}`);}else throw new Error('Action rejected');process.exit(0);}cli(['swipe','1150',pass===0?'2200':'700','1150',pass===0?'700':'2200']);}
throw new Error('Synthetic control not visible');
