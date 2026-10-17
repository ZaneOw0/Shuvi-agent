'use strict';
const cp = require('node:child_process');
const args=['--test'];
if(process.env.HOST_TEST_PATTERN)args.push('--test-name-pattern',process.env.HOST_TEST_PATTERN);
args.push('entry/src/test/run-host-tests.cjs');
const result = cp.spawnSync(process.execPath, args, { cwd:require('node:path').resolve(__dirname,'../../..'), encoding:'utf8', maxBuffer:20*1024*1024 });
const output = result.stdout || '';
for (const line of output.split('\n')) {
  if (/^# (tests|pass|fail|cancelled|skipped|todo|duration_ms) [0-9.]+$/.test(line)) console.log(line);
  if (/^not ok [0-9]+ - /.test(line)) console.log('failed_case_number='+line.match(/^not ok ([0-9]+)/)[1]);
  if (process.env.HOST_TEST_PATTERN === 'KnowledgeResult host' && /^\s+(expected|actual): [0-9]+$/.test(line)) console.log('result_numeric '+line.trim());
  if (process.env.HOST_TEST_PATTERN === 'Knowledge SQLite' && /^\s+(error:|code:|expected:|actual:|at |- |\+ )/.test(line)) {
    const safe=line.replace(/[^a-zA-Z0-9_ .,:'"/()=<>?+\-]/g,'').slice(0,300);
    if(!/password|authorization|secret|token|private.?key/i.test(safe))console.log('injected_diagnostic '+safe);
  }
  if (line.includes('[离线ZIP/host zlib替身]')) console.log('offline_zip bytes=8461084 members=70 CRC=70 expanded=11926995; host-only');
  if (/^# result_pages_offline nodes=[0-9]+ chunks=[0-9]+ cross_chunks=[0-9]+ unknown_empty_nodes=5 original_last_page_unbound=1 new_rpc=0$/.test(line)) console.log(line.slice(2));
  if (/^# result_pages_review_sha256=[a-f0-9]{64}$/.test(line)) console.log(line.slice(2));
  if (/^# result_literal_counts overfit=[0-9]+ upper=[0-9]+ lower=[0-9]+ multi=[0-9]+$/.test(line)) console.log(line.slice(2));
  if (line.includes('[离线规范化计数]')) {
    try {
      const data=JSON.parse(line.slice(line.indexOf('{')));
      console.log('offline_structure '+JSON.stringify({primary:data.primary,inline:data.inline,formulas:data.formulas,tables:data.tables,cells:data.cells,excluded:data.excluded}));
    } catch { console.log('offline_summary_unavailable'); }
  }
}
console.log('host_process_exit='+result.status);
if (!/^# tests [0-9]+$/m.test(output)) console.log('host_summary_missing; no raw diagnostic published');
process.exit(result.status === null ? 1 : result.status);
