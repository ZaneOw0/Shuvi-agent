// UI smoke on an explicitly selected, already-installed test device. Never logs recognized text.
const cp = require('node:child_process');
const path = require('node:path');
const assert = require('node:assert/strict');
const sdk = process.env.DEVECO_SDK_HOME;
const device = process.env.SPEECH_TEST_DEVICE;
if (!sdk || !device) throw new Error('Set DEVECO_SDK_HOME and SPEECH_TEST_DEVICE.');
const hdc = path.join(sdk, 'default/openharmony/toolchains/hdc.exe');
const layoutPath = '/data/local/tmp/shuvi-speech-smoke-layout.json';
function shell(...args) {
  const result = cp.spawnSync(hdc, ['-t', device, 'shell', ...args], { encoding: 'utf8', windowsHide: true, timeout: 10000 });
  if (result.status !== 0) throw new Error('Device command failed: ' + args[0]);
  return result.stdout;
}
function layout() {
  shell('uitest', 'dumpLayout', '-p', layoutPath);
  const raw = shell('cat', layoutPath);
  const tree = JSON.parse(raw.slice(raw.indexOf('{')));
  const nodes = [];
  function visit(node) { if (node.attributes) nodes.push(node.attributes); for (const child of node.children || []) visit(child); }
  visit(tree); return nodes;
}
function find(nodes, id) { return nodes.find(n => n.id === id || n.key === id); }
function click(id) {
  const node = find(layout(), id); assert.ok(node, 'Missing control: ' + id);
  assert.ok(node.enabled === true || node.enabled === 'true', 'Disabled control: ' + id);
  const coords = String(node.bounds).match(/-?\d+/g).map(Number);
  assert.equal(coords.length, 4);
  shell('uitest', 'uiInput', 'click', String(Math.round((coords[0] + coords[2]) / 2)),
    String(Math.round((coords[1] + coords[3]) / 2)));
}
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function waitFor(predicate) {
  for (let i = 0; i < 16; i++) { const nodes = layout(); if (predicate(nodes)) return nodes; await pause(200); }
  throw new Error('Expected speech UI state not reached; check capability and microphone permission.');
}
(async () => {
  let started = false;
  try {
    click('chat-speech'); started = true;
    const nodes = await waitFor(items => !!find(items, 'speech-finish'));
    assert.ok(nodes.some(n => n.text === '正在聆听，最长 60 秒'));
    const input = find(nodes, 'chat-input'); assert.ok(input);
    assert.ok(input.enabled === false || input.enabled === 'false');
    console.log('PASS: real system engine reached Listening; text input is locked.');
    const holdMs = Number(process.env.SPEECH_TEST_HOLD_MS || '0');
    if (!Number.isFinite(holdMs) || holdMs < 0 || holdMs > 45000) throw new Error('Invalid hold duration');
    if (holdMs > 0) {
      await pause(holdMs);
      const held = layout();
      assert.ok(find(held, 'speech-finish'), 'Dictation ended during a pause before the duration cap');
      console.log('PASS: dictation stayed active through a ' + holdMs + ' ms pause.');
    }
    click('speech-cancel'); started = false;
    const idle = await waitFor(items => !find(items, 'speech-cancel') && !!find(items, 'chat-speech'));
    assert.ok(find(idle, 'chat-input').enabled === true || find(idle, 'chat-input').enabled === 'true');
    console.log('PASS: cancellation removed controls and restored keyboard input.');
  } finally {
    if (started && find(layout(), 'speech-cancel')) click('speech-cancel');
    // Only this test's exact temporary device file is removed.
    shell('rm', '-f', layoutPath);
  }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
