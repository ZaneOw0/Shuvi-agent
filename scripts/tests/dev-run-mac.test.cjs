'use strict';
// Isolated regression for scripts/dev-run-mac.sh. macOS only; never calls the real CLI.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const cp = require('node:child_process');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const root = path.resolve(__dirname, '../..');
const shell = process.env.TEST_BASH || '/bin/bash';
const parent = process.env.DEVRUN_TEST_PARENT || os.tmpdir();
const template = '{"app":{"signingConfigs":[],"products":[{"name":"default"}]},"modules":[]}\n';
const fakeSource = String.raw`#!/usr/bin/env node
'use strict';
const fs=require('node:fs'), path=require('node:path');
const root=process.cwd(), f=path.join(root,'fixture.json');
const c=JSON.parse(fs.readFileSync(f,'utf8')), a=process.argv.slice(2);
fs.appendFileSync(path.join(root,'calls.jsonl'), JSON.stringify(a)+'\n');
function out(x){process.stdout.write(typeof x==='string'?x:JSON.stringify(x));}
function notice(){const b=String.fromCharCode(96);return '\nNew version 1.3.5 available, run '+b+'devecocli update'+b+' to upgrade';}
function done(code=0){process.exit(code);}
function save(){fs.writeFileSync(f,JSON.stringify(c));}
if(a[0]==='auth'&&a[1]==='status'){out(c.authText===undefined?'Current user: smoke-user':c.authText);done(c.authExit||0);}
if(a[0]==='device'&&a[1]==='list'){
  if(c.deviceMalformed){out('No active devices.');done();}
  out(c.devices||[]);
  if(c.deviceNotice)out(notice());
  if(c.deviceGarbage)out('\nunexpected trailing diagnostic');
  done();
}
if(a[0]==='emulator'&&a[1]==='list'){
  if(c.emulatorMalformed){out('Mate 90 Pro stopped');done();}
  out(c.emulators||[]);
  if(c.emulatorNotice)out(notice());
  done();
}
if(a[0]==='emulator'&&a[1]==='start'){
  if(c.startLicenseError){out('Emulator license agreements are not accepted yet.');done(9);}
  const name=a[a.length-1];
  const e=(c.emulators||[]).find(e=>e.name===name);if(!e)done(10);
  e.status='running';e.serial='127.0.0.1:5555';
  c.devices=(c.devices||[]).concat([{name:e.name,serial:e.serial,kind:'emulator',deviceType:e.deviceType,osVersion:e.osVersion}]);
  save();out('Emulator started successfully.');done();
}
if(a[0]==='device'&&a[1]==='view'){
  const target=a[a.indexOf('-t')+1];
  const d=(c.devices||[]).find(d=>d.serial===target||d.name===target);if(!d)done(11);
  out(d);done();
}
if(a[0]==='signature'){
  const p=JSON.parse(fs.readFileSync('build-profile.json5'));
  const product=a[a.indexOf('--product')+1];
  for(const file of ['SMOKE-KEY','SMOKE-CERT','SMOKE-PROFILE'])fs.writeFileSync(file,'smoke fixture, not signing material');
  p.app.signingConfigs=[{name:product,material:{storeFile:path.join(root,'SMOKE-KEY'),certpath:path.join(root,'SMOKE-CERT'),profile:path.join(root,'SMOKE-PROFILE'),keyAlias:'smoke',keyPassword:'SMOKE',storePassword:'SMOKE',signAlg:'SHA256withECDSA'}}];
  fs.writeFileSync('build-profile.json5',JSON.stringify(p));
  out('synthetic signature');done(c.signExit||0);
}
if(a[0]==='build'){fs.writeFileSync('built','yes');out('synthetic build');done(c.buildExit||0);}
if(a[0]==='run'){out('synthetic run');done(c.runExit||0);}
done(99);
`;
const stoppedEmu = (name = 'Mate 90 Pro') => ({ name, status: 'stopped', serial: null, deviceType: 'phone', osVersion: 'API 26' });
function fixture(config = {}) {
  const dir = fs.mkdtempSync(path.join(parent, 'shuvi mac '));
  fs.mkdirSync(path.join(dir, 'scripts'));
  fs.mkdirSync(path.join(dir, 'bin'));
  fs.mkdirSync(path.join(dir, 'home'));
  fs.copyFileSync(path.join(root, 'scripts', 'dev-run-mac.sh'), path.join(dir, 'scripts', 'dev-run-mac.sh'));
  fs.chmodSync(path.join(dir, 'scripts', 'dev-run-mac.sh'), 0o755);
  fs.writeFileSync(path.join(dir, 'build-profile.json5'), template);
  fs.writeFileSync(path.join(dir, '.gitignore'), '.local/\nfixture.json\ncalls.jsonl\nSMOKE-*\nbuilt\n');
  fs.writeFileSync(path.join(dir, 'fixture.json'), JSON.stringify(config));
  const cli = path.join(dir, 'bin', 'devecocli');
  fs.writeFileSync(cli, fakeSource, { mode: 0o755 });
  cp.spawnSync('git', ['-C', dir, 'init', '-q']);
  cp.spawnSync('git', ['-C', dir, 'add', 'build-profile.json5', '.gitignore']);
  cp.spawnSync('git', ['-C', dir, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@invalid', 'commit', '-qm', 'fixture']);
  const env = { ...process.env, HOME: path.join(dir, 'home'), USERPROFILE: path.join(dir, 'home'),
    DEVECOCLI_BIN: cli, PATH: path.join(dir, 'bin') + path.delimiter + process.env.PATH,
    EMULATOR_NAME: '', PRODUCT: 'default' };
  for (const name of ['RUN_CMD', 'CAPTURE_HOST_ONLY', 'CAPTURE_BASH_VERSION', 'BUNDLE', 'KEYWORD',
    'DEVECO_CLI_DEBUG', 'DEBUG', 'DEVRUN_CLI_TIMEOUT_MS', 'DEVRUN_SOURCE_ROOT']) Reflect.deleteProperty(env, name);
  return { dir, env,
    calls() { const p = path.join(dir, 'calls.jsonl'); return fs.existsSync(p) ? fs.readFileSync(p, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : []; },
    run(args = [], extra = {}) { return cp.spawnSync(shell, [path.join(dir, 'scripts', 'dev-run-mac.sh'), ...args], { cwd: dir, env: { ...env, ...extra }, encoding: 'utf8', timeout: 120000 }); },
    stateFile() { return JSON.parse(fs.readFileSync(path.join(dir, 'fixture.json'), 'utf8')); },
    close() { fs.rmSync(dir, { recursive: true, force: true }); } };
}
function restored(f) {
  assert.equal(fs.readFileSync(path.join(f.dir, 'build-profile.json5'), 'utf8'), template);
  assert(!fs.existsSync(path.join(f.dir, '.local', 'mac-run.template.bak')), 'template backup removed');
}
const commandOf = (f, head, sub) => f.calls().filter(a => a[0] === head && (!sub || a[1] === sub));

test('mac: stopped emulator starts, locks serial, restores template', () => {
  const f = fixture({ devices: [], emulators: [stoppedEmu(), stoppedEmu('Mate X7')] });
  try {
    const r = f.run(['--emulator', 'Mate 90 Pro']);
    assert.equal(r.status, 0, r.stderr);
    const starts = commandOf(f, 'emulator', 'start');
    assert.equal(starts.length, 1);
    assert.equal(starts[0][starts[0].length - 1], 'Mate 90 Pro');
    const runs = commandOf(f, 'run');
    assert.equal(runs.length, 1);
    assert.equal(runs[0][runs[0].indexOf('--device') + 1], '127.0.0.1:5555');
    assert(fs.existsSync(path.join(f.dir, 'built')), 'build ran');
    restored(f);
  } finally { f.close(); }
});
test('mac: running emulator is reused without starting it', () => {
  const running = { ...stoppedEmu(), status: 'running', serial: '127.0.0.1:5555' };
  const f = fixture({ devices: [{ name: 'Mate 90 Pro', serial: '127.0.0.1:5555', kind: 'emulator', deviceType: 'phone' }], emulators: [running] });
  try {
    const r = f.run(['--emulator', 'Mate 90 Pro']);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(commandOf(f, 'emulator', 'start').length, 0);
    assert.equal(commandOf(f, 'run').length, 1);
    restored(f);
  } finally { f.close(); }
});
test('mac: missing login stops before any emulator or build action', () => {
  const f = fixture({ devices: [], emulators: [stoppedEmu()], authText: 'Not logged in' });
  try {
    const r = f.run();
    assert.notEqual(r.status, 0);
    assert(r.stderr.includes('devecocli auth login'), r.stderr);
    assert.equal(f.calls().filter(a => ['build', 'run', 'signature'].includes(a[0])).length, 0);
    assert.equal(commandOf(f, 'emulator', 'start').length, 0);
    restored(f);
  } finally { f.close(); }
});
test('mac: inherited agent auth variables are called out on login failure', () => {
  const f = fixture({ devices: [], emulators: [stoppedEmu()], authText: 'Not logged in' });
  try {
    const r = f.run([], { DEVECO_CLI_AUTH_SOURCE: 'deveco-code', DEVECO_CODE_AUTH_DIR: '/tmp/none' });
    assert.notEqual(r.status, 0);
    assert(r.stderr.includes('DEVECO_CLI_AUTH_SOURCE'), r.stderr);
    assert(r.stdout.includes('检查登录状态（CLI:'), r.stdout);
    restored(f);
  } finally { f.close(); }
});
test('mac: unaccepted license state stops before starting the instance', () => {
  const f = fixture({ devices: [], emulators: [stoppedEmu()] });
  try {
    const cache = path.join(f.dir, 'home', 'Library', 'Caches', 'Huawei', 'Emulator26.0');
    fs.mkdirSync(cache, { recursive: true });
    fs.writeFileSync(path.join(cache, '.emu_config'), 'HarmonyOS_SDK_Agreement:disagree\nimagePath:/tmp\n');
    const r = f.run();
    assert.notEqual(r.status, 0);
    assert(r.stderr.includes('devecocli emulator license'), r.stderr);
    assert(r.stderr.includes('未接受'), r.stderr);
    assert.equal(commandOf(f, 'emulator', 'start').length, 0);
    restored(f);
  } finally { f.close(); }
});
test('mac: CLI license rejection during start is reported with instructions', () => {
  const f = fixture({ devices: [], emulators: [stoppedEmu()], startLicenseError: true });
  try {
    const r = f.run(['--emulator', 'Mate 90 Pro']);
    assert.notEqual(r.status, 0);
    assert(r.stderr.includes('devecocli emulator license accept'), r.stderr);
    assert.equal(f.calls().filter(a => ['build', 'run', 'signature'].includes(a[0])).length, 0);
    restored(f);
  } finally { f.close(); }
});
test('mac: trailing update notice on JSON is tolerated', () => {
  const f = fixture({ devices: [], emulators: [stoppedEmu()], deviceNotice: true, emulatorNotice: true });
  try {
    const r = f.run(['--emulator', 'Mate 90 Pro']);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(commandOf(f, 'run').length, 1);
    restored(f);
  } finally { f.close(); }
});
test('mac: unknown trailing text still fails closed', () => {
  const f = fixture({ devices: [], emulators: [stoppedEmu()], deviceGarbage: true });
  try {
    const r = f.run();
    assert.notEqual(r.status, 0);
    assert(r.stderr.includes('设备清单 JSON 无效'), r.stderr);
    assert.equal(f.calls().filter(a => ['build', 'run', 'signature'].includes(a[0])).length, 0);
    restored(f);
  } finally { f.close(); }
});
test('mac: malformed device inventory names the phase', () => {
  const f = fixture({ deviceMalformed: true, emulators: [stoppedEmu()] });
  try {
    const r = f.run();
    assert.notEqual(r.status, 0);
    assert(r.stderr.includes('设备清单 JSON 无效'), r.stderr);
    restored(f);
  } finally { f.close(); }
});
test('mac: valid JSON5 signed cache is reused without regenerating', () => {
  const f = fixture({ devices: [], emulators: [stoppedEmu()] });
  try {
    const local = path.join(f.dir, '.local');
    fs.mkdirSync(local, { recursive: true });
    const material = {};
    for (const name of ['CACHED-KEY', 'CACHED-CERT', 'CACHED-PROFILE']) {
      const file = path.join(f.dir, name);
      fs.writeFileSync(file, 'cached fixture material');
      material[name] = file;
    }
    const sha = require('node:crypto').createHash('sha256').update(fs.readFileSync(path.join(f.dir, 'build-profile.json5'))).digest('hex');
    fs.writeFileSync(path.join(local, 'mac-run.default.' + sha + '.json5'),
      "{ app: { signingConfigs: [ { name: 'default', material: { storeFile: '" + material['CACHED-KEY'] +
      "', certpath: '" + material['CACHED-CERT'] + "', profile: '" + material['CACHED-PROFILE'] +
      "', keyAlias: 'cached' } } ] } }\n");
    const r = f.run(['--emulator', 'Mate 90 Pro']);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(commandOf(f, 'signature').length, 0, 'valid cache must skip signature generation');
    assert.equal(commandOf(f, 'run').length, 1);
    restored(f);
  } finally { f.close(); }
});
test('mac: --no-emulator never starts a stopped instance', () => {
  const f = fixture({ devices: [], emulators: [stoppedEmu()] });
  try {
    const r = f.run(['--no-emulator']);
    assert.notEqual(r.status, 0);
    assert.equal(commandOf(f, 'emulator', 'start').length, 0);
    assert.equal(f.calls().filter(a => ['build', 'run', 'signature'].includes(a[0])).length, 0);
    restored(f);
  } finally { f.close(); }
});
test('mac: build failure never installs and restores the template', () => {
  const f = fixture({ devices: [], emulators: [stoppedEmu()], buildExit: 23 });
  try {
    const r = f.run(['--emulator', 'Mate 90 Pro']);
    assert.equal(r.status, 23, r.stderr);
    assert.equal(commandOf(f, 'run').length, 0);
    restored(f);
  } finally { f.close(); }
});
