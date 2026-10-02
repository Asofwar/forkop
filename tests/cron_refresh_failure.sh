#!/usr/bin/env bash
set -euo pipefail

# A cron refresh that fails does not take the proxy down (S5 integration,
# UC-159).
#
# Since the crontab is read back after `crontab` (cddbba56), a nearly full
# overlay or a change another writer made at the same moment fails the
# refresh of Forkop's scheduled jobs. Start and reload aborted at phase
# cron-refresh then: the start left Forkop down and the reload rolled back,
# because the scheduled-jobs file could not be written. Now both carry on,
# and the failure is not masked: an error in the system log and a
# cron_refresh failure in the history (diagnostics/health.uc).
#
# The real service/lifecycle.uc start and reload; every module they call is
# a double that records its call (as tests/shutdown_state_runtime.sh and
# tests/dnsmasq_reload_rollback.sh do).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

FAKE_LIB="$WORK_DIR/fake-lib"
no_fake_modules() { ! pgrep -f "$FAKE_LIB/" >/dev/null 2>&1; }
cleanup() {
  # The lifecycle leaves its background workers (doubles) running briefly.
  wait_until 20 no_fake_modules || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK_DIR/events"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  for log in "$EVENTS" "$WORK_DIR/syslog" "$WORK_DIR/lifecycle.out"; do
    [ ! -s "$log" ] || sed "s|^|  $(basename "$log"): |" "$log" >&2
  done
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }

STATE_DIR="$WORK_DIR/run/forkop"
mkdir -p "$WORK_DIR/bin" "$STATE_DIR" "$WORK_DIR/tmp" "$FAKE_LIB"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR" EVENTS TEST_LIB="$LIB"
export FORKOP_RUNTIME_STATE_DIR="$STATE_DIR"
export FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/forkop.reload.lock"
export FORKOP_PENDING_RELOAD_FILE="$STATE_DIR/reload.pending"
export FORKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$STATE_DIR/subscription-update.lock"
export FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export FORKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export FORKOP_CONFIG_FILE="$WORK_DIR/forkop.config"
export FORKOP_DNSMASQ_CONFIG_FILE="$WORK_DIR/dhcp.config"
export FORKOP_BIN="$WORK_DIR/bin/forkop"
export FORKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export FORKOP_UI_ACTION_TRACKED=1
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_UCI_LOG_FILE="$WORK_DIR/uci.log"
export TMP_SING_BOX_FOLDER="$WORK_DIR/singbox-tmp"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export KILLSWITCH_STATE_DIR="$WORK_DIR/killswitch"
export FORKOP_CONFIG_NAME=forkop
export SB_DNS_INBOUND_ADDRESS=127.0.0.42

# Nothing here may reach the host's syslog, nftables, dnsmasq or init scripts.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TEST_WORK/syslog"\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/init"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/forkop"
printf '#!/bin/sh\nexit 0\n' >"$DNSMASQ_INIT"
chmod 0755 "$WORK_DIR"/bin/*
printf 'config dnsmasq\n' >"$FORKOP_DNSMASQ_CONFIG_FILE"
: >"$FORKOP_CONFIG_FILE"
printf 'forkop.settings=settings\nforkop.settings.yacd_secret_key=0123456789abcdef\nforkop.settings.dont_touch_dhcp=1\n' \
  >"$FORKOP_UCI_STATE_FILE"

# Every module call: records "<module> <arguments>" and succeeds, except as
# below. Locks and the stop request go to the real service/state.uc. The
# cron refresh fails while CRON_FAILS is 1; the runtime runs while RUNNING
# is 1 (a reload), not yet otherwise (a start). The reload plan comes from
# PLAN ("key=value ...").
fake_module() {
  mkdir -p "$(dirname "$FAKE_LIB/$1")"
  cat >"$FAKE_LIB/$1" <<UC
function q(value) { return "'" + replace("" + value, /'/g, "'\\\\''") + "'"; }
let mode = "" + (ARGV[0] ?? "");
let name = "$1";
if (name == "service/state.uc" && (index(mode, "runtime-dir-lock") >= 0 || mode == "runtime-apply-allowed" ||
    mode == "stop-requested")) {
    let command = "ucode -L " + q(getenv("TEST_LIB")) + " " + q(getenv("TEST_LIB") + "/service/state.uc");
    for (let arg in ARGV)
        command += " " + q(arg);
    exit(system(command));
}
system("printf '%s\\\\n' " + q(name + " " + join(" ", ARGV)) + " >> " + q(getenv("EVENTS")));
let running = getenv("RUNNING") == "1";
if (name == "service/state.uc" && (mode == "has-list-update-sources" || mode == "has-nft-list-update-sources" ||
    mode == "sing-box-process-conflict"))
    exit(1);
if (name == "service/state.uc" && (mode == "forkop-stably-running" || mode == "forkop-running"))
    exit(running ? 0 : 1);
if (name == "service/state.uc" && mode == "sing-box-service-runtime-pid") {
    print("4242\\n");
    exit(0);
}
if (name == "service/reload.uc" && mode == "plan-state-files") {
    for (let item in split(trim(getenv("PLAN") ?? ""), " "))
        if (item != "")
            print(replace(item, "=", "\\t"), "\\n");
    exit(0);
}
if (name == "components/updates.uc" && mode == "refresh-cron-from-uci")
    exit(getenv("CRON_FAILS") == "1" ? 1 : 0);
exit(mode == "runtime-cache-needs-rebuild" ? 1 : 0);
UC
}
for module in service/state.uc subscription/cache.uc config/validator.uc nft/apply.uc singbox/runtime.uc \
  singbox/priority.uc singbox/dns_failover.uc singbox/ruleset_cache.uc components/updates.uc \
  autotune/manager.uc providers/byedpi/runtime.uc providers/zapret/runtime.uc providers/zapret2/runtime.uc \
  dns/apply.uc diagnostics/runtime.uc diagnostics/health.uc config/snapshots.uc core/packages.uc \
  service/ui.uc service/reload.uc service/lifecycle.uc killswitch/runtime.uc; do
  fake_module "$module"
done

has_event() { grep -Fq -- "$1" "$EVENTS"; }
cron_failure_reported() {
  has_event 'components/updates.uc refresh-cron-from-uci' || fail "$1: the cron refresh did not run"
  grep -F '[error]' "$WORK_DIR/syslog" | grep -Fiq 'scheduled jobs' ||
    fail "$1: the failed cron refresh was not logged as an error"
  has_event 'diagnostics/health.uc record cron_refresh failure' ||
    fail "$1: the failed cron refresh was not recorded in the history"
}

# ---- start ---------------------------------------------------------------------

start() {
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  STATUS=0
  env FORKOP_LIB="$FAKE_LIB" RUNNING=0 ucode -L "$LIB" "$LIB/service/lifecycle.uc" start >"$WORK_DIR/lifecycle.out" 2>&1 ||
    STATUS=$?
  wait_until 20 no_fake_modules || fail "the background workers of the start did not finish"
}

CRON_FAILS=0 start
[ "$STATUS" = 0 ] || fail "the control start failed (status $STATUS)"
has_event 'service/state.uc start-managed-sing-box-runtime' || fail "the control start did not start sing-box"
has_event 'record cron_refresh' && fail "a start whose cron refresh succeeded recorded a cron_refresh event"

export CRON_FAILS=1
start
[ "$STATUS" = 0 ] || fail "a start whose cron refresh failed did not bring Forkop up (status $STATUS)"
has_event 'service/state.uc start-managed-sing-box-runtime' || fail "a start whose cron refresh failed did not start sing-box"
grep -q "phase 'cron-refresh' failed" "$WORK_DIR/syslog" && fail "the start still failed at phase cron-refresh"
cron_failure_reported "the start"
has_event 'diagnostics/health.uc record start success' || fail "the start was not recorded as a success"
ok "a start whose cron refresh failed brings Forkop up and reports the failed refresh"

# ---- reload --------------------------------------------------------------------

# The reload under reload.lock, as init.d runs it.
cat >"$WORK_DIR/reload" <<'SH'
#!/bin/sh
state() { ucode -L "$TEST_LIB" "$TEST_LIB/service/state.uc" "$@"; }
state acquire-runtime-dir-lock "$FORKOP_RELOAD_LOCK_DIR" "$$" || exit 99
env FORKOP_LIB="$FAKE_LIB" RUNNING=1 ucode -L "$TEST_LIB" "$TEST_LIB/service/lifecycle.uc" reload ""
status=$?
state release-runtime-dir-lock "$FORKOP_RELOAD_LOCK_DIR" "$$"
exit "$status"
SH
chmod 0755 "$WORK_DIR/reload"
export FAKE_LIB
reload() {
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  STATUS=0
  env PLAN="has_work=1 changed_cron=1 needs_cron_refresh=1" "$WORK_DIR/reload" >"$WORK_DIR/lifecycle.out" 2>&1 ||
    STATUS=$?
  wait_until 20 no_fake_modules || fail "the background workers of the reload did not finish"
}

CRON_FAILS=0 reload
[ "$STATUS" = 0 ] || fail "the control reload failed (status $STATUS)"
has_event 'service/state.uc write-captured-reload-state' || fail "the control reload did not record its state"

reload
[ "$STATUS" = 0 ] || fail "a reload whose cron refresh failed was rolled back (status $STATUS)"
has_event 'service/state.uc write-captured-reload-state' ||
  fail "a reload whose cron refresh failed did not record the applied state"
cron_failure_reported "the reload"
has_event 'diagnostics/health.uc record reload success' || fail "the reload was not recorded as a success"
ok "a reload whose cron refresh failed completes and reports the failed refresh"

printf 'cron refresh failure checks passed\n'
