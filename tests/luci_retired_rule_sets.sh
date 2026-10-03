#!/usr/bin/env bash
set -euo pipefail

# Retired b4geoip rule sets in the rule modal (D-13 (b), UC-093). The
# migration removed them and left their ids in retired_rule_sets
# (tests/retired_rule_sets_notice.sh). The real section.js runs under node
# (tests/helpers/luci_form_harness.js):
# - an administrator sees which rule sets the update removed and the
#   built-in rule sets of the same services; nothing is added by itself,
#   and a plain save keeps the rule as it is;
# - Add… asks first; Cancel and Dismiss change nothing; confirmed and saved,
#   Built-in rule sets gain exactly the offered lists and the notice goes;
# - Dismiss notice removes only the marker;
# - a list the rule already uses is not offered; a removed set without a
#   built-in equivalent offers nothing to add;
# - a read-only role sees the notice without any action.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(`${process.argv[2]}/luci_form_harness.js`);

const rule = (values) => Object.assign({ '.name': 'games', '.type': 'section', '.anonymous': false,
  enabled: '1', label: 'Games', action: 'bypass', domain: 'games.example' }, values);
const marked = rule({ retired_rule_sets: ['cloudflare', 'amazon', 'hetzner'] });

const buttons = (node) => node.querySelectorAll('button');
const button = (node, label) => {
  const found = buttons(node).find((b) => b.textContent === label);
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
    await check(`${version} notice`, async () => {
      const config = { games: marked };
      const env = createEnvironment({ version, config });
      const modal = await env.openRule('games');
      assert.equal(modal.active('_retired_rule_sets'), true, 'the notice must be shown');
      const node = modal.option('_retired_rule_sets').renderWidget('games');
      assert.match(node.textContent, /removed the rule sets cloudflare, amazon, hetzner/);
      assert.match(node.textContent, /Built-in rule sets of the same services: Cloudflare, Hetzner ASN/);
      assert.match(node.textContent, /so they were not added/);
      // A plain save adds nothing and keeps the notice.
      await modal.save();
      assert.deepEqual(env.uci.data, config, 'an unchanged save changed UCI');
    });

    await check(`${version} add cancelled and dismissed`, async () => {
      const config = { games: marked };
      let env = createEnvironment({ version, config });
      let modal = await env.openRule('games');
      let node = modal.option('_retired_rule_sets').renderWidget('games');
      button(node, 'Add…').attrs.click();
      assert.match(node.textContent, /Add Cloudflare, Hetzner ASN to Built-in rule sets of this rule\?/);
      button(node, 'Cancel').attrs.click();
      await modal.save();
      assert.deepEqual(env.uci.data, config, 'a cancelled add changed UCI');

      env = createEnvironment({ version, config });
      modal = await env.openRule('games');
      node = modal.option('_retired_rule_sets').renderWidget('games');
      button(node, 'Add…').attrs.click();
      button(node, 'Add').attrs.click();
      await modal.dismiss();
      assert.deepEqual(env.uci.data, config, 'Dismiss must discard the add');
    });

    await check(`${version} add`, async () => {
      const env = createEnvironment({ version, config: { games: marked } });
      const modal = await env.openRule('games');
      const node = modal.option('_retired_rule_sets').renderWidget('games');
      button(node, 'Add…').attrs.click();
      button(node, 'Add').attrs.click();
      assert.match(node.textContent, /added\. Save the rule/);
      assert.equal(buttons(node).length, 0, 'nothing left to click');
      await modal.save();
      const expected = rule({ community_lists: ['cloudflare', 'hetzner'] });
      assert.deepEqual(env.uci.data, { games: expected }, 'exactly the offered lists, and no marker');
    });

    await check(`${version} dismiss notice`, async () => {
      const env = createEnvironment({ version, config: { games: marked } });
      const modal = await env.openRule('games');
      const node = modal.option('_retired_rule_sets').renderWidget('games');
      button(node, 'Dismiss notice').attrs.click();
      assert.match(node.textContent, /dismissed/);
      await modal.save();
      assert.deepEqual(env.uci.data, { games: rule() }, 'only the marker goes');
    });

    await check(`${version} already used and no equivalent`, async () => {
      const used = rule({ community_lists: ['hetzner'], retired_rule_sets: ['hetzner', 'amazon'] });
      let env = createEnvironment({ version, config: { games: used } });
      let modal = await env.openRule('games');
      let node = modal.option('_retired_rule_sets').renderWidget('games');
      assert.doesNotMatch(node.textContent, /same services/);
      assert.equal(buttons(node).some((b) => b.textContent === 'Add…'), false, 'nothing to add');
      button(node, 'Dismiss notice');

      const plain = rule({ retired_rule_sets: ['fastly'] });
      env = createEnvironment({ version, config: { games: plain } });
      modal = await env.openRule('games');
      node = modal.option('_retired_rule_sets').renderWidget('games');
      assert.match(node.textContent, /removed the rule sets fastly/);
      assert.equal(buttons(node).some((b) => b.textContent === 'Add…'), false, 'nothing to add');
    });

    await check(`${version} no marker`, async () => {
      const env = createEnvironment({ version, config: { games: rule() } });
      const modal = await env.openRule('games');
      assert.equal(modal.active('_retired_rule_sets'), false, 'no notice without a marker');
    });

    await check(`${version} read-only`, async () => {
      const env = createEnvironment({ version, config: { games: marked } });
      const modal = await env.openRule('games', { readonly: true });
      const node = modal.option('_retired_rule_sets').renderWidget('games');
      assert.match(node.textContent, /removed retired rule sets .*cloudflare, amazon, hetzner/);
      assert.equal(buttons(node).length, 0, 'a read-only role has no action');
    });
  }

  if (failures.length) {
    for (const failure of failures) console.error(`FAIL: ${failure}`);
    process.exit(1);
  }
  console.log('luci_retired_rule_sets: ok');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
