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
# Now an upgrade fails closed when the stop failed and Forkop's interception
# (its nft table or its ip rule) is still in place: it keeps DNS, the managed
# sing-box and the routing table name, and reports the failure. On apk that
# failure keeps the installed Forkop, so the kill-switch it manages stays
# too; opkg goes on with the change, and a release without the kill-switch
# cannot lift it later (UC-191).
#
# A removal goes on whatever prerm returns, and nothing is left afterwards
# to own what it keeps: Forkop's DNS configuration outlives the package. So
# a removal whose package stop did not take Forkop down tears it down with
# the explicit stop, which needs no proof of ownership for Forkop's own
# interception (UC-213), and restores DNS also when even that left the
# interception in place. The package managers discard prerm's output, so
# the failure goes to the system log.
#
# A failed stop with no interception left, and a stop that succeeded, clean
# up as before.
#
# The real service/package.uc runs against an init.d, a managed sing-box
# init script, nft, ip, logger and the kill-switch module that record what
# they are asked to do.

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

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/apk-bin" "$WORK_DIR/run"
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
export FORKOP_KILLSWITCH_UC="$WORK_DIR/killswitch.uc"
export FORKOP_SING_BOX_INIT="$WORK_DIR/sing-box-init"
export FORKOP_SING_BOX_BIN="$WORK_DIR/sing-box"
export FORKOP_SING_BOX_CRONET="$WORK_DIR/libcronet.so"
export FORKOP_RT_TABLES="$WORK_DIR/rt_tables"
export FORKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/package-was-running"
# A removal checks what is left of Forkop: never the host's crontab or
# kill-switch policy.
export FORKOP_CRONTAB_FILE="$WORK_DIR/crontab"
export KILLSWITCH_NFT_POLICY="$WORK_DIR/killswitch-policy.nft"
printf 'forkop.settings=settings\nforkop.settings.dont_touch_dhcp=0\n' >"$FORKOP_UCI_STATE_FILE"

# /etc/init.d/forkop: "status" reports a running Forkop. Forkop's own stop
# for the package change ends with $STOP_STATUS (2: refused before anything
# was torn down). The explicit stop removes Forkop's nft table and ip rule
# unless $EXPLICIT_LEAVES is set, and ends with $EXPLICIT_STATUS.
cat >"$FORKOP_INIT" <<'SH'
#!/bin/sh
case "$1" in
  status) exit 0 ;;
  stop)
    printf 'forkop stop source=%s\n' "${FORKOP_STOP_SOURCE:-}" >>"$EVENTS"
    [ "${FORKOP_STOP_SOURCE:-}" != package ] || exit "${STOP_STATUS:-0}"
    [ -n "${EXPLICIT_LEAVES:-}" ] || rm -f "$NFT_TABLE_FILE" "$IP_RULE_FILE"
    exit "${EXPLICIT_STATUS:-0}"
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
cat >"$FORKOP_KILLSWITCH_UC" <<'UC'
system("printf 'killswitch %s\\n' '" + join(" ", ARGV) + "' >>'" + getenv("EVENTS") + "'");
UC
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf 'logger %s\n' "$*" >>"$EVENTS"
SH
# apk is present only where a case puts this directory on PATH.
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/apk-bin/apk"
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
chmod +x "$FORKOP_INIT" "$FORKOP_BIN" "$WORK_DIR/bin/"* "$WORK_DIR/apk-bin/apk"
command -v apk >/dev/null 2>&1 && fail "the host has apk on PATH; the opkg cases need it absent"

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
dns_restored() {
  grep -q '^forkop restore_dnsmasq' "$EVENTS" || fail "$1: dnsmasq was not restored"
  grep -q '^dns failsafe-restore$' "$EVENTS" || fail "$1: the DNS failsafe did not run"
}
logged() {
  grep -q "^logger -t forkop \\[warn\\] .*$2" "$EVENTS" || fail "$1: the system log does not say: $2"
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
[ "$(grep -c '^forkop stop' "$EVENTS")" = 1 ] || fail "an upgrade stopped Forkop again after its refused stop"
kept_runtime "refused upgrade stop"
logged "refused upgrade stop" "still intercepts traffic"

# 2. Removal: the package stop was refused with the interception in place.
#    Nothing would own it after the removal: the explicit stop takes Forkop
#    down, and prerm cleans up.
reset_case
printf 'ForkopTable\n' >"$NFT_TABLE_FILE"
printf '105\n' >"$IP_RULE_FILE"
[ "$(STOP_STATUS=2 prerm remove)" = 0 ] || fail "prerm failed although the explicit stop took Forkop down"
grep -q '^forkop stop source=package$' "$EVENTS" || fail "prerm did not stop Forkop as the package first"
grep -q '^forkop stop source=$' "$EVENTS" || fail "a removal did not tear down what the refused package stop kept"
[ ! -e "$NFT_TABLE_FILE" ] && [ ! -e "$IP_RULE_FILE" ] || fail "the interception survived the removal"
cleaned_up "refused removal stop"
grep -q '^killswitch release package removal$' "$EVENTS" || fail "a removal kept the kill-switch"
logged "refused removal stop" "explicit stop"

# 3. Removal: the package stop failed, and the explicit stop left ip rule
#    105 as well. The DNS configuration outlives the package, so it is
#    restored; the managed sing-box goes with the package but keeps serving
#    the interception until a reboot clears both.
reset_case
printf '105\n' >"$IP_RULE_FILE"
[ "$(STOP_STATUS=1 EXPLICIT_LEAVES=1 EXPLICIT_STATUS=1 prerm remove)" != 0 ] || fail "prerm reported success although the interception survived the removal"
grep -q '^forkop stop source=$' "$EVENTS" || fail "a removal did not try the explicit stop"
dns_restored "interception left at removal"
! grep -q '^sing-box init stop$' "$EVENTS" || fail "the removal stopped the sing-box that still serves the interception"
grep -q '^sing-box init disable$' "$EVENTS" || fail "the managed sing-box was not disabled at removal"
[ ! -e "$FORKOP_SING_BOX_INIT" ] && [ ! -e "$FORKOP_SING_BOX_BIN" ] || fail "the managed sing-box was left behind by the removal"
! grep -q '^105 forkop$' "$FORKOP_RT_TABLES" || fail "the routing table name was left behind by the removal"
grep -q '^killswitch release package removal$' "$EVENTS" || fail "a removal kept the kill-switch"
logged "interception left at removal" "still intercepts traffic"

# 4. The stop was refused, but Forkop intercepts nothing (it was not running):
#    nothing can be left without a listener, so prerm cleans up.
reset_case
[ "$(STOP_STATUS=2 prerm upgrade 1.0.40)" = 0 ] || fail "prerm failed although no interception was left"
cleaned_up "refused stop without interception"
reset_case
[ "$(STOP_STATUS=2 prerm remove)" = 0 ] || fail "prerm failed although no interception was left at removal"
[ "$(grep -c '^forkop stop' "$EVENTS")" = 1 ] || fail "a removal stopped Forkop again although nothing was left"
cleaned_up "refused removal stop without interception"

# 5. The stop succeeded: prerm cleans up as before.
reset_case
[ "$(STOP_STATUS=0 prerm upgrade 1.0.40)" = 0 ] || fail "prerm failed after a successful stop"
cleaned_up "successful stop"

# 6. A refused upgrade stop to a release without the kill-switch. apk keeps
#    the installed Forkop when its pre-upgrade fails: the kill-switch stays
#    with it. opkg goes on with the change: the release it installs could
#    never lift the kill-switch, so it goes now.
reset_case
printf 'ForkopTable\n' >"$NFT_TABLE_FILE"
[ "$(PATH="$WORK_DIR/apk-bin:$PATH" STOP_STATUS=2 prerm upgrade 1.0.31)" != 0 ] || fail "apk: prerm reported success after a refused stop"
! grep -q '^killswitch ' "$EVENTS" || fail "apk: the kill-switch of the Forkop that stays installed was released"
kept_runtime "refused apk downgrade stop"
reset_case
printf 'ForkopTable\n' >"$NFT_TABLE_FILE"
[ "$(PATH="$WORK_DIR/apk-bin:$PATH" STOP_STATUS=2 prerm upgrade)" != 0 ] || fail "apk: prerm reported success after a refused stop (old pre-upgrade)"
! grep -q '^killswitch ' "$EVENTS" || fail "apk: the kill-switch was released although an old pre-upgrade fails the change"
reset_case
printf 'ForkopTable\n' >"$NFT_TABLE_FILE"
[ "$(STOP_STATUS=2 prerm upgrade 1.0.31)" != 0 ] || fail "opkg: prerm reported success after a refused stop"
grep -q '^killswitch release change to a release without the kill-switch (1.0.31)$' "$EVENTS" ||
  fail "opkg: the kill-switch outlives the change to a release that cannot lift it"
kept_runtime "refused opkg downgrade stop"

printf 'package prerm refused stop checks passed\n'
