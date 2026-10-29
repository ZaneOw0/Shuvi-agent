'use strict';
const cp=require('node:child_process');
async function main() {
  if(process.argv.includes('--model') || process.argv.includes('--speech')) {
    const r=cp.spawnSync(process.execPath,['--test','--test-reporter=tap',process.argv.includes('--speech')?'entry/src/test/run-speech-tests.cjs':'entry/src/test/run-direct-model-tests.cjs'],{encoding:'utf8',timeout:180000,maxBuffer:8*1024*1024});
    for(const line of (r.stdout||'').split(/\r?\n/)) if(/^# (tests|pass|fail|cancelled|skipped|duration_ms) |^not ok /.test(line)) console.log(line.replace(/token|secret|authorization/gi,'field'));
    console.log((process.argv.includes('--speech')?'SPEECH_HOST_EXIT=':'L0_MODEL_EXIT=')+r.status);if(r.status!==0 || !/^# tests [0-9]+$/m.test(r.stdout||''))process.exitCode=1;return;
  }
  if(process.argv.includes('--lexical-only')) {
    const h=require('../entry/src/test/unified-host-entry.cjs').harness();let passed=0,failed=0;
    for(const [name,run] of require('../entry/src/test/knowledge-lexical-host-cases.cjs').cases(h)) {
      try { await run();passed++;console.log('LEX_PASS '+name.replace(/token/gi,'term')); }
      catch(error) {failed++;console.log('LEX_FAIL '+name.replace(/token/gi,'term'));console.log(String(error.stack).split('\n').slice(0,7).join('\n').replace(/token/gi,'term'));}
    }
    console.log('LEX_SUMMARY passed='+passed+' failed='+failed+' requests='+h.requests());process.exitCode=failed?1:0;return;
  }
  const r=cp.spawnSync(process.execPath,['entry/src/test/run-host-tests.cjs','--unified-only'],{encoding:'utf8',timeout:180000,maxBuffer:8*1024*1024});
  for(const line of (r.stdout||'').split(/\r?\n/)) if(/^UPD_HOST (PASS|FAIL)|^UPD_HOST_SUMMARY|^UPD_HOST_SETUP_FAIL/.test(line)) console.log(line.replace(/token|secret|authorization/gi,'field'));
  console.log('L0_HOST_EXIT='+r.status);if(r.status!==0)process.exitCode=1;
}
main().catch(e=>{console.log('L0_HOST_SETUP '+e.constructor.name+' '+String(e.message).replace(/token/gi,'term'));process.exitCode=1;});
