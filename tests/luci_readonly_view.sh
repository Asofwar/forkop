#!/usr/bin/env bash
set -euo pipefail

# Forkop X is a LuCI menu subtree (admin/services/forkop/*), one view per
# page. This test covers the views themselves: a session that cannot read the
# Forkop UCI package is switched to read-only mode before any page content
# renders, status pages have no Save/Apply footer, and the configuration form
# lives only on the Settings page, which the read-only role cannot reach.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = process.argv[2];
const viewDir = path.join(root, 'luci-app-forkop/htdocs/luci-static/resources/view/forkop');
const read = file => fs.readFileSync(path.join(viewDir, file), 'utf8');

// LuCI module: "require x as y" directives, then `return <class>`.
function load(file, modules) {
  const source = read(file);
  const names = [];
  const values = [];
  for (const [, dep, alias] of source.matchAll(/^"require ([\w.]+)(?: as (\w+))?";$/gm)) {
    const name = alias || dep.split('.').pop();
    assert(name in modules, `${file}: no stub for ${dep}`);
    names.push(name);
    values.push(modules[name]);
  }
  return new Function(...names, '_', 'E', 'window', 'CustomEvent', source)(
    ...values, value => value, (tag, attrs, children) => ({ tag, attrs, children }),
    { dispatchEvent() {}, setTimeout() {} }, class {});
}

function stubs(canReadUci, calls, { stale = false } = {}) {
  const main = {
    FORKOP_UCI_PACKAGE: 'forkop',
    FORKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT: 'x',
    injectGlobalStyles() {},
    coreService() { calls.push('core'); },
    setReadonlyMode(value) { calls.push(`readonly:${value}`); },
    setForkopPage(page) { calls.push(`page:${page}`); },
    store: { get: () => ({ diagnosticsSystemInfo: {} }), set() {} },
    ForkopShellMethods: { getUiCapabilities: async () => ({ success: true, data: {} }) },
  };
  if (stale) delete main.setReadonlyMode;
  for (const tab of ['DashboardTab', 'MonitoringTab', 'DiagnosticTab']) {
    main[tab] = {
      initController() { calls.push(`init:${tab}`); },
      render() {
        assert(!canReadUci ? calls.includes('readonly:true') || stale : true,
          `${tab} rendered before the read-only mode was set`);
        calls.push(`render:${tab}`);
        return tab;
      },
    };
  }
  const uci = { load: async () => { if (!canReadUci) throw Error('Permission denied'); } };
  const baseclass = { extend: value => value };
  const shell = load('shell.js', { baseclass, uci, main });
  return {
    view: { extend: value => value }, baseclass, uci, main, shell,
    localDevices: { loadLocalDeviceChoices() {} },
  };
}

(async () => {
  const pages = {
    'page/overview.js': 'DashboardTab',
    'page/monitoring.js': 'MonitoringTab',
    'page/diagnostics.js': 'DiagnosticTab',
  };
  for (const [file, tab] of Object.entries(pages)) {
    for (const stale of [false, true]) {
      const calls = [];
      const page = load(file, stubs(false, calls, { stale }));
      assert.equal(await page.load(), true, `${file}: read-only session not detected`);
      const rendered = page.render();
      assert.equal(rendered.children[1], tab, `${file}: page content not rendered`);
      if (!stale) {
        assert.equal(calls.filter(call => call === 'readonly:true').length, 1,
          `${file}: read-only mode not set exactly once`);
        assert(calls.indexOf('readonly:true') < calls.indexOf(`render:${tab}`),
          `${file}: read-only mode must be set before rendering`);
      }
      assert.equal(page.handleSave, null, `${file}: status page must not offer Save`);
      assert.equal(page.handleSaveApply, null, `${file}: status page must not offer Save & Apply`);
      assert.equal(page.handleReset, null, `${file}: status page must not offer Reset`);
    }
    const calls = [];
    const page = load(file, stubs(true, calls));
    assert.equal(await page.load(), false, `${file}: administrator detected as read-only`);
    page.render();
    assert(!calls.some(call => call.startsWith('readonly:')), `${file}: administrator switched to read-only`);
    assert(calls.includes(`init:${tab}`), `${file}: controller not initialised`);
  }

  // Settings: the only page with the configuration form and its Save & Apply.
  const settingsSource = read('page/settings.js');
  assert.match(settingsSource, /new form\.Map\(UCI_PACKAGE/, 'settings page must host the form');
  assert.match(settingsSource, /forkopMap\.handleSaveApply = async function/,
    'settings page must keep the snapshot-first Save & Apply');
  assert.match(settingsSource, /snapshotCreate\("automatic"\)[\s\S]*originalHandleSaveApply\.call/,
    'a snapshot must be taken before applying');
  for (const section of ['"section"', '"settings"', '"updates"'])
    assert(settingsSource.includes(`form.${section === '"section"' ? 'GridSection' : 'TypedSection'},\n      ${section}`),
      `settings page lost the ${section} tab`);
  for (const file of Object.keys(pages))
    assert.doesNotMatch(read(file), /form\.(Map|JSONMap)/, `${file} must not render a form`);

  // The old single view and its wrappers are gone.
  for (const file of ['forkop.js', 'dashboard.js', 'diagnostic.js', 'monitoring.js'])
    assert(!fs.existsSync(path.join(viewDir, file)), `${file} should have been removed`);

  // Menu subtree.
  const menu = JSON.parse(fs.readFileSync(
    path.join(root, 'luci-app-forkop/root/usr/share/luci/menu.d/luci-app-forkop.json'), 'utf8'));
  const parent = menu['admin/services/forkop'];
  assert.deepEqual(parent.action, { type: 'firstchild' },
    'the old URL admin/services/forkop must open the first page');
  assert.deepEqual(parent.depends.acl, ['luci-app-forkop']);
  const children = Object.entries(menu).filter(([key]) => key.startsWith('admin/services/forkop/'));
  const order = children.sort((a, b) => a[1].order - b[1].order).map(([key]) => key.split('/').pop());
  assert.deepEqual(order, ['overview', 'monitoring', 'diagnostics', 'settings']);
  for (const [key, node] of children) {
    assert.equal(node.action.type, 'view', `${key} must be a view`);
    assert(fs.existsSync(path.join(root, 'luci-app-forkop/htdocs/luci-static/resources/view', `${node.action.path}.js`)),
      `${key} points to a missing view ${node.action.path}`);
  }
  assert.deepEqual(menu['admin/services/forkop/settings'].depends, { acl: ['luci-app-forkop-admin'] },
    'Settings must be hidden from the read-only role');
  for (const key of ['overview', 'monitoring', 'diagnostics'])
    assert(!menu[`admin/services/forkop/${key}`].depends,
      `${key} must stay available to the read-only role`);

  const acl = JSON.parse(fs.readFileSync(
    path.join(root, 'luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json'), 'utf8'));
  assert.deepEqual(acl['luci-app-forkop-admin'].read.uci, ['forkop'],
    'the Settings gate group must grant the Forkop UCI read access');

  console.log('luci_readonly_view: PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
NODE
