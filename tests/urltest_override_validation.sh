#!/usr/bin/env bash
set -eo pipefail

# Dashboard URLTest overrides (config urltest_override: rule, tag, settings)
# replace the settings of a URLTest group of a rule in the generated config.
# The validator checks them as the dashboard saves them. An override that no
# rule uses (the rule was deleted before overrides went with it, is disabled
# or is no longer a Connection rule) is never applied and never refuses the
# configuration (UC-151).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
VALIDATOR="$FORKOP_LIB/config/validator.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# fixture <name> <override JSON objects...>
fixture() {
  local name="$1"
  shift
  node - "$WORK_DIR/$name.json" "$@" <<'JS'
const fs = require('fs');
const [path, ...overrides] = process.argv.slice(2);
const rule = (name, values) => Object.assign({ '.name': name, '.type': 'section', enabled: '1',
  action: 'connection', selector_proxy_links: [ 'socks5://10.0.0.1:1080' ] }, values);
fs.writeFileSync(path, JSON.stringify({
  settings: { '.name': 'settings', '.type': 'settings', dns_server: [ '77.88.8.8' ],
    bootstrap_dns_server: [ '77.88.8.8' ], yacd_secret_key: 'test-clash-secret' },
  section: [
    rule('main'),
    rule('off', { enabled: '0' }),
    rule('blocked', { action: 'block', selector_proxy_links: undefined, community_lists: [ 'youtube' ] })
  ],
  urltest_override: overrides.map((value, index) => Object.assign({ '.name': 'cfg0' + index + '0000',
    '.type': 'urltest_override', testing_url: 'https://example.com/generate_204', check_interval: '70s',
    tolerance: '175', idle_timeout: '30m', interrupt_exist_connections: '1' }, JSON.parse(value)))
}));
JS
}

validate() {
  ucode -L "$FORKOP_LIB" "$VALIDATOR" validate-runtime-fixture "$WORK_DIR/$1.json" '{}'
}

accepts() {
  local output
  output="$(validate "$1" 2>&1)" || fail "$1 must be accepted, got: $output"
}

rejects() {
  local output
  if output="$(validate "$1" 2>&1)"; then
    fail "$1 must be rejected"
  fi
  printf '%s\n' "$output" | grep -Fq "$2" ||
    fail "$1: expected a message containing '$2', got '$output'"
}

fixture valid '{"rule":"main","tag":"Flint Auto"}' \
  '{"rule":"main","tag":"main-urltest-ut_1a2b3c4d-out","interrupt_exist_connections":"0","tolerance":"0"}' \
  '{"rule":"main","tag":"Flint Fallback","interrupt_exist_connections":"","tolerance":"10000"}'
accepts valid

# Nothing applies these: they never refuse the configuration.
fixture orphans \
  '{"rule":"gone","tag":"Flint Auto","testing_url":"","check_interval":"soon","tolerance":"-1"}' \
  '{"rule":"off","tag":"Flint Auto","testing_url":"ftp://example.com","idle_timeout":""}' \
  '{"rule":"blocked","tag":"Flint Auto","interrupt_exist_connections":"yes"}' \
  '{"tag":"Flint Auto","check_interval":""}' \
  '{"rule":"main","tag":"","testing_url":"not a url"}'
accepts orphans

fixture bad_url '{"rule":"main","tag":"Flint Auto","testing_url":"ftp://example.com/check"}'
rejects bad_url "Invalid URL value for URLTest override 'Flint Auto' of rule 'main' (testing_url)"
fixture no_url '{"rule":"main","tag":"Flint Auto","testing_url":""}'
rejects no_url "URLTest override 'Flint Auto' of rule 'main' (testing_url)"
fixture no_host '{"rule":"main","tag":"Flint Auto","testing_url":"http:///generate_204"}'
rejects no_host "Invalid URL value for URLTest override 'Flint Auto' of rule 'main' (testing_url)"
fixture bad_interval '{"rule":"main","tag":"Flint Auto","check_interval":"soon"}'
rejects bad_interval "Invalid duration value for URLTest override 'Flint Auto' of rule 'main' (check_interval)"
fixture no_idle '{"rule":"main","tag":"Flint Auto","idle_timeout":""}'
rejects no_idle "Missing duration value for URLTest override 'Flint Auto' of rule 'main' (idle_timeout)"
fixture bad_tolerance '{"rule":"main","tag":"Flint Auto","tolerance":"70000"}'
rejects bad_tolerance "Invalid tolerance '70000' for URLTest override 'Flint Auto' of rule 'main'"
# The range of the URLTest group of a rule, which an override replaces.
fixture group_tolerance '{"rule":"main","tag":"Flint Auto","tolerance":"10001"}'
rejects group_tolerance "Invalid tolerance '10001' for URLTest override 'Flint Auto' of rule 'main'. Use a number from 0 to 10000."
fixture text_tolerance '{"rule":"main","tag":"Flint Auto","tolerance":"fast"}'
rejects text_tolerance "Invalid tolerance 'fast' for URLTest override 'Flint Auto' of rule 'main'"
fixture bad_interrupt '{"rule":"main","tag":"Flint Auto","interrupt_exist_connections":"yes"}'
rejects bad_interrupt "Invalid interrupt_exist_connections 'yes' for URLTest override 'Flint Auto' of rule 'main'"

printf 'URLTest override validation checks passed\n'
