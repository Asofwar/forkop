#!/usr/bin/env bash
set -euo pipefail

# A removal judges Forkop's stop by what it left, not by its exit status, and
# never reports success with something of Forkop in place (UC-028).
#
# Before: prerm checked Forkop's interception only when the stop exited
# non-zero. A stop that exited 0 and still left ForkopTable or the fwmark rule
# at priority 105 (rc.common drops the status of stop_service unless a hook
# passes it on; a stop that cannot delete the table or the rule goes on) let
# a removal stop and delete the managed sing-box that served it: the
# interception black-holed traffic until a reboot. Forkop's lines in the
# crontab, the kill-switch and the TorrServer Direct table were never
# checked: a removal that left them reported success.
#
# Now a removal whose package stop left Forkop's interception or its
# scheduled jobs in place stops Forkop again with the explicit stop (no proof
# of ownership needed for its own interception, UC-213), and the managed
# sing-box keeps serving an interception that is still in place. At the end
# a removal checks again, with the kill-switch table and its saved policy and
# the TorrServer Direct table: prerm fails, and the system log (the package
# managers discard prerm's output) says what is left. An upgrade is
# unchanged: a failed stop keeps the runtime (UC-197,
# tests/package_prerm_refused_stop.sh), and the start in postinst brings it
# back after a stop that succeeded.
#
# The real service/package.uc runs against an init.d, nft, ip, logger, a
# crontab and the kill-switch module that record what they are asked to do.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
PACKAGE_UC="$LIB/service/package.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK_DIR/events"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$EVENTS" ] || sed 's/^/  event: /' "$EVENTS" >&2
  exit 1
}

STATE="$WORK_DIR/state"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$STATE/nft"
export PATH="$WORK_DIR/bin:$PATH"
export EVENTS STATE
export FORKOP_LIB="$LIB"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_INIT="$WORK_DIR/forkop-init"
export FORKOP_TORRSERVER_DIRECT_INIT="$WORK_DIR/missing-torrserver-init"
export FORKOP_RC_D_DIR="$WORK_DIR/rc.d"
export FORKOP_BIN="$WORK_DIR/bin/forkop"
export FORKOP_DNS_APPLY_UC="$WORK_DIR/dns-apply.uc"
export FORKOP_KILLSWITCH_UC="$WORK_DIR/killswitch.uc"
export FORKOP_SING_BOX_INIT="$WORK_DIR/sing-box-init"
export FORKOP_SING_BOX_BIN="$WORK_DIR/sing-box"
export FORKOP_SING_BOX_CRONET="$WORK_DIR/libcronet.so"
export FORKOP_RT_TABLES="$WORK_DIR/rt_tables"
export FORKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/package-was-running"
export FORKOP_CRONTAB_FILE="$WORK_DIR/crontab"
export KILLSWITCH_NFT_POLICY="$WORK_DIR/killswitch-policy.nft"
printf 'forkop.settings=settings\nforkop.settings.dont_touch_dhcp=0\n' >"$FORKOP_UCI_STATE_FILE"

FORKOP_CRON='0 */6 * * * /usr/bin/forkop list_update_if_due # forkop-list-update'
FOREIGN_CRON='0 3 * * * /usr/bin/backup # mine'

# /etc/init.d/forkop: "status" reports a running Forkop. A stop exits 0 and
# takes down Forkop's interception (table, rule) and its scheduled jobs,
# except what $STATE/<source>-leaves names; <source> is "package" for
# Forkop's own stop for the package change and "explicit" otherwise.
cat >"$FORKOP_INIT" <<'SH'
#!/bin/sh
case "$1" in
  status) exit 0 ;;
  stop)
    source=explicit
    [ "${FORKOP_STOP_SOURCE:-}" != package ] || source=package
    printf 'forkop stop %s\n' "$source" >>"$EVENTS"
    leaves="$(cat "$STATE/$source-leaves" 2>/dev/null || true)"
    case "$leaves" in *table*) ;; *) rm -f "$STATE/nft/ForkopTable" ;; esac
    case "$leaves" in *rule*) ;; *) rm -f "$STATE/rule" ;; esac
    case "$leaves" in *cron*) ;; *)
      grep -v '# forkop-' "$FORKOP_CRONTAB_FILE" >"$STATE/cron.new" || true
      mv "$STATE/cron.new" "$FORKOP_CRONTAB_FILE" ;;
    esac
    ;;
esac
exit 0
SH
cat >"$FORKOP_BIN" <<'SH'
#!/bin/sh
printf 'forkop %s\n' "$*" >>"$EVENTS"
SH
cat >"$FORKOP_DNS_APPLY_UC" <<'UC'
system("printf 'dns %s\\n' '" + ARGV[0] + "' >>'" + getenv("EVENTS") + "'");
UC
# The kill-switch release lifts the table and the saved policy unless
# $STATE/killswitch-stays exists.
cat >"$FORKOP_KILLSWITCH_UC" <<'UC'
let fs = require("fs");
system("printf 'killswitch %s\\n' '" + join(" ", ARGV) + "' >>'" + getenv("EVENTS") + "'");
if (ARGV[0] == "release" && fs.stat(getenv("STATE") + "/killswitch-stays") == null) {
    fs.unlink(getenv("STATE") + "/nft/ForkopKillswitch");
    fs.unlink(getenv("KILLSWITCH_NFT_POLICY"));
}
UC
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf 'logger %s\n' "$*" >>"$EVENTS"
SH
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
[ "$1" != -t ] || shift
case "$1 $2 $3" in
  "list table inet") [ -e "$STATE/nft/$4" ]; exit $? ;;
esac
exit 1
SH
cat >"$WORK_DIR/bin/ip" <<'SH'
#!/bin/sh
case "$*" in
  "-4 rule show")
    printf '0:\tfrom all lookup local\n'
    [ ! -e "$STATE/rule" ] || printf '105:\tfrom all fwmark 0x4000000/0x4000000 lookup forkop\n'
    printf '32766:\tfrom all lookup main\n'
    ;;
esac
exit 0
SH
chmod +x "$FORKOP_INIT" "$FORKOP_BIN" "$WORK_DIR/bin/"*
command -v apk >/dev/null 2>&1 && fail "the host has apk on PATH; the cases need opkg's behaviour"

# A running Forkop: its table and rule, its scheduled jobs next to another
# program's, the kill-switch with its saved policy, the TorrServer Direct
# table and the managed sing-box.
reset_case() {
  : >"$EVENTS"
  rm -f "$STATE"/*-leaves "$STATE/killswitch-stays" "$FORKOP_PACKAGE_UPGRADE_STATE"
  touch "$STATE/nft/ForkopTable" "$STATE/rule" "$STATE/nft/ForkopKillswitch" "$KILLSWITCH_NFT_POLICY"
  rm -f "$STATE/nft/ForkopTorrServerDirect"
  printf '%s\n%s\n' "$FOREIGN_CRON" "$FORKOP_CRON" >"$FORKOP_CRONTAB_FILE"
  printf '100 main\n105 forkop\n' >"$FORKOP_RT_TABLES"
  cat >"$FORKOP_SING_BOX_INIT" <<'SH'
#!/bin/sh
# Forkop managed sing-box service for binary variants
printf 'sing-box init %s\n' "$1" >>"$EVENTS"
SH
  chmod +x "$FORKOP_SING_BOX_INIT"
  : >"$FORKOP_SING_BOX_BIN"
  : >"$FORKOP_SING_BOX_CRONET"
}
prerm() { # prerm <action> [new version]: status of service/package.uc prerm
  local rc=0
  ucode -L "$LIB" "$PACKAGE_UC" prerm "$@" >>"$EVENTS" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}
called() { grep -Fqx "$1" "$EVENTS"; }
line_of() { grep -Fnx "$1" "$EVENTS" | head -1 | cut -d: -f1; }
left_logged() { # left_logged <case> <item>...
  local case_name="$1" item
  shift
  for item in "$@"; do
    grep -q "^logger -t forkop \\[warn\\] Forkop's removal left in place: .*$item" "$EVENTS" ||
      fail "$case_name: the system log does not say that $item is left"
  done
}
nothing_left_logged() {
  ! grep -q "removal left in place" "$EVENTS" || fail "$1: the system log names something left after a clean removal"
}

# 1. Removal: the package stop exited 0 but left the interception. The
#    explicit stop takes it down before the managed sing-box goes.
reset_case
printf 'table rule\n' >"$STATE/package-leaves"
[ "$(prerm remove)" = 0 ] || fail "prerm failed although the explicit stop took Forkop down"
called 'forkop stop explicit' || fail "a removal did not stop Forkop again when its stop left the interception"
[ "$(line_of 'forkop stop explicit')" -lt "$(line_of 'sing-box init stop')" ] ||
  fail "the managed sing-box was stopped before the interception it serves was taken down"
if [ -e "$STATE/nft/ForkopTable" ] || [ -e "$STATE/rule" ]; then fail "the interception survived the removal"; fi
nothing_left_logged "stop left the interception"

# 2. Removal: both stops exited 0 and left the table and the rule. The
#    managed sing-box keeps serving them until a reboot, and prerm says so.
reset_case
printf 'table rule\n' >"$STATE/package-leaves"
printf 'table rule\n' >"$STATE/explicit-leaves"
[ "$(prerm remove)" != 0 ] || fail "prerm reported success although the interception survived the removal"
! called 'sing-box init stop' || fail "the removal stopped the sing-box that still serves the interception"
left_logged "interception left" 'nft table inet ForkopTable' 'IPv4 rule 105'

# 3. Removal: Forkop's scheduled jobs stayed in the crontab. The explicit
#    stop tries again; what still stays is reported. Another program's jobs
#    are not touched.
reset_case
printf 'cron\n' >"$STATE/package-leaves"
[ "$(prerm remove)" = 0 ] || fail "prerm failed although the explicit stop removed the scheduled jobs"
called 'forkop stop explicit' || fail "a removal did not stop Forkop again when its stop left the scheduled jobs"
reset_case
printf 'cron\n' >"$STATE/package-leaves"
printf 'cron\n' >"$STATE/explicit-leaves"
[ "$(prerm remove)" != 0 ] || fail "prerm reported success with Forkop's scheduled jobs in the crontab"
left_logged "scheduled jobs left" "scheduled jobs in $FORKOP_CRONTAB_FILE"
grep -Fqx "$FOREIGN_CRON" "$FORKOP_CRONTAB_FILE" || fail "another program's scheduled job was removed"

# 4. Removal: the kill-switch could not be lifted, and the TorrServer Direct
#    table is still there.
reset_case
: >"$STATE/killswitch-stays"
touch "$STATE/nft/ForkopTorrServerDirect"
[ "$(prerm remove)" != 0 ] || fail "prerm reported success with the kill-switch in place"
called 'killswitch release package removal' || fail "a removal did not release the kill-switch"
left_logged "kill-switch left" 'nft table inet ForkopKillswitch' "saved kill-switch policy $KILLSWITCH_NFT_POLICY" \
  'nft table inet ForkopTorrServerDirect'

# 5. A clean removal reports success and nothing left.
reset_case
[ "$(prerm remove)" = 0 ] || fail "a clean removal failed"
! called 'forkop stop explicit' || fail "a clean removal stopped Forkop twice"
called 'sing-box init stop' || fail "a clean removal did not stop the managed sing-box"
nothing_left_logged "clean removal"

printf 'package removal leftover checks passed\n'
