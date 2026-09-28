#!/usr/bin/env bash
set -euo pipefail

# The item settings modals of a rule (subscription source, URLTest, priority
# and its levels, rule set) stack on top of the rule modal and write their
# Save into uci right away: the rule modal map shares the page's uci state.
# Dismiss of the rule modal must discard them together with the rest of the
# modal, or the next Save & Apply sends edits the user never confirmed; the
# Save button of the rule modal keeps them (UC-045). The real section.js runs
# on the LuCI model of tests/helpers/luci_form_harness.js, whose uci keeps
# staged edits the way luci-base uci.js does.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);

const B4 = 'https://mirror.infotechtg.ru/forkop/lists/b4geoip-forkop/srs';
const VALVE = `${B4}/valve.srs`;
const CUSTOM = 'https://example.com/custom.srs';

function section(name, type, values) {
  return Object.assign({ '.name': name, '.type': type, '.anonymous': false }, values);
}
const urltest = {
  check_interval: '3m', tolerance: '50', testing_url: 'https://www.gstatic.com/generate_204',
  idle_timeout: '30m', interrupt_exist_connections: '1', pin_dashboard: '1', filter_mode: 'disabled',
  detect_server_country: 'flag_emoji',
};
const priority = {
  health_url: 'https://www.gstatic.com/generate_204', active_check_interval: '5s', check_timeout: '2s',
  recovery_check_interval: '15s', pick_fastest: '0', switch_to_faster_same_priority: '0',
  fastest_check_interval: '3m', interrupt_exist_connections: '1', pin_dashboard: '1',
};
const level = { direct: '0', filter_mode: 'include', detect_server_country: 'flag_emoji' };
const config = {
  rule: section('rule', 'section', { enabled: '1', action: 'connection', mixed_proxy_enabled: '0',
    community_lists: ['youtube'], rule_set: [CUSTOM], rule_set_with_subnets: [VALVE],
    selector_proxy_links: ['socks5://10.0.0.1:1080'] }),
  sub: section('sub', 'subscription_url', { section: 'rule', url: 'https://example.com/sub',
    subscription_update_enabled: '1', subscription_update_interval: '4h' }),
  // An older editor also stored id and display_name; saving the item drops them.
  fastest: section('fastest', 'urltest', { section: 'rule', name: 'Fastest', id: 'fastest',
    display_name: 'Fastest', ...urltest }),
  pg_main: section('pg_main', 'priority_group', { section: 'rule', name: 'Main', ...priority }),
  lvl_a: section('lvl_a', 'priority_level', { group: 'pg_main', name: 'First', order: '0', ...level }),
  lvl_b: section('lvl_b', 'priority_level', { group: 'pg_main', name: 'Second', order: '1', ...level }),
};

// What each item settings modal edits, and how its Save shows in uci.
const edits = [
  ['subscription source interval', 'subscription_url', 'sub', undefined, (settings) => {
    settings.setValue('subscription_update_interval', '12h');
  }, (data) => assert.equal(data.sub.subscription_update_interval, '12h')],
  ['URLTest tolerance', 'urltest', 'fastest', undefined, (settings) => {
    settings.setValue('tolerance', '150');
  }, (data) => {
    assert.equal(data.fastest.tolerance, '150');
    assert.equal(data.fastest.id, undefined);
  }],
  ['priority renamed and a level removed', 'priority_group', 'pg_main', undefined, (settings) => {
    settings.setValue('name', 'Renamed');
    settings.setValue('priority_level', ['lvl_a']);
  }, (data) => {
    assert.equal(data.pg_main.name, 'Renamed');
    assert.equal(data.lvl_b, undefined);
  }],
  ['new priority', 'priority_group', '', { adding: true }, (settings) => {
    settings.setValue('name', 'Backup');
  }, (data) => {
    assert.equal(Object.values(data).filter((s) => s['.type'] === 'priority_group').length, 2);
  }],
  ['rule set with subnets', 'rule_set', CUSTOM, undefined, (settings) => {
    settings.setValue('include_subnets', '1');
  }, (data) => {
    assert.equal(data.rule.rule_set, undefined);
    assert.deepEqual(data.rule.rule_set_with_subnets, [VALVE, CUSTOM]);
  }],
];

const failures = [];
async function check(label, fn) {
  try {
    await fn();
  } catch (error) {
    failures.push(`${label}: ${error.stack || error.message}`);
  }
}

(async () => {
  for (const version of ['24.10', '25.12']) {
    for (const [label, option, item, context, edit, saved] of edits) {
      await check(`${version} ${label}: Dismiss discards the item settings`, async () => {
        const env = createEnvironment({ version, config });
        const modal = await env.openRule('rule');
        const settings = await modal.openItemSettings(option, item, context);
        edit(settings);
        await settings.save();
        saved(env.uci.data);

        await modal.dismiss();
        assert.deepEqual(env.uci.data, config, 'Dismiss left the item settings in uci');
        await env.uci.save();
        assert.deepEqual(env.uci.data, config, 'Save & Apply after Dismiss sent the item settings');

        // The editor opened again starts from the saved rule.
        const again = await env.openRule('rule');
        await again.saveButton();
        assert.deepEqual(env.uci.data, config, 'an unchanged save after Dismiss changed UCI');
      });

      await check(`${version} ${label}: the rule's Save keeps the item settings`, async () => {
        const env = createEnvironment({ version, config });
        const modal = await env.openRule('rule');
        const settings = await modal.openItemSettings(option, item, context);
        edit(settings);
        await settings.save();
        await modal.saveButton();
        saved(env.uci.data);

        // Closing after the save changes nothing.
        await modal.dismiss();
        saved(env.uci.data);
      });
    }

    // A rule modal whose Save was refused and then dismissed leaves nothing either.
    await check(`${version} refused rule save, then Dismiss`, async () => {
      const env = createEnvironment({ version, config });
      const modal = await env.openRule('rule');
      const settings = await modal.openItemSettings('subscription_url', 'sub');
      settings.setValue('subscription_update_interval', '12h');
      await settings.save();
      modal.option('outbound_jsons').getUIElement('rule').setValue(['{"type":"vless"}']);
      await modal.saveButton();
      assert.equal(env.uci.data.sub.subscription_update_interval, '12h', 'the refused save closed the modal');
      await modal.dismiss();
      assert.deepEqual(env.uci.data, config);
    });
  }
  if (failures.length) {
    console.error(failures.join('\n\n'));
    process.exit(1);
  }
  console.log('luci_item_settings_dismiss: PASS');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
