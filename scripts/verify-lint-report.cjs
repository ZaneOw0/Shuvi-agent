const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const logNames = ['codelinter.log', 'arkPerfCheck.log', 'hpauditor.log'];
const hash = data => crypto.createHash('sha256').update(data).digest('hex');
const decode = data => data[0] === 0xff && data[1] === 0xfe
  ? data.subarray(2).toString('utf16le') : data.toString('utf8').replace(/^\uFEFF/, '');
const genericError = /\[(?:ERROR|FATAL)\]|Invalid rule name|Error running file check|No permission to access|(?:TypeError|ReferenceError|SyntaxError):/i;
const crashLine = /Error running file check for (.+?): Cannot read properties of undefined \(reading 'getDeclaringMethod'\)/i;

// Known defects of the pinned Code Linter build (DevEco Studio / Command Line Tools
// 26.0.0.821 ships Code Linter 6.0.240). The ArkTS analyzer aborts on these files with
// "Cannot read properties of undefined (reading 'getDeclaringMethod')", so they are
// scanned but never checked. The exemption is exact and auditable:
//   - a crash on any file that is not listed here still fails the gate;
//   - the same file crashing with a different message still fails the gate;
//   - any other analyzer ERROR/FATAL still fails the gate;
//   - the exemption only applies while the reported tool version matches the baseline.
// Remove every entry after upgrading the toolchain, then re-run the gate.
const KNOWN_DEFECT_TOOL_VERSION = '6.0.240';
const KNOWN_ANALYZER_CRASHES = [
  'entry/src/main/ets/pages/Index.ets',
  'entry/src/main/ets/mock/MockAssistantService.ets',
  'entry/src/main/ets/knowledge/infra/RdbKnowledgeStore.ets',
  'entry/src/main/ets/knowledge/probe/KnowledgeProbe.ets',
  'entry/src/main/ets/knowledge/ui/KnowledgeVisuals.ets',
  'modules/harmony_agent/mcp_client/src/main/ets/mcp/McpClientManager.ets',
  'modules/harmony_agent/mcp_client/src/main/ets/mcp/SseParser.ets',
  'modules/harmony_agent/mcp_client/src/main/ets/mcp/internal/ProtocolClient.ets',
  'modules/harmony_agent/mcp_client/src/main/ets/mcp/internal/Transport.ets'
];

function snapshot(logDirectory, runDirectory) {
  const logs = {};
  for (const name of logNames) {
    const file = path.join(logDirectory, name);
    if (!fs.existsSync(file)) { logs[name] = null; continue; }
    const data = fs.readFileSync(file);
    logs[name] = { size: data.length, sha256: hash(data) };
  }
  fs.writeFileSync(path.join(runDirectory, 'before.json'), JSON.stringify({
    startedAt: Date.now(), logDirectory: path.resolve(logDirectory), logs
  }, null, 2));
}

// Only exact, enumerated tool defects may be exempted; everything else stays a failure.
function collectAnalyzerErrors(text, coverageGaps) {
  const unexpected = [];
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const crash = line.match(crashLine);
    if (crash) {
      const file = crash[1].replace(/\\/g, '/');
      const known = KNOWN_ANALYZER_CRASHES.find(entry => file === entry || file.endsWith('/' + entry));
      if (known) {
        if (!coverageGaps.analyzerCrashFiles.includes(known)) coverageGaps.analyzerCrashFiles.push(known);
      } else {
        unexpected.push(line);
      }
      continue;
    }
    if (genericError.test(line)) unexpected.push(line);
  }
  return unexpected;
}

function verify(runDirectory, exitCode, toolVersion) {
  const before = JSON.parse(fs.readFileSync(path.join(runDirectory, 'before.json'), 'utf8'));
  const problems = [];
  const coverageGaps = { analyzerCrashFiles: [], toolVersion: toolVersion || 'unreported' };
  // Older CLT versions return 1 on a clean report. Never accept other exit codes.
  if (![0, 1].includes(exitCode)) problems.push(`Unexpected linter exit code: ${exitCode}`);
  const readFresh = file => {
    const stat = fs.statSync(file);
    if (!stat.isFile() || stat.mtimeMs < before.startedAt - 2000) throw new Error('Missing or stale evidence');
    return fs.readFileSync(file);
  };
  let issueCount = 0;
  try {
    const report = JSON.parse(decode(readFresh(path.join(runDirectory, 'report.json'))));
    if (!Array.isArray(report)) throw new Error('Report must be an array');
    for (const item of report) {
      if (!item || typeof item.filePath !== 'string' || !Array.isArray(item.messages)) throw new Error('Invalid report entry');
      // An entry without diagnostics is not the verified empty-report format ([]).
      if (!item.messages.length) throw new Error('Unexpected empty report entry');
      issueCount += item.messages.length;
    }
    if (issueCount) problems.push(`Code Linter reported ${issueCount} diagnostic(s)`);
  } catch { problems.push('Report missing, stale, malformed or not a valid diagnostic array'); }

  const currentLogs = {};
  for (const name of logNames) {
    try {
      let data = readFresh(path.join(before.logDirectory, name));
      const previous = before.logs[name];
      if (previous && data.length >= previous.size && hash(data.subarray(0, previous.size)) === previous.sha256) {
        data = data.subarray(previous.size);
      }
      const text = decode(data);
      if (!text.trim()) throw new Error('Log did not change');
      // Keep only this run's appended/replaced evidence; never erase shared tool logs.
      fs.writeFileSync(path.join(runDirectory, `evidence-${name}`), data);
      currentLogs[name] = text;
      const errors = name === 'arkPerfCheck.log'
        ? collectAnalyzerErrors(text, coverageGaps)
        : (text.match(genericError) || []);
      if (errors.length) problems.push(`Analyzer failed or coverage incomplete: ${name}`);
    } catch { problems.push(`Missing, stale or unchanged analyzer log: ${name}`); }
  }
  if (coverageGaps.analyzerCrashFiles.length) {
    if (coverageGaps.toolVersion === 'unreported') {
      problems.push('Code Linter version not reported; the analyzer-defect exemption cannot be justified');
    } else if (coverageGaps.toolVersion !== KNOWN_DEFECT_TOOL_VERSION) {
      problems.push(`Code Linter ${coverageGaps.toolVersion} differs from exemption baseline ${KNOWN_DEFECT_TOOL_VERSION}; re-validate and refresh the known-defect list`);
    }
  }
  if (!/cli completed/.test(currentLogs['codelinter.log'] || '')) problems.push('CLI completion marker missing');
  const arkLog = currentLogs['arkPerfCheck.log'] || '';
  if (!/File count:\s*[1-9]\d*\b/.test(arkLog) || !/Checking completed/.test(arkLog) || !/HomeCheck took:/.test(arkLog)) {
    problems.push('ArkTS analyzer did not complete a non-empty scan');
  }
  if (!/hpauditor completed, exitCode:\s*0\b/.test(currentLogs['hpauditor.log'] || '')) {
    problems.push('Security/performance analyzer completion missing or unsuccessful');
  }
  const consoleFile = path.join(runDirectory, 'console.log');
  try {
    const text = decode(readFresh(consoleFile));
    if (/\b(?:EPERM|EACCES|ENOENT)\b|\[(?:ERROR|FATAL)\]|(?:TypeError|ReferenceError|SyntaxError):/i.test(text)) {
      problems.push('Linter console contains execution errors');
    }
  } catch { problems.push('Console evidence missing or stale'); }
  const result = { passed: problems.length === 0, exitCode, issueCount, problems, coverageGaps };
  fs.writeFileSync(path.join(runDirectory, 'summary.json'), JSON.stringify(result, null, 2) + '\n');
  return result;
}

module.exports = { snapshot, verify, KNOWN_ANALYZER_CRASHES, KNOWN_DEFECT_TOOL_VERSION };
if (require.main === module) {
  try {
    const [mode, first, second, third] = process.argv.slice(2);
    if (mode === 'snapshot' && first && second) snapshot(first, second);
    else if (mode === 'verify' && first && /^-?\d+$/.test(second || '')) {
      const result = verify(first, Number(second), third);
      console.log(JSON.stringify(result));
      process.exitCode = result.passed ? 0 : 1;
    } else throw new Error('Usage: snapshot <log-dir> <run-dir> | verify <run-dir> <exit-code> [tool-version]');
  } catch (error) {
    console.error(`Lint evidence check failed: ${error.message}`);
    process.exitCode = 1;
  }
}
