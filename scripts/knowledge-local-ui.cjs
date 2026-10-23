#!/usr/bin/env node
'use strict';
const cp = require('node:child_process');
const device = '127.0.0.1:5555';
function cli(args) {
  const r = cp.spawnSync('devecocli', ['ui', ...args, '--device', device], { encoding: 'utf8', timeout: 30000, maxBuffer: 4 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`UI operation failed: ${args[0]}`);
  if (args[0] !== 'layout') cp.spawnSync('/bin/sleep', ['0.3']);
  return r.stdout;
}
function nodes() {
  const data = JSON.parse(cli(['layout', '--format', 'json'])); const rows = [];
  const visit = n => { rows.push(n); for (const child of n.children || []) visit(child); };
  for (const n of Array.isArray(data) ? data : [data]) visit(n);
  return rows;
}
function control(id, direction = 'down') {
  for (let i = 0; i < 8; i++) {
    const row = nodes().find(n => n.id === id && n.bounds[3] > n.bounds[1] && n.bounds[1] >= 528 && n.bounds[3] <= 2519);
    if (row) return row;
    cli(['swipe', '1150', direction === 'down' ? '2200' : '700', '1150', direction === 'down' ? '700' : '2200']);
  }
  throw new Error(`Public control unavailable: ${id}`);
}
function click(id, direction) { control(id, direction); cli(['click', '--id', id]); }
const action = process.argv[2];
if (action === 'review-pdf') {
  click('r2-review-kb-60986788281e094aff01063dfcf764f1'); console.log('UI_DRY submitted=1 requests=0');
} else if (action === 'review-status') {
  const row=control('r2-dry-review-summary','up'); const text=row.text||'';
  if(!text.includes('343')||!text.includes('BoundUnproven 0')||!text.includes('Invalid 0'))throw new Error('Dry review summary mismatch');
  console.log('UI_DRY inputs=343 unproven=0 invalid=0 summary_visible=1');
} else if (action === 'review-next') {
  click('r2-review-next'); console.log('UI_DRY page_advanced=1');
} else if (action === 'query-count') {
  click('r2-query-count','up'); console.log('UI_QUERY_COUNT submitted=1');
} else if (action === 'query-count-result') {
  const row=control('r2-query-bound','up'); const match=(row.text||'').match(/SafeUnderPinnedProfile \/ bound (\d+)\/8192 \/ hash ([a-f0-9]{64}) \/ AcceptedEngineeringBaseline/);
  if(!match)throw new Error('Query count evidence unavailable'); console.log(`UI_QUERY_COUNT safe=1 bound=${match[1]} hash=${match[2]} baseline=accepted requests=0`);
} else if (action === 'diagnostic') {
  const controls = { vector: 'r2-run-vector', embedding: 'r2-run-embedding', basis: 'r2-run-basis', dry: 'r2-dry-approved-pdf', local: 'r2-run-local', native: 'r2-run-native', audit: 'r2-public-audit', pdf: 'r2-pdf-audit', cleanup: 'r2-clean-vector-owned', open: 'r2-open-vector-session', prepareRestart: 'r2-vector-restart-prepare', verifyRestart: 'r2-vector-restart-verify' };
  const selected = process.argv[3]; if (!Object.hasOwn(controls,selected)) throw new Error('Diagnostic action rejected');
  for (let at = 0; at < 4; at++) cli(['swipe','1150','700','1150','2200']);
  click(controls[selected],'down'); console.log(`UI_DIAGNOSTIC action=${selected} submitted=1`);
} else if (action === 'leave-diagnostics') {
  let back;
  for (let at=0;at<8;at++) { back=nodes().find(n=>n.type==='Button'&&n.text==='返回'&&n.bounds[1]>=528&&n.bounds[3]<=2519); if(back)break; cli(['swipe','1150','2200','1150','700']); }
  if (!back) throw new Error('Diagnostic return missing'); const b = back.bounds; cli(['click', String((b[0] + b[2]) / 2), String((b[1] + b[3]) / 2)]);
  cli(['click', '800', '2610']);
} else if (action === 'query') {
  const cases = { literal: 'the', negation: 'not all', absent: 'shuviround2nomatch927463', formula: 'formula' };
  const id = process.argv[3]; if (!Object.hasOwn(cases, id)) throw new Error('Query fixture rejected');
  control('r2-query-clear', 'up'); cli(['click', '--id', 'r2-query-clear']);
  control('r2-query-input', 'up'); cli(['text', cases[id], '--id', 'r2-query-input']);
  const back = cp.spawnSync('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc', ['-t', device, 'shell', 'uitest', 'uiInput', 'keyEvent', 'Back'], { encoding: 'utf8', timeout: 30000 });
  if (back.status !== 0) throw new Error('IME dismissal failed'); cp.spawnSync('/bin/sleep', ['0.3']);
  cli(['swipe', '1150', '1450', '1150', '620']); click('r2-query-search');
  console.log(`UI_QUERY fixture=${id} submitted=1`);
} else if (action === 'open-hit' || action === 'open-citation' || action === 'open-image') {
  const prefix = action === 'open-hit' ? 'r2-hit-' : action === 'open-citation' ? 'r2-citation-' : 'r2-asset-'; let selected;
  for (let i = 0; i < 8; i++) { selected = nodes().find(n => n.id && n.id.startsWith(prefix) && Math.min(n.bounds[3], 2510) - Math.max(n.bounds[1], 540) > 60); if (selected) break; cli(['swipe', '1150', '2200', '1150', '700']); }
  if (!selected) throw new Error('Source control not visible'); const b = selected.bounds; cli(['click', String((b[0] + b[2]) / 2), String((Math.max(b[1], 540) + Math.min(b[3], 2510)) / 2)]); console.log(`UI_SOURCE action=${action} control=${selected.id}`);
} else if (action === 'history') { click('r2-query-history', 'up'); console.log('UI_HISTORY opened=1');
} else if (action === 'source-back') { click('r2-source-back', 'up'); console.log('UI_SOURCE closed=1');
} else if (action === 'structure') { click('r2-source-structure'); console.log('UI_STRUCTURE opened=1');
} else throw new Error('Unsupported local UI action');
