'use strict';
const cp = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const device = '127.0.0.1:5555';
const doc = 'kb-60986788281e094aff01063dfcf764f1';
const fullJob='kb-a559722e0fceb2006b145f2ad9e6c656';
const fullSpace='kb-5f85a339550011dce2c68243d97e2b1f';
const controls = new Set(['r2-embedding-public-audit','r2-accept-basis','r2-open-embedding','r2-embedding-audit','r2-models-free','r2-models-request','r2-probe-free','r2-probe-request','r2-embedding-back','r2-open-diagnostics','r2-trial-audit',`r2-review-${doc}`,`r2-vectorize-${doc}`,'r2-corpus-consent','r2-corpus-free','r2-trial-query-input','r2-trial-query-count','r2-trial-query-bound','r2-trial-query-consent','r2-trial-query-free','r2-trial-query-request','r2-full-audit','r2-full-scope',`r2-resume-${fullJob}`,'r2-query-input','r2-query-count','r2-query-bound','r2-query-consent','r2-query-free','r2-query-search',`r2-space-${fullSpace}`]);
function addTrialControl(id) { if(!/^r2-trial-prepare-kb-[a-f0-9]{32}$/.test(id))throw new Error('Trial job identity rejected'); controls.add(id); }
function cli(args, inspection = false) {
  const result = cp.spawnSync('devecocli',['ui',...args,'--device',device],{ encoding:'utf8',timeout:30000,maxBuffer:1024*1024 });
  if (result.status !== 0) { if (inspection) return undefined; throw new Error('Public UI operation not confirmed'); }
  return result.stdout;
}
function node(id, visible = true) {
  if (!controls.has(id)) throw new Error('Control not allowlisted');
  // Never dump a settings page. Only this exact nonsecret control subtree is requested.
  const raw = cli(['layout','--id',id,'--format','json'],true);
  if (raw === undefined) return undefined;
  let data; try { data=JSON.parse(raw); } catch { return undefined; }
  const visit = item => { if (item.id===id) return item; for (const child of item.children||[]) { const found=visit(child); if(found)return found; } };
  for (const item of Array.isArray(data)?data:[data]) { const found=visit(item); if(found && (!visible || (found.bounds && found.bounds[1]>=528 && found.bounds[3]<=2515 && found.bounds[3]>found.bounds[1]))) return found; }
}
function locate(id) {
  for(let pass=0;pass<2;pass++) {
    for(let at=0;at<9;at++) {
      const found=node(id); if(found)return found;
      cli(['swipe','1150',pass===0?'2200':'700','1150',pass===0?'700':'2200']);
    }
  }
  throw new Error(`Allowlisted control not visible: ${id}`);
}
const action=process.argv[2];
if(action==='waitSummary') {
  controls.add('r2-suite-summary'); const expected=process.argv[3]; if(!/^(\d+\/\d+|QualityPASS|QualityContractPASS|AuditPassed|SnapshotReadbackPassed|ProductionVectorAuditPASS)$/.test(expected||''))throw new Error('Expected summary rejected');
  const deadline=Date.now()+120000;
  while(Date.now()<deadline){ const row=node('r2-suite-summary',false);if(row?.text===expected){console.log(`R2_QUALITY_UI summary=${expected} verified=1`);process.exit(0);} if(row?.text?.includes('Stopped')||row?.text?.includes('FAIL'))throw new Error('Suite failed');cp.spawnSync('/bin/sleep',['1']); }
  throw new Error('Expected suite completion not observed');
}
const qualityActions={qualityContract:'r2-quality-contract',qualityConsent:'r2-quality-consent',qualityFree:'r2-quality-free',qualityRun:'r2-quality-run',qualityReadback:'r2-quality-readback',qualitySummary:'r2-suite-summary',nativeSuite:'r2-run-native',localSuite:'r2-run-local',vectorSuite:'r2-run-vector',basisSuite:'r2-run-basis',workflowSuite:'r2-run-embedding',publicAudit:'r2-public-audit',pdfAudit:'r2-pdf-audit'};
for(const id of Object.values(qualityActions))controls.add(id);
qualityActions.productionVectorAudit='r2-quality-production-audit';controls.add(qualityActions.productionVectorAudit);
for(const [action,id] of [['closeoutSuite','r2-run-closeout'],['sourceFixture','r2-open-closeout-source'],['dryReview','r2-dry-approved-pdf']]){qualityActions[action]=id;controls.add(id);}
qualityActions.queryFixture='r2-open-closeout-query';controls.add(qualityActions.queryFixture);
qualityActions.capability='r2-check-capability';controls.add(qualityActions.capability);
qualityActions.residualIngestion='r2-open-residual-ingestion';controls.add(qualityActions.residualIngestion);
qualityActions.residualHistory='r2-open-residual-history';controls.add(qualityActions.residualHistory);
if(Object.hasOwn(qualityActions,action)) {
  const id=qualityActions[action]; const row=locate(id);
  if(action==='qualitySummary') { if(!/^(Quality[A-Za-z]+|\d+\/\d+|AuditPassed|SnapshotReadbackPassed)$/.test(row.text||''))throw new Error('Summary unavailable'); console.log(`R2_QUALITY_UI summary=${row.text}`); }
  else { if(action==='qualityRun') { if(row.enabled===false)throw new Error('Quality action disabled'); const guard=path.resolve(__dirname,'../.cache/r025-quality-a220261017240001-one-attempt.guard'); const fd=fs.openSync(guard,'wx',0o600);fs.writeSync(fd,JSON.stringify({run:'a220261017240001',documentCap:8,queryCap:16,model:'BAAI/bge-m3',provider:'SiliconFlow',at:new Date().toISOString(),retry:false})+'\n');fs.closeSync(fd); }cli(['click','--id',id]);console.log(`R2_QUALITY_UI action=${action} clicked=1`); }
  process.exit(0);
}
if(action==='knowledge') { cli(['click','800','2610']); console.log('R024_UI knowledge_opened=1'); }
else if(action==='profile') { cli(['click','1120','2610']); console.log('R024_UI profile_opened=1'); }
else if(action==='prepareTrial') { const id=`r2-trial-prepare-${process.argv[3]}`; addTrialControl(id); locate(id); cli(['click','--id',id]); console.log('R024_UI trial_prepared=1'); }
else if(action==='trialText') { const id='r2-trial-query-input'; locate(id); cli(['text','这几段内容主要讨论什么？','--id',id]); console.log('R024_UI fixed_trial_query_entered=1'); }
else if(action==='trialCountResult') { const row=locate('r2-trial-query-bound'); const match=(row.text||'').match(/SafeUnderPinnedProfile \/ bound (\d+)\/8192 \/ hash ([a-f0-9]{64}) \/ AcceptedEngineeringBaseline/); if(!match)throw new Error('Trial query count unavailable');console.log(`R024_QUERY_REVIEW safe=1 bound=${match[1]} hash=${match[2]} baseline=accepted`); }
else if(action==='fullText') { locate('r2-query-input'); cli(['text','这份资料的核心主题和主要内容是什么？','--id','r2-query-input']); console.log('R025_UI fixed_full_query_entered=1'); }
else if(action==='fullCountResult') { const row=locate('r2-query-bound'); const match=(row.text||'').match(/SafeUnderPinnedProfile \/ bound (\d+)\/8192 \/ hash ([a-f0-9]{64}) \/ AcceptedEngineeringBaseline/); if(!match)throw new Error('Full query count unavailable');console.log(`R025_QUERY_REVIEW safe=1 bound=${match[1]} hash=${match[2]} baseline=accepted`); }
else {
  const actions={ auditKnowledge:'r2-embedding-public-audit', basis:'r2-accept-basis', settings:'r2-open-embedding', audit:'r2-embedding-audit', modelsFree:'r2-models-free', models:'r2-models-request', probeFree:'r2-probe-free', probe:'r2-probe-request', back:'r2-embedding-back', diagnostics:'r2-open-diagnostics', review:`r2-review-${doc}`, trialAudit:'r2-trial-audit', corpusConsent:'r2-corpus-consent', corpusFree:'r2-corpus-free', corpus:`r2-vectorize-${doc}`, trialCount:'r2-trial-query-count', trialConsent:'r2-trial-query-consent', trialFree:'r2-trial-query-free', trialQuery:'r2-trial-query-request', fullAudit:'r2-full-audit',fullScope:'r2-full-scope',fullResume:`r2-resume-${fullJob}`,fullSelect:`r2-space-${fullSpace}`,fullCount:'r2-query-count',fullConsent:'r2-query-consent',fullFree:'r2-query-free',fullQuery:'r2-query-search' };
  if(!Object.hasOwn(actions,action))throw new Error('Action not allowlisted');
  const id=actions[action]; locate(id);
  if(['models','probe','corpus','trialQuery','fullResume','fullQuery'].includes(action)) {
    const guard=path.resolve(__dirname,'../.cache',`r024-20261017-${action}-one-attempt.guard`);
    const fd=fs.openSync(guard,'wx',0o600); fs.writeSync(fd,JSON.stringify({action,job:fullJob,cap:action==='fullResume'?340:1,at:new Date().toISOString(),policy:'one UI submission; no retry or journal deletion'})+'\n'); fs.closeSync(fd);
  }
  cli(['click','--id',id]);
  console.log(`R024_UI action=${action} clicked=1`);
}
