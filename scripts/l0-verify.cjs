'use strict';
// Public verification summary only. Never print signing configuration or raw CLI output.
const cp = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const cli = process.env.L0_DEVECO_CLI;
if (!cli || !fs.existsSync(cli)) throw Error('L0_DEVECO_CLI required');
const mode = process.argv[2];
const args = mode === 'build' ? ['build', '--modules', 'entry', '--product', 'default'] : ['check', 'lint', 'entry/src/main/ets/knowledge', '--format', 'json', '--output-path', '.cache/l0-lint.json'];
const result = cp.spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8', timeout: 240000, maxBuffer: 16 * 1024 * 1024 });
const output = (result.stdout || '') + (result.stderr || '');
console.log('L0_VERIFY mode=' + mode + ' rc=' + result.status);
for (const line of output.split(/\r?\n/)) {
  if (/BUILD (SUCCESSFUL|FAILED)|COMPILE RESULT|ArkTS:ERROR|Error Message:|File:|Error Code:|CompileArkTS|Failed to generate|Native JSON|EPERM|EACCES/.test(line) && !/sign|password|secret|token|certificate|\.p12|\.p7b|\.cer/i.test(line)) {
    console.log(line.replace(/\x1b\[[0-9;]*m/g, '').slice(0, 700));
  }
}
if (result.error) console.log('L0_VERIFY error=' + result.error.code);
if (mode !== 'build') {
  if (!fs.existsSync('.cache/l0-lint.json')) { console.log('L0_LINT_REPORT_MISSING'); process.exitCode=1; }
  else { const report=JSON.parse(fs.readFileSync('.cache/l0-lint.json','utf8')); console.log('L0_LINT_ERRORS='+report.summary.errors); if (report.summary.errors>0) { process.exitCode=1; for(const issue of report.issues) console.log('L0_LINT '+path.basename(issue.file)+':'+issue.line+' '+issue.rule); } }
}
if (mode === 'build') {
  const success = /BUILD SUCCESSFUL/.test(output);
  console.log('L0_BUILD_SUCCESS_MARKER=' + success);
  for (const name of ['entry-default-unsigned.hap', 'entry-default-signed.hap']) {
    const artifact = path.join('entry/build/default/outputs/default', name);
    if (fs.existsSync(artifact)) console.log('L0_ARTIFACT name=' + name + ' modified=' + fs.statSync(artifact).mtime.toISOString());
  }
  if (!success) process.exitCode = 1;
}
if (result.status !== 0) process.exitCode = result.status || 1;
