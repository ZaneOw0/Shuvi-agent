const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { snapshot, verify, KNOWN_ANALYZER_CRASHES, KNOWN_DEFECT_TOOL_VERSION } = require('../verify-lint-report.cjs');

const root = path.resolve(__dirname, '../../.local/lint-gate-tests');
fs.mkdirSync(root, { recursive: true });
const goodLogs = {
  'codelinter.log': '[INFO] cli completed, exitCode: 0\n',
  'arkPerfCheck.log': '[INFO] File count: 136\n[INFO] Checking completed.\n[INFO] HomeCheck took: 2 s.\n',
  'hpauditor.log': '[INFO] hpauditor completed, exitCode:0\n'
};
function fixture(t, previous = {}) {
  const dir = fs.mkdtempSync(path.join(root, 'run-'));
  const logs = path.join(dir, 'engine');
  const run = path.join(dir, 'result');
  fs.mkdirSync(logs); fs.mkdirSync(run);
  for (const [name, text] of Object.entries(previous)) fs.writeFileSync(path.join(logs, name), text);
  snapshot(logs, run);
  for (const [name, text] of Object.entries(goodLogs)) fs.appendFileSync(path.join(logs, name), text);
  fs.writeFileSync(path.join(run, 'report.json'), '[]');
  fs.writeFileSync(path.join(run, 'console.log'), 'Finished\n');
  t.after(() => {
    // Only remove this test-created directory inside the fixed ignored test root.
    if (path.dirname(dir) !== root || !path.basename(dir).startsWith('run-')) throw new Error('Unsafe cleanup path');
    fs.rmSync(dir, { recursive: true });
  });
  return { logs, run };
}

for (const code of [0, 1]) test(`complete clean evidence accepts supported exit ${code}`, t => {
  const { run } = fixture(t);
  assert.equal(verify(run, code).passed, true);
});
test('empty report cannot hide analyzer exception or invalid rule', t => {
  const { run, logs } = fixture(t);
  fs.appendFileSync(path.join(logs, 'arkPerfCheck.log'), '[ERROR] Invalid rule name: example\nError running file check\n');
  assert.equal(verify(run, 0).passed, false);
});
test('old engine errors are not confused with this run, shared logs remain intact', t => {
  const old = '[ERROR] old failure\n';
  const { run, logs } = fixture(t, { 'arkPerfCheck.log': old });
  assert.equal(verify(run, 0).passed, true);
  assert.ok(fs.readFileSync(path.join(logs, 'arkPerfCheck.log'), 'utf8').startsWith(old));
  assert.ok(!fs.readFileSync(path.join(run, 'evidence-arkPerfCheck.log'), 'utf8').includes(old));
});
test('replaced engine log is captured as a new run', t => {
  const { run, logs } = fixture(t, { 'arkPerfCheck.log': '[ERROR] old failure\n' });
  fs.writeFileSync(path.join(logs, 'arkPerfCheck.log'), goodLogs['arkPerfCheck.log']);
  assert.equal(verify(run, 0).passed, true);
});
for (const report of ['{}', 'null', 'not json', '[{}]', '[{"filePath":"file.ets","messages":[]}]']) {
  test(`reject malformed report ${report}`, t => {
    const { run } = fixture(t);
    fs.writeFileSync(path.join(run, 'report.json'), report);
    assert.equal(verify(run, 0).passed, false);
  });
}
test('any diagnostic fails regardless of process exit', t => {
  const { run } = fixture(t);
  fs.writeFileSync(path.join(run, 'report.json'), JSON.stringify([{ filePath: 'file.ets', messages: [{ severity: 'suggestion' }] }]));
  const result = verify(run, 0);
  assert.equal(result.passed, false); assert.equal(result.issueCount, 1);
});
test('missing engine log or missing completion cannot pass', t => {
  const { run, logs } = fixture(t);
  fs.unlinkSync(path.join(logs, 'hpauditor.log'));
  fs.writeFileSync(path.join(logs, 'arkPerfCheck.log'), '[INFO] File count: 1\n');
  assert.equal(verify(run, 0).passed, false);
});
test('unchanged previous logs cannot pass', t => {
  const { run, logs } = fixture(t);
  snapshot(logs, run);
  assert.equal(verify(run, 0).passed, false);
});
test('stale report fails', t => {
  const { run } = fixture(t);
  const old = new Date(Date.now() - 60000);
  fs.utimesSync(path.join(run, 'report.json'), old, old);
  assert.equal(verify(run, 0).passed, false);
});
test('zero scanned files, unreadable sources and unexpected exit fail', t => {
  const { run, logs } = fixture(t);
  fs.writeFileSync(path.join(logs, 'arkPerfCheck.log'), goodLogs['arkPerfCheck.log'].replace('136', '0'));
  fs.appendFileSync(path.join(logs, 'codelinter.log'), 'No permission to access source\n');
  assert.equal(verify(run, 2).passed, false);
});
test('PowerShell UTF-16 console errors are detected', t => {
  const { run } = fixture(t);
  fs.writeFileSync(path.join(run, 'console.log'), Buffer.from('\uFEFFError: EPERM', 'utf16le'));
  assert.equal(verify(run, 0).passed, false);
});

// Known-defect allowlist: exact signatures only, pinned to the pinned tool version.
const crashLog = file => '[2026-10-25T16:50:20.973] [ERROR] [44672] [HomeCheck] - [CheckEntry] '
  + `Error running file check for D:\\runner\\_work\\Shuvi-agent\\Shuvi-agent\\${file}: `
  + "Cannot read properties of undefined (reading 'getDeclaringMethod')\n";

for (const file of KNOWN_ANALYZER_CRASHES) {
  test(`known analyzer crash is exempted and recorded as a coverage gap: ${file}`, t => {
    const { run, logs } = fixture(t);
    fs.appendFileSync(path.join(logs, 'arkPerfCheck.log'), crashLog(file));
    const result = verify(run, 1, KNOWN_DEFECT_TOOL_VERSION);
    assert.equal(result.passed, true);
    assert.deepEqual(result.coverageGaps.analyzerCrashFiles, [file]);
    assert.equal(result.coverageGaps.toolVersion, KNOWN_DEFECT_TOOL_VERSION);
  });
}

test('analyzer crash on an unlisted file still fails', t => {
  const { run, logs } = fixture(t);
  fs.appendFileSync(path.join(logs, 'arkPerfCheck.log'), crashLog('entry/src/main/ets/pages/Other.ets'));
  assert.equal(verify(run, 1, KNOWN_DEFECT_TOOL_VERSION).passed, false);
});

test('same file crashing with a different message still fails', t => {
  const { run, logs } = fixture(t);
  fs.appendFileSync(path.join(logs, 'arkPerfCheck.log'),
    '[ERROR] [1] [HomeCheck] - [CheckEntry] Error running file check for D:\\x\\entry\\src\\main\\ets\\pages\\Index.ets: '
    + 'Cannot read properties of undefined (reading \'getModifierFlags\')\n');
  assert.equal(verify(run, 1, KNOWN_DEFECT_TOOL_VERSION).passed, false);
});

test('exemption requires the pinned tool version', t => {
  const { run, logs } = fixture(t);
  fs.appendFileSync(path.join(logs, 'arkPerfCheck.log'), crashLog(KNOWN_ANALYZER_CRASHES[0]));
  assert.equal(verify(run, 1, '6.0.250').passed, false);
  assert.equal(verify(run, 1).passed, false);
});

test('no crash exemption leaves the tool version check out of the way', t => {
  const { run } = fixture(t);
  const result = verify(run, 0, '6.0.250');
  assert.equal(result.passed, true);
  assert.deepEqual(result.coverageGaps.analyzerCrashFiles, []);
});
