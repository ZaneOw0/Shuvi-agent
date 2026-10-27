// Host-only behavior checks. No device calendar, permissions or model calls.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const sdk = process.env.DEVECO_SDK_HOME;
if (!sdk) throw new Error('Set DEVECO_SDK_HOME.');
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = fs.readFileSync(path.resolve(__dirname, '../main/ets/services/calendar/CalendarProbeSession.ets'), 'utf8');
const compiled = ts.transpileModule(source, {
  fileName: 'CalendarProbeSession.ts',
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText;
const loaded = { exports: {} };
new Function('module', 'exports', compiled)(loaded, loaded.exports);
const { CalendarProbeSession, CalendarProbeDraft, calendarProbeDraftError, parseCalendarProbeRecord } = loaded.exports;
const journalSource = fs.readFileSync(path.resolve(__dirname, '../main/ets/services/calendar/CalendarJournalStore.ets'), 'utf8');
const journalModule = { exports: {} };
new Function('require', 'module', 'exports', ts.transpileModule(journalSource, {
  fileName: 'CalendarJournalStore.ts', compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText)(() => loaded.exports, journalModule, journalModule.exports);
const { CalendarJournalStore } = journalModule.exports;
const now = Date.parse('2026-10-26T10:00:00+08:00');
function draft() {
  return Object.assign(new CalendarProbeDraft(), {
    title: '测试日程', startAt: '2026-10-27T15:00:00+08:00', endAt: '2026-10-27T16:00:00+08:00'
  });
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const tick = () => new Promise(resolve => setImmediate(resolve));
function harness(overrides = {}, shared = { value: undefined }, timeout = 20000) {
  const calls = [];
  const states = [];
  const port = {
    authorize: async () => { calls.push('authorize'); },
    prepare: async () => { calls.push('prepare'); },
    add: async () => { calls.push('add'); return 42; },
    read: async () => { calls.push('read'); return { eventId: 42, matches: true, reminderConfigured: true }; },
    ...overrides.port
  };
  const store = {
    load: async () => shared.value === undefined ? undefined : parseCalendarProbeRecord(shared.value),
    list: async () => { const record = await store.load(); return record === undefined ? [] : [record]; },
    save: async record => { calls.push(`save:${record.eventId}`); shared.value = JSON.stringify(record); },
    ...overrides.store
  };
  const session = new CalendarProbeSession(port, store, () => 'shuvi-calendar-test-001', () => now, timeout);
  session.attach(value => states.push(value));
  return { session, calls, states, shared };
}
async function ready(overrides, shared, timeout) {
  const h = harness(overrides, shared, timeout);
  await tick();
  h.session.preview(draft());
  return h;
}

test('date validation rejects rollover, bad offsets, past reminders and malformed input', () => {
  assert.equal(calendarProbeDraftError(draft(), now), '');
  for (const change of [
    { title: ' ' }, { startAt: '2026-02-30T15:00:00+08:00' },
    { startAt: '2026-10-27T25:00:00+08:00' }, { endAt: '2026-10-27T14:00:00+08:00' },
    { startAt: '2026-10-27T15:00:00Z' }, { timeZone: 'UTC' }, { reminderMinutes: NaN },
    { reminderMinutes: -1 }, { reminderMinutes: 1.5 }, { reminderMinutes: 10081 },
    { startAt: '2026-10-26T10:05:00+08:00' }
  ]) assert.notEqual(calendarProbeDraftError(Object.assign(draft(), change), now), '', JSON.stringify(change));
});

test('confirmation is mandatory, snapshot is immutable and intent is flushed before writing', async () => {
  const h = harness();
  await tick();
  await h.session.confirm();
  assert.deepEqual(h.calls, []);
  const input = draft();
  h.session.preview(input);
  input.title = 'changed';
  h.states.at(-1).draft.title = 'also changed';
  await h.session.confirm();
  assert.deepEqual(h.calls, ['authorize', 'prepare', 'save:-1', 'add', 'save:42', 'read', 'save:42']);
  assert.equal(h.states.at(-1).phase, 'verified');
  assert.equal(JSON.parse(h.shared.value).draft.title, '测试日程');
  await h.session.confirm();
  assert.equal(h.calls.filter(x => x === 'add').length, 1);
});

test('double click while permission is pending does not write twice', async () => {
  const gate = deferred();
  const h = await ready({ port: { authorize: () => gate.promise } });
  const first = h.session.confirm();
  await h.session.confirm();
  gate.resolve();
  await first;
  assert.equal(h.calls.filter(x => x === 'add').length, 1);
});

test('permission denial preserves draft and sends no write', async () => {
  const h = await ready({ port: { authorize: async () => { throw new Error('拒绝权限'); } } });
  await h.session.confirm();
  assert.equal(h.states.at(-1).phase, 'failed');
  assert.equal(h.states.at(-1).draft.title, '测试日程');
  assert.deepEqual(h.calls, []);
});

test('invalid input and cancelled confirmation never reach platform', async () => {
  const h = await ready();
  h.session.cancelDraft();
  await h.session.confirm();
  h.session.preview(Object.assign(draft(), { endAt: 'invalid' }));
  await h.session.confirm();
  assert.deepEqual(h.calls, []);
});

test('leaving during permission or preparation stops before event creation', async () => {
  for (const phase of ['authorize', 'prepare']) {
    const gate = deferred();
    const h = await ready({ port: { [phase]: () => gate.promise } });
    const run = h.session.confirm();
    await tick();
    h.session.detach();
    gate.resolve();
    await run;
    assert(!h.calls.includes('add'));
    assert.equal(h.shared.value, undefined);
  }
});

test('storage failure before write locks the probe and never dispatches add', async () => {
  const h = await ready({ store: { save: async () => { throw new Error('disk'); } } });
  await h.session.confirm();
  h.session.preview(draft());
  await h.session.confirm();
  assert(!h.calls.includes('add'));
  assert.equal(h.states.at(-1).locked, true);
});

test('uncertain write survives restart; recovery only reads and never creates', async () => {
  const h = await ready({ port: { add: async () => { throw new Error('timeout after write'); } } });
  await h.session.confirm();
  assert.equal(h.states.at(-1).phase, 'unknown');
  const recovered = await ready({}, h.shared);
  await recovered.session.confirm();
  assert.deepEqual(recovered.calls, []);
  await recovered.session.reconcile();
  assert.deepEqual(recovered.calls, ['save:-1', 'authorize', 'read', 'save:42']);
  assert.equal(recovered.states.at(-1).phase, 'verified');
});

test('late successful write is recorded after stop without automatic re-dispatch', async () => {
  const gate = deferred();
  const h = await ready({ port: { add: () => gate.promise } });
  const run = h.session.confirm();
  await tick();
  h.session.stop();
  gate.resolve(42);
  await run;
  assert.equal(JSON.parse(h.shared.value).eventId, 42);
  assert.equal(h.states.at(-1).phase, 'unknown');
  assert(!h.calls.includes('read'));
});

test('timeout stops a delayed preparation from dispatching a late write', async () => {
  const gate = deferred();
  const h = await ready({ port: { prepare: () => gate.promise } }, undefined, 5);
  const run = h.session.confirm();
  await new Promise(resolve => setTimeout(resolve, 15));
  assert.equal(h.states.at(-1).phase, 'stopping');
  gate.resolve();
  await run;
  assert(!h.calls.includes('add'));
});

test('missing or inconsistent readback cannot be reported successful', async () => {
  const h = await ready({ port: { read: async () => ({ eventId: -1, matches: false, reminderConfigured: false }) } });
  await h.session.confirm();
  assert.equal(h.states.at(-1).phase, 'unknown');
  await h.session.reconcile();
  assert.equal(h.calls.filter(x => x === 'add').length, 1);
});

test('reminder mismatch is partial success, not an event retry', async () => {
  const h = await ready({ port: { read: async () => ({ eventId: 42, matches: true, reminderConfigured: false }) } });
  await h.session.confirm();
  assert.equal(h.states.at(-1).phase, 'partial');
  assert.equal(h.states.at(-1).eventId, 42);
});

test('corrupt or newer journal fails closed; no default empty record', async () => {
  for (const raw of ['null', '[]', '{', '{}', '{"schemaVersion":2}',
    JSON.stringify({ schemaVersion: 1, operationId: 'shuvi-calendar-a', draft: draft(), eventId: 0 })]) {
    assert.throws(() => parseCalendarProbeRecord(raw));
    const h = await ready({}, { value: raw });
    await h.session.confirm();
    assert.equal(h.states.at(-1).locked, true);
    assert.deepEqual(h.calls, []);
  }
});

test('failure saving the returned event ID still preserves the original intent for recovery', async () => {
  const shared = { value: undefined };
  let saves = 0;
  const h = await ready({ store: { save: async record => {
    if (++saves > 1) throw new Error('disk');
    shared.value = JSON.stringify(record);
  } } }, shared);
  await h.session.confirm();
  assert.equal(h.states.at(-1).phase, 'unknown');
  assert.equal(JSON.parse(shared.value).eventId, -1);
  const recovered = await ready({}, shared);
  await recovered.session.reconcile();
  assert(!recovered.calls.includes('add'));
  assert.equal(recovered.states.at(-1).eventId, 42);
});

// Exercise the real adapter against SDK-shaped fakes; not evidence of device behavior.
function deviceHarness(options = {}) {
  const calls = [];
  const data = new Map();
  const record = { schemaVersion: 1, operationId: 'shuvi-calendar-test-001', draft: draft(), eventId: 42 };
  if (options.recover) data.set('operation', JSON.stringify(record));
  let config = { enableReminder: false };
  const event = {
    id: 42, type: 0, title: draft().title, startTime: Date.parse(draft().startAt),
    endTime: Date.parse(draft().endAt), timeZone: 'Asia/Shanghai', isAllDay: false,
    identifier: record.operationId, reminderTime: [10]
  };
  const calendar = {
    getConfig: () => config,
    setConfig: async value => { calls.push('config'); config = value; },
    addEvent: async value => { calls.push('add'); assert.deepEqual(value.reminderTime, [10]); return 42; },
    getEvents: async () => options.duplicate ? [event, event] : [event]
  };
  let gets = 0;
  const imports = {
    BuildProfile: { DEBUG: true },
    '@kit.AbilityKit': { abilityAccessCtrl: { createAtManager: () => ({ requestPermissionsFromUser: async () => ({
      authResults: options.denied ? [0, -1] : [0, 0]
    }) }) } },
    '@kit.BasicServicesKit': {},
    '@kit.ArkTS': { util: { generateRandomUUID: () => 'test-001' } },
    '@kit.ArkData': { preferences: { getPreferences: async () => ({
      has: async key => data.has(key), get: async key => data.get(key),
      put: async (key, value) => data.set(key, value), flush: async () => {}
    }) } },
    '@kit.CalendarKit': { calendarManager: {
      CalendarType: { LOCAL: 'local' }, EventType: { NORMAL: 0 },
      EventFilter: { filterById: ids => ids, filterByTime: (start, end) => [start, end] },
      getCalendarManager: () => ({
        getCalendar: async account => {
          assert.equal(account.name, 'com.example.shuvi.calendar.probe.v1');
          if (++gets === 1 && options.errorCode) throw { code: options.errorCode };
          return calendar;
        },
        createCalendar: async () => { calls.push('create-account'); return calendar; }
      })
    } },
    './CalendarProbeSession': loaded.exports,
    './CalendarJournalStore': journalModule.exports
  };
  const serviceSource = fs.readFileSync(path.resolve(__dirname, '../main/ets/services/calendar/CalendarProbeService.ets'), 'utf8');
  const code = ts.transpileModule(serviceSource, {
    fileName: 'CalendarProbeService.ts', compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  new Function('require', 'module', 'exports', 'canIUse', code)(id => {
    assert(Object.hasOwn(imports, id), id); return imports[id];
  }, module, module.exports, () => true);
  const service = module.exports.CalendarProbeService;
  service.bind({});
  const states = [];
  service.session.attach(value => states.push(value));
  return { service, states, calls };
}

test('platform adapter only creates a calendar for explicit account-not-found', async () => {
  for (const code of [23900003, 201, 801, 23900004]) {
    const h = deviceHarness({ errorCode: code });
    await tick();
    const value = draft();
    const future = new Date(Date.now() + 86400000 * 3);
    value.startAt = future.toISOString().slice(0, 10) + 'T15:00:00+08:00';
    value.endAt = future.toISOString().slice(0, 10) + 'T16:00:00+08:00';
    h.service.session.preview(value);
    await h.service.session.confirm();
    assert.equal(h.calls.includes('create-account'), code === 23900003);
    assert.equal(h.calls.includes('add'), code === 23900003);
  }
});

test('platform adapter rejects partial permission grant before touching calendar', async () => {
  const h = deviceHarness({ recover: true, denied: true });
  await tick();
  await h.service.session.reconcile();
  assert.deepEqual(h.calls, []);
  assert.equal(h.states.at(-1).phase, 'unknown');
});

test('platform recovery with duplicate identifiers never succeeds or modifies the calendar', async () => {
  const h = deviceHarness({ recover: true, duplicate: true });
  await tick();
  await h.service.session.reconcile();
  assert.deepEqual(h.calls, []);
  assert.equal(h.states.at(-1).phase, 'unknown');
});

function journalHarness(initial = new Map(), failKey) {
  const data = new Map(initial);
  const writes = [];
  const text = {
    read: async key => data.get(key),
    writeAndFlush: async (key, value) => {
      writes.push(key);
      if (key === failKey) throw new Error('flush failure');
      data.set(key, value);
    }
  };
  return { store: new CalendarJournalStore(text), data, writes, text };
}
function record(id = 'shuvi-calendar-legacy') {
  return { schemaVersion: 1, operationId: id, draft: draft(), eventId: 42 };
}

test('v1 migration preserves original bytes and marks verification pending', async () => {
  const original = JSON.stringify({ ...record(), verified: true, reminderConfigured: true });
  const h = journalHarness(new Map([['operation', original]]));
  const list = await h.store.list();
  assert.equal(list.length, 1);
  assert.equal(list[0].eventId, 42);
  assert.equal(list[0].verified, false);
  assert.equal(h.data.get('operation'), original);
  assert.deepEqual(h.writes, ['shuvi-calendar-legacy', 'journal-v2']);
  await h.store.list();
  assert.equal(h.writes.length, 2);
});

test('failed migration does not appear as an empty history or overwrite the legacy record', async () => {
  const original = JSON.stringify(record());
  const h = journalHarness(new Map([['operation', original]]), 'journal-v2');
  await assert.rejects(h.store.list());
  await assert.rejects(h.store.list());
  assert.equal(h.data.get('operation'), original);
  const recovered = new CalendarJournalStore({
    read: async key => h.data.get(key), writeAndFlush: async (key, value) => h.data.set(key, value)
  });
  assert.equal((await recovered.list()).length, 1);
});

test('invalid v2 index, missing entries and duplicate IDs never fall back to a blank history', async () => {
  for (const index of ['{', 'null', JSON.stringify({ schemaVersion: 3, ids: [] }),
    JSON.stringify({ schemaVersion: 2, ids: [] }),
    JSON.stringify({ schemaVersion: 2, ids: ['shuvi-calendar-missing'] }),
    JSON.stringify({ schemaVersion: 2, ids: ['shuvi-calendar-a', 'shuvi-calendar-a'] })]) {
    const h = journalHarness(new Map([['journal-v2', index]]));
    await assert.rejects(h.store.list());
    await assert.rejects(h.store.save(record()));
    assert.equal(h.writes.length, 0);
  }
});

test('existing operation cannot change its draft or known system ID', async () => {
  for (const changed of [{ eventId: 43 }, { draft: { ...draft(), title: '换标题' } }]) {
    const h = journalHarness();
    await h.store.save(record());
    const before = h.data.get('shuvi-calendar-legacy');
    await assert.rejects(h.store.save({ ...record(), ...changed }));
    assert.equal(h.data.get('shuvi-calendar-legacy'), before);
  }
});

test('record and index must both flush before an intent is accepted', async () => {
  const h = journalHarness(new Map(), 'journal-v2');
  await assert.rejects(h.store.save(record()));
  assert.deepEqual(h.writes, ['shuvi-calendar-legacy', 'journal-v2']);
  await assert.rejects(h.store.save(record('shuvi-calendar-next')));
});

async function multiSession(journal, failSecond = false) {
  let sequence = 0;
  let created = 0;
  const states = [];
  const port = {
    authorize: async () => {}, prepare: async () => {},
    add: async () => {
      created++;
      if (created === 2 && failSecond) throw new Error('unknown result');
      return created;
    },
    read: async current => ({ eventId: current.eventId, matches: current.eventId > 0, reminderConfigured: true })
  };
  const session = new CalendarProbeSession(port, journal.store, () => `shuvi-calendar-multi-${++sequence}`, () => now);
  session.attach(value => states.push(value));
  await tick();
  return { session, states, created: () => created };
}

test('two confirmed operations persist independently; selection cannot replace history', async () => {
  const journal = journalHarness();
  const h = await multiSession(journal);
  h.session.preview(draft());
  await h.session.confirm();
  assert.equal(h.states.at(-1).canCreate, true);
  h.session.newDraft();
  h.session.preview(Object.assign(draft(), { title: '第二条日程' }));
  await h.session.confirm();
  assert.equal(h.created(), 2);
  assert.equal(h.states.at(-1).records.length, 2);
  h.session.select('shuvi-calendar-multi-1');
  await h.session.reconcile();
  assert.equal(h.states.at(-1).eventId, 1);
  assert.equal(h.created(), 2);
  const restored = new CalendarJournalStore(journal.text);
  assert.deepEqual((await restored.list()).map(r => r.eventId), [1, 2]);
  h.states.at(-1).records[0].draft.title = 'UI mutation';
  assert.equal((await restored.list())[0].draft.title, '测试日程');
});

test('unresolved second write cannot be bypassed by selecting a verified earlier operation', async () => {
  const journal = journalHarness();
  const h = await multiSession(journal, true);
  h.session.preview(draft());
  await h.session.confirm();
  h.session.newDraft();
  h.session.preview(Object.assign(draft(), { title: '第二条' }));
  await h.session.confirm();
  h.session.select('shuvi-calendar-multi-1');
  h.states.at(-1).canCreate = true;
  h.session.newDraft();
  h.session.preview(Object.assign(draft(), { title: '第三条' }));
  await h.session.confirm();
  assert.equal(h.states.at(-1).canCreate, false);
  assert.equal(h.created(), 2);
  const restored = await multiSession(journal);
  assert.equal(restored.states.at(-1).operationId, 'shuvi-calendar-multi-2');
  assert.equal(restored.states.at(-1).canCreate, false);
});

test('same title and time cannot accidentally create a second event via new-draft', async () => {
  const h = await multiSession(journalHarness());
  h.session.preview(draft());
  await h.session.confirm();
  h.session.newDraft();
  h.session.preview(draft());
  await h.session.confirm();
  assert.equal(h.states.at(-1).phase, 'failed');
  assert.equal(h.created(), 1);
});
