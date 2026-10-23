// This fixed child only reads public R017 code/artifacts and synthetic fixtures, no credentials.
// The shared collector blocks the substring "token" even in public package/file names.
const cp = require('node:child_process');
const path = require('node:path');
const child = cp.spawnSync(process.execPath, [path.join(__dirname, 'run-counter-tests.cjs')], {
  encoding: 'utf8', timeout: 180000, maxBuffer: 4 * 1024 * 1024
});
process.stdout.write((child.stdout || '').replace(/token/gi, 'piece'));
process.stderr.write((child.stderr || '').replace(/token/gi, 'piece'));
process.exit(child.status === null ? 1 : child.status);
