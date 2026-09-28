#!/usr/bin/env bash
set -euo pipefail

# Round trip of the rule editor: the real LuCI section.js is loaded under node
# with a model of luci-base form.js (tests/helpers/luci_form_harness.js, 24.10
# and 25.12 parse semantics). Opening a rule modal and saving it without
# touching anything must leave the rule's UCI section byte-for-byte unchanged.
# Also covers the rule-set item settings modal ("Include IP addresses and
# subnets"), which must not drop Built-in rule sets #2 (UC-003, UC-004).
# Built-in rule sets #2 are hidden for DNS rules without dropping stored
# values (UC-046).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);

const B4 = 'https://mirror.infotechtg.ru/forkop/lists/b4geoip-forkop/srs';
const VALVE = `${B4}/valve.srs`;
const GOOGLE = `${B4}/google.srs`;
const CUSTOM = 'https://example.com/custom.srs';
const CUSTOM_SUBNETS = 'https://example.com/with-subnets.srs';

function rule(values) {
  return Object.assign({ '.name': 'rule', '.type': 'section', '.anonymous': false, enabled: '1' }, values);
}
// Connection-like actions always store the Mixed Proxy flag (form.Flag, rmempty=false).
const routed = { mixed_proxy_enabled: '0' };

const fixtures = {
  // UC-003: the only destination condition is a Built-in rule set #2.
  device_filter_secondary_only: rule({ action: 'connection', ...routed,
    rule_set_with_subnets: [VALVE], source_ip_cidr: ['192.168.1.50'] }),
  device_filter_secondary_only_block: rule({ action: 'block',
    rule_set_with_subnets: [GOOGLE], source_ip_cidr: ['192.168.1.51', '192.168.1.52'] }),
  // UC-003: legacy remote lists have no LuCI widget but the backend honours them.
  device_filter_remote_domain_lists: rule({ action: 'block',
    remote_domain_lists: ['https://example.com/domains.lst'], source_ip_cidr: ['192.168.1.50'] }),
  device_filter_remote_subnet_lists: rule({ action: 'connection', ...routed,
    remote_subnet_lists: ['https://example.com/subnets.lst'], source_ip_cidr: ['192.168.1.0/28'] }),
  // UC-004 storage: user subnet rule sets and Built-in #2 share one option.
  mixed_subnet_rule_sets: rule({ action: 'connection', ...routed, rule_set: [CUSTOM],
    rule_set_with_subnets: [CUSTOM_SUBNETS, VALVE], source_ip_cidr: ['192.168.1.50'] }),
  // Normal rules.
  community_device_filter: rule({ action: 'connection', ...routed,
    community_lists: ['youtube'], source_ip_cidr: ['192.168.1.50'] }),
  domains_and_links: rule({ action: 'connection', ...routed, label: 'Work',
    domain: 'example.com\nfull:exact.example.org', selector_proxy_links: ['socks5://10.0.0.1:1080'],
    community_lists: ['youtube', 'geoblock'], excluded_source_ip_cidr: ['192.168.1.9'] }),
  bypass_ip_ports: rule({ action: 'bypass', ip_cidr: '10.10.0.0/16', ports: ['443', '8000-8080'],
    fully_routed_ips: ['192.168.1.77'] }),
  block_domain_ip_lists: rule({ action: 'block', domain_ip_lists: ['https://example.com/list.lst'],
    source_ip_cidr: ['192.168.1.60'] }),
  dns_rule: rule({ action: 'dns', dns_type: 'udp', dns_server: '1.1.1.1', dns_detour_enabled: '0',
    domain: 'example.net', community_lists: ['youtube'], source_ip_cidr: ['192.168.1.50'] }),
  disabled_rule: rule({ enabled: '0', action: 'connection', ...routed, community_lists: ['youtube'],
    outbound_detour_enabled: '1', outbound_detour_section: 'transit', sort_by_latency: '1' }),
  // UC-046: a DNS rule never shows Built-in rule sets #2 but keeps stored ones.
  dns_rule_secondary_rule_sets: rule({ action: 'dns', dns_type: 'udp', dns_server: '1.1.1.1',
    dns_detour_enabled: '0', domain: 'example.net', rule_set_with_subnets: [VALVE] }),
  dns_rule_sets_and_secondary: rule({ action: 'dns', dns_type: 'udp', dns_server: '1.1.1.1',
    dns_detour_enabled: '0', rule_set: [CUSTOM], rule_set_with_subnets: [GOOGLE] }),
  // DPI rules with their strategies.
  zapret_rule: rule({ action: 'zapret', ...routed, nfqws_opt: '--filter-tcp=443 --dpi-desync=fake',
    community_lists: ['youtube'] }),
  zapret2_rule: rule({ action: 'zapret2', ...routed, nfqws2_opt: '--filter-tcp=443 --lua-desync=fake:blob=fake_default_tls',
    community_lists: ['youtube'] }),
  byedpi_rule: rule({ action: 'byedpi', ...routed, byedpi_cmd_opts: '-o 1 -d 1', community_lists: ['youtube'] }),
};

// Every case runs; all failures are reported together.
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
    for (const [name, fixture] of Object.entries(fixtures))
      await check(`${version} ${name}`, async () => {
        const env = createEnvironment({ version, config: { rule: fixture } });
        await (await env.openRule('rule')).save();
        assert.deepEqual(env.uci.data.rule, fixture, 'an unchanged rule modal save changed UCI');
      });

    // UC-046: Built-in rule sets #2 are hidden for DNS rules and edits of the
    // DNS rule sets keep the stored values.
    await check(`${version} dns rule hides Built-in rule sets #2`, async () => {
      const fixture = fixtures.dns_rule_sets_and_secondary;
      const env = createEnvironment({ version, config: { rule: fixture } });
      const modal = await env.openRule('rule');
      assert.equal(modal.active('secondary_rule_sets'), false);
      modal.option('_dns_rule_set').getUIElement('rule').setValue([CUSTOM, CUSTOM_SUBNETS]);
      await modal.save();
      assert.deepEqual(env.uci.data.rule.rule_set, [CUSTOM, CUSTOM_SUBNETS]);
      assert.deepEqual(env.uci.data.rule.rule_set_with_subnets, [GOOGLE]);

      const routedRule = createEnvironment({ version, config: { rule: fixtures.device_filter_secondary_only } });
      assert.equal((await routedRule.openRule('rule')).active('secondary_rule_sets'), true);
    });

    // UC-003: the device filter is offered whenever a Built-in rule set #2 is set.
    await check(`${version} device filter visibility`, async () => {
      const env = createEnvironment({ version, config: { rule: fixtures.device_filter_secondary_only } });
      const modal = await env.openRule('rule');
      assert.equal(modal.active('source_ip_cidr'), true,
        `${version}: Device filter must be shown for a rule with Built-in rule sets #2`);

      // A rule without any destination condition still hides the device filter.
      const bare = createEnvironment({ version, config: { rule: rule({ action: 'block',
        source_ip_cidr: ['192.168.1.50'] }) } });
      assert.equal((await bare.openRule('rule')).active('source_ip_cidr'), false,
        `${version}: Device filter must stay hidden without destination conditions`);
    });

    // A hidden device filter is kept only while legacy remote lists (no widget)
    // still match; removing the last destination condition clears it, and a
    // visible device filter can always be cleared.
    for (const [label, values, edit, expected] of [
      ['last condition removed', { community_lists: ['youtube'] },
        { community_lists: [] }, undefined],
      ['last visible condition removed, legacy list left',
        { community_lists: ['youtube'], remote_domain_lists: ['https://example.com/domains.lst'] },
        { community_lists: [] }, ['192.168.1.50']],
      ['visible filter cleared next to legacy list',
        { community_lists: ['youtube'], remote_domain_lists: ['https://example.com/domains.lst'] },
        { source_ip_cidr: [] }, undefined],
    ]) await check(`${version} device filter: ${label}`, async () => {
      const env = createEnvironment({ version, config: { rule: rule({ action: 'block', ...values,
        source_ip_cidr: ['192.168.1.50'] }) } });
      const modal = await env.openRule('rule');
      for (const [name, value] of Object.entries(edit))
        modal.option(name).getUIElement('rule').setValue(value);
      await modal.save();
      assert.deepEqual(env.uci.data.rule.source_ip_cidr, expected);
    });

    // UC-004: the item settings modal of a user rule set keeps Built-in #2.
    for (const [include, expected] of [
      ['0', { rule_set: [CUSTOM], rule_set_with_subnets: [CUSTOM_SUBNETS, VALVE] }],
      ['1', { rule_set_with_subnets: [CUSTOM_SUBNETS, VALVE, CUSTOM] }],
    ]) await check(`${version} include_subnets=${include}`, async () => {
      const fixture = fixtures.mixed_subnet_rule_sets;
      const env = createEnvironment({ version, config: { rule: fixture } });
      const modal = await env.openRule('rule');
      const settings = await modal.openItemSettings('rule_set', CUSTOM);
      settings.setValue('include_subnets', include);
      await settings.save();
      const { rule_set, rule_set_with_subnets, ...rest } = fixture;
      const after = Object.assign({}, rest, expected);
      assert.deepEqual(env.uci.data.rule, after,
        `${version}: include_subnets=${include} for a user rule set changed other rule sets`);
      await modal.save();
      assert.deepEqual(env.uci.data.rule, after,
        `${version}: include_subnets=${include}: the rule save changed the rule sets`);
    });

    // Turning subnets off for a user set also keeps Built-in #2.
    await check(`${version} include_subnets off`, async () => {
      const fixture = fixtures.mixed_subnet_rule_sets;
      const env = createEnvironment({ version, config: { rule: fixture } });
      const modal = await env.openRule('rule');
      const settings = await modal.openItemSettings('rule_set', CUSTOM_SUBNETS);
      settings.setValue('include_subnets', '0');
      await settings.save();
      await modal.save();
      assert.deepEqual(env.uci.data.rule.rule_set, [CUSTOM, CUSTOM_SUBNETS]);
      assert.deepEqual(env.uci.data.rule.rule_set_with_subnets, [VALVE],
        `${version}: disabling subnets for a user rule set dropped Built-in rule sets #2`);
    });
  }
  if (failures.length) {
    console.error(failures.join('\n\n'));
    process.exit(1);
  }
  console.log('luci_rule_roundtrip: PASS');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
