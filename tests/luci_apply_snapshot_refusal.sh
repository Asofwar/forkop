#!/usr/bin/env bash
set -euo pipefail

# Save & Apply on the Rules and Settings pages (configform.js) never applies
# without its pre-apply snapshot, and a refusal says why (UC-225, UC-022):
# the snapshot store being full points to deleting a manual snapshot, a busy
# store, a store that cannot be locked, an unreadable configuration and a
# snapshot that cannot be written each have their own text. The pages are
# driven as LuCI drives them (the footer's Save & Apply of the view,
# UC-064, UC-224): the changes are saved, as Save does, and the page says
# so; ui.changes.apply() never runs, the health is not read and the service
# is not shown as reloading.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment, cliAnswers } = require(process.argv[2]);
// main.js logs every CLI call at debug level.
const print = console.log;
console.log = (...args) => `${args[0]}`.startsWith('[DEBUG]') || print(...args);

const config = {
  vpn: { '.name': 'vpn', '.type': 'section', '.anonymous': false, enabled: '1', label: 'VPN',
    action: 'connection', selector_proxy_links: ['socks5://10.0.0.1:1080'] },
};
const SAVED = 'The changes are saved: Save & Apply applies them once a snapshot can be taken.';

async function saveApply(snapshot, version = '24.10') {
  const log = [];
  const env = createEnvironment({ version, config, fs: cliAnswers({ config_snapshot_create: snapshot }, log) });
  const stored = [];
  env.main.store.set = (value) => stored.push(value);
  const rules = await env.openRules();
  rules.setEnabled('vpn', '0');
  await rules.saveApply('0');
  // Refused before anything else: no apply, no "reloading", no health read.
  assert.deepEqual(log.filter((entry) => !/^exec config_snapshot_create automatic$/.test(entry)), []);
  assert.deepEqual(env.ui.changes.applies, []);
  assert.deepEqual(stored, []);
  assert.equal(env.uci.data.vpn.enabled, '0', 'the changes must be saved');
  assert.equal(env.notifications.length, 1);
  assert.equal(env.notifications[0].type, 'error');
  const [reason, saved] = env.notifications[0].node.childNodes.map((node) => node.textContent);
  assert.equal(saved, SAVED);
  return reason;
}

const refused = (reason, status = 'failed') => ({ code: 1, data: { status, reason } });

(async () => {
  for (const version of ['24.10', '25.12']) {
    const full = await saveApply(refused('retention_full'), version);
    assert.match(full, /Snapshot storage is full/);
    assert.match(full, /delete a manual snapshot in History and recovery/);
    assert.match(full, /Changes were not applied/);
  }

  assert.match(await saveApply(refused('snapshot_operation_in_progress', 'busy')),
    /Another snapshot operation is already in progress\. Changes were not applied/);
  assert.match(await saveApply(refused('lock_unavailable')), /snapshot storage could not be locked/);
  assert.match(await saveApply(refused('config_unavailable')), /configuration file could not be read/);
  for (const reason of ['write_failed', 'hash_unavailable'])
    assert.match(await saveApply(refused(reason)), /could not be written\. Check the free space on the router/);

  // No answer, or one this page does not know: the general refusal.
  const general = 'Could not save a pre-apply configuration snapshot. Changes were not applied.';
  assert.equal(await saveApply({ code: 1, stdout: '' }), general);
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
