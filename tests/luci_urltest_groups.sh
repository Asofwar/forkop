#!/usr/bin/env bash
set -euo pipefail

# URLTest groups of a rule in the LuCI editor. sing-box tags a group
# <rule>-urltest-<section name>, and libuci names an anonymous section after
# its position in the file, so a group added in the editor gets a named
# section (ut_<8 hex digits>, like pg_ priorities): adding or removing
# another section no longer changes its tag (UC-044). The dashboard keeps its
# URLTest settings for a rule in urltest_override sections (rule, tag);
# deleting the rule deletes them too, so a later rule with the same name does
# not inherit them, and the overrides of other rules stay (UC-151). The real
# section.js runs on the LuCI model of tests/helpers/luci_form_harness.js.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);

function rule(name, values) {
  return Object.assign({ '.name': name, '.type': 'section', '.anonymous': false, enabled: '1',
    action: 'connection', mixed_proxy_enabled: '0', community_lists: ['youtube'],
    selector_proxy_links: ['socks5://10.0.0.1:1080'] }, values);
}
function override(name, ruleName, tag) {
  return { '.name': name, '.type': 'urltest_override', '.anonymous': true, rule: ruleName, tag,
    testing_url: 'https://example.com/generate_204', check_interval: '70s', tolerance: '175',
    idle_timeout: '30m', interrupt_exist_connections: '1' };
}
const settings = { '.name': 'settings', '.type': 'settings', '.anonymous': false,
  yacd_secret_key: 'secret-0123456789' };

const failures = [];
async function check(label, fn) {
  try {
    await fn();
  } catch (error) {
    failures.push(`${label}: ${error.stack || error.message}`);
  }
}

(async () => {
  const urltestGroups = (env) => Object.values(env.uci.data).filter((item) => item['.type'] === 'urltest');

  for (const version of ['24.10', '25.12']) {
    // UC-044: the "+ Add URLTest" button, the group settings, then the rule's Save.
    await check(`${version} a URLTest group added in the editor gets a stable section name`, async () => {
      const env = createEnvironment({ version, config: { settings, main: rule('main') } });
      const modal = await env.openRule('main');
      const group = await modal.openItemSettings('urltest', '', { adding: true });
      group.setValue('name', 'Fastest');
      await group.save();
      modal.option('urltest').getUIElement('main').setValue(['Fastest']);
      await modal.saveButton();

      const [created, ...others] = urltestGroups(env);
      assert.equal(others.length, 0);
      assert.match(created['.name'], /^ut_[0-9a-f]{8}$/, 'the group got an anonymous section');
      assert.equal(created['.anonymous'], false);
      assert.equal(created.section, 'main');
      assert.equal(created.name, 'Fastest');

      // Saving the rule again keeps the group and its name.
      await (await env.openRule('main')).saveButton();
      assert.deepEqual(urltestGroups(env), [created]);
    });

    // Existing groups, anonymous ones included, keep their sections.
    await check(`${version} existing URLTest groups keep their sections`, async () => {
      const group = (name, anonymous, label) => ({ '.name': name, '.type': 'urltest', '.anonymous': anonymous,
        section: 'main', name: label, check_interval: '3m', tolerance: '50',
        testing_url: 'https://www.gstatic.com/generate_204', idle_timeout: '30m',
        interrupt_exist_connections: '1', pin_dashboard: '1', filter_mode: 'disabled',
        detect_server_country: 'flag_emoji' });
      const config = { settings, main: rule('main'), cfg032898: group('cfg032898', true, 'Old'),
        ut_1a2b3c4d: group('ut_1a2b3c4d', false, 'New') };
      const env = createEnvironment({ version, config });
      await (await env.openRule('main')).saveButton();
      assert.deepEqual(env.uci.data, config);
    });

    // UC-151: the rule's dashboard URLTest overrides go with the rule.
    await check(`${version} removing a rule removes its URLTest overrides`, async () => {
      const config = {
        settings,
        main: rule('main'),
        other: rule('other'),
        cfg0a0001: override('cfg0a0001', 'main', 'Flint Auto'),
        cfg0b0002: override('cfg0b0002', 'main', 'main-urltest-ut_old-out'),
        cfg0c0003: override('cfg0c0003', 'other', 'Flint Auto'),
      };
      const env = createEnvironment({ version, config });
      await (await env.openRules()).removeRule('main');
      assert.equal(env.uci.data.main, undefined, 'the rule was not removed');
      assert.equal(env.uci.data.cfg0a0001, undefined, 'an override of the removed rule stayed');
      assert.equal(env.uci.data.cfg0b0002, undefined, 'an override of the removed rule stayed');
      assert.deepEqual(env.uci.data.cfg0c0003, config.cfg0c0003, 'an override of another rule changed');
      assert.deepEqual(env.uci.data.other, config.other);
    });
  }
  if (failures.length) {
    console.error(failures.join('\n\n'));
    process.exit(1);
  }
  console.log('luci_urltest_groups: PASS');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
