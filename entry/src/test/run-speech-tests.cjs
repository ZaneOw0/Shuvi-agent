// Host regression only: native speech/permission calls are injected, never real microphone acceptance.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const sdk = process.env.DEVECO_SDK_HOME;
if (!sdk) throw new Error('Set DEVECO_SDK_HOME to the installed SDK.');
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../main/ets/services/speech');

function harness(options = {}) {
  let now = 0, next = 0;
  const timers = new Map();
  const schedule = (fn, ms) => { timers.set(++next, { fn, at: now + ms }); return next; };
  function advance(ms) {
    now += ms;
    for (;;) {
      const due = [...timers].find(([, t]) => t.at <= now);
      if (!due) break;
      timers.delete(due[0]); due[1].fn();
    }
  }
  const cache = new Map();
  const fileData = new Map(); const directories = new Set(['/test']); const handles = new Map(); let fd = 0;
  const files = {
    OpenMode: { CREATE: 1, READ_WRITE: 2, TRUNC: 4, READ_ONLY: 8 },
    accessSync: name => fileData.has(name) || directories.has(name),
    mkdirSync(name) { directories.add(name); },
    openSync(name, mode) { handles.set(++fd, name); if (mode & 1) fileData.set(name, new Uint8Array()); return { fd }; },
    closeSync() {}, fsyncSync() {},
    writeSync(id, bytes) { fileData.set(handles.get(id), new Uint8Array(bytes.slice(0))); return options.shortWrite ? bytes.byteLength - 2 : bytes.byteLength; },
    readSync(id, bytes) { const data = fileData.get(handles.get(id)); new Uint8Array(bytes).set(data); return data.length; },
    renameSync(from, to) { fileData.set(to, fileData.get(from)); fileData.delete(from); },
    unlinkSync(name) { if (!fileData.delete(name)) throw new Error('missing file'); },
    statSync(name) { if (!fileData.has(name)) throw new Error('missing file'); return { size: fileData.get(name).length }; },
    listFileSync(name) { return [...fileData.keys()].filter(key => key.startsWith(name + '/')).map(key => key.slice(name.length + 1)); }
  };
  let readData;
  const capture = { state: 1, on(type, callback) { if (type === 'readData') readData = callback; },
    off() { readData = undefined; }, async start() { capture.state = 2; },
    async stop() { capture.state = 3; }, async release() { capture.state = 4; },
    emit(bytes) { readData?.(bytes); } };
  const audio = {
    AudioDataCallbackResult: { VALID: 0, INVALID: -1 }, StreamUsage: { STREAM_USAGE_VOICE_MESSAGE: 5 },
    createAudioRenderer: value => options.createRenderer(value),
    AudioState: { STATE_RUNNING: 2, STATE_RELEASED: 4 }, AudioSamplingRate: { SAMPLE_RATE_16000: 16000 },
    AudioChannel: { CHANNEL_1: 1 }, AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 },
    AudioEncodingType: { ENCODING_TYPE_RAW: 0 }, SourceType: { SOURCE_TYPE_VOICE_RECOGNITION: 1 },
    async createAudioCapturer(value) { if (options.captureError) throw new Error('capture unavailable'); return capture; }
  };
  const intervals = new Set();
  const repeat = (fn, ms) => {
    const id = ++next; intervals.add(id);
    const tick = () => { fn(); if (intervals.has(id)) timers.set(id, { fn: tick, at: now + ms }); };
    timers.set(id, { fn: tick, at: now + ms }); return id;
  };
  function load(name) {
    if (cache.has(name)) return cache.get(name);
    const module = { exports: {} };
    const source = fs.readFileSync(path.join(root, name + '.ets'), 'utf8');
    const output = ts.transpileModule(source, { compilerOptions: {
      target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS
    }}).outputText;
    new Function('require', 'module', 'exports', 'setTimeout', 'clearTimeout', 'canIUse', 'setInterval', 'clearInterval', output)(id => {
      if (id === '@kit.AbilityKit') return { abilityAccessCtrl: {
        createAtManager: () => ({ requestPermissionsFromUser: options.permission || (async () => ({ authResults: [0] })) })
      }};
      if (id === '@kit.CoreFileKit') return { fileIo: files };
      if (id === '@kit.AudioKit') return { audio };
      if (id === '@kit.CoreSpeechKit') return { speechRecognizer: { createEngine: options.createEngine } };
      if (id.startsWith('./')) return load(id.slice(2));
      throw new Error('Unexpected import: ' + id);
    }, module, module.exports, schedule, id => timers.delete(id), () => options.supported !== false, repeat, id => { intervals.delete(id); timers.delete(id); });
    cache.set(name, module.exports);
    return module.exports;
  }
  const { SpeechSession, SpeechPhase } = load('SpeechSession');
  let events, creates = 0, starts = 0, finishes = 0, cancels = 0, shutdowns = 0;
  let shutdownError = false;
  const handle = {
    start() { starts++; if (options.startError) throw new Error('start failed'); events.started(); },
    finish() { finishes++; if (options.finishError) throw new Error('finish failed'); },
    cancel() { cancels++; if (options.cancelError) throw new Error('cancel failed'); },
    shutdown() { shutdowns++; if (shutdownError) throw new Error('shutdown failed'); return options.shutdownPromise; }
  };
  const port = {
    authorize: options.authorize || (async () => {}),
    async create(id, listener) { creates++; events = listener; return options.create ? options.create(handle) : handle; }
  };
  const session = new SpeechSession(port);
  const { VoiceArchive } = load('VoiceArchive'); const archive = new VoiceArchive(); archive.bind({ filesDir: '/test' });
  return { session, SpeechPhase, load, advance, handle, archive, fileData, capture,
    events: () => events, counts: () => ({ creates, starts, finishes, cancels, shutdowns }),
    shutdownError: value => { shutdownError = value; }, timerCount: () => timers.size };
}

function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }
async function flush() { for (let i = 0; i < 24; i++) await Promise.resolve(); }

test('intermediate revisions replace preview; only finalized text is committed on completion', async () => {
  const h = harness(); await h.session.start();
  h.events().result('明', false, false); await flush(); h.events().result('明天开会', false, false); await flush();
  assert.equal(h.session.snapshot().preview, '明天开会');
  assert.equal(h.session.snapshot().text, '');
  h.events().result('明天开会。', true, true); await flush(); h.events().complete(); await flush();
  assert.equal(h.session.snapshot().text, '明天开会。');
  assert.equal(h.session.snapshot().phase, h.SpeechPhase.Ready);
  assert.equal(h.counts().shutdowns, 1); assert.equal(h.timerCount(), 0);
});

test('final clauses are assembled without appending every intermediate revision', async () => {
  const h = harness(); await h.session.start();
  h.events().result('第一句。', true, false); await flush(); h.events().result('第二', false, false); await flush();
  h.events().result('第二句。', true, true); await flush(); h.events().complete(); await flush();
  assert.equal(h.session.snapshot().text, '第一句。第二句。');
});

test('duplicate terminal result and completion cannot duplicate committed text', async () => {
  const h = harness(); await h.session.start(); const events = h.events();
  events.result('你好', true, true); await flush(); events.result('你好', true, true); await flush(); events.complete(); await flush();
  const id = h.session.snapshot().resultId; events.complete(); await flush();
  assert.equal(h.session.snapshot().text, '你好'); assert.equal(h.session.snapshot().resultId, id);
});

test('finish waits for final callbacks and releases the engine', async () => {
  const h = harness(); await h.session.start(); h.session.finish(); await flush(); h.session.finish(); await flush();
  assert.equal(h.counts().finishes, 1); assert.equal(h.session.snapshot().text, '');
  h.events().result('完成', true, true); await flush(); h.events().complete(); await flush();
  assert.equal(h.session.snapshot().text, '完成'); assert.equal(h.counts().shutdowns, 1);
});

test('cancel suppresses all late results and completion', async () => {
  const h = harness(); await h.session.start(); const events = h.events(); await h.session.cancel();
  events.result('迟到结果', true, true); await flush(); events.complete(); await flush(); events.failed('late'); await flush();
  assert.equal(h.session.snapshot().text, ''); assert.equal(h.session.snapshot().phase, h.SpeechPhase.Idle);
});

test('permission denied leaves keyboard available and never creates an engine', async () => {
  const h = harness({ authorize: async () => { throw new Error('permission denied'); } });
  await h.session.start(); assert.equal(h.counts().creates, 0);
  assert.equal(h.session.busy(), false); assert.match(h.session.snapshot().message, /permission/);
});

test('cancel during permission prompt does not start recording after permission resolves', async () => {
  const gate = deferred(); const h = harness({ authorize: () => gate.promise });
  const pending = h.session.start(); await h.session.cancel(); gate.resolve(); await pending;
  assert.equal(h.counts().creates, 0); assert.equal(h.session.busy(), false);
});

test('cancel during creation releases a late engine without starting it', async () => {
  const gate = deferred(); const h = harness({ create: () => gate.promise });
  const pending = h.session.start(); await flush(); await h.session.cancel();
  await h.session.start(); assert.equal(h.counts().creates, 1);
  gate.resolve(h.handle); await pending;
  assert.equal(h.counts().starts, 0); assert.equal(h.counts().shutdowns, 1);
});

test('background cancels; foreground permits a fresh session with stale callback isolation', async () => {
  const h = harness(); await h.session.start(); const old = h.events(); h.session.setForeground(false); await flush();
  await h.session.start(); assert.equal(h.counts().creates, 1);
  h.session.setForeground(true); await h.session.start();
  old.result('旧会话', true, true); await flush(); old.complete(); await flush();
  assert.equal(h.session.snapshot().phase, h.SpeechPhase.Listening); await h.session.cancel();
});

test('repeated starts cannot acquire concurrent engines', async () => {
  const h = harness(); await Promise.all([h.session.start(), h.session.start()]);
  assert.equal(h.counts().creates, 1); await h.session.cancel();
});

test('sixty second cap calls finish and missing completion times out safely', async () => {
  const h = harness(); await h.session.start(); h.advance(60000); await flush();
  assert.equal(h.counts().finishes, 1); h.advance(5000); await flush();
  assert.equal(h.session.snapshot().phase, h.SpeechPhase.Error);
  assert.equal(h.session.snapshot().text, ''); assert.equal(h.counts().shutdowns, 1);
});

test('silence and intermediate-only completion never become sendable text', async () => {
  const h = harness(); await h.session.start(); h.events().result('未确认', false, false); await flush(); h.events().complete(); await flush();
  assert.equal(h.session.snapshot().text, ''); assert.equal(h.session.snapshot().phase, h.SpeechPhase.Error);
});

test('oversized hidden transcripts are retained without truncation and cannot be sent', async () => {
  const h = harness(); await h.session.start(); const text = '字'.repeat(501);
  h.events().result(text, true, true); await flush(); h.events().complete(); await flush();
  assert.equal(h.session.snapshot().text, text); assert.match(h.session.snapshot().message, /上限/);
});

test('invalid result payload fails closed', async () => {
  const h = harness(); await h.session.start(); h.events().result(undefined, true, true); await flush();
  assert.equal(h.session.snapshot().phase, h.SpeechPhase.Error); assert.equal(h.counts().shutdowns, 1);
});

test('failed shutdown retains ownership and blocks restart until release succeeds', async () => {
  const h = harness(); await h.session.start(); h.shutdownError(true); await h.session.cancel();
  assert.equal(h.session.snapshot().cleanupPending, true); await h.session.start();
  assert.equal(h.counts().creates, 1); h.shutdownError(false); await h.session.cancel();
  assert.equal(h.session.busy(), false);
});

test('shutdown is attempted even when native cancellation fails', async () => {
  const h = harness({ cancelError: true }); await h.session.start(); await h.session.cancel();
  assert.equal(h.counts().shutdowns, 1); assert.equal(h.session.busy(), false);
});

test('start failure releases the acquired engine', async () => {
  const h = harness({ startError: true }); await h.session.start();
  assert.equal(h.session.snapshot().phase, h.SpeechPhase.Error); assert.equal(h.counts().shutdowns, 1);
});

test('detach releases recording and stops observer updates', async () => {
  const h = harness(); let updates = 0; h.session.attach(() => { updates++; });
  await h.session.start(); h.session.detach(); await flush(); const before = updates; h.events().complete(); await flush();
  assert.equal(updates, before); assert.equal(h.counts().shutdowns, 1);
});

test('native adapter requests only microphone and uses offline continuous PCM recognition', async () => {
  let request, creation, start, listener, finishes = 0, cancels = 0, shutdowns = 0;
  const engine = { setListener(value) { listener = value; }, startListening(value) { start = value; },
    finish() { finishes++; }, cancel() { cancels++; }, shutdown() { shutdowns++; } };
  const h = harness({ permission: async (ctx, permissions) => { request = permissions; return { authResults: [0] }; },
    createEngine: async params => { creation = params; return engine; } });
  const { HarmonySpeechPort } = h.load('HarmonySpeechPort'); const port = new HarmonySpeechPort(h.archive);
  port.bind({}); await port.authorize(); let text = '';
  const handle = await port.create('current', { started() {}, result(value) { text = value; }, complete() {}, failed() {} });
  handle.start(); assert.deepEqual(request, ['ohos.permission.MICROPHONE']);
  assert.equal(creation.online, 1); assert.equal(creation.language, 'zh-CN');
  assert.equal(creation.extraParams.recognizerMode, 'long');
  assert.equal(start.extraParams.vadEnd, undefined);
  assert.equal(start.extraParams.recognitionMode, 1); assert.equal(start.extraParams.maxAudioDuration, 60000);
  assert.deepEqual(start.audioInfo, { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 });
  listener.onResult('wrong', { result: 'wrong', isFinal: true, isLast: true }); assert.equal(text, '');
  listener.onResult('current', { result: '正确', isFinal: true, isLast: true }); assert.equal(text, '正确');
  handle.finish(); await flush(); handle.cancel(); await handle.shutdown(); assert.deepEqual([finishes, cancels, shutdowns], [1, 1, 1]);
});

test('unsupported native capability does not ask for microphone permission', async () => {
  let requests = 0; const h = harness({ supported: false, permission: async () => { requests++; } });
  const { HarmonySpeechPort } = h.load('HarmonySpeechPort'); const port = new HarmonySpeechPort(h.archive); port.bind({});
  await assert.rejects(port.authorize(), /不支持/); assert.equal(requests, 0);
});

test('native denied permission is not treated as granted', async () => {
  const h = harness({ permission: async () => ({ authResults: [-1] }) });
  const { HarmonySpeechPort } = h.load('HarmonySpeechPort'); const port = new HarmonySpeechPort(h.archive); port.bind({});
  await assert.rejects(port.authorize(), /未允许/);
});

test('creation timeout releases an engine arriving after the timeout without starting it', async () => {
  const gate = deferred(); const h = harness({ create: () => gate.promise });
  const pending = h.session.start(); await flush(); h.advance(15000); await flush();
  assert.equal(h.session.snapshot().phase, h.SpeechPhase.Error);
  gate.resolve(h.handle); await pending;
  assert.equal(h.counts().starts, 0); assert.equal(h.counts().shutdowns, 1);
  assert.equal(h.session.busy(), false);
});

test('a finalized clause and long pause do not end dictation before manual finish or the duration cap', async () => {
  const h = harness(); await h.session.start(); h.events().result('第一句。', true, false); await flush();
  h.advance(12000); await flush(); assert.equal(h.session.snapshot().phase, h.SpeechPhase.Listening);
  assert.equal(h.counts().finishes, 0);
  h.events().result('第二句。', true, false); await flush(); h.session.finish(); await flush();
  h.events().complete(); await flush(); assert.equal(h.session.snapshot().text, '第一句。第二句。');
});

test('finish failure releases the microphone and produces no text', async () => {
  const h = harness({ finishError: true }); await h.session.start(); h.session.finish(); await flush();
  assert.equal(h.session.snapshot().phase, h.SpeechPhase.Error);
  assert.equal(h.counts().shutdowns, 1); assert.equal(h.session.snapshot().text, '');
});

test('engine error after a final clause still cannot commit an unsuccessful session', async () => {
  const h = harness(); await h.session.start(); h.events().result('尚未完成', true, true); await flush();
  h.events().failed('engine error'); await flush(); h.events().complete(); await flush();
  assert.equal(h.session.snapshot().text, ''); assert.equal(h.session.snapshot().phase, h.SpeechPhase.Error);
});

test('late engine with failed shutdown remains owned and can be released by retrying cancel', async () => {
  const gate = deferred(); const h = harness({ create: () => gate.promise });
  const pending = h.session.start(); await flush(); await h.session.cancel(); h.shutdownError(true);
  gate.resolve(h.handle); await pending;
  assert.equal(h.session.snapshot().cleanupPending, true);
  h.shutdownError(false); await h.session.cancel(); assert.equal(h.session.busy(), false);
});

test('native listener setup failure never starts a microphone without callbacks', async () => {
  let starts = 0, shutdowns = 0;
  const engine = { setListener() { throw new Error('listener failed'); }, startListening() { starts++; },
    cancel() {}, shutdown() { if (++shutdowns === 1) throw new Error('release failed'); } };
  const h = harness({ createEngine: async () => engine });
  const { HarmonySpeechPort } = h.load('HarmonySpeechPort'); const { SpeechSession } = h.load('SpeechSession');
  const port = new HarmonySpeechPort(h.archive); port.bind({}); const session = new SpeechSession(port);
  await session.start(); assert.equal(starts, 0); assert.equal(shutdowns, 1);
  assert.equal(session.snapshot().phase, h.SpeechPhase.Error); assert.equal(session.busy(), true);
  await session.cancel(); assert.equal(shutdowns, 2); assert.equal(session.busy(), false);
});

test('PCM recording is bounded at sixty seconds and ASR tail packets are zero padded', () => {
  const h = harness(); const { VoicePcmBuffer } = h.load('VoiceAudio'); const buffer = new VoicePcmBuffer();
  buffer.append(Uint8Array.from([1, 2, 3, 4]).buffer);
  assert.equal(buffer.packet(false), undefined);
  const packet = buffer.packet(true); assert.equal(packet.length, 640);
  assert.deepEqual([...packet.slice(0, 6)], [1, 2, 3, 4, 0, 0]); assert.equal(buffer.bytes().length, 4);
  const capped = new VoicePcmBuffer(); assert.equal(capped.append(new Uint8Array(1920002).buffer), true);
  assert.equal(capped.bytes().length, 1920000);
});

test('WAV archive survives reopening and stores audio without transcript metadata', () => {
  const h = harness(); const id = 'shuvi-speech-1700000000000-1'; const pcm = new Uint8Array(3200).fill(7);
  const clip = h.archive.save(id, pcm); assert.equal(clip.durationMs, 100);
  const { VoiceArchive } = h.load('VoiceArchive'); const reopened = new VoiceArchive(); reopened.bind({ filesDir: '/test' });
  const saved = reopened.list(); assert.equal(saved.length, 1); assert.equal(saved[0].id, id);
  assert.deepEqual(reopened.read(saved[0]), pcm);
  assert.equal([...h.fileData.keys()].filter(key => key.endsWith('.tmp')).length, 0);
  assert.equal([...h.fileData.keys()].filter(key => key.endsWith('.json')).length, 0);
  reopened.remove(saved[0]); assert.equal(reopened.list().length, 0);
});

test('recording archive rejects path traversal and does not trust a message file path', () => {
  const h = harness(); const clip = h.archive.save('shuvi-speech-1700000000000-2', new Uint8Array(640));
  clip.path = '/unrelated/private-file'; assert.equal(h.archive.read(clip).length, 640);
  assert.throws(() => h.archive.remove({ id: '../../unrelated' }), /标识/);
  assert.equal(h.archive.list().length, 1);
});

test('WAV decoding rejects corrupted audio headers', () => {
  const h = harness(); const { voiceWave, voicePcm } = h.load('VoiceAudio');
  const wave = voiceWave(new Uint8Array(640)); wave[24] = 0;
  assert.throws(() => voicePcm(wave), /格式/);
});

test('real adapter streams capture packets and archives the exact original PCM before delivering a voice result', async () => {
  let listener, params; const packets = [];
  const engine = { setListener(value) { listener = value; }, startListening(value) { params = value; listener.onStart(value.sessionId, 'ok'); },
    writeAudio(id, bytes) { packets.push(bytes); },
    finish(id) { listener.onResult(id, { result: '后台理解用', isFinal: true, isLast: true }); listener.onComplete(id, 'done'); },
    cancel() {}, shutdown() {} };
  const h = harness({ createEngine: async () => engine });
  const { SpeechSession } = h.load('SpeechSession'); const { HarmonySpeechPort } = h.load('HarmonySpeechPort');
  const port = new HarmonySpeechPort(h.archive); port.bind({}); const session = new SpeechSession(port);
  await session.start(); await flush(); assert.equal(session.snapshot().phase, h.SpeechPhase.Listening);
  const original = new Uint8Array(960).fill(9); h.capture.emit(original.buffer);
  h.advance(20); await flush(); assert.equal(packets.length, 1);
  session.finish(); await flush(); h.advance(20); await flush();
  assert.equal(packets.length, 2); assert.equal(packets[1][319], 9); assert.equal(packets[1][320], 0);
  assert.equal(session.snapshot().phase, h.SpeechPhase.Ready);
  assert.ok(session.snapshot().clip); assert.deepEqual(h.archive.read(session.snapshot().clip), original);
  assert.equal(h.capture.state, 4);
});

test('cancelled recording is released without creating a saved audio file', async () => {
  let listener;
  const engine = { setListener(value) { listener = value; }, startListening(value) { listener.onStart(value.sessionId, 'ok'); },
    writeAudio() {}, finish() {}, cancel() {}, shutdown() {} };
  const h = harness({ createEngine: async () => engine });
  const { SpeechSession } = h.load('SpeechSession'); const { HarmonySpeechPort } = h.load('HarmonySpeechPort');
  const port = new HarmonySpeechPort(h.archive); port.bind({}); const session = new SpeechSession(port);
  await session.start(); await flush(); h.capture.emit(new Uint8Array(640).buffer);
  await session.cancel(); assert.equal(h.archive.list().length, 0); assert.equal(h.capture.state, 4);
});

test('microphone creation failure releases the initialized ASR engine', async () => {
  let listener, closed = 0;
  const engine = { setListener(value) { listener = value; }, startListening(value) { listener.onStart(value.sessionId, 'ok'); },
    writeAudio() {}, finish() {}, cancel() {}, shutdown() { closed++; } };
  const h = harness({ createEngine: async () => engine, captureError: true });
  const { SpeechSession } = h.load('SpeechSession'); const { HarmonySpeechPort } = h.load('HarmonySpeechPort');
  const port = new HarmonySpeechPort(h.archive); port.bind({}); const session = new SpeechSession(port);
  await session.start(); await flush(); assert.equal(closed, 1); assert.equal(session.snapshot().phase, h.SpeechPhase.Error);
});

test('voice UI excludes transcript preview and input binding; saved audio is excluded from system backup', () => {
  const entry = path.resolve(root, '../..');
  const page = fs.readFileSync(path.join(entry, 'pages/Index.ets'), 'utf8');
  assert.equal(page.includes('Text(this.speech.preview)'), false);
  assert.equal(page.includes('this.input = view.text'), false);
  assert.ok(page.includes('this.hiddenVoiceQueries.has(this.runtimeSearch.query)'));
  assert.ok(page.includes('this.hiddenVoiceQueries.has(this.runtimeKnowledge.query'));
  const bubble = fs.readFileSync(path.join(entry, 'components/VoiceMessageBubble.ets'), 'utf8');
  assert.equal(/transcript|\.text\b|voiceText/.test(bubble), false);
  const backup = JSON.parse(fs.readFileSync(path.join(entry, '../resources/base/profile/backup_config.json'), 'utf8'));
  assert.ok(backup.excludes.includes('/data/storage/el2/base/files/voice_messages/'));
});

test('finished audio survives a transcription timeout and remains available for playback', async () => {
  let listener;
  const engine = { setListener(value) { listener = value; }, startListening(value) { listener.onStart(value.sessionId, 'ok'); },
    writeAudio() {}, finish() {}, cancel() {}, shutdown() {} };
  const h = harness({ createEngine: async () => engine });
  const { SpeechSession } = h.load('SpeechSession'); const { HarmonySpeechPort } = h.load('HarmonySpeechPort');
  const port = new HarmonySpeechPort(h.archive); port.bind({}); const session = new SpeechSession(port);
  await session.start(); await flush(); h.capture.emit(new Uint8Array(640).buffer);
  session.finish(); await flush(); assert.equal(h.archive.list().length, 1);
  h.advance(5000); await flush();
  assert.equal(session.snapshot().phase, h.SpeechPhase.Error); assert.ok(session.snapshot().clip);
  assert.equal(h.archive.read(h.archive.list()[0]).length, 640); assert.equal(h.capture.state, 4);
});

test('partial archive write is rejected and leaves no audio or temporary file', () => {
  const h = harness({ shortWrite: true });
  assert.throws(() => h.archive.save('shuvi-speech-1700000000000-3', new Uint8Array(640)), /保存失败/);
  assert.equal(h.fileData.size, 0);
});

test('playback renders original PCM then releases its audio renderer', async () => {
  let write;
  const renderer = { state: 1, on(type, callback) { write = callback; }, off() {},
    async start() { renderer.state = 2; }, async stop() { renderer.state = 3; }, async release() { renderer.state = 4; } };
  const h = harness({ createRenderer: async () => renderer });
  const clip = h.archive.save('shuvi-speech-1700000000000-4', new Uint8Array(640).fill(8));
  const { VoicePlayback } = h.load('VoicePlayback'); const player = new VoicePlayback(h.archive);
  let playing = ''; player.attach(id => { playing = id; }); await player.play(clip); assert.equal(playing, clip.id);
  const output = new ArrayBuffer(1280); write(output);
  assert.equal(new Uint8Array(output)[639], 8); assert.equal(new Uint8Array(output)[640], 0);
  h.advance(200); await flush(); assert.equal(renderer.state, 4); assert.equal(playing, '');
});

test('leaving while a playback renderer is being created never starts late audio', async () => {
  const gate = deferred(); let starts = 0, releases = 0;
  const renderer = { async start() { starts++; }, async release() { releases++; } };
  const h = harness({ createRenderer: () => gate.promise });
  const clip = h.archive.save('shuvi-speech-1700000000000-5', new Uint8Array(640));
  const { VoicePlayback } = h.load('VoicePlayback'); const player = new VoicePlayback(h.archive);
  const pending = player.play(clip); await flush(); await player.stop(); gate.resolve(renderer); await pending;
  assert.equal(starts, 0); assert.equal(releases, 1);
});


test('repeated cancel shares pending native release instead of double releasing resources', async () => {
  const gate = deferred(); const h = harness({ shutdownPromise: gate.promise }); await h.session.start();
  const first = h.session.cancel(); const second = h.session.cancel();
  assert.equal(h.counts().shutdowns, 1); gate.resolve(); await Promise.all([first, second]);
  assert.equal(h.session.busy(), false); assert.equal(h.session.snapshot().phase, h.SpeechPhase.Idle);
});


test('late playback creation failure cannot stop a newer voice message', async () => {
  let rejectOld; const old = new Promise((resolve, reject) => { rejectOld = reject; }); let requests = 0;
  const renderer = { state: 1, on() {}, off() {}, async start() { renderer.state = 2; },
    async stop() { renderer.state = 3; }, async release() { renderer.state = 4; } };
  const h = harness({ createRenderer: () => ++requests === 1 ? old : Promise.resolve(renderer) });
  const first = h.archive.save('shuvi-speech-1700000000000-6', new Uint8Array(640));
  const second = h.archive.save('shuvi-speech-1700000000000-7', new Uint8Array(640));
  const { VoicePlayback } = h.load('VoicePlayback'); const player = new VoicePlayback(h.archive);
  const pending = player.play(first); await flush(); await player.play(second);
  rejectOld(new Error('old create failed')); await pending; assert.equal(renderer.state, 2); await player.stop();
});

// Exercise the real page send method with injected runtime sessions; no provider requests.
function voiceSendFixture(kind = 'chat', sendResult = true) {
  const h = harness();
  const page = fs.readFileSync(path.resolve(root, '../../pages/Index.ets'), 'utf8');
  const method = page.match(/  private async sendVoice\(\): Promise<void> \{[\s\S]*?\n  \}/);
  assert.ok(method, 'Voice send method not found');
  const code = ts.transpileModule('class VoiceSendFixture {\n' + method[0] + '\n}', {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.None }
  }).outputText;
  const calls = [], notices = [];
  const runtime = name => ({ session: { async send(text) { calls.push({ name, text }); const result = await sendResult; if (result === false) throw new Error('InjectedSendRejected'); return result; } } });
  const fixture = new Function('composeVoiceMessage', 'ShuviRuntimeState', 'RuntimeChatService', 'RuntimeSearchService',
    'RuntimeKnowledgeService', 'Edge', code + '; return new VoiceSendFixture();')(
    h.load('VoiceAudio').composeVoiceMessage, { READY: 'ready' }, runtime('chat'), runtime('search'), { session: {} }, { Bottom: 1 });
  const clip = { id: 'voice-test', path: '/local/voice.wav', durationMs: 1000, createdAt: 1 };
  Object.assign(fixture, { voiceDraft: clip, voiceText: '语音里的要求', input: '另外请列成三点',
    realChatMode: true, searchEnabled: kind === 'search', knowledgeEnabled: kind === 'knowledge',
    runtimeChat: { lifecycle: 'ready', requestCount: 0, maxRequests: 10 },
    runtimeSearch: { lifecycle: 'ready', allowance: true }, runtimeKnowledge: { lifecycle: 'ready' },
    service: { nextId: () => 'message-test' }, messages: [], hiddenVoiceQueries: new Set(), alive: true,
    scroller: { scrollEdge() {} }, blocked: () => false, notice: (...args) => notices.push(args) });
  return { fixture, calls, notices, clip };
}

test('voice composition retains both inputs with a clear paragraph boundary', () => {
  const combine = harness().load('VoiceAudio').composeVoiceMessage;
  assert.equal(combine('  语音内容  ', '  补充说明  '), '语音内容\n\n补充说明');
  assert.equal(combine('语音内容', ' \n '), '语音内容');
  assert.equal(combine(' ', '补充说明'), '');
});

test('voice and supplement are sent as one chat request while only the supplement is visible', async () => {
  const { fixture, calls, clip } = voiceSendFixture(); await fixture.sendVoice();
  assert.deepEqual(calls, [{ name: 'chat', text: '语音里的要求\n\n另外请列成三点' }]);
  assert.equal(fixture.messages.length, 1); assert.equal(fixture.messages[0].voice, clip);
  assert.equal(fixture.messages[0].text, '另外请列成三点');
  assert.equal(fixture.input, ''); assert.equal(fixture.voiceDraft, undefined);
});

test('voice without a supplement preserves the existing voice-only payload', async () => {
  const { fixture, calls } = voiceSendFixture(); fixture.input = '  '; await fixture.sendVoice();
  assert.equal(calls[0].text, '语音里的要求'); assert.equal(fixture.messages[0].text, '');
});

test('search receives one combined request and registers the combined query as hidden', async () => {
  const { fixture, calls } = voiceSendFixture('search'); await fixture.sendVoice();
  assert.deepEqual(calls, [{ name: 'search', text: '语音里的要求\n\n另外请列成三点' }]);
  assert.ok(fixture.hiddenVoiceQueries.has(calls[0].text)); assert.equal(fixture.searchVoiceQuery, true);
});

test('shared assistant rejection with knowledge enabled restores both drafts without joining twice on retry', async () => {
  const { fixture, calls, clip } = voiceSendFixture('knowledge', false); await fixture.sendVoice();
  assert.equal(fixture.voiceDraft, clip); assert.equal(fixture.voiceText, '语音里的要求');
  assert.equal(fixture.input, '另外请列成三点'); assert.equal(fixture.messages.length, 0);
  await fixture.sendVoice(); assert.equal(calls.length, 2); assert.equal(calls[1].text, calls[0].text);
});

test('unavailable assistant keeps both parts of the draft and sends nothing', async () => {
  const { fixture, calls, notices, clip } = voiceSendFixture(); fixture.runtimeChat.lifecycle = 'stopped';
  await fixture.sendVoice(); assert.equal(calls.length, 0); assert.equal(notices.length, 1);
  assert.equal(fixture.voiceDraft, clip); assert.equal(fixture.voiceText, '语音里的要求');
  assert.equal(fixture.input, '另外请列成三点');
});

test('combined length includes the separator and refuses excess without truncating either part', async () => {
  const { fixture, calls } = voiceSendFixture(); fixture.voiceText = '语'.repeat(490); fixture.input = '字'.repeat(9);
  await fixture.sendVoice(); assert.equal(calls.length, 0); assert.equal(fixture.input.length, 9);
  fixture.input = '字'.repeat(8); await fixture.sendVoice(); assert.equal(calls.length, 1);
  assert.equal(calls[0].text.length, 500);
});

test('a late failed voice send cannot overwrite newly typed text', async () => {
  const gate = deferred(); const { fixture, calls } = voiceSendFixture('knowledge', gate.promise);
  const pending = fixture.sendVoice(); await flush(); fixture.input = '新的草稿'; gate.resolve(false); await pending;
  assert.equal(calls.length, 1); assert.equal(fixture.input, '新的草稿'); assert.equal(fixture.messages.length, 0);
});

test('voice plus text still requires the real assistant and never dispatches a mock request', async () => {
  const { fixture, calls, clip } = voiceSendFixture(); fixture.realChatMode = false; await fixture.sendVoice();
  assert.equal(calls.length, 0); assert.equal(fixture.voiceDraft, clip); assert.equal(fixture.input, '另外请列成三点');
});

test('dismissing a saved voice notice preserves transcript, clip and result identity', async () => {
  const h = harness(); const clip = { id: 'saved', durationMs: 1000 }; h.handle.clip = () => clip;
  await h.session.start(); h.events().result('后台文字', true, true); await flush(); h.events().complete(); await flush();
  const before = h.session.snapshot(); h.session.dismissMessage(); const after = h.session.snapshot();
  assert.equal(after.message, ''); assert.equal(after.phase, before.phase); assert.equal(after.text, before.text);
  assert.equal(after.clip, clip); assert.equal(after.resultId, before.resultId); assert.equal(h.counts().shutdowns, 1);
});

test('dismissing recognition failure keeps saved audio and a later session can show its own notice', async () => {
  const h = harness(); const clip = { id: 'saved-on-error', durationMs: 1000 }; h.handle.clip = () => clip;
  await h.session.start(); h.events().failed('识别失败'); await flush(); h.session.dismissMessage();
  assert.equal(h.session.snapshot().message, ''); assert.equal(h.session.snapshot().clip, clip);
  assert.equal(h.session.snapshot().phase, h.SpeechPhase.Error);
  await h.session.start(); h.events().failed('识别失败'); await flush(); assert.equal(h.session.snapshot().message, '识别失败');
});

test('dismiss does not hide active recording or an unconfirmed microphone release', async () => {
  const h = harness(); await h.session.start(); const message = h.session.snapshot().message;
  h.session.dismissMessage(); assert.equal(h.session.snapshot().message, message); assert.equal(h.counts().cancels, 0);
  h.shutdownError(true); await h.session.cancel(); const warning = h.session.snapshot().message;
  h.session.dismissMessage(); assert.equal(h.session.snapshot().message, warning);
  h.shutdownError(false); await h.session.cancel();
});


test('knowledge authorized voice uses the ordinary assistant loop and never the removed knowledge send API', async () => {
  const { fixture, calls, clip } = voiceSendFixture('knowledge'); await fixture.sendVoice();
  assert.deepEqual(calls, [{ name: 'chat', text: '语音里的要求\n\n另外请列成三点' }]);
  assert.equal(fixture.messages[0].voice, clip); assert.equal(fixture.messages[0].text, '另外请列成三点');
  assert.equal(fixture.knowledgeVoiceQuery, true); assert.equal(fixture.searchVoiceQuery, false);
  assert.ok(fixture.hiddenVoiceQueries.has(calls[0].text));
});

test('knowledge readiness cannot bypass the shared assistant readiness or remaining request budget', async () => {
  for (const reason of ['stopped', 'budget']) {
    const { fixture, calls, clip } = voiceSendFixture('knowledge');
    if (reason === 'stopped') fixture.runtimeChat.lifecycle = 'stopped'; else fixture.runtimeChat.requestCount = 10;
    await fixture.sendVoice();assert.equal(calls.length, 0);assert.equal(fixture.messages.length, 0);
    assert.equal(fixture.voiceDraft, clip);assert.equal(fixture.input, '另外请列成三点');
  }
});

test('page back cancels active speech before closing PDF and preserves normal drawer navigation', () => {
  const page=fs.readFileSync(path.resolve(root,'../../pages/Index.ets'),'utf8');
  const method=page.match(/  onBackPress\(\): boolean \{[\s\S]*?\n  \}/);assert.ok(method);
  const code=ts.transpileModule('class BackFixture {\n'+method[0]+'\n}',{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.None}}).outputText;
  const calls=[],pdf={shared:{expanded:true,closePreview(){calls.push('pdf');}}};
  const fixture=new Function('SpeechService','PdfJsRuntime',code+';return new BackFixture();')({session:{cancel(){calls.push('speech');}}},pdf);
  fixture.speech={busy:true};assert.equal(fixture.onBackPress(),true);assert.deepEqual(calls,['speech']);
  fixture.speech.busy=false;assert.equal(fixture.onBackPress(),true);assert.deepEqual(calls,['speech','pdf']);
  pdf.shared.expanded=false;fixture.drawerOpen=true;assert.equal(fixture.onBackPress(),true);assert.equal(fixture.drawerOpen,false);
});
