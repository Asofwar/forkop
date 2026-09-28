#!/usr/bin/env bash
set -euo pipefail

# Settings "through a section" selects (DNS, lists and components downloads)
# keep a saved section that is disabled, uses a DPI provider that is not
# installed, or no longer exists: the value stays selected with a label and
# Save is refused until the user picks another section, instead of silently
# re-pointing to the first eligible rule (UC-008). The provider availability
# the Settings page gets from shell.js follows availability updates after
# Components installs or removes a provider (UC-152). A rule removal that
# such a refusal blocks is reported instead of failing silently.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);

function section(name, values) {
  return Object.assign({ '.name': name, '.type': 'section', '.anonymous': false, enabled: '1',
    label: name.toUpperCase() }, values);
}
const baseConfig = {
  vpn: section('vpn', { action: 'connection', selector_proxy_links: ['socks5://10.0.0.1:1080'] }),
  off: section('off', { enabled: '0', action: 'connection', selector_proxy_links: ['socks5://10.0.0.2:1080'] }),
  dpi: section('dpi', { action: 'zapret', community_lists: ['youtube'] }),
};
function settingsConfig(values) {
  return Object.assign({}, baseConfig, {
    settings: Object.assign({ '.name': 'settings', '.type': 'settings', '.anonymous': false,
      yacd_secret_key: 'secret-0123456789' }, values),
  });
}
const installed = { loaded: true, zapretInstalled: true, zapret2Installed: true, byedpiInstalled: true };
const noZapret = Object.assign({}, installed, { zapretInstalled: false });

const failures = [];
async function check(label, fn) {
  try {
    await fn();
  } catch (error) {
    failures.push(`${label}: ${error.stack || error.message}`);
  }
}

const references = [
  ['dns_detour_enabled', 'dns_detour_section'],
  ['download_lists_via_proxy', 'download_lists_via_proxy_section'],
  ['download_components_via_proxy', 'download_components_via_proxy_section'],
];

(async () => {
  for (const version of ['24.10', '25.12']) {
    for (const [flag, option] of references)
      for (const [label, value, capabilities, mark] of [
        ['disabled section', 'off', installed, /^OFF \(disabled\)$/],
        ['provider not installed', 'dpi', noZapret, /^DPI \(provider not installed\)$/],
        ['deleted section', 'gone', installed, /^gone \(unavailable\)$/],
      ]) await check(`${version} ${option}: ${label}`, async () => {
        const env = createEnvironment({ version, config: settingsConfig({ [flag]: '1', [option]: value }) });
        const settings = await env.openSettings(capabilities);
        const select = settings.option(option);
        assert.equal(select.formvalue('settings'), value, 'the widget must keep the saved section');
        assert.match(select.vallist[select.keylist.indexOf(value)], mark);
        assert.equal(select.keylist.includes('vpn'), true, 'eligible sections are still offered');
        await assert.rejects(settings.save());
        assert.equal(env.uci.data.settings[option], value, 'a refused save re-pointed the section');

        select.getUIElement('settings').setValue('vpn');
        await settings.save();
        assert.equal(env.uci.data.settings[option], 'vpn', 'an explicit choice is saved');
      });

    // An available saved section saves unchanged.
    await check(`${version} available section`, async () => {
      const env = createEnvironment({ version, config: settingsConfig({ dns_detour_enabled: '1',
        dns_detour_section: 'dpi' }) });
      const settings = await env.openSettings(installed);
      await settings.save();
      assert.equal(env.uci.data.settings.dns_detour_section, 'dpi');
    });

    // Deleting a rule saves the whole Settings page silently in LuCI. When a
    // kept section refuses that save, the row stays and the removal waits
    // for the next successful save; the user is told why.
    await check(`${version} rule removal refused by a kept section`, async () => {
      const env = createEnvironment({ version, config: settingsConfig({ dns_detour_enabled: '1',
        dns_detour_section: 'gone' }) });
      const notifications = [];
      env.ui.addNotification = (_title, node, type) => notifications.push({ type, text: node.textContent });
      const settings = await env.openSettings(installed);
      await settings.removeRule('off');
      assert.equal(notifications.length, 1, 'a refused removal must be reported');
      assert.equal(notifications[0].type, 'error');
      assert.match(notifications[0].text, /next successful save/);
      assert.match(notifications[0].text, /The selected section no longer exists/);

      // Control: a removal that saves reports nothing.
      const ok = createEnvironment({ version, config: settingsConfig({ dns_detour_enabled: '1',
        dns_detour_section: 'vpn' }) });
      ok.ui.addNotification = () => notifications.push('unexpected');
      await (await ok.openSettings(installed)).removeRule('off');
      assert.equal(ok.uci.data.off, undefined);
      assert.equal(notifications.length, 1, 'a saved removal must not report an error');
    });

    // UC-152: shell.uiCapabilities (what page/settings.js passes to the
    // Settings tabs) follows the provider availability event.
    await check(`${version} shell capabilities follow availability updates`, async () => {
      const env = createEnvironment({ version, config: settingsConfig({ dns_detour_enabled: '1',
        dns_detour_section: 'dpi' }) });
      const shell = env.shell();
      env.main.ForkopShellMethods.getUiCapabilities = () => Promise.resolve({ success: true,
        data: { zapret_installed: 0, zapret2_installed: 0, byedpi_installed: 0 } });
      await shell.loadUiCapabilities();
      assert.equal(shell.uiCapabilities.zapretInstalled, false);
      let settings = await env.openSettings(shell.uiCapabilities);
      await assert.rejects(settings.save(), /not installed/);

      // Components installed Zapret.
      env.window.dispatchEvent(new env.CustomEvent(env.main.FORKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT,
        { detail: { zapretInstalled: true, zapret2Installed: false, byedpiInstalled: false } }));
      assert.equal(shell.uiCapabilities.zapretInstalled, true, 'shell capabilities were not refreshed');
      settings = await env.openSettings(shell.uiCapabilities);
      const select = settings.option('dns_detour_section');
      assert.equal(select.vallist[select.keylist.indexOf('dpi')], 'DPI');
      await settings.save();
      assert.equal(env.uci.data.settings.dns_detour_section, 'dpi');

      // Status polling refreshes the store; a removal reaches the shell copy too.
      const setZapret = (installed) => env.main.store.set({ diagnosticsSystemInfo: {
        ...env.main.store.get().diagnosticsSystemInfo, providerInfoLoaded: true, zapret_installed: installed } });
      setZapret(1);
      assert.equal(shell.uiCapabilities.zapretInstalled, true);
      setZapret(0);
      assert.equal(shell.uiCapabilities.zapretInstalled, false, 'store update did not reach the shell');
    });
  }
  if (failures.length) {
    console.error(failures.join('\n\n'));
    process.exit(1);
  }
  console.log('luci_settings_section_references: PASS');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
