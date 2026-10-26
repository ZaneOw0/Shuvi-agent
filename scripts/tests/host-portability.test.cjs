'use strict';
// Cross-platform guard for the host-test harness. Every historical failure in this area was
// of one class: an assertion that depended on the platform's path separator or line endings
// (whitelists compared against `path.relative`, source-file hashes over CRLF checkouts,
// `.cache/` assumed to exist). The rules below are deliberately narrow so that only
// assertions can fail the guard, never diagnostics that merely print a fingerprint.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');

const projectRoot = path.resolve(__dirname, '../..');
const harnessRoot = path.join(projectRoot, 'entry/src/test');
// Files the CI actually executes; the guard scans these with every rule.
const CI_HARNESS = /(?:run-(?:host-tests|direct-model-tests|floating-placement-tests|mcp-probe-tests)|-host-cases|-host-entry|mineru-host-loader|result-pages-offline|corpus-fixtures)\.cjs$/;
const BINARY_FIXTURE_READ = /\.cache\/|\.(?:png|webp|jpe?g|zip|pdf|bin)\b/i;

function harnessFiles() {
  const files = [];
  const walk = dir => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      if (entry.name === 'node_modules' || entry.name === '.cache') continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith('.cjs')) files.push(full);
    }
  };
  walk(harnessRoot);
  return files;
}

const relative = file => path.relative(projectRoot, file).replace(/\\/g, '/');

// --- rules (pure functions so the negative self-checks can exercise them) ---

// A whitelist/loader key derived from the filesystem must be POSIX-normalised before it is
// compared with a repository-relative literal.
function unnormalisedWhitelistKey(line) {
  if (!/path\.relative\(/.test(line)) return false;
  if (/toPosix\(|relativePosix\(|path\.sep/.test(line)) return false;
  return /\.replace\(\/\\\.ets\$\/|allowed\.includes\(|\.includes\(\s*relative|startsWith\(\s*['"][^'"]*\//.test(line);
}

// A hash of a *text* source file that feeds an assertion must ignore CRLF, otherwise the
// same commit passes on macOS/Linux and fails on a Windows checkout.
function unnormalisedTextHashAssertion(line) {
  if (!/createHash\('sha256'\)/.test(line)) return false;
  if (!/readFileSync\(/.test(line)) return false;
  if (!/assert|!==|===|throw/.test(line)) return false;      // diagnostics may print raw digests
  if (BINARY_FIXTURE_READ.test(line)) return false;          // binary fixtures are pinned as bytes
  return !/toLf\(|readTextLf\(|\\r\\n/.test(line);
}

// Gitignored directories never exist on a fresh checkout: create them instead of asserting.
function assumesCacheExists(line) {
  return /SyntheticParentMissing/.test(line) || /statSync\([^)]*\.cache[^)]*\)\)\s*throw/.test(line);
}

const rules = [
  ['whitelist-key-without-posix-normalisation', unnormalisedWhitelistKey],
  ['text-hash-assertion-without-eol-normalisation', unnormalisedTextHashAssertion],
  ['cache-directory-assumed-to-exist', assumesCacheExists]
];

test('rule matchers detect the historical violations and ignore legitimate shapes', () => {
  // historical docx/unified whitelist bug
  assert.equal(unnormalisedWhitelistKey("const relative = path.relative(root,file).replace(/\\.ets$/,''); if(!allowed.includes(relative)) throw Error();"), true);
  assert.equal(unnormalisedWhitelistKey("const relative = relativePosix(root,file).replace(/\\.ets$/,''); if(!allowed.includes(relative)) throw Error();"), false);
  // loader key that is only fed back into the same loader is not a whitelist
  assert.equal(unnormalisedWhitelistKey('mod.require = id => id.startsWith(\'.\') ? load(path.relative(outputRoot, path.resolve(path.dirname(file), id))) : require(id);'), false);
  // boundary check against a repository-relative literal is a whitelist comparison
  assert.equal(unnormalisedWhitelistKey("const target = path.relative(project, file); if (!target.startsWith('entry/src/main/ets/knowledge/')) throw Error();"), true);
  // historical source-hash assertion over a CRLF-sensitive checkout
  assert.equal(unnormalisedTextHashAssertion("assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(project,file))).digest('hex'), expected);"), true);
  assert.equal(unnormalisedTextHashAssertion("assert.equal(crypto.createHash('sha256').update(toLf(fs.readFileSync(file,'utf8'))).digest('hex'), expected);"), false);
  // diagnostics and binary fixtures are allowed
  assert.equal(unnormalisedTextHashAssertion("console.log(`SRC_SHA256 ${name} ${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`);"), false);
  assert.equal(unnormalisedTextHashAssertion("assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(project,'.cache/m3-input/photo.png'))).digest('hex'), expected);"), false);
  // .cache assumption
  assert.equal(assumesCacheExists("if(!fs.statSync(path.join(project,'.cache')).isDirectory())throw Error('SyntheticParentMissing');"), true);
  assert.equal(assumesCacheExists('ensureDir(path.join(project,\'.cache\'));'), false);
});

test('host harness has no platform-dependent whitelist, hash assertion or .cache assumption', () => {
  const offenders = [];
  for (const file of harnessFiles()) {
    const ciHarness = CI_HARNESS.test(path.basename(file));
    const lines = fs.readFileSync(file, 'utf8').split('\n');
    lines.forEach((line, index) => {
      for (const [name, rule] of rules) {
        if (name !== 'whitelist-key-without-posix-normalisation' && !ciHarness) continue;
        if (rule(line)) offenders.push(`${relative(file)}:${index + 1} [${name}] ${line.trim().slice(0, 140)}`);
      }
    });
  }
  assert.deepEqual(offenders, []);
});

test('repository pins LF for text and CRLF only for batch scripts', () => {
  const attributes = fs.readFileSync(path.join(projectRoot, '.gitattributes'), 'utf8').split(/\r?\n/);
  const indexOfFirstMatch = predicate => attributes.findIndex(predicate);
  const globalRule = indexOfFirstMatch(line => /^\* text=auto eol=lf\s*$/.test(line));
  const cmdRule = indexOfFirstMatch(line => /^\*\.cmd text eol=crlf\s*$/.test(line));
  const batRule = indexOfFirstMatch(line => /^\*\.bat text eol=crlf\s*$/.test(line));
  assert.ok(globalRule >= 0, 'missing global "* text=auto eol=lf" rule');
  assert.ok(cmdRule > globalRule, '*.cmd must override the global rule with eol=crlf');
  assert.ok(batRule > globalRule, '*.bat must override the global rule with eol=crlf');
});

// Files that `.gitattributes` pins to `eol=lf` are the ones whose bytes tests depend on
// (frozen fixtures, hashed sources, gold sets). The global `* text=auto eol=lf` rule is not a
// pin: it only guarantees LF on a fresh checkout, whereas a long-lived CI worktree may still
// hold pre-pin CRLF bytes for unrelated files.
function lfPinMatchers(attributes) {
  const matchers = [];
  for (const line of attributes.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const parts = trimmed.split(/\s+/);
    if (parts.length < 2 || parts[0] === '*') continue;
    if (!parts.includes('eol=lf')) continue;
    const escaped = parts[0].replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '[^/]*');
    matchers.push({ pattern: parts[0], regex: new RegExp('^' + escaped + '$') });
  }
  return matchers;
}

test('attribute matcher understands wildcard and literal LF pins', () => {
  const matchers = lfPinMatchers([
    '* text=auto eol=lf',
    '*.cmd text eol=crlf',
    '*.md text eol=lf',
    'entry/src/test/fixtures/*.txt text eol=lf',
    'oh-package.json5 text eol=lf'
  ].join('\n'));
  const matches = file => matchers.some(m => m.regex.test(file));
  assert.equal(matchers.length, 3);
  assert.equal(matches('LICENSE.md'), true);
  assert.equal(matches('entry/src/test/fixtures/apache-license-2.0.txt'), true);
  assert.equal(matches('entry/src/test/fixtures/corpus/manifest.json'), false);
  assert.equal(matches('oh-package.json5'), true);
  assert.equal(matches('scripts/ci-windows.cmd'), false);
});

test('files pinned to eol=lf are actually checked out as LF', t => {
  const matchers = lfPinMatchers(fs.readFileSync(path.join(projectRoot, '.gitattributes'), 'utf8'));
  assert.ok(matchers.length >= 5, 'expected several explicit eol=lf pins');
  let files;
  try {
    files = cp.execFileSync('git', ['ls-files', '-z'], { cwd: projectRoot, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
      .split('\0').filter(Boolean);
  } catch {
    t.skip('git unavailable; the LF pin invariant is enforced by the checkout instead');
    return;
  }
  const offenders = [];
  let checked = 0;
  for (const file of files) {
    const posix = file.replace(/\\/g, '/');
    if (!matchers.some(m => m.regex.test(posix))) continue;
    let bytes;
    try { bytes = fs.readFileSync(path.join(projectRoot, file)); } catch { continue; }
    if (bytes.includes(0)) continue; // binary fixture, pinned by bytes
    checked++;
    if (bytes.includes(Buffer.from('\r\n'))) offenders.push(posix);
  }
  assert.ok(checked > 0, 'expected at least one pinned file to be checked');
  assert.deepEqual(offenders, []);
});
