#!/usr/bin/env bash
set -euo pipefail

# Full uninstall removes Forkop only once its runtime is down, and reports
# success only when nothing of it is left (UC-028, UC-083).
#
# Before: the stop phase trusted the exit status of /etc/init.d/forkop stop.
# A stop that left Forkop's interception in place and still exited 0 (rc.common
# drops the status of stop_service unless a service_stopped hook passes it on;
# a stop that could not delete the table or rule logs and goes on) let the
# removal go on: the packages, the managed sing-box that served ForkopTable
# and the feeds went, the job reported "complete", and ForkopTable and the
# fwmark rule at priority 105 kept diverting traffic to a port nobody served
# until a reboot. Cron lines calling the removed /usr/bin/forkop stayed.
# forkop-torrserver-direct was neither stopped nor disabled, and the rc.d
# links of the package's services stayed behind.
#
# Now, right after Forkop's stop, the removal checks what is left of its
# runtime: ForkopTable, an IPv4 or IPv6 rule at priority 105 that looks up
# Forkop's table (by name or, once rt_tables lost the name, by number) and
# Forkop's lines in the crontab. Anything left refuses the removal before
# anything is disabled, stopped or removed, and says what is left (also in the
# status the UI reads). At the end it checks again, with the TorrServer
# Direct table, the kill-switch table and the kill-switch loader of fw4, and
# fails instead of reporting success when any of it is still there.
#
# full-uninstall.sh runs against a fixture root with an init.d, nft, ip and a
# package manager that record what they are asked to do.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/forkop/files/usr/lib/full-uninstall.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

ROOT=""
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if [ -n "$ROOT" ]; then
    [ ! -s "$ROOT/calls" ] || sed 's/^/  call: /' "$ROOT/calls" >&2
    cat "$ROOT"/tmp/forkop-uninstall.*/output.log 2>/dev/null | sed 's/^/  log: /' >&2 || true
  fi
  exit 1
}

FORKOP_CRON='0 */6 * * * /usr/bin/forkop list_update_if_due # forkop-list-update'
FOREIGN_CRON='0 3 * * * /usr/bin/backup # mine'

# fixture <name>: a router with Forkop running. Forkop's stop takes its
# runtime down unless $ROOT/stop-leaves names what it leaves.
fixture() {
  ROOT="$WORK/$1"
  mkdir -p "$ROOT/etc/opkg" "$ROOT/usr/bin" "$ROOT/bin" "$ROOT/packages" "$ROOT/etc/forkop" \
    "$ROOT/etc/config" "$ROOT/usr/lib/forkop" "$ROOT/etc/init.d" "$ROOT/etc/rc.d" \
    "$ROOT/etc/crontabs" "$ROOT/nft" "$ROOT/usr/share/nftables.d/ruleset-post"
  : >"$ROOT/calls"
  printf 'original vendor repositories\n' >"$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
  printf 'https://mirror.51343.ru/openwrt/releases/test\n' >"$ROOT/etc/opkg/distfeeds.conf"
  touch "$ROOT/usr/lib/forkop/test" "$ROOT/packages/forkop" "$ROOT/packages/luci-app-forkop" \
    "$ROOT/packages/sing-box" "$ROOT/nft/ForkopTable" "$ROOT/nft/ForkopTorrServerDirect"
  printf '# loader\n' >"$ROOT/usr/share/nftables.d/ruleset-post/90-forkop-killswitch-loader.nft"
  printf '105:\tfrom all fwmark 0x4000000/0x4000000 lookup forkop\n' >"$ROOT/rules4"
  printf '105:\tfrom all fwmark 0x4000000/0x4000000 lookup forkop\n' >"$ROOT/rules6"
  printf '%s\n%s\n' "$FOREIGN_CRON" "$FORKOP_CRON" >"$ROOT/etc/crontabs/root"
  for link in S99forkop S20forkop-killswitch K90forkop-killswitch S100forkop-torrserver-direct \
    K9forkop-torrserver-direct S19dnsmasq K50dropbear; do
    ln -s "../init.d/${link##*[0-9]}" "$ROOT/etc/rc.d/$link"
  done

  cat >"$ROOT/usr/bin/forkop" <<'SH'
#!/bin/sh
printf 'forkop %s\n' "$*" >>"$FORKOP_UNINSTALL_ROOT/calls"
SH
  # /etc/init.d/forkop: its stop takes Forkop's runtime down (table, rules,
  # cron lines) except what stop-leaves names, and exits with stop-status.
  cat >"$ROOT/etc/init.d/forkop" <<'SH'
#!/bin/sh
R="$FORKOP_UNINSTALL_ROOT"
printf 'init.d/forkop %s\n' "$1" >>"$R/calls"
case "$1" in
  stop)
    leaves="$(cat "$R/stop-leaves" 2>/dev/null || true)"
    case "$leaves" in *table*) ;; *) rm -f "$R/nft/ForkopTable" ;; esac
    case "$leaves" in *rule4*) ;; *) : >"$R/rules4" ;; esac
    case "$leaves" in *rule6*) ;; *) : >"$R/rules6" ;; esac
    case "$leaves" in *cron*) ;; *) grep -v '# forkop-' "$R/etc/crontabs/root" >"$R/cron.new"; mv "$R/cron.new" "$R/etc/crontabs/root" ;; esac
    exit "$(cat "$R/stop-status" 2>/dev/null || echo 0)"
    ;;
  disable) rm -f "$R"/etc/rc.d/S??forkop "$R"/etc/rc.d/K??forkop ;;
esac
SH
  # As rc.common: disable removes only S?? and K?? links.
  cat >"$ROOT/etc/init.d/forkop-torrserver-direct" <<'SH'
#!/bin/sh
R="$FORKOP_UNINSTALL_ROOT"
printf 'init.d/forkop-torrserver-direct %s\n' "$1" >>"$R/calls"
case "$1" in
  stop) rm -f "$R/nft/ForkopTorrServerDirect" ;;
  disable) rm -f "$R"/etc/rc.d/S??forkop-torrserver-direct "$R"/etc/rc.d/K??forkop-torrserver-direct ;;
esac
SH
  cat >"$ROOT/etc/init.d/forkop-killswitch" <<'SH'
#!/bin/sh
R="$FORKOP_UNINSTALL_ROOT"
printf 'init.d/forkop-killswitch %s\n' "$1" >>"$R/calls"
case "$1" in
  disable) rm -f "$R"/etc/rc.d/S??forkop-killswitch "$R"/etc/rc.d/K??forkop-killswitch ;;
esac
SH
  cat >"$ROOT/etc/init.d/sing-box" <<'SH'
#!/bin/sh
printf 'init.d/sing-box %s\n' "$1" >>"$FORKOP_UNINSTALL_ROOT/calls"
SH
  cat >"$ROOT/bin/nft" <<'SH'
#!/bin/sh
R="$FORKOP_UNINSTALL_ROOT"
[ "$1" != -t ] || shift
case "$1 $2 $3" in
  "list table inet") [ -e "$R/nft/$4" ]; exit $? ;;
  "delete table inet") rm -f "$R/nft/$4"; exit 0 ;;
esac
exit 1
SH
  cat >"$ROOT/bin/ip" <<'SH'
#!/bin/sh
R="$FORKOP_UNINSTALL_ROOT"
case "$*" in
  "-4 rule show") printf '0:\tfrom all lookup local\n'; cat "$R/rules4"; printf '32766:\tfrom all lookup main\n' ;;
  "-6 rule show") printf '0:\tfrom all lookup local\n'; cat "$R/rules6"; printf '32766:\tfrom all lookup main\n' ;;
  *) exit 1 ;;
esac
SH
  cat >"$ROOT/bin/opkg" <<'SH'
#!/bin/sh
R="$FORKOP_UNINSTALL_ROOT"
case "$1" in
  status) [ -e "$R/packages/$2" ] && echo 'Status: install ok installed' ;;
  remove)
    printf 'opkg %s\n' "$*" >>"$R/calls"
    shift
    for p in "$@"; do rm -f "$R/packages/$p"; done
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$ROOT/usr/bin/forkop" "$ROOT"/etc/init.d/* "$ROOT/bin/"*
}

worker_settled() {
  status="$(cat "$ROOT"/www/forkop-uninstall.*.json 2>/dev/null)"
  case "$status" in *'"state":"complete"'* | *'"state":"failed"'*) return 0 ;; esac
  return 1
}

run_removal() {
  FORKOP_UNINSTALL_ROOT="$ROOT" PATH="$ROOT/bin:$PATH" sh "$SCRIPT" start >"$ROOT/response"
  wait_until 60 worker_settled || fail "$CASE: the removal did not finish"
  LOG="$(cat "$ROOT"/tmp/forkop-uninstall.*/output.log)"
}

# Nothing was removed, disabled or stopped after Forkop's own stop.
refused_at_stop() {
  printf '%s\n' "$status" | grep -q '"state":"failed","phase":"stop"' ||
    fail "$CASE: the removal went on although Forkop's runtime is still up: $status"
  if [ ! -e "$ROOT/packages/forkop" ] || [ ! -e "$ROOT/packages/sing-box" ]; then
    fail "$CASE: packages were removed"
  fi
  grep -q 'mirror.51343.ru' "$ROOT/etc/opkg/distfeeds.conf" || fail "$CASE: the feeds were changed"
  [ -e "$ROOT/usr/lib/forkop/test" ] || fail "$CASE: Forkop's files were removed"
  [ "$(cat "$ROOT/calls")" = 'init.d/forkop stop' ] ||
    fail "$CASE: the removal did more than Forkop's stop"
  [ -L "$ROOT/etc/rc.d/S99forkop" ] || fail "$CASE: Forkop's autostart was removed"
}
says_left() { # says_left <item>...: the log and the status name each item
  local item
  for item in "$@"; do
    printf '%s\n' "$LOG" | grep -Fq "$item" || fail "$CASE: the log does not say that $item is left: $LOG"
    printf '%s\n' "$status" | grep -Fq "$item" || fail "$CASE: the status does not say that $item is left: $status"
  done
}

# 1. Forkop's stop exited 0 and left everything in place.
CASE="stop left the runtime"
fixture runtime_left
printf 'table rule4 rule6 cron\n' >"$ROOT/stop-leaves"
run_removal
refused_at_stop
says_left 'nft table inet ForkopTable' 'IPv4 rule 105' 'IPv6 rule 105' 'scheduled jobs in /etc/crontabs/root'

# 2. Any one of them is enough: the IPv6 rule once rt_tables lost the name
#    (it shows "lookup 105"), the table, the scheduled jobs.
CASE="IPv6 rule by number"
fixture rule_by_number
printf 'rule6\n' >"$ROOT/stop-leaves"
printf '105:\tfrom all fwmark 0x4000000/0x4000000 lookup 105\n' >"$ROOT/rules6"
run_removal
refused_at_stop
says_left 'IPv6 rule 105'
if printf '%s\n' "$status" | grep -Fq 'ForkopTable'; then
  fail "$CASE: the status names a table that is gone: $status"
fi
CASE="table only"
fixture table_only
printf 'table\n' >"$ROOT/stop-leaves"
run_removal
refused_at_stop
says_left 'nft table inet ForkopTable'
CASE="scheduled jobs only"
fixture cron_only
printf 'cron\n' >"$ROOT/stop-leaves"
run_removal
refused_at_stop
says_left 'scheduled jobs in /etc/crontabs/root'

# 3. A stop that failed (refused: exit 2) says what it left too.
CASE="refused stop"
fixture refused_stop
printf 'table rule4\n' >"$ROOT/stop-leaves"
printf '2\n' >"$ROOT/stop-status"
run_removal
refused_at_stop
says_left 'nft table inet ForkopTable' 'IPv4 rule 105'

# 4. A stop that took everything down: the removal completes, TorrServer
#    Direct is stopped and disabled, and no rc.d link of the package's
#    services is left, also not the links an older release made for
#    TorrServer Direct (S100, K9), which its disable never removed.
CASE="clean stop"
fixture clean
run_removal
printf '%s\n' "$status" | grep -q '"state":"complete"' || fail "$CASE: the removal failed: $status"
grep -Fqx 'init.d/forkop-torrserver-direct stop' "$ROOT/calls" || fail "$CASE: TorrServer Direct was not stopped"
grep -Fqx 'init.d/forkop-torrserver-direct disable' "$ROOT/calls" || fail "$CASE: TorrServer Direct was not disabled"
[ ! -e "$ROOT/nft/ForkopTorrServerDirect" ] || fail "$CASE: the TorrServer Direct table was left"
[ ! -e "$ROOT/etc/init.d/forkop-torrserver-direct" ] || fail "$CASE: the TorrServer Direct init script was left"
left_links="$(find "$ROOT/etc/rc.d" -mindepth 1 -name '*forkop*' -printf '%f ')"
[ -z "$left_links" ] || fail "$CASE: rc.d links of the removed services were left: $left_links"
if [ ! -L "$ROOT/etc/rc.d/S19dnsmasq" ] || [ ! -L "$ROOT/etc/rc.d/K50dropbear" ]; then
  fail "$CASE: rc.d links of other services were removed"
fi
[ "$(cat "$ROOT/etc/crontabs/root")" = "$FOREIGN_CRON" ] || fail "$CASE: the crontab is not as the stop left it: $(cat "$ROOT/etc/crontabs/root")"
[ ! -e "$ROOT/packages/forkop" ] || fail "$CASE: the forkop package was not removed"

# 5. What the removal itself takes away is checked at the end: a kill-switch
#    table that nothing lifted fails the removal instead of "complete".
CASE="kill-switch left"
fixture killswitch_left
touch "$ROOT/nft/ForkopKillswitch"
run_removal
printf '%s\n' "$status" | grep -q '"state":"failed","phase":"files"' ||
  fail "$CASE: the removal reported success with the kill-switch table in place: $status"
says_left 'nft table inet ForkopKillswitch'

printf 'full uninstall runtime leftover checks passed\n'
