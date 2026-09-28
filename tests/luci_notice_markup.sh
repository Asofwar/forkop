#!/usr/bin/env bash
set -euo pipefail

# The rule modal notices about hidden and legacy settings (UC-041, UC-042,
# UC-043) show UCI values: legacy conditions, interface names, rule labels
# and section names. LuCI's E() turns a single string child into innerHTML,
# so such values must reach the page as text: shown exactly as stored, never
# parsed as markup in the administrator's session. The real section.js runs
# under node (tests/helpers/luci_form_harness.js), whose E() records the
# strings LuCI would parse as HTML.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers" <<'NODE'
const assert = require('node:assert/strict');
const helpers = process.argv[2];
const { createEnvironment } = require(`${helpers}/luci_form_harness.js`);

function section(name, values) {
  return Object.assign({ '.name': name, '.type': 'section', '.anonymous': false, enabled: '1' }, values);
}
const rule = (values) => section('rule', values);
const routed = { mixed_proxy_enabled: '0' };

// Values with markup, and the string that must stay text.
const REGEX = '<svg/onload=alert(1)>';
const KEYWORD = '<img src=x onerror=alert(2)>';
const IFACE = '<svg/onload=alert(3)>';
const LABEL = '<img src=x onerror=alert(4)>';
const TARGET = '<svg/onload=alert(5)>';
const NAMED_GROUP = '^(?P<sub>[a-z]+)\\.example$';

// Strings in the notice that LuCI would parse as HTML and that carry a value.
function parsedValues(node, values) {
  const found = [];
  const walk = (current) => {
    if (typeof current === 'string') return;
    if (current.markup !== undefined && values.some((value) => current.markup.includes(value)))
      found.push(current.markup);
    current.childNodes.forEach(walk);
  };
  walk(node);
  return found;
}
function assertText(node, values) {
  assert.deepEqual(parsedValues(node, values), [], 'a value would be parsed as HTML');
  for (const value of values)
    assert(node.textContent.includes(value), `the notice does not show ${value} as it is: ${node.textContent}`);
}
const button = (node, label) => {
  const found = node.querySelectorAll('button').find((b) => b.textContent === label);
  assert(found, `no "${label}" button in: ${node.textContent}`);
  return found;
};

const failures = [];
async function check(label, fn) {
  try {
    await fn();
  } catch (error) {
    failures.push(`${label}: ${error.message}`);
  }
}

(async () => {
  for (const version of ['24.10', '25.12']) {
    // Conversion preview: the domain value it sets and the interface item
    // it adds.
    await check(`${version} conversion preview`, async () => {
      const env = createEnvironment({ version, config: { rule: rule({ action: 'connection', ...routed,
        domain_regex: [REGEX], interfaces: [IFACE] }) } });
      const modal = await env.openRule('rule');
      const notice = modal.option('_legacy_conditions').renderWidget('rule');
      assertText(notice, [REGEX, IFACE]);
      button(notice, 'Convert…').attrs.click();
      assertText(notice, [`regex:${REGEX}`, `add the interface item ${IFACE}`]);
    });

    // Blocked conversion: the values it names.
    await check(`${version} blocked conversion`, async () => {
      const env = createEnvironment({ version, config: { rule: rule({ action: 'block',
        domain_keyword: [KEYWORD], domain_regex: [NAMED_GROUP] }) } });
      const modal = await env.openRule('rule');
      const notice = modal.option('_legacy_conditions').renderWidget('rule');
      assert.match(notice.textContent, /cannot be converted/);
      assertText(notice, [KEYWORD, NAMED_GROUP]);
    });

    // Hidden cascade: the transit rule label, and a transit section name
    // that no longer exists.
    const transit = section('transit', { label: LABEL, action: 'connection', ...routed,
      selector_proxy_links: ['socks5://10.0.0.1:1080'], domain: 'transit.example' });
    const cascade = (target) => rule({ action: 'connection', ...routed, domain: 'work.example',
      selector_proxy_links: ['socks5://10.0.0.2:1080'], outbound_detour_enabled: '1',
      outbound_detour_section: target });
    await check(`${version} hidden cascade`, async () => {
      for (const [config, value] of [[{ rule: cascade('transit'), transit }, LABEL],
        [{ rule: cascade(TARGET), transit }, TARGET],
        [{ rule: { ...cascade('transit'), outbound_detour_enabled: '0' }, transit }, LABEL]]) {
        const env = createEnvironment({ version, config });
        const modal = await env.openRule('rule');
        assertText(modal.option('_hidden_cascade').renderWidget('rule'), [value]);
      }
    });

    await check(`${version} cascade action warning`, async () => {
      const env = createEnvironment({ version, config: { rule: cascade('transit'), transit } });
      const modal = await env.openRule('rule');
      modal.option('action').getUIElement('rule').setValue('block');
      modal.map.checkDepends();
      assert.equal(modal.active('_cascade_action_warning'), true);
      assertText(modal.option('_cascade_action_warning').renderWidget('rule'), [LABEL]);
    });
  }

  if (failures.length) {
    console.error(failures.map((failure) => `FAIL: ${failure}`).join('\n'));
    process.exit(1);
  }
  console.log('Rule modal notices show stored values as text');
})();
NODE
