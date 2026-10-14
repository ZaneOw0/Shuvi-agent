'use strict';
// Built-ins only. CLI stdout/stderr are never copied into public diagnostics.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const cp = require('node:child_process');
function fail(code) { throw new Error(code); }
function text(v, optional = false) {
  if (optional && (v === null || v === undefined)) return '';
  if (typeof v !== 'string' || !v.trim() || /[\x00-\x1f\x7f]/.test(v)) fail('invalid-field');
  return v;
}
function parse(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { fail('invalid-json'); }
}
function device(d) {
  if (!d || typeof d !== 'object' || Array.isArray(d)) fail('invalid-device');
  text(d.name); text(d.serial);
  if (!['device', 'emulator'].includes(d.kind)) fail('invalid-device-kind');
  text(d.deviceType, true); text(d.osVersion, true);
  return d;
}
function inventory(file, kind) {
  const a = parse(file);
  if (!Array.isArray(a)) fail('invalid-list');
  const serials = new Set(), names = new Set();
  for (const d of a) {
    if (kind === 'device') device(d);
    else {
      if (!d || typeof d !== 'object' || Array.isArray(d)) fail('invalid-emulator');
      text(d.name); text(d.deviceType, true); text(d.osVersion, true);
      if (!['running', 'stopped'].includes(d.status)) fail('invalid-emulator-status');
      if (d.serial !== null) text(d.serial);
      if (d.status === 'stopped' && d.serial !== null) fail('contradictory-emulator');
      const nameKey = d.name.normalize('NFKC').replace(/\s+/g, ' ').trim();
      if (names.has(nameKey)) fail('duplicate-emulator');
      names.add(nameKey);
    }
    if (d.serial) { if (serials.has(d.serial)) fail('duplicate-serial'); serials.add(d.serial); }
  }
  return a;
}
function matchDevice(devices, target) {
  const serial = devices.find(d => d.serial === target);
  if (serial) return serial;
  const found = devices.filter(d => d.name === target);
  if (found.length > 1) fail('ambiguous-device');
  return found[0];
}
function select(devices, emulators, wantedDevice, wantedEmulator, noEmulator) {
  mappings(devices, emulators);
  let d, e;
  if (wantedDevice) d = matchDevice(devices, text(wantedDevice));
  if (wantedEmulator) {
    e = emulators.find(e => e.name === text(wantedEmulator));
    if (!e) fail('emulator-not-found');
    if (wantedDevice && (!d || d.kind !== 'emulator' || d.name !== e.name || e.serial !== d.serial)) fail('target-conflict');
  } else if (wantedDevice) {
    if (!d) fail('device-not-found');
    if (d.kind === 'emulator') e = emulators.find(e => e.name === d.name && e.serial === d.serial);
    if (d.kind === 'emulator' && !e) fail('target-conflict');
  } else {
    if (devices.length > 1) fail('multiple-devices-specify-target');
    if (devices.length === 1) {
      d = devices[0];
      if (d.kind === 'emulator') {
        e = emulators.find(e => e.name === d.name && e.serial === d.serial);
        if (!e) fail('target-conflict');
      }
    } else { e = emulators[0]; if (!e) fail('no-target'); }
  }
  if (e) {
    if (e.status === 'stopped' && noEmulator) fail('emulator-start-disabled');
    return [e.status === 'stopped' ? 'start' : 'wait', e.name, wantedDevice && d ? d.serial : e.serial || ''];
  }
  return ['device', d.name, d.serial];
}
function mappings(devices, emulators) {
  for (const d of devices) if (d.kind === 'emulator') {
    const e = emulators.find(e => e.name === d.name);
    if (!e || e.status !== 'running' || e.serial !== d.serial) fail('contradictory-target-mapping');
  }
  for (const e of emulators) if (e.serial) {
    const d = devices.find(d => d.serial === e.serial);
    if (d && (d.name !== e.name || d.kind !== 'emulator')) fail('contradictory-target-mapping');
  }
}
function ready(devices, emulators, mode, name, serial) {
  mappings(devices, emulators);
  if (mode === 'device') {
    const d = devices.find(d => d.serial === serial);
    if (!d) return '';
    if (d.name !== name || d.kind !== 'device') fail('target-changed');
    return d.serial;
  }
  const e = emulators.find(e => e.name === name);
  if (!e) fail('emulator-disappeared');
  if (e.status !== 'running' || !e.serial) return '';
  if (serial && e.serial !== serial) fail('target-changed');
  const d = devices.find(d => d.serial === e.serial);
  if (!d) return '';
  if (d.name !== name || d.kind !== 'emulator') fail('target-conflict');
  return d.serial;
}
function normalize(value) { return value.normalize('NFKC').replace(/\s+/g, ' ').trim().toLowerCase(); }
function downloadedFlag(value) {
  if (value === true || value === 'true') return true;
  if (value === false || value === 'false') return false;
  fail('invalid-image-state');
}
// Advisory gate only: 'unknown' never blocks a start, 'missing' means the CLI
// itself reports no downloaded image for the exact target device type and OS.
function imageGate(imagesFile, emulatorsFile, name) {
  try {
    const target = inventory(emulatorsFile, 'emulator').find(e => e.name === name);
    if (!target || !target.deviceType || !target.osVersion) return 'unknown';
    const entries = parse(imagesFile);
    if (!Array.isArray(entries) || entries.length === 0) return 'unknown';
    const matched = [];
    for (const entry of entries) {
      if (!entry || typeof entry !== 'object' || Array.isArray(entry)) return 'unknown';
      const deviceType = text(entry.deviceType), osVersion = text(entry.osVersion);
      if (normalize(deviceType) !== normalize(target.deviceType) || normalize(osVersion) !== normalize(target.osVersion)) continue;
      matched.push(downloadedFlag(entry.downloaded));
    }
    if (matched.length === 0) return 'unknown';
    return matched.some(Boolean) ? 'ok' : 'missing ' + target.deviceType + ' ' + target.osVersion;
  } catch { return 'unknown'; }
}
// Known CLI wording for "engine launched, guest never reached hdc"; diagnosis only.
function startHealth(file) {
  let raw = '';
  try { raw = fs.readFileSync(file, 'utf8'); } catch { return 'unclassified'; }
  return /did not appear in hdc list targets/i.test(raw.replace(/\x1b\[[0-9;]*m/g, '')) ? 'emulator-not-joined-hdc' : 'unclassified';
}
function inventoryCheck(file, kind) {
  try { inventory(file, kind); return 'ok'; }
  catch (error) {
    let detail = /^[a-z][a-z0-9-]+$/.test(error.message) ? error.message : 'check-failed';
    try {
      const raw = fs.readFileSync(file, 'utf8');
      const shape = raw.length === 0 ? 'empty' : /\x1b\[[0-9;]*m/.test(raw) ? 'ansi-decorated'
        : /^[[{]/.test(raw.trimStart()) ? 'json-looking' : 'text';
      return detail + '; bytes=' + raw.length + '; shape=' + shape;
    } catch { return detail + '; bytes=unreadable'; }
  }
}
function digest(file) { return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'); }
// A data-only JSON5 subset covers CLI-generated profiles and common repository templates.
// Unsupported syntax fails closed; no eval, Function, or configuration execution.
function profile(file) {
  const source = fs.readFileSync(file, 'utf8');
  let at = 0;
  function skip() {
    while (at < source.length) {
      if (/\s/.test(source[at])) { at++; continue; }
      if (source.slice(at, at + 2) === '//') { at = source.indexOf('\n', at); if (at < 0) at = source.length; continue; }
      if (source.slice(at, at + 2) === '/*') { const end = source.indexOf('*/', at + 2); if (end < 0) fail('invalid-profile'); at = end + 2; continue; }
      break;
    }
  }
  function string() {
    const quote = source[at++]; let result = '';
    while (at < source.length) {
      let c = source[at++]; if (c === quote) return result;
      if (c === '\\') {
        c = source[at++];
        const escapes = { n: '\n', r: '\r', t: '\t', b: '\b', f: '\f', v: '\v', '0': '\0' };
        if (c === 'u' || c === 'x') {
          const length = c === 'u' ? 4 : 2, hex = source.slice(at, at + length);
          if (!new RegExp('^[0-9a-fA-F]{' + length + '}$').test(hex)) fail('invalid-profile');
          result += String.fromCharCode(parseInt(hex, 16)); at += length;
        } else if (c === '\n') { /* JSON5 continuation */ }
        else if (c === '\r') { if (source[at] === '\n') at++; }
        else result += Object.hasOwn(escapes, c) ? escapes[c] : c;
      } else { if (c === '\n' || c === '\r') fail('invalid-profile'); result += c; }
    }
    fail('invalid-profile');
  }
  function value() {
    skip(); const c = source[at];
    if (c === '"' || c === "'") return string();
    if (c === '{' || c === '[') {
      at++; const array = c === '[', result = array ? [] : {}, end = array ? ']' : '}'; skip();
      while (source[at] !== end) {
        if (array) result.push(value());
        else {
          skip(); let key;
          if (source[at] === '"' || source[at] === "'") key = string();
          else { const m = /^[A-Za-z_$][A-Za-z0-9_$]*/.exec(source.slice(at)); if (!m) fail('invalid-profile'); key = m[0]; at += key.length; }
          if (['__proto__', 'constructor', 'prototype'].includes(key) || Object.hasOwn(result, key)) fail('invalid-profile-key');
          skip(); if (source[at++] !== ':') fail('invalid-profile'); result[key] = value();
        }
        skip(); if (source[at] === end) break;
        if (source[at++] !== ',') fail('invalid-profile'); skip();
      }
      at++; return result;
    }
    const m = /^(true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/.exec(source.slice(at));
    if (!m) fail('invalid-profile'); at += m[0].length; return JSON.parse(m[0]);
  }
  const p = value(); skip(); if (at !== source.length || !p || !p.app) fail('invalid-profile');
  return p;
}
function templateCheck(file, product) {
  text(product); const p = profile(file);
  if (!Array.isArray(p.app.signingConfigs) || p.app.signingConfigs.length !== 0 || !Array.isArray(p.app.products)) fail('signed-or-invalid-template');
  if (p.app.products.some(p => Object.hasOwn(p, 'signingConfig'))) fail('signed-or-invalid-template');
  const found = p.app.products.filter(p => p.name === product);
  if (found.length !== 1) fail('product-not-found');
  return p;
}
function signedCheck(file, backup, product) {
  const p = profile(file), original = templateCheck(backup, product);
  if (!Array.isArray(p.app.signingConfigs) || !Array.isArray(p.app.products)) fail('invalid-signed-profile');
  const selected = p.app.products.find(p => p.name === product);
  if (!selected) fail('invalid-signed-product');
  const configs = p.app.signingConfigs.filter(c => c.name === selected.signingConfig);
  if (configs.length !== 1 || p.app.signingConfigs.length !== 1 || p.app.products.some(p => p.name !== product && Object.hasOwn(p, 'signingConfig'))) fail('invalid-signed-config');
  const m = configs[0].material;
  if (!m) fail('invalid-signed-material');
  for (const field of ['storeFile', 'certpath', 'profile', 'keyAlias', 'keyPassword', 'storePassword', 'signAlg']) text(m[field]);
  for (const field of ['storeFile', 'certpath', 'profile']) if (!fs.statSync(m[field]).isFile()) fail('signing-material-unavailable');
  const unsigned = JSON.parse(JSON.stringify(p)); unsigned.app.signingConfigs = [];
  for (const item of unsigned.app.products) Reflect.deleteProperty(item, 'signingConfig');
  if (!require('node:util').isDeepStrictEqual(unsigned, original)) fail('signed-template-mismatch');
}
function safeDir(dir) {
  try { fs.mkdirSync(dir, { mode: 0o700 }); } catch (error) { if (error.code !== 'EEXIST') throw error; }
  const stat = fs.lstatSync(dir);
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail('unsafe-private-directory');
}
function gitClean(root, file) {
  for (const a of [['ls-files', '--error-unmatch', '--', file], ['diff', '--quiet', '--', file], ['diff', '--cached', '--quiet', '--', file]]) {
    const r = cp.spawnSync('git', ['-C', root, ...a], { stdio: 'ignore', env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' } });
    if (r.status !== 0) fail('template-dirty-or-untracked');
  }
}
function owner(lock, token) {
  if (fs.lstatSync(lock).isSymbolicLink() || fs.readFileSync(path.join(lock, 'owner'), 'utf8') !== token) fail('lock-ownership-mismatch');
}
function begin(root, product, token) {
  const bp = path.join(root, 'build-profile.json5'), local = path.join(root, '.local'), lock = path.join(local, 'dev-run.lock');
  if (!fs.lstatSync(bp).isFile() || fs.lstatSync(bp).isSymbolicLink()) fail('invalid-template-file');
  gitClean(root, 'build-profile.json5'); templateCheck(bp, product);
  safeDir(local);
  if (fs.existsSync(path.join(local, 'build-profile.template.bak'))) fail('existing-recovery-backup');
  try { fs.mkdirSync(lock, { mode: 0o700 }); } catch { fail('existing-lock-manual-recovery-required'); }
  try {
    fs.writeFileSync(path.join(lock, 'owner'), token, { mode: 0o600, flag: 'wx' });
    gitClean(root, 'build-profile.json5'); templateCheck(bp, product);
    fs.copyFileSync(bp, path.join(lock, 'template.bak'), fs.constants.COPYFILE_EXCL);
    fs.chmodSync(path.join(lock, 'template.bak'), 0o600);
    fs.writeFileSync(path.join(lock, 'expected.sha'), digest(bp), { mode: 0o600 });
    fs.writeFileSync(path.join(lock, 'original.sha'), digest(bp), { mode: 0o600 });
  } catch { fail('backup-failed-recovery-preserved'); }
}
function cachePath(root, product, backup) {
  const identity = crypto.createHash('sha256').update(digest(backup) + '\0' + product).digest('hex');
  return path.join(root, '.local', 'signed-v1-' + identity + '.json5');
}
function cacheApply(root, product, token) {
  const lock = path.join(root, '.local/dev-run.lock'); owner(lock, token);
  const backup = path.join(lock, 'template.bak'), cache = cachePath(root, product, backup), bp = path.join(root, 'build-profile.json5');
  stateCheck(root, token);
  let from = cache;
  if (!fs.existsSync(from) && product === 'default') {
    // Legacy hash was a Git blob id. Match actual clean bytes and full template shape first.
    const old = path.join(root, '.local/build-profile.signed.json5'), sha = path.join(root, '.local/build-profile.template.sha');
    const r = cp.spawnSync('git', ['hash-object', backup], { encoding: 'utf8', env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' } });
    if (r.status === 0 && fs.existsSync(old) && fs.existsSync(sha) && fs.readFileSync(sha, 'utf8').trim() === r.stdout.trim()) from = old;
  }
  if (!fs.existsSync(from)) return 2;
  try {
    if (fs.lstatSync(from).isSymbolicLink()) return 2;
    signedCheck(from, backup, product);
  } catch { return 2; }
  fs.copyFileSync(from, bp); fs.writeFileSync(path.join(lock, 'expected.sha'), digest(bp));
  if (from !== cache) { fs.copyFileSync(from, cache, fs.constants.COPYFILE_EXCL); fs.chmodSync(cache, 0o600); }
  return 0;
}
function note(root, token) {
  const lock = path.join(root, '.local/dev-run.lock'); owner(lock, token);
  fs.writeFileSync(path.join(lock, 'expected.sha'), digest(path.join(root, 'build-profile.json5')));
}
function stateCheck(root, token) {
  const lock = path.join(root, '.local/dev-run.lock'); owner(lock, token);
  if (digest(path.join(lock, 'template.bak')) !== fs.readFileSync(path.join(lock, 'original.sha'), 'utf8')) fail('backup-changed');
  const bp = path.join(root, 'build-profile.json5');
  if (!fs.lstatSync(bp).isFile() || fs.lstatSync(bp).isSymbolicLink() || digest(bp) !== fs.readFileSync(path.join(lock, 'expected.sha'), 'utf8')) fail('external-template-change');
}
function cacheSave(root, product, token) {
  const lock = path.join(root, '.local/dev-run.lock'); owner(lock, token);
  const bp = path.join(root, 'build-profile.json5'), backup = path.join(lock, 'template.bak');
  signedCheck(bp, backup, product);
  const cache = cachePath(root, product, backup);
  if (fs.existsSync(cache) && fs.lstatSync(cache).isSymbolicLink()) fail('unsafe-cache-path');
  const temporary = path.join(lock, 'cache.new'); fs.copyFileSync(bp, temporary); fs.chmodSync(temporary, 0o600); fs.renameSync(temporary, cache);
}
function restore(root, token) {
  const lock = path.join(root, '.local/dev-run.lock'); owner(lock, token);
  const bp = path.join(root, 'build-profile.json5'), backup = path.join(lock, 'template.bak');
  if (digest(backup) !== fs.readFileSync(path.join(lock, 'original.sha'), 'utf8')) fail('restore-failed-backup-changed');
  if (!fs.lstatSync(bp).isFile() || fs.lstatSync(bp).isSymbolicLink() || digest(bp) !== fs.readFileSync(path.join(lock, 'expected.sha'), 'utf8')) fail('restore-failed-external-change-or-write-error');
  fs.copyFileSync(backup, bp);
  if (digest(bp) !== digest(backup)) fail('restore-failed-byte-mismatch');
  fs.rmSync(lock, { recursive: true });
}
function category(stdout, stderr) {
  const s = (fs.readFileSync(stdout, 'utf8') + '\n' + fs.readFileSync(stderr, 'utf8')).replace(/\x1b\[[0-9;]*m/g, '');
  if (/not logged in|auth login|sign in|invalid accesstoken|unauthori[sz]ed|permission denied|\b401\b|\b403\b/i.test(s)) return 'authorization-blocked';
  if (/license|agreement/i.test(s)) return 'license-blocked';
  if (/sign info inconsistent|signature.*(?:invalid|conflict|mismatch)|certificate|provision|keypassword|storepassword/i.test(s)) return 'signing-identity-blocked';
  if (/device.*(?:offline|not ready)|connection.*(?:reset|timed out)/i.test(s)) return 'transient-connection';
  return 'tool-failed';
}
function publicOutput(input, output) {
  const raw = fs.readFileSync(input, 'utf8');
  // Keep arbitrary auth/signature output out of public evidence, even from RUN_CMD.
  if (/signingConfigs|signingConfig|storeFile|password|keyAlias|certpath|token|secret|private.?key|authorization|current user:|\.p12\b|\.p7b\b|\.cer\b/i.test(raw)) {
    fs.writeFileSync(output, '[private output withheld; see phase and exit metadata]\n', { mode: 0o600 });
  } else fs.copyFileSync(input, output);
}
function readGit(root, args) {
  const r = cp.spawnSync('git', ['-C', root, ...args], { encoding: 'utf8', maxBuffer: 20 * 1024 * 1024, env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' } });
  return r.status === 0 ? r.stdout.trim() : '';
}
function evidenceDir(root, scope) {
  if (!/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(scope)) fail('invalid-scope');
  const base = path.join(root, '.cache/test-logs');
  fs.mkdirSync(base, { recursive: true });
  const name = new Date().toISOString().slice(0, 10) + '-' + scope + '-' + (readGit(root, ['rev-parse', '--short', 'HEAD']) || 'nogit');
  for (let suffix = 1; suffix <= 10000; suffix++) {
    const dir = path.join(base, name + (suffix === 1 ? '' : '-' + suffix));
    try { fs.mkdirSync(dir, { mode: 0o700 }); return dir; } catch (error) { if (error.code !== 'EEXIST') throw error; }
  }
  fail('evidence-directory-exhausted');
}
async function evidenceMeta(a) {
  const [root, dir, scope, window, device, bundle, keyword, cmdExit, logExit, status] = a;
  const changes = readGit(root, ['status', '--porcelain']);
  const sha = readGit(root, ['rev-parse', '--short', 'HEAD']) || 'nogit';
  const hash = crypto.createHash('sha256');
  // Hash Git deltas internally; never print their contents into logs (profile may be signed).
  hash.update(readGit(root, ['diff', '--binary'])); hash.update(readGit(root, ['diff', '--cached', '--binary']));
  const untracked = cp.spawnSync('git', ['-C', root, 'ls-files', '--others', '--exclude-standard', '-z'], { encoding: 'utf8', maxBuffer: 20 * 1024 * 1024, env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' } });
  if (untracked.status === 0) for (const file of untracked.stdout.split('\0').filter(Boolean).sort()) {
    if (/^(?:\.local|signing)\//.test(file)) continue;
    const full = path.join(root, file); if (!fs.lstatSync(full).isFile()) continue;
    hash.update(file + '\0' + digest(full));
  }
  let state = 'signed-or-modified';
  try { const p = profile(path.join(root, 'build-profile.json5')); if (Array.isArray(p.app.signingConfigs) && p.app.signingConfigs.length === 0 && !p.app.products.some(p => Object.hasOwn(p, 'signingConfig'))) state = 'template'; } catch {}
  const rows = { run_at: new Date().toISOString(), scope, branch: readGit(root, ['rev-parse', '--abbrev-ref', 'HEAD']), commit: sha,
    dirty_files: changes ? changes.split('\n').length : 0, worktree_fingerprint: hash.digest('hex'), bundle, device: device || 'auto', log_window: window,
    keyword: keyword || '-', status, build_profile: state, run_cmd: process.env.RUN_CMD ? 'provided (content not recorded)' : '-',
    run_cmd_sha256: process.env.RUN_CMD ? crypto.createHash('sha256').update(process.env.RUN_CMD).digest('hex') : '-',
    run_cmd_status: cmdExit === 'not-run' ? 'not-run' : cmdExit === '0' ? 'ok' : 'failed', run_cmd_exit: cmdExit,
    log_status: status, log_exit: logExit, platform: process.platform, bash: process.env.CAPTURE_BASH_VERSION || '-', node: process.version };
  for (const file of ['dev-run.sh', 'dev-run-mac.sh', 'dev-run.cmd', 'dev-run-support.cjs', 'capture-test-log.sh']) {
    const full = path.join(root, 'scripts', file); if (fs.existsSync(full)) rows[file + '_sha256'] = digest(full);
  }
  for (const field of [scope, window, device, bundle, keyword]) if (/[\x00-\x1f\x7f]/.test(field)) fail('invalid-metadata-field');
  fs.writeFileSync(path.join(dir, 'meta.txt'), Object.entries(rows).map(([k, v]) => k + '\t' + v).join('\n') + '\n', { flag: 'wx', mode: 0o600 });
  const indexLock = path.join(root, '.cache/test-logs/.index.lock');
  let locked = false;
  for (let i = 0; i < 100; i++) {
    try { fs.mkdirSync(indexLock); locked = true; break; } catch (error) { if (error.code !== 'EEXIST') throw error; }
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  if (!locked) fail('evidence-index-lock-timeout');
  try {
    fs.appendFileSync(path.join(root, '.cache/test-logs/index.tsv'), [rows.run_at, scope, sha, rows.dirty_files, rows.worktree_fingerprint, bundle, path.relative(root, dir), cmdExit, logExit, status].join('\t') + '\n');
  } finally { fs.rmdirSync(indexLock); }
}
function windowsCommand(cli, args, platform = process.platform) {
  if (platform !== 'win32' && /\.(cmd|bat|exe)$/i.test(cli)) fail('windows-cli-on-unix');
  if (platform !== 'win32' || !/\.(cmd|bat)$/i.test(cli)) return { command: cli, args };
  // Expansion values are not recursively parsed as %variables%. Quoted environment
  // slots avoid concatenating user input into /c; delayed expansion is disabled.
  const all = [cli, ...args];
  if (all.some(a => /["\x00-\x1f\x7f]/.test(a))) fail('unsafe-cmd-argument-use-native-cli');
  const env = { DEVRUN_CLI: cli };
  args.forEach((arg, i) => { env['DEVRUN_ARG_' + i] = arg; });
  const line = ['"%DEVRUN_CLI%"', ...args.map((_, i) => '"%DEVRUN_ARG_' + i + '%"')].join(' ');
  return { batch: true, env, command: process.env.ComSpec || 'cmd.exe', args: ['/d', '/v:off', '/s', '/c', '"' + line + '"'], windowsVerbatimArguments: true };
}
async function invoke(cli, stdout, stderr, args) {
  const spec = windowsCommand(cli, args);
  // CLI versions may enable debug on mere presence or any nonempty value.
  const env = { ...process.env, ...spec.env };
  Reflect.deleteProperty(env, 'DEVECO_CLI_DEBUG');
  Reflect.deleteProperty(env, 'DEBUG');
  // Fresh inode per invocation: a descendant that inherited an earlier descriptor
  // (detached emulator, hdc helper) can then never scribble into a file a later
  // invocation truncates and the driver parses.
  fs.rmSync(stdout, { force: true }); fs.rmSync(stderr, { force: true });
  const out = fs.openSync(stdout, 'wx', 0o600), err = fs.openSync(stderr, 'wx', 0o600);
  try {
    return await new Promise(resolve => {
      const child = cp.spawn(spec.command, spec.args, { stdio: ['ignore', out, err], windowsHide: true,
        detached: process.platform !== 'win32', windowsVerbatimArguments: spec.windowsVerbatimArguments,
        env });
      let signal;
      let killTimer;
      const killTree = s => {
        if (!child.pid) return;
        if (process.platform === 'win32') {
          // Native Windows signal forwarding does not reach grandchildren.
          cp.spawnSync('taskkill.exe', ['/pid', String(child.pid), '/t', '/f'], { stdio: 'ignore', windowsHide: true });
        } else { try { process.kill(-child.pid, s); } catch {} }
      };
      const forward = s => {
        signal = s; killTree(s);
        killTimer = setTimeout(() => killTree('SIGKILL'), 3000);
      };
      const int = () => forward('SIGINT'), term = () => forward('SIGTERM');
      const discovery = args[0] === 'device' || args[0] === 'emulator' && (args[1] === 'list' || args[1] === 'image' && args[2] === 'list');
      let timeout = discovery ? 30000 : 0;
      if (process.env.DEVRUN_CLI_TIMEOUT_MS && discovery) {
        const requested = Number(process.env.DEVRUN_CLI_TIMEOUT_MS);
        if (Number.isFinite(requested) && requested > 0) timeout = Math.min(timeout, requested);
      }
      let timedOut = false;
      const timer = timeout ? setTimeout(() => { timedOut = true; forward('SIGTERM'); }, timeout) : undefined;
      process.on('SIGINT', int); process.on('SIGTERM', term);
      child.once('error', () => resolve(127));
      child.once('close', async code => {
        clearTimeout(timer);
        if (signal && process.platform !== 'win32' && child.pid) {
          const end = Date.now() + 3100;
          while (Date.now() < end) {
            try { process.kill(-child.pid, 0); } catch { break; }
            await new Promise(resolve => setTimeout(resolve, 20));
          }
          killTree('SIGKILL');
        }
        clearTimeout(killTimer);
        process.removeListener('SIGINT', int); process.removeListener('SIGTERM', term);
        resolve(timedOut ? 124 : signal === 'SIGINT' ? 130 : signal === 'SIGTERM' ? 143 : code ?? 1);
      });
    });
  } finally { fs.closeSync(out); fs.closeSync(err); }
}
async function main(a) {
  const op = a.shift();
  if (op === 'invoke') return invoke(a[0], a[1], a[2], a.slice(3));
  if (op === 'hash') console.log(digest(a[0]));
  else if (op === 'select') console.log(select(inventory(a[0], 'device'), inventory(a[1], 'emulator'), a[2], a[3], a[4] === '1').join('\n'));
  else if (op === 'ready') {
    const serial = ready(inventory(a[0], 'device'), inventory(a[1], 'emulator'), a[2], a[3], a[4]);
    if (!serial) return 2;
    console.log(serial);
  } else if (op === 'view') {
    const d = device(parse(a[0]));
    if (d.serial !== a[1] || d.name !== a[2] || d.kind !== (a[3] === 'device' ? 'device' : 'emulator')) fail('view-target-mismatch');
  } else if (op === 'check') console.log(inventoryCheck(a[0], a[1]));
  else if (op === 'image-gate') console.log(imageGate(a[0], a[1], a[2]));
  else if (op === 'start-health') console.log(startHealth(a[0])); else if (op === 'begin') begin(a[0], a[1], a[2]);
  else if (op === 'cache-apply') return cacheApply(a[0], a[1], a[2]);
  else if (op === 'cache-save') cacheSave(a[0], a[1], a[2]);
  else if (op === 'note') note(a[0], a[1]);
  else if (op === 'state') stateCheck(a[0], a[1]);
  else if (op === 'restore') restore(a[0], a[1]);
  else if (op === 'category') console.log(category(a[0], a[1]));
  else if (op === 'public-output') publicOutput(a[0], a[1]);
  else if (op === 'evidence-dir') console.log(evidenceDir(a[0], a[1]));
  else if (op === 'evidence-meta') await evidenceMeta(a);
  else if (op === 'private-temp') {
    const local = path.join(a[0], '.local'); safeDir(local);
    console.log(fs.mkdtempSync(path.join(local, 'capture-')));
  }
  else if (op === 'filter') {
    const raw = fs.readFileSync(a[0], 'utf8');
    fs.writeFileSync(a[1], raw.split('\n').filter(line => line.includes(a[2])).join('\n'));
  }
  else if (op === 'auth') {
    const s = fs.readFileSync(a[0], 'utf8').replace(/\x1b\[[0-9;]*m/g, '').trim();
    if (!/^Current user: [^\r\n\x00-\x1f]+$/.test(s)) fail('login-not-confirmed');
  } else fail('unsupported-operation');
  return 0;
}
module.exports = { inventory, select, ready, digest, windowsCommand, text, templateCheck, imageGate, startHealth, inventoryCheck, main };
if (require.main === module) main(process.argv.slice(2)).then(code => { process.exitCode = code; }).catch(error => {
  // Only locally defined category identifiers are public, never exception messages from SDK/files.
  const code = /^[a-z][a-z0-9-]+$/.test(error.message) ? error.message : 'support-operation-failed';
  console.error('[error] ' + code); process.exitCode = 1;
});
