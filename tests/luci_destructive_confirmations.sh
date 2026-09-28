#!/usr/bin/env bash
set -euo pipefail

# Destructive or disruptive actions must ask for confirmation before the
# backend call: stopping Forkop X, removing a component package, closing all
# connections and restoring or deleting a configuration snapshot.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const root = process.argv[2];
const read = file => fs.readFileSync(path.join(root, file), 'utf8');

function functionBody(source, signature) {
  const start = source.indexOf(signature);
  assert(start >= 0, `${signature} not found`);
  const open = source.indexOf('{', start + signature.length - 1);
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === '{') depth++;
    if (source[i] === '}' && --depth === 0) return source.slice(open, i + 1);
  }
  throw Error(`${signature} is not closed`);
}

function assertConfirmedBefore(body, confirmCall, backendCall, label) {
  const confirmAt = body.indexOf(confirmCall);
  const backendAt = body.indexOf(backendCall);
  assert(confirmAt >= 0, `${label}: no confirmation`);
  assert(backendAt > confirmAt, `${label}: backend call runs before the confirmation`);
  assert.match(body.slice(confirmAt, backendAt), /if \(!confirmed[^)]*\)\s*\{?\s*return/,
    `${label}: a declined confirmation must stop the action`);
}

const diagnostics = read('fe-app-forkop/src/forkop/tabs/diagnostic/initController.ts');
assertConfirmedBefore(functionBody(diagnostics, 'async function handleStop()'),
  'confirmStopForkop(', 'handleServiceRuntimeAction(', 'stop Forkop X');

const dashboard = read('fe-app-forkop/src/forkop/tabs/dashboard/initController.ts');
assert.match(functionBody(dashboard, 'async function handleServiceAction(action: ForkopServiceAction)'),
  /action === 'stop' && !\(await confirmStopForkop\(\)\)\) return;[\s\S]*runForkopServiceAction\(action\)/,
  'overview: stop Forkop X must be confirmed before the service job');
const control = read('fe-app-forkop/src/forkop/tabs/shared/serviceControl.ts');
assert.match(functionBody(control, 'export function confirmStopForkop()'), /confirmAction\(\{[\s\S]*danger: true/,
  'the shared stop confirmation must be a destructive confirmAction');

const monitoring = read('fe-app-forkop/src/forkop/tabs/monitoring/initController.ts');
assertConfirmedBefore(functionBody(monitoring, 'async function closeAllConnections()'),
  'confirmAction(', 'closeAllClashApiConnections(', 'close all connections');

const updates = read('fe-app-forkop/src/forkop/tabs/updates/initController.ts');
const componentAction = functionBody(updates,
  'async function handleComponentAction(button: ComponentActionButton)');
assert.match(componentAction,
  /button\.action === 'remove' &&\s*!\(await confirmComponentRemoval\(button\)\)[\s\S]*?return;/,
  'component removal must be confirmed');
assert(componentAction.indexOf('confirmComponentRemoval') < componentAction.indexOf('componentActionStart('),
  'component removal is confirmed before the backend call');

const settings = read('luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js');
assertConfirmedBefore(settings, 'confirmSnapshotAction({\n            title: _("Restore',
  'snapshotRestore(', 'restore snapshot');
assertConfirmedBefore(settings, 'confirmSnapshotAction({\n            title: _("Delete',
  'snapshotDelete(', 'delete snapshot');
assert.equal(settings.match(/window\.confirm\(/g).length, 1,
  'window.confirm is only the fallback for a stale bundle');

console.log('Destructive actions ask for confirmation first');
NODE
