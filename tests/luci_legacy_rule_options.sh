#!/usr/bin/env bash
set -euo pipefail

# Legacy rule conditions in the LuCI rule editor (UC-042, UC-043, D-6):
# the real section.js runs under node (tests/helpers/luci_form_harness.js)
# and the backend's own read layer (routing/rule_conditions.uc, config/rule.uc,
# config/connections.uc) reports what sing-box and nft are built from.
# - Opening a rule and saving it unchanged leaves UCI byte-for-byte unchanged,
#   legacy options included (a legacy `list interfaces` used to be dropped).
# - Every condition field shows the values the backend uses: text mode
#   (<key>_text_mode, conditions_text_mode) reads the *_text option, a list
#   shadows its *_text option, ports and ports_text are merged, and
#   fully_routed_ips_text is not read at all.
# - Saving a field with the values it shows keeps what the rule matches;
#   clearing a field clears the values the backend used, wherever they were
#   stored. Fields whose values conditions_text_mode keeps in the *_text
#   options are read-only (only an explicit conversion changes them).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers" <<'NODE'
const assert = require('node:assert/strict');
const helpers = process.argv[2];
const { createEnvironment } = require(`${helpers}/luci_form_harness.js`);
const backend = require(`${helpers}/uci_backend.js`);

function rule(values) {
  return Object.assign({ '.name': 'rule', '.type': 'section', '.anonymous': false, enabled: '1' }, values);
}
const routed = { mixed_proxy_enabled: '0' };
const DNS = { action: 'dns', dns_type: 'udp', dns_server: '1.1.1.1', dns_detour_enabled: '0' };
const iface = (name, extra) => Object.assign({ '.name': name, '.type': 'section_interface', '.anonymous': true,
  section: 'rule', domain_resolver_enabled: '0', domain_resolver_dns_type: 'udp',
  domain_resolver_dns_server: '8.8.8.8' }, extra);

const fixtures = {
  legacy_interfaces: { rule: rule({ action: 'connection', ...routed, domain: 'example.com',
    interfaces: ['awg0', 'wg1'] }) },
  legacy_interface_option: { rule: rule({ action: 'connection', ...routed, domain: 'example.com',
    interface: 'awg0' }) },
  legacy_interfaces_shadowed: {
    rule: rule({ action: 'connection', ...routed, domain: 'example.com', interfaces: ['awg0'] }),
    if1: iface('if1', { name: 'wg0' }),
  },
  ip_text_mode: { rule: rule({ action: 'block', ip_cidr: ['1.1.1.1'], ip_cidr_text: '8.8.8.8',
    ip_cidr_text_mode: '1' }) },
  ip_text_fallback: { rule: rule({ action: 'block', ip_cidr_text: '8.8.4.4, 9.9.9.9' }) },
  ip_list_shadows_text: { rule: rule({ action: 'block', ip_cidr: ['1.1.1.1'], ip_cidr_text: '8.8.8.8' }) },
  ports_text: { rule: rule({ action: 'block', domain: 'example.com', ports: ['443'],
    ports_text: '80 8000-8080 bad' }) },
  ports_text_only: { rule: rule({ action: 'bypass', ip_cidr: '10.0.0.0/8', ports_text: '53' }) },
  source_text_mode: { rule: rule({ action: 'block', domain: 'example.com', source_ip_cidr: ['192.168.1.2'],
    source_ip_cidr_text: '192.168.1.3', source_ip_cidr_text_mode: '1' }) },
  source_text_fallback: { rule: rule({ action: 'block', domain: 'example.com',
    source_ip_cidr_text: '192.168.1.4 192.168.1.5' }) },
  conditions_text_mode: { rule: rule({ action: 'block', domain_keyword: ['video'], domain_keyword_text: 'music',
    ip_cidr: ['1.1.1.1'], ip_cidr_text: '8.8.8.8', source_ip_cidr: ['192.168.1.2'],
    source_ip_cidr_text: '192.168.1.3', excluded_source_ip_cidr_text: '192.168.1.9',
    conditions_text_mode: '1' }) },
  keyword_text_mode: { rule: rule({ action: 'block', domain: 'example.com', domain_keyword: ['video'],
    domain_keyword_text: 'music', domain_keyword_text_mode: '1' }) },
  keyword_list_shadows_text: { rule: rule({ action: 'block', domain_keyword: ['video'],
    domain_keyword_text: 'music' }) },
  domain_text_exact: { rule: rule({ action: 'block', domain: 'a.example', domain_text: 'exact.example' }) },
  fully_routed_text: { rule: rule({ action: 'bypass', ip_cidr: '10.0.0.0/8',
    fully_routed_ips_text: '192.168.1.7' }) },
  remote_lists: { rule: rule({ action: 'block', remote_domain_lists: ['https://example.com/domains.lst'],
    remote_subnet_lists: ['https://example.com/subnets.srs'], source_ip_cidr: ['192.168.1.50'] }) },
  unsupported: { rule: rule({ action: 'block', domain: 'example.com', local_domain_lists: ['/etc/list.lst'],
    subnet_text: '10.0.0.0/8' }) },
  dns_text: { rule: rule({ ...DNS, domain_keyword_text: 'video', source_ip_cidr_text: '192.168.1.3' }) },
};

const CONDITION_OPTIONS = ['domain', 'ip_cidr', 'source_ip_cidr', 'excluded_source_ip_cidr',
  'fully_routed_ips', 'ports', 'interfaces'];
const LOCKED_BY_TEXT_MODE = ['ip_cidr', 'source_ip_cidr', 'excluded_source_ip_cidr'];

// What a rule matches, as a set: order and duplicates of the stored values
// do not change sing-box matching.
function matching(conditions) {
  const set = (values) => [...new Set(values.map(String))].sort();
  return {
    domains: Object.fromEntries(Object.entries(conditions.domains).map(([k, v]) => [k, set(v)])),
    ip_cidr: set(conditions.ip_cidr),
    source_ip_cidr: set(conditions.source_ip_cidr),
    excluded_source_ip_cidr: set(conditions.excluded_source_ip_cidr),
    fully_routed_ips: set(conditions.fully_routed_ips),
    ports: set(conditions.ports),
    interfaces: conditions.interfaces,
  };
}

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
    for (const [name, config] of Object.entries(fixtures)) {
      const before = backend.effectiveConditions(config).rule;

      await check(`${version} ${name}: unchanged save`, async () => {
        const env = createEnvironment({ version, config });
        await (await env.openRule('rule')).save();
        assert.deepEqual(env.uci.data, config, 'an unchanged rule modal save changed UCI');
      });

      // Saving every editable condition field with the values it shows.
      await check(`${version} ${name}: save shown values`, async () => {
        const env = createEnvironment({ version, config });
        const modal = await env.openRule('rule');
        for (const optionName of CONDITION_OPTIONS) {
          const option = modal.option(optionName);
          if (modal.active(optionName) && option.readonly !== true) option.forcewrite = true;
        }
        await modal.save();
        assert.deepEqual(matching(backend.effectiveConditions(env.uci.data).rule), matching(before),
          'the rule matches something else after saving the values the editor showed');
      });

      await check(`${version} ${name}: text mode locks`, async () => {
        const env = createEnvironment({ version, config });
        const modal = await env.openRule('rule');
        const locked = name === 'conditions_text_mode';
        for (const optionName of CONDITION_OPTIONS)
          assert.equal(modal.option(optionName).readonly === true,
            locked && LOCKED_BY_TEXT_MODE.includes(optionName), `${optionName} read-only state`);
      });
    }

    // The fields show the values the backend uses.
    const shown = async (config, optionName) => {
      const env = createEnvironment({ version, config });
      return (await env.openRule('rule')).option(optionName).formvalue('rule');
    };
    await check(`${version} shown values`, async () => {
      assert.equal(await shown(fixtures.ip_text_mode, 'ip_cidr'), '8.8.8.8');
      assert.equal(await shown(fixtures.ip_list_shadows_text, 'ip_cidr'), '1.1.1.1');
      assert.deepEqual(await shown(fixtures.ports_text, 'ports'), ['443', '80', '8000-8080']);
      assert.deepEqual(await shown(fixtures.ports_text_only, 'ports'), ['53']);
      assert.deepEqual(await shown(fixtures.source_text_mode, 'source_ip_cidr'), ['192.168.1.3']);
      assert.deepEqual(await shown(fixtures.source_text_fallback, 'source_ip_cidr'),
        ['192.168.1.4', '192.168.1.5']);
      assert.deepEqual(await shown(fixtures.conditions_text_mode, 'excluded_source_ip_cidr'), ['192.168.1.9']);
      assert.equal(await shown(fixtures.conditions_text_mode, 'domain'), 'keyword:music');
      assert.equal(await shown(fixtures.keyword_text_mode, 'domain'), 'example.com\nkeyword:music');
      assert.equal(await shown(fixtures.keyword_list_shadows_text, 'domain'), 'keyword:video');
      assert.equal(await shown(fixtures.domain_text_exact, 'domain'), 'a.example\nfull:exact.example');
      assert.deepEqual(await shown(fixtures.fully_routed_text, 'fully_routed_ips'), []);
    });

    // The rules grid counts what the rule matches, legacy options included.
    await check(`${version} grid summary`, async () => {
      const summary = (config, column) => createEnvironment({ version, config }).grid.children
        .find((option) => option.option === column).textvalue('rule');
      assert.equal(summary(fixtures.remote_lists, '_conditions_summary'), 'Lists: 2');
      assert.equal(summary(fixtures.ip_text_mode, '_conditions_summary'), 'IPs: 1');
      assert.equal(summary(fixtures.ports_text, '_conditions_summary'), 'Domains: 1 · Ports: 3');
      assert.equal(summary(fixtures.keyword_text_mode, '_conditions_summary'), 'Domains: 2');
      assert.equal(summary(fixtures.source_text_mode, '_devices_summary'), 'Only: 1');
      assert.equal(summary(fixtures.conditions_text_mode, '_devices_summary'), 'Only: 1 · Except: 1');
      assert.equal(summary(fixtures.fully_routed_text, '_devices_summary'), 'All devices');
    });

    // Clearing a field clears what the backend used.
    for (const [name, optionName, value] of [
      ['ip_text_fallback', 'ip_cidr', ''],
      ['ip_text_mode', 'ip_cidr', ''],
      ['ports_text', 'ports', []],
      ['source_text_fallback', 'source_ip_cidr', []],
      ['source_text_mode', 'source_ip_cidr', []],
      ['keyword_list_shadows_text', 'domain', ''],
      ['keyword_text_mode', 'domain', ''],
    ]) await check(`${version} ${name}: clear ${optionName}`, async () => {
      const env = createEnvironment({ version, config: fixtures[name] });
      const modal = await env.openRule('rule');
      modal.option(optionName).getUIElement('rule').setValue(value);
      await modal.save().catch(() => {});
      const after = backend.effectiveConditions(env.uci.data).rule;
      const key = optionName === 'domain' ? 'domains' : optionName;
      const empty = key === 'domains'
        ? { domain: [], domain_suffix: [], domain_keyword: [], domain_regex: [] } : [];
      assert.deepEqual(after[key], empty, `${optionName} still matches after it was cleared`);
    });

    // Removing the rule's interfaces does not bring back a legacy list they
    // shadowed.
    await check(`${version} legacy_interfaces_shadowed: remove interfaces`, async () => {
      const env = createEnvironment({ version, config: fixtures.legacy_interfaces_shadowed });
      const modal = await env.openRule('rule');
      modal.option('interfaces').getUIElement('rule').setValue([]);
      await modal.save();
      assert.deepEqual(backend.effectiveConditions(env.uci.data).rule.interfaces, []);
      assert.equal(env.uci.data.rule.interfaces, undefined);
    });
  }

  if (failures.length) {
    console.error(failures.map((failure) => `FAIL: ${failure}`).join('\n'));
    process.exit(1);
  }
  console.log('LuCI rule editor shows and keeps legacy rule conditions');
})();
NODE
