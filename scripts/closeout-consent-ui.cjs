'use strict';
const cp=require('node:child_process');
const device='127.0.0.1:5555';
const allowed=new Set(['r2-query-input','r2-query-count','r2-query-consent','r2-query-free','r2-query-search','r2-query-clear','r2-query-bound','r2-trial-query-input','r2-trial-query-count','r2-trial-query-consent','r2-trial-query-free','r2-trial-query-request','r2-query-status','r2-consent-ui-audit','r2-consent-ui-summary','r2-consent-ui-back']);
function cli(args){const r=cp.spawnSync('devecocli',['ui',...args,'--device',device],{encoding:'utf8',timeout:30000,maxBuffer:1024*1024});return r.status===0?r.stdout:undefined;}
function node(id){const raw=cli(['layout','--id',id,'--format','json']);if(!raw)return;let data;try{data=JSON.parse(raw);}catch{return;}const visit=n=>n.id===id?n:(n.children||[]).map(visit).find(Boolean);return(Array.isArray(data)?data:[data]).map(visit).find(Boolean);}
const action=process.argv[2],id=process.argv[3];if(!allowed.has(id))throw new Error('Isolated consent control rejected');
for(let pass=0;pass<2;pass++)for(let at=0;at<14;at++){
 const n=node(id);if(n&&n.bounds[1]>=528&&n.bounds[3]<=2515&&n.bounds[3]>n.bounds[1]){
  if(action==='text'){const text=process.argv[4];if(!['reviewed input','adversarial input'].includes(text))throw new Error('Fixture text rejected');if(cli(['text',text,'--id',id])===undefined)throw new Error('Text failed');cp.spawnSync('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc',['-t',device,'shell','uitest','uiInput','keyEvent','Back'],{timeout:30000,stdio:'ignore'});}
  else if(action==='click'){if(cli(['click','--id',id])===undefined)throw new Error('Click failed');}
  else if(action==='check'){const expected=process.argv[4];if(expected&&!String(n.text||'').includes(expected))throw new Error('Public fixture state mismatch');}
  else if(action==='disabled'){if(n.clickable===true)throw new Error('Stale consent action still enabled');}
  else throw new Error('Action rejected');console.log(`R2_CONSENT_UI action=${action} control=${id} verified=1`);process.exit(0);
 }
 cli(['swipe','1150',pass===0?'2200':'700','1150',pass===0?'700':'2200']);
}
throw new Error('Isolated consent control not visible');
