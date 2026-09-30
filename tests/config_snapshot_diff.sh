#!/bin/sh
# The snapshot diff (config_snapshot_diff, History > Changes, the restore
# confirmation) on configurations in the form libuci writes them.
# UC-018: an anonymous section (`config <type>` without a name) is a section
# of its own, addressed as libuci does (@type[n], n counting every section of
# that type in file order), never merged into the named section before it.
set -eu
ROOT="$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
command -v ucode >/dev/null || { echo 'FAIL: ucode is required' >&2; exit 1; }
command -v node >/dev/null || { echo 'FAIL: node is required' >&2; exit 1; }
# Where the OpenWrt uci CLI exists, every anonymous row is also read back
# through libuci's own addressing.
UCI_BIN="$(command -v uci 2>/dev/null || true)"
[ -n "$UCI_BIN" ] || echo 'NOTE: no uci CLI on PATH, @type[n] keys are not cross-checked with libuci' >&2

node - "$LIB" "$SCRIPT" "$WORK" "$UCI_BIN" <<'JS'
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const assert = require('node:assert/strict');
const [lib, script, work, uci] = process.argv.slice(2);
let run = 0;
function diff(before, after) {
  const dir = `${work}/case${run++}`;
  fs.mkdirSync(dir);
  fs.writeFileSync(`${dir}/before`, before);
  fs.writeFileSync(`${dir}/forkop`, after);
  const rows = JSON.parse(execFileSync('ucode', ['-L', lib, script, 'fixture-diff', `${dir}/before`, `${dir}/forkop`]));
  // libuci reads the same option at the reported key.
  if (uci) {
    for (const row of rows) {
      if (!row.section.startsWith('@') || typeof row.after !== 'string' || row.after === '***') continue;
      const got = execFileSync(uci, ['-c', dir, 'get', `forkop.${row.section}.${row.option}`]).toString().trim();
      assert.equal(got, row.after, `uci get forkop.${row.section}.${row.option}`);
    }
  }
  return rows;
}
// libuci's export format: `config <type>` for an anonymous section.
const section = (type, name, ...options) =>
  `\nconfig ${type}${name ? ` '${name}'` : ''}\n${options.map((o) => `\t${o}\n`).join('')}`;
const iface = (name, dns) => section('section_interface', null,
  "option section 'Czech'", `option name '${name}'`, `option dns_type '${dns}'`);
const routing = section('section', 'Czech', "option action 'proxy'");
const two = routing + iface('awg0', 'udp') + iface('awg1', 'udp');

// A change in the first of two anonymous items is reported for that item.
assert.deepEqual(diff(two, routing + iface('awg0', 'doh') + iface('awg1', 'udp')), [
  { section: '@section_interface[0]', option: 'dns_type', before: 'udp', after: 'doh' },
]);
// A change in the second one is keyed @type[1], not to the named parent.
assert.deepEqual(diff(two, routing + iface('awg0', 'udp') + iface('awg1', 'dot')), [
  { section: '@section_interface[1]', option: 'dns_type', before: 'udp', after: 'dot' },
]);
// Removing the first item is a change (it was an empty diff: the restore
// preview said "No saved changes" while the restore re-adds the interface).
const removed = diff(two, routing + iface('awg1', 'dot'));
assert.ok(removed.length > 0, 'removing an anonymous section must be visible');
assert.deepEqual(removed.map((row) => row.section).filter((s) => !s.startsWith('@section_interface[')), []);
assert.ok(removed.some((row) => row.section === '@section_interface[1]'));
assert.deepEqual(removed.find((row) => row.section === '@section_interface[0]' && row.option === 'dns_type'),
  { section: '@section_interface[0]', option: 'dns_type', before: 'udp', after: 'dot' });

// List options of two anonymous items stay separate.
const urltest = (...servers) => section('urltest', null, ...servers.map((s) => `list dns_server '${s}'`));
const main = section('section', 'main', "option action 'proxy'");
assert.deepEqual(diff(main + urltest('1.1.1.1') + urltest('8.8.8.8'), main + urltest('8.8.8.8') + urltest('1.1.1.1')), [
  { section: '@urltest[0]', option: 'dns_server', kind: 'list', before: ['1.1.1.1'], after: ['8.8.8.8'] },
  { section: '@urltest[1]', option: 'dns_server', kind: 'list', before: ['8.8.8.8'], after: ['1.1.1.1'] },
]);

// A child option does not hide the named parent's option of the same name.
const child = section('section_interface', null, "option action 'block'");
assert.deepEqual(diff(main + child, section('section', 'main', "option action 'direct'") + child), [
  { section: 'main', option: 'action', before: 'proxy', after: 'direct' },
]);
// Nor the other way round: the child's change is the child's.
assert.deepEqual(diff(main + child, main + section('section_interface', null, "option action 'proxy'")), [
  { section: '@section_interface[0]', option: 'action', before: 'block', after: 'proxy' },
]);

// An anonymous section before any named one is not dropped.
const first = (dns) => section('settings', null, `option dns_type '${dns}'`) + main;
assert.deepEqual(diff(first('udp'), first('doh')), [
  { section: '@settings[0]', option: 'dns_type', before: 'udp', after: 'doh' },
]);

// libuci's @type[n] counts every section of the type, named ones included;
// a named section that appears again is the same section (no new index).
const mixed = (dns) => section('t', 'named', "option action 'a'") + section('t', null, `option dns_type '${dns}'`) +
  section('u', null, "option action 'u'") + section('t', 'named', "option enabled '1'") +
  section('t', null, `option dns_type '${dns}'`);
assert.deepEqual(diff(mixed('udp'), mixed('doh')), [
  { section: '@t[1]', option: 'dns_type', before: 'udp', after: 'doh' },
  { section: '@t[2]', option: 'dns_type', before: 'udp', after: 'doh' },
]);
// An empty name is no name.
const empty = (dns) => `config t ''\n\toption dns_type '${dns}'\n`;
assert.deepEqual(diff(empty('udp'), empty('doh')), [
  { section: '@t[0]', option: 'dns_type', before: 'udp', after: 'doh' },
]);
// Quoted type and name, as hand-written configurations have them.
const quoted = (dns) => `config "section" "main"\n\toption dns_type '${dns}'\nconfig "urltest"\n\toption dns_type '${dns}'\n`;
assert.deepEqual(diff(quoted('udp'), quoted('doh')), [
  { section: 'main', option: 'dns_type', before: 'udp', after: 'doh' },
  { section: '@urltest[0]', option: 'dns_type', before: 'udp', after: 'doh' },
]);

// D-2(a), UC-063: a side without the option is null ("not set"); '***'
// stands only for a value that exists and is hidden.
const settings = (...options) => section('settings', 'settings', ...options);
const secret = "option password 'SECRET_MARKER_s3cr3t'";
assert.deepEqual(diff(settings(), settings(secret)), [
  { section: 'settings', option: 'password', before: null, after: '***' },
]);
assert.deepEqual(diff(settings(secret), settings()), [
  { section: 'settings', option: 'password', before: '***', after: null },
]);
assert.deepEqual(diff(settings(secret), settings("option password 'other'")), [
  { section: 'settings', option: 'password', before: '***', after: '***' },
]);
assert.deepEqual(diff(settings(), settings("option dns_server '1.1.1.1'")), [
  { section: 'settings', option: 'dns_server', before: null, after: '1.1.1.1' },
]);
assert.deepEqual(diff(settings("list subscription_urls 'https://SECRET_MARKER_u@example.com'"), settings()), [
  { section: 'settings', option: 'subscription_urls', kind: 'list', before: ['***'], after: null },
]);
// A whole anonymous section that is gone: every option of it is not set.
assert.deepEqual(diff(main + section('section_interface', null, secret, "option dns_type 'udp'"), main), [
  { section: '@section_interface[0]', option: 'password', before: '***', after: null },
  { section: '@section_interface[0]', option: 'dns_type', before: 'udp', after: null },
]);
// An option statement without a value sets nothing, as libuci loads it:
// alone it is not set, after a value the value stays.
assert.deepEqual(diff(settings(), settings("option password ''")), []);
assert.deepEqual(diff(settings("option dns_type 'udp'"), settings("option dns_type 'udp'", "option dns_type ''")), []);
assert.deepEqual(diff(settings("option dns_type ''"), settings("option dns_type 'doh'")), [
  { section: 'settings', option: 'dns_type', before: null, after: 'doh' },
]);
// Absence reveals no value: nothing of a secret reaches the output.
const all = JSON.stringify([
  diff(settings(), settings(secret)), diff(settings(secret), settings()),
  diff(settings("list subscription_urls 'https://SECRET_MARKER_u@example.com'"), settings()),
]);
assert.equal(all.includes('SECRET_MARKER'), false);
JS
echo 'config_snapshot_diff: PASS'
