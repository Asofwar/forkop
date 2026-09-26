#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
// The ACL split that would create a genuine read-only role is not part of this
// release: it could not be verified against rpcd on a router. What is covered
// here is the view itself — when a session cannot read UCI, the page must fall
// back to the JSON-backed status view instead of failing to render.
const source = fs.readFileSync(path.join(root, 'luci-app-forkop/htdocs/luci-static/resources/view/forkop/forkop.js'), 'utf8');
async function render(write) {
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
    ForkopShellMethods: { getUiCapabilities: async () => ({ success: true, data: {} }) },
  };
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
  const read = await render(false);
  if (read.mapKind !== 'JSON' || !read.calls.includes('dashboard') || !read.calls.includes('diagnostic'))
    throw Error(`read-only dashboard/diagnostics not rendered: ${JSON.stringify(read)}`);
  if (read.rendered.sections.some(name => name === 'settings' || name === 'section'))
    throw Error('read-only view exposes configuration form');
  const write = await render(true);
  if (write.mapKind !== 'UCI' || !write.rendered.sections.includes('settings') || !write.rendered.sections.includes('section'))
    throw Error(`write view lost full configuration: ${JSON.stringify(write)}`);
  console.log('luci_readonly_view: PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
NODE
