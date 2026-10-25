'use strict';
// Cross-platform helpers for the host-test harness. Platform-sensitive values (path
// separators, EOL) must be normalised at the boundary so assertions and whitelists do not
// depend on whether the tests run on Windows, macOS or Linux.
const fs = require('node:fs');
const path = require('node:path');

// Repository-relative / synthetic path keys are always POSIX. `path.relative` and
// `path.join` return "\" on Windows, which never matches a whitelist written with "/".
const toPosix = value => String(value).replace(/\\/g, '/');

const relativePosix = (from, to) => toPosix(path.relative(from, to));

// Creates a directory (and parents) instead of assuming it already exists. `.cache/` is
// gitignored, so a fresh checkout never has it.
const ensureDir = dir => {
  fs.mkdirSync(dir, { recursive: true });
  return dir;
};

// Text assertions and text hashes must not depend on CRLF vs LF. Binary fixtures are pinned
// as bytes and never go through this helper.
const toLf = value => String(value).replace(/\r\n?/g, '\n');

const readTextLf = file => toLf(fs.readFileSync(file, 'utf8'));

module.exports = { toPosix, relativePosix, ensureDir, toLf, readTextLf };
