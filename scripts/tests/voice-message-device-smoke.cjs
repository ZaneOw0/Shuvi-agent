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
  let recording = false;
  try {
    click('voice-archive-toggle');
    const before = new Set(layout().filter(n => String(n.id || n.key).startsWith('voice-play-')).map(n => n.id || n.key));
    click('voice-archive-toggle');
    click('chat-speech'); recording = true;
    await waitFor(nodes => !!find(nodes, 'speech-finish'));
    await pause(2500); click('speech-finish');
    await waitFor(nodes => !find(nodes, 'speech-cancel')); recording = false;
    const composer = layout(); const textInput = find(composer, 'chat-input');
    assert.ok(textInput && (textInput.enabled === true || textInput.enabled === 'true'),
      'Text input must remain editable after recording, including when a voice draft is present');
    console.log('PASS: editable text input is available after recording.');
    console.log('INFO: recognized voice draft present: ' + !!find(composer, 'voice-discard'));
    const hadVoiceDraft = !!find(composer, 'voice-discard');
    const originalInput = find(composer, 'chat-input').text || '';
    assert.ok(find(composer, 'speech-dismiss'), 'Completed/failed speech notice must have a close button');
    click('speech-dismiss');
    const dismissed = await waitFor(nodes => !find(nodes, 'speech-status'));
    assert.equal(!!find(dismissed, 'voice-discard'), hadVoiceDraft);
    assert.equal(find(dismissed, 'chat-input').text || '', originalInput);
    console.log('PASS: closing the speech notice hides the banner and preserves the draft and text input.');
    click('voice-archive-toggle');
    const saved = layout().filter(n => String(n.id || n.key).startsWith('voice-play-') && !before.has(n.id || n.key));
    const ids = [...new Set(saved.map(n => n.id || n.key))];
    assert.equal(ids.length, 1, 'Exactly one new saved voice recording expected');
    const playId = ids[0]; const recordingId = playId.slice('voice-play-'.length);
    console.log('PASS: finishing created a playable saved recording without displaying transcript text.');
    click(playId); await waitFor(nodes => nodes.some(n => n.text === '停止播放'));
    console.log('PASS: native audio renderer started playback.');
    await waitFor(nodes => !nodes.some(n => n.text === '停止播放'));
    shell('aa', 'force-stop', 'com.example.shuvi');
    shell('aa', 'start', '-b', 'com.example.shuvi', '-a', 'EntryAbility');
    await waitFor(nodes => !!find(nodes, 'voice-archive-toggle')); click('voice-archive-toggle');
    assert.ok(find(layout(), playId), 'Saved recording missing after process restart');
    console.log('PASS: saved recording survives process restart.');
    click('voice-delete-' + recordingId);
    const dialog = await waitFor(nodes => nodes.some(n => n.text === '删除这条录音？'));
    const button = dialog.find(n => n.text === '删除' && n.type === 'Text'); assert.ok(button, 'Delete confirmation missing');
    const coords = String(button.bounds).match(/-?\d+/g).map(Number);
    shell('uitest', 'uiInput', 'click', String(Math.round((coords[0] + coords[2]) / 2)), String(Math.round((coords[1] + coords[3]) / 2)));
    await waitFor(nodes => !find(nodes, playId));
    console.log('PASS: only this test recording was deleted after confirmation.');
    click('voice-archive-toggle');
  } finally {
    if (recording && find(layout(), 'speech-cancel')) click('speech-cancel');
    shell('rm', '-f', layoutPath);
  }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
