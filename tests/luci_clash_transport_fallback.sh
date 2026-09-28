#!/usr/bin/env bash
set -euo pipefail

# The sing-box controller websocket (ws://host:9090) is unreachable from an
# HTTPS LuCI page and can drop at any time. Dashboard widgets and Monitoring
# must then keep working through rpcd (`clash_api get_connections`) instead
# of showing "unavailable" until the page is reloaded.

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

const dashboard = read('fe-app-forkop/src/forkop/tabs/dashboard/initController.ts');
const start = functionBody(dashboard, 'function startDashboardDataUpdates()');
assert.match(start, /if \(canUseDirectClashApi\(\)\) \{\s*void connectToClashSockets\(dataUpdatesId\);\s*\} else \{\s*startClashRpcPolling\(dataUpdatesId\);/,
  'dashboard must poll through rpcd when the controller socket is not reachable');
const sockets = functionBody(dashboard, 'async function connectToClashSockets(dataUpdatesId: number)');
assert.equal((sockets.match(/fallBackToClashRpcPolling\(dataUpdatesId\)/g) || []).length, 2,
  'both dashboard sockets must fall back to rpcd polling on error');
assert.doesNotMatch(sockets, /failed: true/,
  'a socket error must not mark the widgets unavailable for good');
assert.match(functionBody(dashboard, 'function stopDashboardDataUpdates()'), /stopClashRpcPolling\(\)/,
  'dashboard polling must stop with the data updates');

// On Monitoring → Nodes the dashboard controller shares the page with the
// monitoring connections stream: it opens no Clash stream there and never
// closes sockets it did not open.
assert.match(start, /if \(overviewHost\) \{\s*clashUpdatesStarted = true;/,
  'the Clash traffic stream is only for the Overview page');
assert.match(functionBody(dashboard, 'function stopDashboardDataUpdates()'),
  /if \(clashUpdatesStarted\) socket\.resetAll\(\);/,
  'the dashboard must not close the monitoring socket');

const monitoring = read('fe-app-forkop/src/forkop/tabs/monitoring/initController.ts');
const monitoringSocket = functionBody(monitoring, 'async function connectToConnectionsSocket(updatesId: number)');
assert.match(monitoringSocket, /socket\.disconnect\(connectionsSocketUrl\);[\s\S]*startConnectionsPolling\(\);/,
  'monitoring must fall back to rpcd polling when the socket fails');
assert.doesNotMatch(monitoringSocket, /failed = true/,
  'a socket error must not mark connections unavailable for good');

console.log('Clash controller socket failures fall back to rpcd polling');
NODE
