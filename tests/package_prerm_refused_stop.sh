#!/usr/bin/env bash
set -euo pipefail

# A package stop that does not take Forkop down leaves its interception with
# the runtime that still serves it (UC-197; the upgrade variant of UC-028).
#
# Before: service/package.uc prerm ignored the status of Forkop's own stop.
# When the stop was refused (another sing-box made ownership ambiguous, so
# nothing was torn down) it went on to restore dnsmasq, stop, disable and
# delete the managed sing-box and remove the "105 forkop" routing table name:
# ForkopTable and the fwmark rule at priority 105 stayed with no listener and
# black-holed proxied traffic until someone cleaned up by hand.
#
# Now prerm fails closed when the stop failed and Forkop's interception (its
# nft table or its ip rule) is still in place: it keeps DNS, the managed
# sing-box and the routing table name, and reports the failure. A failed stop
# with no interception left, and a stop that succeeded, clean up as before.
#
# The real service/package.uc runs against an init.d, a managed sing-box
# init script, nft and ip that record what they are asked to do.

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

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run"
export PATH="$WORK_DIR/bin:$PATH"
export EVENTS
export NFT_TABLE_FILE="$WORK_DIR/nft.table"
export IP_RULE_FILE="$WORK_DIR/ip.rule"
export FORKOP_LIB="$LIB"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_INIT="$WORK_DIR/forkop-init"
export FORKOP_BIN="$WORK_DIR/bin/forkop"
export FORKOP_DNS_APPLY_UC="$WORK_DIR/dns-apply.uc"
export FORKOP_KILLSWITCH_UC="$WORK_DIR/missing-killswitch.uc"
export FORKOP_SING_BOX_INIT="$WORK_DIR/sing-box-init"
export FORKOP_SING_BOX_BIN="$WORK_DIR/sing-box"
export FORKOP_SING_BOX_CRONET="$WORK_DIR/libcronet.so"
export FORKOP_RT_TABLES="$WORK_DIR/rt_tables"
export FORKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/package-was-running"
printf 'forkop.settings=settings\nforkop.settings.dont_touch_dhcp=0\n' >"$FORKOP_UCI_STATE_FILE"

# /etc/init.d/forkop: "status" reports a running Forkop, "stop" ends with
# $STOP_STATUS (2: refused before anything was torn down).
cat >"$FORKOP_INIT" <<'SH'
#!/bin/sh
case "$1" in
  status) exit 0 ;;
  stop)
    printf 'forkop stop source=%s\n' "${FORKOP_STOP_SOURCE:-}" >>"$EVENTS"
    exit "${STOP_STATUS:-0}"
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
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
[ "$1" != -t ] || shift
if [ "$1 $2 $3" = "list table inet" ]; then
  [ "$4" = ForkopTable ] && [ -e "$NFT_TABLE_FILE" ]
  exit $?
fi
exit 1
SH
cat >"$WORK_DIR/bin/ip" <<'SH'
#!/bin/sh
case "$*" in
  "-4 rule show" | "rule show")
    printf '0:\tfrom all lookup local\n'
    [ ! -e "$IP_RULE_FILE" ] || printf '105:\tfrom all fwmark 0x4000000/0x4000000 lookup forkop\n'
    printf '32766:\tfrom all lookup main\n'
    ;;
esac
exit 0
SH
chmod +x "$FORKOP_INIT" "$FORKOP_BIN" "$WORK_DIR/bin/"*

reset_case() {
  : >"$EVENTS"
  printf '100 main\n105 forkop\n' >"$FORKOP_RT_TABLES"
  cat >"$FORKOP_SING_BOX_INIT" <<'SH'
#!/bin/sh
# Forkop managed sing-box service for binary variants
printf 'sing-box init %s\n' "$1" >>"$EVENTS"
SH
  chmod +x "$FORKOP_SING_BOX_INIT"
  : >"$FORKOP_SING_BOX_BIN"
  : >"$FORKOP_SING_BOX_CRONET"
  rm -f "$NFT_TABLE_FILE" "$IP_RULE_FILE" "$FORKOP_PACKAGE_UPGRADE_STATE"
}
prerm() { # prerm <action> [new version]: status of service/package.uc prerm
  local rc=0
  ucode -L "$LIB" "$PACKAGE_UC" prerm "$@" >>"$EVENTS" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}
kept_runtime() {
  ! grep -q '^sing-box init' "$EVENTS" || fail "$1: the managed sing-box was stopped or disabled"
  local file
  for file in "$FORKOP_SING_BOX_INIT" "$FORKOP_SING_BOX_BIN" "$FORKOP_SING_BOX_CRONET"; do
    [ -e "$file" ] || fail "$1: the managed sing-box was removed ($file)"
  done
  grep -q '^105 forkop$' "$FORKOP_RT_TABLES" || fail "$1: the routing table name of ip rule 105 was removed"
  ! grep -qE '^(dns |forkop restore_dnsmasq)' "$EVENTS" || fail "$1: DNS was restored away from the running runtime"
}
cleaned_up() {
  grep -q '^sing-box init stop$' "$EVENTS" || fail "$1: the managed sing-box was not stopped"
  grep -q '^sing-box init disable$' "$EVENTS" || fail "$1: the managed sing-box was not disabled"
  [ ! -e "$FORKOP_SING_BOX_INIT" ] || fail "$1: the managed sing-box init script was not removed"
  [ ! -e "$FORKOP_SING_BOX_BIN" ] || fail "$1: the managed sing-box binary was not removed"
  ! grep -q '^105 forkop$' "$FORKOP_RT_TABLES" || fail "$1: the routing table name was not removed"
  grep -q '^forkop restore_dnsmasq' "$EVENTS" || fail "$1: dnsmasq was not restored"
}

# 1. Upgrade: the stop was refused and ForkopTable is still in place.
reset_case
printf 'ForkopTable\n' >"$NFT_TABLE_FILE"
printf '105\n' >"$IP_RULE_FILE"
[ "$(STOP_STATUS=2 prerm upgrade 1.0.40)" != 0 ] || fail "prerm reported success after a refused stop left the interception"
grep -q '^forkop stop source=package$' "$EVENTS" || fail "prerm did not stop Forkop as the package"
kept_runtime "refused upgrade stop"

# 2. Removal: the stop failed and only the ip rule is left.
reset_case
printf '105\n' >"$IP_RULE_FILE"
[ "$(STOP_STATUS=1 prerm remove)" != 0 ] || fail "prerm reported success after a failed stop left ip rule 105"
kept_runtime "failed removal stop"

# 3. The stop was refused, but Forkop intercepts nothing (it was not running):
#    nothing can be left without a listener, so prerm cleans up.
reset_case
[ "$(STOP_STATUS=2 prerm upgrade 1.0.40)" = 0 ] || fail "prerm failed although no interception was left"
cleaned_up "refused stop without interception"

# 4. The stop succeeded: prerm cleans up as before.
reset_case
[ "$(STOP_STATUS=0 prerm upgrade 1.0.40)" = 0 ] || fail "prerm failed after a successful stop"
cleaned_up "successful stop"

printf 'package prerm refused stop checks passed\n'
