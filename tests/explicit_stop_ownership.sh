#!/usr/bin/env bash
set -euo pipefail

# An explicit Stop ends Forkop's interception and stops the sing-box that
# Forkop owns, and no other process (UC-194, UC-213, UC-216, UC-229).
#
# Before (1.0.28, e6c31a4d): an explicit Stop or Restart sent TERM and KILL to
# every process whose executable is named sing-box, a user's own sing-box
# included, after deleting procd's 'sing-box' service, and failed when that
# service was not registered, which it is not after any stop of it. So
# stopping a stopped Forkop failed, a restart of a stopped Forkop never
# reached its start (init.d now exits on a failed stop) and recorded a stop
# by the user, Full uninstall of a stopped Forkop failed at its stop phase,
# and a stray Forkop runtime outside procd was not stopped at all.
#
# Now an explicit Stop removes Forkop's nft table, ip rules and DNS, and
# signals only processes proven to be Forkop's: procd's 'sing-box' instance,
# the process recorded for a managed upgrade, a sing-box that runs Forkop's
# own configuration file. Each signal re-checks the process identity
# (core/process_identity.uc) right before it is sent. An unregistered service
# is a stopped one. Other sing-box processes are reported, not signalled.
#
# init.d, service/initd.uc, service/lifecycle.uc and the sing-box process
# handling of service/state.uc are real, with procd's 'sing-box' service
# modelled by a ubus stand-in; nft, ip, DNS and the other modules the stop
# calls are modelled and record what they are asked to do. A modelled
# state.uc mode that this test does not know fails loudly (UC-229).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The stop must neither see nor signal sing-box processes of the host or of
# tests running in parallel: run in a private PID namespace with its own
# /proc where available; without one, a foreign sing-box is a failed
# precondition.
if [ "${FORKOP_EXPLICIT_STOP_ISOLATED:-}" != 1 ]; then
  if unshare --pid --fork --mount-proc true 2>/dev/null; then
    FORKOP_EXPLICIT_STOP_ISOLATED=1 exec unshare --pid --fork --mount-proc bash "$0" "$@"
  elif unshare --user --map-root-user --pid --fork --mount-proc true 2>/dev/null; then
    FORKOP_EXPLICIT_STOP_ISOLATED=1 exec unshare --user --map-root-user --pid --fork --mount-proc bash "$0" "$@"
  fi
  for exe in /proc/[0-9]*/exe; do
    case "$(readlink "$exe" 2>/dev/null)" in
      */sing-box | */'sing-box (deleted)')
        printf 'FAIL: precondition: a sing-box process (%s) is running and no private PID namespace is available\n' "${exe%/exe}" >&2
        exit 1
        ;;
    esac
  done
fi

REAL_LIB="$ROOT_DIR/forkop/files/usr/lib"
REAL_INITD="$ROOT_DIR/forkop/files/etc/init.d/forkop"
STATE_UC="$REAL_LIB/service/state.uc"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

doubles=()
cleanup() {
  local pid
  for pid in "${doubles[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK_DIR/events"
SYSLOG="$WORK_DIR/syslog"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$EVENTS" ] || sed 's/^/  event: /' "$EVENTS" >&2
  [ ! -s "$SYSLOG" ] || sed 's/^/  syslog: /' "$SYSLOG" >&2
  exit 1
}

LIB="$WORK_DIR/lib"
STATE_DIR="$WORK_DIR/run/forkop"
CONFIG_PATH="$WORK_DIR/etc/sing-box/config.json"
mkdir -p "$WORK_DIR/bin" "$STATE_DIR" "$WORK_DIR/tmp" "$WORK_DIR/singbox-tmp/rulesets" "$WORK_DIR/procd" \
  "$WORK_DIR/ui-state" "$LIB/service" "$LIB/config" "$LIB/singbox" "$LIB/subscription" "$LIB/dns" "$LIB/nft" \
  "$(dirname "$CONFIG_PATH")"
ln -s "$REAL_LIB/core" "$LIB/core"
ln -s "$REAL_LIB/service/lifecycle.uc" "$LIB/service/lifecycle.uc"

cat >"$WORK_DIR/uci.state" <<EOF
forkop.settings=settings
forkop.settings.yacd_secret_key=0123456789abcdef
forkop.settings.dont_touch_dhcp=0
forkop.settings.config_path=$CONFIG_PATH
EOF
: >"$WORK_DIR/forkop.config"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export EVENTS SYSLOG REAL_LIB REAL_INITD LIB
export PROCD="$WORK_DIR/procd"
export NFT_TABLE_FILE="$WORK_DIR/nft.table"
export IP_RULE_FILE="$WORK_DIR/ip.rule"
export FORKOP_LIB="$LIB"
export FORKOP_BIN="$WORK_DIR/bin/forkop"
export FORKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export FORKOP_SERVICE_NAME=forkop
export FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/forkop.reload.lock"
export FORKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$STATE_DIR/subscription-update.lock"
export FORKOP_RUNTIME_STATE_DIR="$STATE_DIR"
export FORKOP_PENDING_RELOAD_FILE="$STATE_DIR/reload.pending"
export FORKOP_LIST_UPDATE_PID_FILE="$STATE_DIR/list-update.pid"
export FORKOP_START_IN_PROGRESS_FILE="$STATE_DIR/start.in-progress"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_CONFIG_FILE="$WORK_DIR/forkop.config"
export FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export FORKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export FORKOP_HISTORY_FILE="$WORK_DIR/history.jsonl"
export FORKOP_UI_STATE_DIR="$WORK_DIR/ui-state"
export FORKOP_UI_SERVICE_ACTION_DIR="$WORK_DIR/ui-state/service-actions"
export FORKOP_UI_SERVICE_ACTION_LOCK_DIR="$WORK_DIR/ui-state/service-actions.lock"
export FORKOP_UI_ACTION_TRACKED=1
export TMP_SING_BOX_FOLDER="$WORK_DIR/singbox-tmp"
export TMP_RULESET_FOLDER="$WORK_DIR/singbox-tmp/rulesets"
export FORKOP_SING_BOX_RELOAD_PID_TIMEOUT=2
export FORKOP_STOP_RUNTIME_LOCK_WAIT_SECONDS=2
STOP_MARKER="$STATE_DIR/stop.requested"
START_RECORD="$STATE_DIR/start.explicit"
MARKER="$FORKOP_MANAGED_UPGRADE_SING_BOX_MARKER"

# Nothing here may reach the host's syslog, firewall, routing or procd.
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSLOG"
SH
cat >"$WORK_DIR/bin/ip" <<'SH'
#!/bin/sh
case "$*" in
  *" rule del "*) printf 'ip %s\n' "$*" >>"$EVENTS"; rm -f "$IP_RULE_FILE" ;;
esac
exit 0
SH
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
[ "$1" != -t ] || shift
if [ "$1 $2 $3" = "list table inet" ]; then
  [ "$4" = ForkopTable ] && [ -e "$NFT_TABLE_FILE" ]
  exit $?
fi
if [ "$1 $2 $3" = "delete table inet" ]; then
  printf 'nft %s\n' "$*" >>"$EVENTS"
  rm -f "$NFT_TABLE_FILE"
fi
exit 0
SH
# procd's 'sing-box' service: registered while $PROCD/registered exists,
# which names its running instance. Like procd, `service list` with a name
# answers {} for a service it does not know, and `service delete` of one
# fails with NOT_FOUND; deleting a registered service stops its instance.
cat >"$WORK_DIR/bin/ubus" <<'SH'
#!/bin/sh
printf 'ubus %s\n' "$*" >>"$EVENTS"
[ "$1 $2" = "call service" ] || exit 1
case "$3" in
  list)
    if [ ! -f "$PROCD/registered" ]; then
      printf '{}\n'
    else
      pid="$(cat "$PROCD/registered")"
      if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        printf '{"sing-box":{"instances":{"instance1":{"running":true,"pid":%s}}}}\n' "$pid"
      else
        printf '{"sing-box":{"instances":{}}}\n'
      fi
    fi
    exit 0
    ;;
  delete)
    if [ -f "$PROCD/registered" ]; then
      pid="$(cat "$PROCD/registered")"
      rm -f "$PROCD/registered"
      [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null
      exit 0
    fi
    echo 'Command failed: Not found' >&2
    exit 4
    ;;
esac
exit 1
SH
cat >"$WORK_DIR/bin/init" <<'SH'
#!/bin/sh
printf 'init %s\n' "$*" >>"$EVENTS"
exit 0
SH
cat >"$WORK_DIR/bin/forkop" <<'SH'
#!/bin/sh
case "$1" in
  stop)
    ucode -L "$LIB" "$LIB/service/lifecycle.uc" stop >>"$EVENTS" 2>&1
    rc=$?
    printf 'forkop stop exit=%s\n' "$rc" >>"$EVENTS"
    exit "$rc"
    ;;
  get_status) printf '{"running":0}\n' ;;
esac
exit 0
SH

fake_header='let fs = require("fs");
function q(value) { return "'"'"'" + replace("" + value, /'"'"'/g, "'"'"'\\'"'"''"'"'") + "'"'"'"; }
function ev(line) { system("printf '"'"'%s\\n'"'"' " + q(line) + " >> " + q(getenv("EVENTS"))); }
let mode = "" + (ARGV[0] ?? "");
'
# service/state.uc: locks, the stop request and everything about sing-box
# processes and the upgrade marker are the real module's; the reload state
# is recorded. Any other mode is a mode this test does not model: it fails
# instead of passing silently.
cat >"$LIB/service/state.uc" <<UC
$fake_header
if (index(mode, "runtime-dir-lock") >= 0 || mode == "runtime-apply-allowed" || mode == "stop-requested" ||
    index(mode, "sing-box") >= 0 || index(mode, "managed-upgrade") >= 0) {
    let command = "ucode -L " + q(getenv("REAL_LIB")) + " " + q(getenv("REAL_LIB") + "/service/state.uc");
    for (let arg in ARGV)
        command += " " + q(arg);
    let status = system(command);
    if (index(mode, "stop") >= 0 && index(mode, "sing-box") >= 0)
        ev("state " + mode + " -> " + status);
    exit(status);
}
if (mode == "clear-reload-state") {
    ev("state " + mode);
    exit(0);
}
ev("unmodelled state mode " + mode);
exit(97);
UC
cat >"$LIB/dns/apply.uc" <<UC
$fake_header
ev("dns " + mode);
exit(0);
UC
# The fwmark rule at priority 105 is present while \$IP_RULE_FILE exists.
cat >"$LIB/nft/apply.uc" <<UC
$fake_header
if (mode == "tproxy-marking-rule4-present")
    exit(fs.stat(getenv("IP_RULE_FILE")) != null ? 0 : 1);
exit(mode == "remove-dpi-transition-guard" ? 0 : 1);
UC
mkdir -p "$LIB/components" "$LIB/autotune" "$LIB/providers/zapret" "$LIB/providers/zapret2" "$LIB/providers/byedpi"
for module in config/validator service/reload subscription/cache singbox/priority singbox/dns_failover \
  components/updates autotune/manager providers/zapret/runtime providers/zapret2/runtime providers/byedpi/runtime; do
  printf '%s\nexit(mode == "runtime-list-cache-active" ? 1 : 0);\n' "$fake_header" >"$LIB/$module.uc"
done

# /etc/init.d/forkop as rc.common runs it: stop() is stop_service and then
# procd_kill; restart() is stop() and then start().
cat >"$WORK_DIR/rc" <<'SH'
#!/usr/bin/env bash
action="$1"
shift
initscript="$REAL_INITD"
# shellcheck disable=SC1090
. "$REAL_INITD"
FORKOP_LIB="$LIB"
FORKOP_INITD_UC="$REAL_LIB/service/initd.uc"
case "$action" in
  stop)
    stop_service "$@"
    echo 'procd_kill forkop' >>"$EVENTS"
    ;;
  restart)
    stop_service "$@"
    echo 'procd_kill forkop' >>"$EVENTS"
    echo 'start reached' >>"$EVENTS"
    ;;
  disable) ;;
  *) exit 64 ;;
esac
SH
chmod +x "$WORK_DIR/bin/"* "$WORK_DIR/rc"

# sing-box doubles. A copy of sleep, for a process whose command line does
# not matter (procd's instance is known by its PID). A copy of bash named
# sing-box, for one with a sing-box command line: `sing-box run -c <config>`
# runs the script ./run, which blocks on a FIFO without a child process, and
# ignores TERM when IGNORE_TERM=1.
mkdir -p "$WORK_DIR/procd-bin" "$WORK_DIR/stray-bin" "$WORK_DIR/foreign-bin" "$WORK_DIR/doubles"
cp "$(command -v sleep)" "$WORK_DIR/procd-bin/sing-box"
cp "$(command -v bash)" "$WORK_DIR/stray-bin/sing-box"
cp "$(command -v bash)" "$WORK_DIR/foreign-bin/sing-box"
mkfifo "$WORK_DIR/doubles/block"
cat >"$WORK_DIR/doubles/run" <<'SH'
[ "${IGNORE_TERM:-}" != 1 ] || trap '' TERM
read -r _ <"$BLOCK_FIFO"
SH
export BLOCK_FIFO="$WORK_DIR/doubles/block"

LAST_DOUBLE=''
start_double() { # start_double <sing-box binary> [arguments...]
  (cd "$WORK_DIR/doubles" && exec "$@") &
  LAST_DOUBLE=$!
  # The stop kills doubles: no job notices for them.
  disown "$LAST_DOUBLE"
  doubles+=("$LAST_DOUBLE")
  wait_until 10 process_exec_is "$LAST_DOUBLE" sing-box || fail "a sing-box double did not start"
}
term_ignored() { # SigIgn of /proc/<pid>/status has bit 15 (TERM)
  local mask
  mask="$(sed -n 's/^SigIgn:[[:space:]]*//p' "/proc/$1/status" 2>/dev/null)"
  [ -n "$mask" ] && [ $((0x$mask & 0x4000)) -ne 0 ]
}
procd_instance() { # Forkop's runtime: procd's 'sing-box' instance
  start_double "$WORK_DIR/procd-bin/sing-box" 300
  printf '%s\n' "$LAST_DOUBLE" >"$PROCD/registered"
}
foreign_sing_box() { # another program's sing-box, e.g. HomeProxy's
  start_double "$WORK_DIR/foreign-bin/sing-box" run -c "$WORK_DIR/homeproxy/config.json"
}
stray_runtime() { # Forkop's own configuration, outside procd [ignore TERM]
  IGNORE_TERM="${1:-}" start_double "$WORK_DIR/stray-bin/sing-box" run -c "$CONFIG_PATH" -D /usr/share/sing-box
}
alive() { process_running "$1"; }
gone() { process_gone "$1"; }
has_event() { grep -q -- "$1" "$EVENTS" 2>/dev/null; }
no_event() { ! grep -q -- "$1" "$EVENTS" 2>/dev/null; }

runtime_up() { # Forkop's interception: its nft table and its ip rule
  printf 'ForkopTable\n' >"$NFT_TABLE_FILE"
  printf '105\n' >"$IP_RULE_FILE"
}

reset_case() {
  local pid
  for pid in "${doubles[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
    wait_until 10 process_gone "$pid" || fail "a sing-box double of the previous case did not exit"
  done
  doubles=()
  : >"$EVENTS"
  : >"$SYSLOG"
  rm -f "$PROCD/registered" "$NFT_TABLE_FILE" "$IP_RULE_FILE" "$STOP_MARKER" "$START_RECORD" "$MARKER"
  printf 'explicit\n' >"$START_RECORD"
  [ ! -e "$FORKOP_RELOAD_LOCK_DIR" ] || fail "reload.lock leaked from the previous case"
}

rc() { # rc <action> [FORKOP_STOP_SOURCE]: status of /etc/init.d/forkop <action>
  local rc=0
  env ${2:+FORKOP_STOP_SOURCE="$2"} bash "$WORK_DIR/rc" "$1" >>"$EVENTS" 2>&1 || rc=$?
  no_event '^unmodelled state mode' || fail "the stop asked service/state.uc for a mode this test does not model"
  printf '%s\n' "$rc"
}

# 1. Forkop is stopped: nothing runs and procd knows no 'sing-box' service.
#    Stopping it again succeeds, and a restart reaches its start.
reset_case
[ "$(rc stop)" = 0 ] || fail "stopping a stopped Forkop failed"
no_event 'dns failsafe-restore' || fail "stopping a stopped Forkop applied the DNS failsafe"
reset_case
[ "$(rc restart)" = 0 ] || fail "a restart of a stopped Forkop failed in its stop"
has_event '^start reached$' || fail "a restart of a stopped Forkop did not reach its start"

# 2. Forkop's procd instance and another program's sing-box: Forkop's
#    interception and runtime go, the other sing-box stays and is reported.
reset_case
runtime_up
procd_instance
forkop_pid=$LAST_DOUBLE
foreign_sing_box
foreign_pid=$LAST_DOUBLE
[ "$(rc stop)" = 0 ] || fail "an explicit stop next to another program's sing-box failed"
wait_until 10 gone "$forkop_pid" || fail "an explicit stop left Forkop's procd-owned sing-box running"
alive "$foreign_pid" || fail "an explicit stop signalled a sing-box that Forkop does not own"
[ ! -e "$NFT_TABLE_FILE" ] || fail "an explicit stop left ForkopTable"
[ ! -e "$IP_RULE_FILE" ] || fail "an explicit stop left the ip rule at priority 105"
has_event '^dns restore' || fail "an explicit stop did not restore DNS"
grep -q "pid=$foreign_pid" "$SYSLOG" || fail "the sing-box left running is not reported with its pid"
grep -q "$WORK_DIR/homeproxy/config.json" "$SYSLOG" || fail "the sing-box left running is not reported with its command line"

# 3. A stray Forkop runtime outside procd (no service registered) that
#    ignores TERM: it runs Forkop's configuration, so it is Forkop's and an
#    explicit stop ends it, escalating to KILL. Another program's sing-box
#    stays.
reset_case
runtime_up
stray_runtime 1
stray_pid=$LAST_DOUBLE
wait_until 10 term_ignored "$stray_pid" || fail "the stray double does not ignore TERM"
foreign_sing_box
foreign_pid=$LAST_DOUBLE
[ "$(rc stop)" = 0 ] || fail "an explicit stop of a stray Forkop runtime failed"
gone "$stray_pid" || fail "an explicit stop left a stray sing-box that runs Forkop's configuration"
alive "$foreign_pid" || fail "an explicit stop signalled a sing-box that Forkop does not own"
[ ! -e "$NFT_TABLE_FILE" ] || fail "an explicit stop left ForkopTable next to a stray runtime"

# 4. Full uninstall of a stopped Forkop passes its stop phase.
reset_case
UNINSTALL_ROOT="$WORK_DIR/uninstall-root"
mkdir -p "$UNINSTALL_ROOT/etc/init.d" "$UNINSTALL_ROOT/usr/bin" "$UNINSTALL_ROOT/bin"
printf '#!/bin/sh\nexec bash %q "$@"\n' "$WORK_DIR/rc" >"$UNINSTALL_ROOT/etc/init.d/forkop"
printf '#!/bin/sh\nexit 0\n' >"$UNINSTALL_ROOT/usr/bin/forkop"
cat >"$UNINSTALL_ROOT/bin/opkg" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$UNINSTALL_ROOT/etc/init.d/forkop" "$UNINSTALL_ROOT/usr/bin/forkop" "$UNINSTALL_ROOT/bin/opkg"
FORKOP_UNINSTALL_ROOT="$UNINSTALL_ROOT" FORKOP_MIRROR_BASE_URL=https://mirror.invalid PATH="$UNINSTALL_ROOT/bin:$PATH" \
  sh "$REAL_LIB/full-uninstall.sh" start >"$WORK_DIR/uninstall.response" ||
  fail "full uninstall did not start: $(cat "$WORK_DIR/uninstall.response")"
uninstall_finished() {
  grep -qE '"state":"(complete|failed)"' "$UNINSTALL_ROOT"/www/forkop-uninstall.*.json 2>/dev/null
}
wait_until 30 uninstall_finished || fail "full uninstall did not finish"
grep -q '"state":"complete"' "$UNINSTALL_ROOT"/www/forkop-uninstall.*.json ||
  fail "full uninstall of a stopped Forkop failed: $(cat "$UNINSTALL_ROOT"/www/forkop-uninstall.*.json)"

# 5. Stop stays offered while Forkop owns a sing-box, not for another
#    program's (service/ui.uc stop_available).
ui_stop_available() {
  env FORKOP_LIB="$REAL_LIB" FORKOP_UI_SING_BOX_BIN_PATH="$WORK_DIR/missing-sing-box" \
    FORKOP_UI_SING_BOX_VARIANT_STATE_FILE="$WORK_DIR/missing-variant" \
    FORKOP_UI_LATENCY_ACTION_DIR="$WORK_DIR/ui-state/latency-actions" \
    FORKOP_UI_COMPONENT_ACTION_DIR="$WORK_DIR/ui-state/component-actions" \
    FORKOP_UI_SUBSCRIPTION_ACTION_DIR="$WORK_DIR/ui-state/subscription-actions" \
    ZAPRET_PROVIDER_NFQWS_BIN="$WORK_DIR/missing-nfqws" ZAPRET2_PROVIDER_NFQWS2_BIN="$WORK_DIR/missing-nfqws2" \
    BYEDPI_BIN="$WORK_DIR/missing-ciadpi" \
    ucode -L "$REAL_LIB" "$REAL_LIB/service/ui.uc" get-ui-state >"$WORK_DIR/ui.json" ||
    fail "ui.uc get-ui-state failed"
  ucode -e 'print(json(require("fs").readfile(ARGV[0])).service.forkop.stop_available, "\n");' "$WORK_DIR/ui.json"
}
reset_case
foreign_sing_box
[ "$(ui_stop_available)" = 0 ] || fail "Stop is offered for another program's sing-box: $(cat "$WORK_DIR/ui.json")"
stray_runtime
[ "$(ui_stop_available)" = 1 ] || fail "Stop is not offered for a stray Forkop runtime: $(cat "$WORK_DIR/ui.json")"

# Each signal of the explicit stop goes through the identity re-check of
# core/process_identity.uc, never through a bare kill of a PID (UC-216).
region="$(source_function "$STATE_UC" stop_owned_sing_box_and_wait)" || exit 1
source_refute_text "the explicit stop must signal only through process_identity.signal_record" \
  -E '(^|[^a-z_.])kill([^a-z_]|$)' "$region"
grep -q 'process_identity.signal_record(' <<<"$region" ||
  fail "the explicit stop does not re-check each process identity before it signals"

printf 'explicit stop ownership checks passed\n'
