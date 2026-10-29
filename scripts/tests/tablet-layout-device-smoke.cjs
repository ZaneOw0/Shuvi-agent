'use strict';
// Page navigation on an explicitly selected, already-installed tablet. No key access or send/search actions.
// Every assertion polls for a bounded time instead of sleeping a fixed amount, so a slow first
// render fails with the real reason and visible ids rather than a misleading "page not reached".
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const assert = require('node:assert/strict');
const sdk = process.env.DEVECO_SDK_HOME;
const serial = process.env.TABLET_TEST_DEVICE;
if (!sdk || !serial) throw Error('Set DEVECO_SDK_HOME and TABLET_TEST_DEVICE.');
const hdc = path.join(sdk, 'default/openharmony/toolchains', process.platform === 'win32' ? 'hdc.exe' : 'hdc');
const root = path.resolve(__dirname, '../..');
const output = path.join(root, '.cache/tablet-ui-smoke', String(Date.now()));
fs.mkdirSync(output, { recursive: true });
const POLL_MS = 300;
const READY_TIMEOUT_MS = 20000;
function command(...args) {
  const result = cp.spawnSync(hdc, ['-t', serial, ...args], {
    encoding: 'utf8', windowsHide: true, timeout: 30000
  });
  assert.equal(result.status, 0, 'Device command failed: ' + args[0]);
  assert(!/\[Fail\]/.test(result.stdout || ''), 'Device reported command failure.');
  return result.stdout;
}
function shell(...args) { return command('shell', ...args); }
function layout() {
  const remote = '/data/local/tmp/shuvi-tablet-smoke.json';
  shell('uitest', 'dumpLayout', '-p', remote);
  const text = shell('cat', remote);
  const tree = JSON.parse(text.slice(text.indexOf('{'))), nodes = [];
  function visit(node) {
    if (node.attributes) nodes.push(node.attributes);
    for (const child of node.children || []) visit(child);
  }
  visit(tree); return nodes;
}
function find(nodes, id) { return nodes.find(node => node.id === id || node.key === id); }
function anyOf(nodes, ids) { return ids.some(id => find(nodes, id)); }
// Diagnostics only: stable component ids, never user text, keys or paths.
function visibleIds(nodes) {
  const ids = [];
  for (const node of nodes) {
    const id = node.id || node.key;
    if (id && ids.indexOf(id) < 0) ids.push(id);
  }
  return ids.slice(0, 60).join(',');
}
function click(id) {
  const item = find(layout(), id); assert(item, 'Missing control: ' + id);
  assert(item.enabled !== false && item.enabled !== 'false', 'Disabled control: ' + id);
  const bounds = String(item.bounds).match(/-?\d+/g).map(Number);
  assert.equal(bounds.length, 4);
  shell('uitest', 'uiInput', 'click', String(Math.round((bounds[0] + bounds[2]) / 2)),
    String(Math.round((bounds[1] + bounds[3]) / 2)));
}
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(description, probe) {
  const deadline = Date.now() + READY_TIMEOUT_MS;
  for (;;) {
    const value = probe();
    if (value) return value;
    if (Date.now() > deadline) {
      throw Error('Timeout waiting for ' + description + '; visible=' + visibleIds(layout()));
    }
    await pause(POLL_MS);
  }
}
function capture(name) {
  const remote = '/data/local/tmp/shuvi-tablet-smoke-' + name + '.jpeg';
  shell('snapshot_display', '-f', remote);
  const local = path.join(output, name + '.jpeg'); command('file', 'recv', remote, local);
  assert(fs.existsSync(local) && fs.statSync(local).size > 1000, 'Screenshot was not saved.');
  console.log('TABLET_SCREENSHOT ' + path.relative(root, local).replaceAll('\\', '/'));
}
(async () => {
  assert.equal(shell('param', 'get', 'const.product.devicetype').trim(), 'tablet');
  assert(shell('pidof', 'com.example.shuvi').trim(), 'Shuvi is not running.');
  const initial = await until('application shell',
    () => { const nodes = layout(); return find(nodes, 'responsive-shell') ? nodes : null; });
  assert(!find(initial, 'pdfjs-close-preview'), 'Close the current PDF preview before navigation smoke.');
  assert(!initial.some(n => n.type === 'Button' && ['取消回答', '停止等待', '结束'].includes(n.text)),
    'Finish the active assistant/recording task first.');
  const draft = find(initial, 'chat-input');
  assert(!draft || !draft.text, 'Preserve the unsent draft; finish it before navigation smoke.');
  // Calendar has several legitimate states (form, confirmation, list), so accept any stable marker.
  const pages = [
    ['assistant', ['chat-input']], ['calendar', ['calendar-new-draft', 'calendar-probe-preview',
      'calendar-probe-confirm', 'calendar-form-close']],
    ['knowledge', ['upd-query-input', 'upd-back', 'upd-query-home']], ['profile', ['profile-api-keys']]
  ];
  for (let index = 0; index < pages.length; index++) {
    if (!find(layout(), 'drawer-tab-' + index)) {
      click('chat-menu');
      await until('drawer tab ' + index, () => find(layout(), 'drawer-tab-' + index));
    }
    click('drawer-tab-' + index);
    const nodes = await until(pages[index][0],
      () => { const current = layout(); return anyOf(current, pages[index][1]) ? current : null; });
    const bounds = find(nodes, 'responsive-shell').bounds;
    capture(pages[index][0]); console.log('TABLET_PAGE_PASS ' + pages[index][0] + ' bounds=' + bounds);
  }
  if (!find(layout(), 'drawer-tab-0')) {
    click('chat-menu'); await until('drawer tab 0', () => find(layout(), 'drawer-tab-0'));
  }
  click('drawer-tab-0');
  console.log('TABLET_UI_SUMMARY pages=4 device=tablet explicit_cloud_actions=none');
})().catch(error => { console.log('TABLET_UI_FAIL ' + error.message); process.exitCode = 1; });
