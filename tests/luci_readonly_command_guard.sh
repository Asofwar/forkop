#!/usr/bin/env bash
set -euo pipefail

# A read-only LuCI session must not issue a single command outside the read
# grants of the ACL: the frontend refuses everything else locally
# (fe-app-forkop/src/forkop/services/readonlyCommandGuard.ts). The allowlist
# there must stay identical to the ACL, and the pages must ask for the
# masked variants the read role is allowed to run.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const root = process.argv[2];

const acl = JSON.parse(fs.readFileSync(
  path.join(root, 'luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json'), 'utf8'));
const grants = Object.entries(acl['luci-app-forkop'].read.file)
  .filter(([, permissions]) => permissions.includes('exec'))
  .map(([pattern]) => pattern)
  .sort();

const guard = fs.readFileSync(
  path.join(root, 'fe-app-forkop/src/forkop/services/readonlyCommandGuard.ts'), 'utf8');
const block = guard.match(/READONLY_EXEC_PATTERNS = \[([\s\S]*?)\];/);
assert(block, 'READONLY_EXEC_PATTERNS not found');
const patterns = [...block[1].matchAll(/'([^']+)'/g)].map(match => match[1]).sort();
assert.deepEqual(patterns, grants, 'frontend read-only allowlist differs from the ACL read grants');

const shell = fs.readFileSync(
  path.join(root, 'fe-app-forkop/src/helpers/executeShellCommand.ts'), 'utf8');
assert.match(shell, /shouldRefuseCommand\(command, args\)[\s\S]*?return \{[^}]*READONLY_REFUSED/,
  'executeShellCommand must refuse commands before fs.exec');
assert(shell.indexOf('shouldRefuseCommand(') < shell.indexOf('fs.exec('),
  'the read-only check must run before fs.exec');

const diagnostics = fs.readFileSync(
  path.join(root, 'fe-app-forkop/src/forkop/tabs/diagnostic/initController.ts'), 'utf8');
for (const method of ['globalCheck', 'showSingBoxConfig']) {
  assert.doesNotMatch(diagnostics, new RegExp(`${method}\\(false\\)`),
    `${method} must not request raw output regardless of the role`);
  assert.match(diagnostics, new RegExp(`${method}\\(\\s*readonly\\s*\\)`),
    `${method} must request the masked output in a read-only session`);
}

console.log('LuCI read-only command guard matches the ACL');
NODE
