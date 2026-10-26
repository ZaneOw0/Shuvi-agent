// Run the imported MCP fixture contract tests on a temporary loopback port.
const path = require('node:path');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const fixtureRoot = path.resolve(__dirname, '../tools/agent/fixture');

async function main() {
  const server = spawn(process.execPath, [path.join(fixtureRoot, 'fixture-server.mjs')], {
    windowsHide: true, stdio: ['ignore', 'pipe', 'pipe']
  });
  const serverExit = once(server, 'exit');
  let suite;
  let deadline;
  try {
    const ready = await new Promise((resolve, reject) => {
      let output = '';
      deadline = setTimeout(() => reject(new Error('Fixture startup timed out')), 10000);
      server.once('error', reject);
      server.once('exit', code => reject(new Error(`Fixture exited before ready: ${code}`)));
      server.stdout.on('data', chunk => {
        output += chunk;
        const newline = output.indexOf('\n');
        if (newline < 0) return;
        try { resolve(JSON.parse(output.slice(0, newline))); } catch (error) { reject(error); }
      });
      server.stderr.on('data', chunk => process.stderr.write(chunk));
    });
    clearTimeout(deadline);
    if (ready.host !== '127.0.0.1' || !Number.isInteger(ready.port) || ready.port < 1 || ready.port > 65535) {
      throw new Error('Invalid fixture listener');
    }
    suite = spawn(process.execPath, ['--test', '--test-timeout=20000', path.join(fixtureRoot, 'fixture-contract.test.mjs')], {
      windowsHide: true, stdio: 'inherit',
      env: { ...process.env, MCP_FIXTURE_URL: `http://127.0.0.1:${ready.port}`, MCP_PROTOCOL: 'Both' }
    });
    deadline = setTimeout(() => suite.kill(), 120000);
    const [code] = await once(suite, 'exit');
    if (code !== 0) throw new Error(`Fixture tests failed: ${code}`);
  } finally {
    clearTimeout(deadline);
    if (suite && suite.exitCode === null) suite.kill();
    if (server.exitCode === null) server.kill();
    await serverExit;
  }
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
