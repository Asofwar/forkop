#!/usr/bin/env bash
set -euo pipefail

# Save & Apply on the Rules and Settings pages (configform.js) never applies
# without its pre-apply snapshot, and a refusal says why (UC-225, UC-022):
# the snapshot store being full points to deleting a manual snapshot, a busy
# store, a store that cannot be locked, an unreadable configuration and a
# snapshot that cannot be written each have their own text. The base apply
# never runs and the service is not shown as reloading.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = process.argv[2];
const file = path.join(root, 'luci-app-forkop/htdocs/luci-static/resources/view/forkop/configform.js');

// LuCI module: "require x as y" directives, then `return <class>`.
function load(modules) {
  const source = fs.readFileSync(file, 'utf8');
  const names = [];
  const values = [];
  for (const [, dep, alias] of source.matchAll(/^"require ([\w.]+)(?: as (\w+))?";$/gm)) {
    const name = alias || dep.split('.').pop();
    assert(name in modules, `no stub for ${dep}`);
    names.push(name);
    values.push(modules[name]);
  }
  return new Function(...names, '_', 'E', 'window', source)(
    ...values, (value) => value, (tag, attrs, children) => ({ tag, attrs, children }),
    { setTimeout() {} });
}

async function saveApply(snapshot) {
  const maps = [];
  const notes = [];
  const calls = [];
  class Map {
    constructor() { maps.push(this); }
    section() { return {}; }
    handleSaveApply() { calls.push('base apply'); return Promise.resolve('applied'); }
    render() { return 'rendered'; }
  }
  const main = {
    FORKOP_UCI_PACKAGE: 'forkop',
    store: {
      get: () => ({ servicesInfoWidget: { data: {} } }),
      set: () => calls.push('store set'),
    },
    ForkopShellMethods: {
      snapshotCreate: async (kind) => { calls.push(`snapshot ${kind}`); return snapshot; },
      getHealthStatus: async () => { calls.push('health'); return { success: false }; },
      snapshotDiff: async () => { calls.push('diff'); return { success: false }; },
      getUiState: async () => ({ success: false }),
    },
  };
  const configform = load({
    baseclass: { extend: (value) => value },
    form: { Map, GridSection: {}, TypedSection: {}, TableSection: { prototype: {} } },
    uci: { get() {} },
    ui: { addNotification(title, node, type) { notes.push({ node, type }); }, addValidator() {} },
    main,
  });
  configform.createMap('Settings', null);
  assert.equal(await maps[0].handleSaveApply({}, undefined), undefined);
  // Refused before anything else: no apply, no "reloading", no health read.
  assert.deepEqual(calls, ['snapshot automatic']);
  assert.equal(notes.length, 1);
  assert.equal(notes[0].type, 'error');
  return notes[0].node.children;
}

const refused = (reason, status = 'failed') => ({ success: true, data: { status, reason } });

(async () => {
  const full = await saveApply(refused('retention_full'));
  assert.match(full, /Snapshot storage is full/);
  assert.match(full, /delete a manual snapshot in History and recovery/);
  assert.match(full, /Changes were not applied/);

  assert.match(await saveApply(refused('snapshot_operation_in_progress', 'busy')),
    /Another snapshot operation is already in progress\. Changes were not applied/);
  assert.match(await saveApply(refused('lock_unavailable')), /snapshot storage could not be locked/);
  assert.match(await saveApply(refused('config_unavailable')), /configuration file could not be read/);
  for (const reason of ['write_failed', 'hash_unavailable'])
    assert.match(await saveApply(refused(reason)), /could not be written\. Check the free space on the router/);

  // No answer, or one this page does not know: the general refusal.
  const general = 'Could not save a pre-apply configuration snapshot. Changes were not applied.';
  assert.equal(await saveApply({ success: false }), general);
  assert.equal(await saveApply(refused('something_new')), general);

  // Every refusal says that nothing was applied.
  for (const reason of ['retention_full', 'lock_unavailable', 'config_unavailable', 'write_failed'])
    assert.match(await saveApply(refused(reason)), /Changes were not applied/);

  console.log('luci_apply_snapshot_refusal: PASS');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
