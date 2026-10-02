#!/usr/bin/env bash
set -euo pipefail

# A reload whose list source changed leaves the nft rebuild and the sing-box
# switch to the list worker's list-content reload (UC-209). Until then the
# live ForkopTable is the previous one while UCI already holds the new rule
# order; a kill-switch refresh rendered from both could reject traffic the
# running Forkop deliberately sends directly. Such a reload must not refresh
# the kill-switch, and records that the live table lacks the list
# generation, so that no other refresh renders from it either
# (killswitch/runtime.uc, tests/killswitch_stale_runtime.sh); the
# list-content reload rebuilds the table and refreshes it.
#
# The reload is the real service/lifecycle.uc under reload.lock (as init.d
# runs it); the modules it calls are modelled and log what they are asked.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

EVENTS="$WORK_DIR/events"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if [ -s "$EVENTS" ]; then
    sed 's/^/  event: /' "$EVENTS" >&2
  fi
  if [ -s "$WORK_DIR/syslog" ]; then
    sed 's/^/  syslog: /' "$WORK_DIR/syslog" >&2
  fi
  exit 1
}

FAKE_LIB="$WORK_DIR/fake-lib"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/forkop" "$WORK_DIR/tmp" "$WORK_DIR/singbox-tmp/rulesets" \
  "$FAKE_LIB/service" "$FAKE_LIB/subscription" "$FAKE_LIB/config" "$FAKE_LIB/singbox" "$FAKE_LIB/nft" \
  "$FAKE_LIB/dns" "$FAKE_LIB/components" "$FAKE_LIB/autotune" "$FAKE_LIB/diagnostics" "$FAKE_LIB/killswitch" \
  "$FAKE_LIB/providers/zapret" "$FAKE_LIB/providers/zapret2" "$FAKE_LIB/providers/byedpi"
cat >"$WORK_DIR/uci.state" <<'EOF'
forkop.settings=settings
forkop.settings.yacd_secret_key=0123456789abcdef
forkop.settings.dont_touch_dhcp=0
EOF
: >"$WORK_DIR/forkop.config"
printf 'config dnsmasq\n' >"$WORK_DIR/dhcp"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export EVENTS REAL_LIB FAKE_LIB
export FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/forkop.reload.lock"
export FORKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$WORK_DIR/run/forkop/subscription-update.lock"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run/forkop"
export FORKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/forkop/reload.pending"
export FORKOP_SERVICE_INIT="$WORK_DIR/bin/no-init"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_CONFIG_FILE="$WORK_DIR/forkop.config"
export FORKOP_DNSMASQ_CONFIG_FILE="$WORK_DIR/dhcp"
export DNSMASQ_INIT="$WORK_DIR/bin/no-init"
export FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export FORKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export FORKOP_UI_ACTION_TRACKED=1
export TMP_SING_BOX_FOLDER="$WORK_DIR/singbox-tmp"
export TMP_RULESET_FOLDER="$WORK_DIR/singbox-tmp/rulesets"
export FORKOP_SING_BOX_RELOAD_PID_TIMEOUT=2
LISTS_PENDING="$FORKOP_RUNTIME_STATE_DIR/runtime-lists.pending"

# Nothing here may reach the host's syslog, firewall or init scripts.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$WORK_DIR/syslog" >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/no-init"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
[ "$1 $2 $3 $4" = "list table inet ForkopTable" ] && exit 0
[ "$1 $2 $3" != "list table inet" ] || exit 1
[ "$1 $2" != "list chain" ]
SH

# init.d holds reload.lock around `forkop reload`.
cat >"$WORK_DIR/reload" <<'SH'
#!/bin/sh
state() { ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" "$@"; }
state acquire-runtime-dir-lock "$FORKOP_RELOAD_LOCK_DIR" "$$" || exit 99
env FORKOP_LIB="$FAKE_LIB" ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" reload "$1"
status=$?
state release-runtime-dir-lock "$FORKOP_RELOAD_LOCK_DIR" "$$"
exit "$status"
SH

# shellcheck disable=SC1003 # a ucode string, not shell quoting
fake_header='let fs = require("fs");
function q(value) { return "'"'"'" + replace("" + value, /'"'"'/g, "'"'"'\\'"'"''"'"'") + "'"'"'"; }
function ev(line) { system("printf '"'"'%s\\n'"'"' " + q(line) + " >> " + q(getenv("EVENTS"))); }
let mode = "" + (ARGV[0] ?? "");
'

cat >"$FAKE_LIB/service/state.uc" <<UC
$fake_header
if (index(mode, "runtime-dir-lock") >= 0 || mode == "runtime-apply-allowed" || mode == "stop-requested") {
    let command = "ucode -L " + q(getenv("REAL_LIB")) + " " + q(getenv("REAL_LIB") + "/service/state.uc");
    for (let arg in ARGV)
        command += " " + q(arg);
    exit(system(command));
}
if (mode == "sing-box-process-conflict" || mode == "has-nft-list-update-sources")
    exit(1);
// A start: nothing runs yet; LISTS=1 gives the configuration list sources.
if (mode == "has-list-update-sources")
    exit(getenv("LISTS") == "1" ? 0 : 1);
if (getenv("STARTING") == "1" && (mode == "forkop-running" || mode == "forkop-stably-running"))
    exit(1);
if (mode == "sing-box-service-runtime-pid") {
    print("4242\n");
    exit(0);
}
exit(0);
UC

# The reload plan comes from the test (PLAN: "key=value ...").
cat >"$FAKE_LIB/service/reload.uc" <<UC
$fake_header
if (mode != "plan-state-files")
    exit(0);
for (let item in split(trim(getenv("PLAN") ?? ""), " "))
    if (item != "")
        print(replace(item, "=", "\t"), "\n");
exit(0);
UC

cat >"$FAKE_LIB/subscription/cache.uc" <<UC
$fake_header
exit(mode == "runtime-cache-needs-rebuild" ? 1 : 0);
UC

cat >"$FAKE_LIB/killswitch/runtime.uc" <<UC
$fake_header
ev("killswitch " + join(" ", ARGV));
exit(0);
UC

# LIST_CACHE=missing: no list generation can be applied at start.
cat >"$FAKE_LIB/components/updates.uc" <<UC
$fake_header
ev("components/updates " + mode);
if (getenv("LIST_CACHE") == "missing" && (mode == "runtime-list-cache-active" || mode == "list-cache-valid"))
    exit(1);
exit(0);
UC

for module in service/ui config/validator config/snapshots diagnostics/health diagnostics/runtime singbox/runtime \
  singbox/ruleset_cache nft/apply dns/apply singbox/priority singbox/dns_failover autotune/manager core/packages \
  providers/zapret/runtime providers/zapret2/runtime providers/byedpi/runtime; do
  mkdir -p "$(dirname "$FAKE_LIB/$module.uc")"
  cat >"$FAKE_LIB/$module.uc" <<UC
$fake_header
ev("$module " + mode);
exit(0);
UC
done
chmod +x "$WORK_DIR/bin/"* "$WORK_DIR/reload"

has_event() { grep -q "$1" "$EVENTS" 2>/dev/null; }

reload_with() {
  local plan="$1" reason="$2"
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  env PLAN="$plan" "$WORK_DIR/reload" "$reason" >"$WORK_DIR/reload.out" 2>&1 ||
    fail "the reload ($plan, '$reason') failed: $(cat "$WORK_DIR/reload.out")"
}

# 1. A changed list source: the table is not rebuilt now and the kill-switch
#    is not refreshed from it.
reload_with "has_work=1 needs_nft_rebuild=1 needs_sing_box_reload=1 needs_list_update=1 changed_list=1" ""
! has_event '^nft/apply nft-rebuild-runtime-from-uci$' || fail "the control: a changed list source rebuilt the table now"
! has_event '^killswitch ' || fail "a reload that left the table to the list worker must not refresh the kill-switch"
[ -e "$LISTS_PENDING" ] || fail "the reload must record that the live table lacks the list generation"
grep -q 'Kill-switch refresh deferred' "$WORK_DIR/syslog" || fail "the deferred refresh must be logged"
printf 'ok - a reload with a changed list source does not refresh the kill-switch\n'

# The same without a sing-box change (the list worker's own final reload is
# not under test here).
rm -f "$LISTS_PENDING" "$FORKOP_RUNTIME_STATE_DIR/list-update.reload"
reload_with "has_work=1 needs_nft_rebuild=1 needs_list_update=1 changed_list=1" ""
! has_event '^killswitch ' || fail "a list source change without a sing-box change must not refresh the kill-switch either"
[ -e "$LISTS_PENDING" ] || fail "the list generation must be recorded as pending"

# 2. A reload that rebuilds nothing leaves the record; the kill-switch
#    itself keeps its protection while it is there.
reload_with "has_work=1 needs_dnsmasq_configure=1" ""
[ -e "$LISTS_PENDING" ] || fail "a reload that did not rebuild the table must keep the record"

# 3. The list-content reload rebuilds the table and refreshes the kill-switch.
reload_with "has_work=1 needs_list_update=1 changed_list=1" list-content
has_event '^nft/apply nft-rebuild-runtime-from-uci$' || fail "the list-content reload must rebuild the table"
has_event '^killswitch sync reload list-content reload-lock-held$' || fail "the list-content reload must refresh the kill-switch"
[ ! -e "$LISTS_PENDING" ] || fail "the rebuilt table holds the list generation"
printf 'ok - the list-content reload refreshes the kill-switch\n'

# 4. An ordinary rebuild refreshes it as before.
printf 'reload\n' >"$LISTS_PENDING"
reload_with "has_work=1 needs_nft_rebuild=1" ""
has_event '^killswitch sync reload reload-lock-held$' || fail "a reload that rebuilt the table must refresh the kill-switch"
[ ! -e "$LISTS_PENDING" ] || fail "a table rebuilt from the active list generation is complete"
printf 'ok - a rebuilt table refreshes the kill-switch\n'

# 5. A start without its list generation runs with empty list sets until the
#    list update's list-content reload; one with it holds the generation.
start_with() {
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  env STARTING=1 LISTS=1 LIST_CACHE="$1" FORKOP_LIB="$FAKE_LIB" \
    ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" start >"$WORK_DIR/start.out" 2>&1 ||
    fail "the start ($1) failed: $(cat "$WORK_DIR/start.out")"
  has_event '^nft/apply nft-commit-candidate-batch$\|^nft/apply nft-apply-candidate-batch$' ||
    fail "the start ($1) did not publish its nft table"
}
rm -f "$LISTS_PENDING"
start_with missing
! has_event '^killswitch ' || fail "a start without its list generation must not refresh the kill-switch"
[ -e "$LISTS_PENDING" ] || fail "a start without its list generation must record it as pending"
start_with present
has_event '^killswitch sync start reload-lock-held$' || fail "a start with its list generation must refresh the kill-switch"
[ ! -e "$LISTS_PENDING" ] || fail "a start with its list generation holds it"
printf 'ok - a start records whether its table holds the list generation\n'

[ ! -e "$FORKOP_RELOAD_LOCK_DIR" ] || fail "reload.lock was left behind"
printf 'killswitch_reload_lists: PASS\n'
