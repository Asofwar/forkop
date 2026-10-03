#!/usr/bin/env bash
set -euo pipefail

# The rule modal refuses to save an enabled Connection rule without a
# connection (a connection URL, a subscription, a network interface or a
# JSON outbound), before anything is written: the sing-box generator refuses
# such a rule, and config/validator.uc refuses it before the reload
# (UC-092). It counts the sources the backend counts
# (config/connections.uc has_connection_sources), legacy options included,
# as the save leaves them: removing the last interface item also removes the
# legacy `list interfaces` those items shadowed. A disabled rule may keep
# none, and another action needs none. The Enable checkbox of the rules grid
# refuses to enable such a rule as well; a rule left as it is does not hold
# up the save of the other rows.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);

function section(name, values) {
  return Object.assign({ '.name': name, '.type': 'section', '.anonymous': false, enabled: '1',
    label: name.toUpperCase(), domain: 'example.com' }, values);
}
const settings = { '.name': 'settings', '.type': 'settings', '.anonymous': false,
  yacd_secret_key: 'secret-0123456789' };
const NO_SOURCE = /A Connection rule needs a connection: add a connection URL, a subscription, a network interface or a JSON outbound, or disable the rule\./;
const refusal = (modal) => modal.map.root.querySelector('.fkp-rule-save-refusal')?.textContent || '';

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
    await check(`${version}: removing the last connection URL is refused`, async () => {
      const config = { settings, vpn: section('vpn', { action: 'connection',
        selector_proxy_links: ['socks5://10.0.0.1:1080'] }) };
      const env = createEnvironment({ version, config });
      const before = JSON.parse(JSON.stringify(env.uci.data));
      const modal = await env.openRule('vpn');
      modal.option('selector_proxy_links').getUIElement('vpn').setValue([]);
      await assert.rejects(modal.save(), NO_SOURCE);
      assert.deepEqual(env.uci.data, before, 'a refused modal save changed UCI');

      // LuCI drops the refusal of the modal Save: the modal shows it.
      await modal.saveButton();
      assert.match(refusal(modal), NO_SOURCE, 'the refusal must be shown in the modal');
      assert.deepEqual(env.uci.data, before, 'a refused modal save changed UCI');

      // Disabled, the rule may keep no connection.
      modal.option('enabled').getUIElement('vpn').setValue('0');
      await modal.save();
      assert.equal(env.uci.data.vpn.enabled, '0');
      assert.equal(env.uci.data.vpn.selector_proxy_links, undefined);
    });

    await check(`${version}: a rule with a connection saves`, async () => {
      const config = { settings, vpn: section('vpn', { action: 'connection',
        selector_proxy_links: ['socks5://10.0.0.1:1080'] }) };
      const env = createEnvironment({ version, config });
      const modal = await env.openRule('vpn');
      modal.option('selector_proxy_links').getUIElement('vpn').setValue(['socks5://10.0.0.2:1080']);
      await modal.save();
      assert.deepEqual(env.uci.data.vpn.selector_proxy_links, ['socks5://10.0.0.2:1080']);
    });

    // Sources the backend counts besides the connection URLs.
    for (const [label, values, extra] of [
      ['a network interface', { action: 'connection' },
        { if1: { '.name': 'if1', '.type': 'section_interface', '.anonymous': false, section: 'vpn', name: 'wg0' } }],
      ['a subscription', { action: 'connection' },
        { sub1: { '.name': 'sub1', '.type': 'subscription_url', '.anonymous': false, section: 'vpn',
          url: 'https://example.com/sub', subscription_update_enabled: '1', subscription_update_interval: '4h' } }],
      ['a JSON outbound', { action: 'connection', outbound_jsons: ['{"type":"direct","tag":"out"}'] }, {}],
      ['a legacy interface list', { action: 'connection', interfaces: ['wg0'] }, {}],
      ['a legacy interface option', { action: 'connection', interface: 'wg0' }, {}],
      ['a legacy JSON outbound', { action: 'connection', outbound_json: '{"type":"direct"}' }, {}],
      ['a legacy subscription list', { action: 'connection', subscription_urls: ['https://example.com/sub'] }, {}],
      ['no connection, another action', { action: 'block' }, {}],
    ]) await check(`${version}: ${label} saves`, async () => {
      const config = Object.assign({ settings, vpn: section('vpn', values) }, extra);
      const env = createEnvironment({ version, config });
      const modal = await env.openRule('vpn');
      await modal.save();
      assert.equal(env.uci.data.vpn.enabled, '1');
    });

    // InterfaceSettingsDynamicList.remove() drops the legacy list the
    // removed items shadowed; a legacy `option interface` stays.
    await check(`${version}: removing the last interface item that shadows a legacy list is refused`, async () => {
      const config = { settings, vpn: section('vpn', { action: 'connection', interfaces: ['wg1'] }),
        if1: { '.name': 'if1', '.type': 'section_interface', '.anonymous': false, section: 'vpn', name: 'wg0' } };
      const env = createEnvironment({ version, config });
      const before = JSON.parse(JSON.stringify(env.uci.data));
      const modal = await env.openRule('vpn');
      modal.option('interfaces').getUIElement('vpn').setValue([]);
      await assert.rejects(modal.save(), NO_SOURCE);
      assert.deepEqual(env.uci.data, before, 'a refused modal save changed UCI');
    });
    await check(`${version}: removing the last interface item next to a legacy interface option saves`, async () => {
      const config = { settings, vpn: section('vpn', { action: 'connection', interface: 'wg1' }),
        if1: { '.name': 'if1', '.type': 'section_interface', '.anonymous': false, section: 'vpn', name: 'wg0' } };
      const env = createEnvironment({ version, config });
      const modal = await env.openRule('vpn');
      modal.option('interfaces').getUIElement('vpn').setValue([]);
      await modal.save();
      assert.equal(env.uci.data.if1, undefined);
      assert.equal(env.uci.data.vpn.interface, 'wg1');
    });

    // The Enable checkbox of the rules grid.
    const disabled = (values) => section('vpn', Object.assign({ enabled: '0' }, values));
    await check(`${version}: the grid refuses to enable a Connection rule without a connection`, async () => {
      const config = { settings, vpn: disabled({ action: 'connection', community_lists: ['youtube'] }) };
      const env = createEnvironment({ version, config });
      const before = JSON.parse(JSON.stringify(env.uci.data));
      const rules = await env.openRules();
      rules.setEnabled('vpn', '1');
      await assert.rejects(rules.save(), NO_SOURCE);
      assert.deepEqual(env.uci.data, before, 'a refused grid save changed UCI');
    });
    for (const [label, values, extra] of [
      ['a connection URL', { action: 'connection', selector_proxy_links: ['socks5://10.0.0.1:1080'] }, {}],
      ['a network interface', { action: 'connection' },
        { if1: { '.name': 'if1', '.type': 'section_interface', '.anonymous': false, section: 'vpn', name: 'wg0' } }],
      ['a subscription', { action: 'connection' },
        { sub1: { '.name': 'sub1', '.type': 'subscription_url', '.anonymous': false, section: 'vpn',
          url: 'https://example.com/sub', subscription_update_enabled: '1', subscription_update_interval: '4h' } }],
      ['a legacy interface option', { action: 'connection', interface: 'wg0' }, {}],
      ['a legacy JSON outbound', { action: 'proxy', outbound_json: '{"type":"direct"}' }, {}],
      ['no connection, another action', { action: 'block' }, {}],
    ]) await check(`${version}: the grid enables a rule with ${label}`, async () => {
      const config = Object.assign({ settings, vpn: disabled(values) }, extra);
      const env = createEnvironment({ version, config });
      const rules = await env.openRules();
      rules.setEnabled('vpn', '1');
      await rules.save();
      assert.equal(env.uci.data.vpn.enabled, '1');
    });
    await check(`${version}: an enabled rule without a connection does not hold up the grid`, async () => {
      const config = { settings, vpn: section('vpn', { action: 'connection' }),
        off: section('off', { enabled: '0', action: 'block' }) };
      const env = createEnvironment({ version, config });
      const rules = await env.openRules();
      rules.setEnabled('off', '1');
      await rules.save();
      assert.equal(env.uci.data.off.enabled, '1');
    });

    await check(`${version}: an enabled Connection rule without a connection is refused`, async () => {
      const config = { settings, vpn: section('vpn', { action: 'connection', community_lists: ['youtube'] }) };
      const env = createEnvironment({ version, config });
      const before = JSON.parse(JSON.stringify(env.uci.data));
      const modal = await env.openRule('vpn');
      await assert.rejects(modal.save(), NO_SOURCE);
      assert.deepEqual(env.uci.data, before, 'a refused modal save changed UCI');
    });
  }

  if (failures.length) {
    console.error(failures.join('\n\n'));
    process.exit(1);
  }
  console.log('rule modal refuses an enabled Connection rule without a connection');
})();
NODE
