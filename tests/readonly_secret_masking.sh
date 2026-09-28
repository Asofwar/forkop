#!/usr/bin/env bash
set -euo pipefail

# UC-002, UC-006, UC-039, UC-150: every command of the read ACL group runs
# against a configuration whose sensitive values all carry a SECRET_MARKER_*
# substring (outbound links and JSON, WAN credentials, URL userinfo, query
# tokens, DoH paths, Clash secret, subscription URLs, raw DPI strategies).
# No marker may reach any read-only output.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_UC="$ROOT_DIR/forkop/files/usr/bin/forkop"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
STATUS_UC="$FORKOP_LIB/diagnostics/status.uc"
SNAPSHOTS_UC="$FORKOP_LIB/config/snapshots.uc"
FIXTURES="$ROOT_DIR/tests/fixtures/readonly_secrets"
ACL="$ROOT_DIR/luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json"
WORK_DIR="$(mktemp -d)"
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

UCODE_BIN="$(command -v ucode)" || fail "ucode is required"
UCI_BIN="$(command -v uci)" || fail "uci CLI is required"
command -v node >/dev/null || fail "node is required"
TIMEOUT_BIN="$(command -v timeout)" || fail "timeout is required"

leaks=""
check_output() {
  local label="$1"
  local file="$2"
  local found
  found="$(grep -o 'SECRET_MARKER_[0-9]*' "$file" | LC_ALL=C sort -u | tr '\n' ' ' || true)"
  if [ -n "$found" ]; then
    leaks="$leaks
$label: $found"
  fi
}

# Fixture files: the config points at the sing-box fixture.
mkdir -p "$WORK_DIR/etc" "$WORK_DIR/run" "$WORK_DIR/tmp/sing-box" "$WORK_DIR/bin"
cp "$FIXTURES/sing-box.json" "$WORK_DIR/sing-box.json"
sed "s|@SING_BOX_CONFIG@|$WORK_DIR/sing-box.json|" "$FIXTURES/forkop" >"$WORK_DIR/etc/forkop"
sed "s|@WAN_PROTO@|pppoe|" "$FIXTURES/network" >"$WORK_DIR/etc/network"
[ "$(grep -o 'SECRET_MARKER_[0-9]*' "$WORK_DIR/etc/forkop" | sort -u | wc -l)" -ge 49 ] || fail "fixture config lost its markers"

# The backend reads UCI through core/uci.uc; the fixture state file carries
# the same data (lists joined by spaces, as the fixture reader expects).
"$UCI_BIN" -c "$WORK_DIR/etc" -X show forkop >"$WORK_DIR/forkop.show" || fail "uci could not parse the fixture config"
"$UCI_BIN" -c "$WORK_DIR/etc" -X show network >"$WORK_DIR/network.show" || fail "uci could not parse the network fixture"
node - "$WORK_DIR/forkop.show" "$WORK_DIR/network.show" >"$WORK_DIR/uci-state" <<'NODE'
const fs = require('node:fs');
for (const file of process.argv.slice(2)) {
  const text = fs.readFileSync(file, 'utf8');
  let i = 0;
  while (i < text.length) {
    const eq = text.indexOf('=', i);
    if (eq < 0) break;
    const key = text.slice(i, eq);
    let j = eq + 1;
    const values = [];
    while (j < text.length && text[j] !== '\n') {
      if (text[j] === "'") {
        let value = '';
        j++;
        while (j < text.length) {
          if (text.startsWith("'\\''", j)) { value += "'"; j += 4; continue; }
          if (text[j] === "'") { j++; break; }
          value += text[j++];
        }
        values.push(value);
      } else if (text[j] === ' ') {
        j++;
      } else {
        let value = '';
        while (j < text.length && text[j] !== '\n' && text[j] !== ' ') value += text[j++];
        values.push(value);
      }
    }
    process.stdout.write(`${key}=${values.join(' ').replace(/\s+/g, ' ')}\n`);
    i = j + 1;
  }
}
NODE
grep -q '^forkop.settings.yacd_secret_key=SECRET_MARKER_02$' "$WORK_DIR/uci-state" ||
  fail "fixture UCI state was not generated"

cat >"$WORK_DIR/bin/sing-box" <<'SH'
#!/bin/sh
case "$1" in
  version) printf 'sing-box version 1.12.0\n' ;;
  -c) [ "$3" = check ] && exit 0; exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod 0755 "$WORK_DIR/bin/sing-box"
ln -s "$UCODE_BIN" "$WORK_DIR/bin/ucode"
cat >"$WORK_DIR/bin/forkop" <<EOF
#!/bin/sh
exec "$UCODE_BIN" "$CLI_UC" "\$@"
EOF
chmod 0755 "$WORK_DIR/bin/forkop"

export FORKOP_LIB
export FORKOP_BIN="$WORK_DIR/bin/forkop"
export FORKOP_CONFIG="$WORK_DIR/etc/forkop"
export FORKOP_CONFIG_FILE="$WORK_DIR/etc/forkop"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci-state"
export FORKOP_UCI_LOG_FILE="$WORK_DIR/uci-log"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export FORKOP_SYSTEM_INFO_CACHE_FILE="$WORK_DIR/run/system-info.json"
export FORKOP_SNAPSHOT_DIR="$WORK_DIR/snapshots"
export FORKOP_SNAPSHOT_HASH_DIR="$WORK_DIR/run/snapshot-hash"
export FORKOP_SNAPSHOT_LOCK_DIR="$WORK_DIR/run/config-snapshot.lock"
export FORKOP_DIAGNOSTICS_SING_BOX_BIN_PATH="$WORK_DIR/bin/sing-box"
export FORKOP_UI_SING_BOX_BIN_PATH="$WORK_DIR/bin/sing-box"
export FORKOP_HISTORY_FILE="$WORK_DIR/history.jsonl"
export FORKOP_AUTOTUNE_STATE_FILE="$WORK_DIR/autotune/state.json"
export FORKOP_AUTOTUNE_STATE_DIR="$WORK_DIR/run/autotune"
export FORKOP_AUTOTUNE_LAST_DIR="$WORK_DIR/run/autotune/last"
export FORKOP_AUTOTUNE_UCI_SAVEDIR="$WORK_DIR/uci-save"
export FORKOP_AUTOTUNE_TMPDIR="$WORK_DIR/tmp"
export TMP_SING_BOX_FOLDER="$WORK_DIR/tmp/sing-box"
export PATH="$WORK_DIR/bin:$PATH"

# Snapshot of an empty configuration, so the diff lists every fixture option.
: >"$WORK_DIR/empty"
snapshot_id="$(FORKOP_CONFIG_FILE="$WORK_DIR/empty" "$UCODE_BIN" -L "$FORKOP_LIB" "$SNAPSHOTS_UC" create manual |
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).snapshot.id))')" ||
  fail "could not create the baseline snapshot"

# The commands run in private mount and network namespaces with an empty /run
# where available, so nothing reaches the network or the host runtime state.
ISOLATE=()
isolate_probe='mount -t tmpfs tmpfs /run'
if unshare --mount --net --propagation private sh -c "$isolate_probe" 2>/dev/null; then
  ISOLATE=(unshare --mount --net --propagation private)
elif unshare --user --map-root-user --mount --net --propagation private \
  sh -c "$isolate_probe" 2>/dev/null; then
  ISOLATE=(unshare --user --map-root-user --mount --net --propagation private)
fi
if [ "${#ISOLATE[@]}" -gt 0 ]; then
  ISOLATE+=(sh -c "$isolate_probe && exec \"\$@\"" sh)
fi

# Every command of the read ACL group; '*' becomes a sample argument.
node - "$ACL" "$snapshot_id" >"$WORK_DIR/commands" <<'NODE'
const fs = require('node:fs');
const [acl, snapshotId] = process.argv.slice(2);
const files = JSON.parse(fs.readFileSync(acl, 'utf8'))['luci-app-forkop'].read.file;
const prefix = '/usr/libexec/forkop-ro ';
const samples = {
  config_snapshot_diff: snapshotId,
  route_trace: '192.0.2.1 192.0.2.10 TCP 443',
  connectivity_test: 'example.com TCP 443',
  get_outbound_metadata: 'main-out',
};
for (const entry of Object.keys(files)) {
  if (!entry.startsWith(prefix)) continue;
  let command = entry.slice(prefix.length);
  const name = command.split(' ')[0];
  command = command.replace(/ \*$/, ` ${samples[name] || 'main-out'}`);
  process.stdout.write(`${command}\n`);
}
NODE
[ "$(wc -l <"$WORK_DIR/commands")" -gt 30 ] || fail "read ACL commands were not collected"
grep -qx 'global_check masked' "$WORK_DIR/commands" || fail "global_check masked is missing from the read ACL list"

while IFS= read -r command; do
  out="$WORK_DIR/out.$(printf '%s' "$command" | tr -c 'A-Za-z0-9_' '_')"
  # shellcheck disable=SC2086 # the command line is split on purpose
  "${ISOLATE[@]}" "$TIMEOUT_BIN" 60 "$UCODE_BIN" "$CLI_UC" $command >"$out" 2>&1 </dev/null || true
  check_output "$command" "$out"
done <"$WORK_DIR/commands"

# Validator messages quote the rejected value; the masked check keeps only
# the verdict.
cat >"$WORK_DIR/etc/forkop-invalid" <<'EOF'
config settings 'settings'
	option dns_type 'doh'
	list dns_server 'https://SECRET_MARKER_150@dns.example:0/SECRET_MARKER_151'
	list bootstrap_dns_server '77.88.8.8'
EOF
printf '%s\n' 'forkop.settings=settings' 'forkop.settings.dns_type=doh' \
  'forkop.settings.dns_server=https://SECRET_MARKER_150@dns.example:0/SECRET_MARKER_151' \
  'forkop.settings.bootstrap_dns_server=77.88.8.8' >"$WORK_DIR/uci-state-invalid"
FORKOP_CONFIG="$WORK_DIR/etc/forkop-invalid" FORKOP_UCI_STATE_FILE="$WORK_DIR/uci-state-invalid" \
  "${ISOLATE[@]}" "$TIMEOUT_BIN" 60 "$UCODE_BIN" "$CLI_UC" global_check masked >"$WORK_DIR/invalid.out" 2>&1 </dev/null || true
grep -Fq 'Forkop configuration validation failed' "$WORK_DIR/invalid.out" ||
  fail "global_check masked must report the failed validation"
check_output "global_check masked (validation failure)" "$WORK_DIR/invalid.out"

# The masked views must still carry the non-secret structure.
global_out="$WORK_DIR/out.global_check_masked"
grep -Fq "option yacd_secret_key 'MASKED'" "$global_out" || fail "global_check masked lost the option shape"
grep -Fq "option enabled '1'" "$global_out" || fail "global_check masked hides safe options"
grep -Fq "list rule_set 'https://" "$global_out" || fail "global_check masked must keep the list URL host"
grep -Fq 'rules.example/rules.srs' "$global_out" || fail "global_check masked must keep the list URL path"
sb_out="$WORK_DIR/out.show_sing_box_config_masked"
grep -Fq '"tag": "main-out"' "$sb_out" || fail "masked sing-box config lost outbound tags"
grep -Fq '"type": "vless"' "$sb_out" || fail "masked sing-box config lost outbound types"
grep -Fq 'rules.example/r.srs' "$sb_out" || fail "masked sing-box config must keep the rule_set URL path"
grep -Fq '"tag": "main-out"' "$WORK_DIR/out.check_proxy" || fail "check_proxy did not print the masked config"

# UC-039: the read-only sections carry child display names, never URLs.
node - "$WORK_DIR/out.get_readonly_config_sections" <<'NODE' || fail "get_readonly_config_sections contract"
const fs = require('node:fs');
const sections = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const byType = (type) => sections.filter((item) => item['.type'] === type);
const iface = byType('section_interface')[0];
const urltest = byType('urltest')[0];
const subscription = byType('subscription_url')[0];
if (!iface || iface.name !== 'awg1' || iface.section !== 'main') throw new Error('section_interface name missing');
if (!urltest || urltest.name !== 'Fastest') throw new Error('urltest name missing');
if (!subscription || subscription.url !== undefined || subscription.name !== undefined) throw new Error('subscription_url must stay minimal');
NODE

# UC-150: the snapshot list is metadata only.
node - "$WORK_DIR/out.config_snapshot_list" "$snapshot_id" <<'NODE' || fail "config_snapshot_list must not expose config_hash"
const fs = require('node:fs');
const list = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (list.length !== 1 || list[0].id !== process.argv[3]) throw new Error('snapshot missing');
if ('config_hash' in list[0]) throw new Error('config_hash exposed');
NODE
grep -Fq '"option": "outbound_jsons"' "$WORK_DIR/out.config_snapshot_diff_$snapshot_id" ||
  grep -Fq '"option":"outbound_jsons"' "$WORK_DIR/out.config_snapshot_diff_$snapshot_id" ||
  fail "config_snapshot_diff did not list the fixture options"

# WAN credentials of any protocol (global_check reads /etc/config/network).
for proto in static pppoe pppoa l2tp pptp 3g qmi ncm mbim modemmanager wireguard openvpn dhcp; do
  sed "s|@WAN_PROTO@|$proto|" "$FIXTURES/network" >"$WORK_DIR/network.$proto"
  out="$WORK_DIR/wan.$proto"
  "$UCODE_BIN" -L "$FORKOP_LIB" "$STATUS_UC" wan-config-masked "$WORK_DIR/network.$proto" >"$out" 2>&1 || true
  check_output "wan-config-masked ($proto)" "$out"
  grep -Fq "option proto '$proto'" "$out" || fail "masked WAN config lost the protocol ($proto)"
  grep -Fq "option device 'eth1'" "$out" || fail "masked WAN config lost the device ($proto)"
done

# The frontend copy (admin "mask values" toggle) masks exactly like the
# backend. Node imports the TypeScript module directly when it can strip
# types (Node >= 22.18); older Node skips this comparison.
MASK_TS="$ROOT_DIR/fe-app-forkop/src/forkop/tabs/diagnostic/helpers/maskDiagnostics.ts"
"$UCODE_BIN" -L "$FORKOP_LIB" "$STATUS_UC" forkop-config-masked "$FORKOP_CONFIG" >"$WORK_DIR/backend-forkop" ||
  fail "forkop-config-masked failed"
"$UCODE_BIN" -L "$FORKOP_LIB" "$STATUS_UC" mask-sing-box-config "$WORK_DIR/sing-box.json" >"$WORK_DIR/backend-sing-box" ||
  fail "mask-sing-box-config failed"
if node -e 'import(process.argv[1]).then(() => process.exit(0), () => process.exit(1))' "$MASK_TS" 2>/dev/null; then
  node --input-type=module - "$MASK_TS" "$WORK_DIR" <<'NODE' || fail "frontend masking differs from the backend"
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const [module, dir] = process.argv.slice(2);
const { maskGlobalCheckText, formatMaskedSingBoxConfig } = await import(module);
assert.equal(
  maskGlobalCheckText(readFileSync(`${dir}/etc/forkop`, 'utf8')),
  readFileSync(`${dir}/backend-forkop`, 'utf8'),
);
assert.deepEqual(
  JSON.parse(formatMaskedSingBoxConfig(readFileSync(`${dir}/sing-box.json`, 'utf8'))),
  JSON.parse(readFileSync(`${dir}/backend-sing-box`, 'utf8')),
);
NODE
else
  printf 'SKIP: frontend/backend masking comparison needs Node with type stripping\n'
fi

if [ -n "$leaks" ]; then
  printf 'FAIL: secrets reached read-only outputs:%s\n' "$leaks" >&2
  exit 1
fi

printf 'read-only outputs keep fixture secrets masked\n'
