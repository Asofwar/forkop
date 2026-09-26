#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
// This test covers the view itself — when a session cannot read UCI, it must fall
// back to the JSON-backed status view instead of failing to render.
const source = fs.readFileSync(path.join(root, 'luci-app-forkop/htdocs/luci-static/resources/view/forkop/forkop.js'), 'utf8');
async function render(write, stale = false) {
  const calls = [];
  let mapKind = '';
  const makeMap = kind => class {
    constructor() { mapKind = kind; this.sections = []; }
    section(_type, name) {
      const item = { name, option() { return {}; } };
      this.sections.push(item);
      return item;
    }
    handleSaveApply() {}
    async render() {
      if (kind === 'UCI' && !write) throw Error('Permission denied');
      for (const section of this.sections)
        if (section.optionValue?.cfgvalue) section.optionValue.cfgvalue();
      return { kind, sections: this.sections.map(section => section.name) };
    }
  };
  const form = {
    Map: makeMap('UCI'), JSONMap: makeMap('JSON'),
    GridSection: class {}, TypedSection: class {}, TableSection: class {}, DummyValue: class {},
  };
  const mount = name => ({ createDashboardContent(section) {
    section.optionValue = { cfgvalue: () => { calls.push(name); return name; } };
  }, createDiagnosticContent(section) {
    section.optionValue = { cfgvalue: () => { calls.push(name); return name; } };
  }, createMonitoringContent() {}, createUpdatesContent() {}, createSettingsContent() {} });
  const main = {
    FORKOP_UCI_PACKAGE: 'forkop', injectGlobalStyles() {}, coreService() { calls.push('core'); },
    setReadonlyMode(value) { calls.push(`readonly:${value}`); },
    ForkopShellMethods: { getUiCapabilities: async () => ({ success: true, data: {} }) },
  };
  if (stale) delete main.setReadonlyMode;
  const uci = { load: async () => { if (!write) throw Error('Permission denied'); }, get: () => '' };
  const sections = { configureSectionSection() {}, createSectionContent() {} };
  const modules = [form, { extend: value => value }, { extend: value => value }, uci, {}, main,
    mount('dashboard'), mount('monitoring'), mount('diagnostic'), mount('updates'), mount('settings'), sections];
  const entry = new Function('form','view','baseclass','uci','ui','main','dashboard','monitoring','diagnostic','updates','settings','section','_', 'window', 'CustomEvent', source)(
    ...modules, value => value, { dispatchEvent() {}, setTimeout() {} }, class {});
  const rendered = await entry.render();
  return { rendered, mapKind, calls };
}
(async () => {
  for (const stale of [false, true]) {
    const read = await render(false, stale);
    if (read.mapKind !== 'JSON' || !read.calls.includes('dashboard') || !read.calls.includes('diagnostic'))
      throw Error(`read-only dashboard/diagnostics not rendered: ${JSON.stringify(read)}`);
    if (!stale && read.calls.filter(call => call === 'readonly:true').length !== 1)
      throw Error('read-only view did not switch the bundle to read-only mode');
    if (read.rendered.sections.some(name => name === 'settings' || name === 'section'))
      throw Error('read-only view exposes configuration form');
    const write = await render(true, stale);
    if (write.mapKind !== 'UCI' || !write.rendered.sections.includes('settings') || !write.rendered.sections.includes('section'))
      throw Error(`write view lost full configuration: ${JSON.stringify(write)}`);
    if (write.calls.some(call => call.startsWith('readonly:')))
      throw Error('write view was switched to read-only mode');
  }
  console.log('luci_readonly_view: PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
NODE
