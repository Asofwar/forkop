#!/usr/bin/env bash
set -euo pipefail

# What a running Forkop writes to /etc/config/dhcp (UC-236).
#
# dnsmasq builds its configuration from UCI at every start, so forwarding to
# sing-box (server=127.0.0.42, noresolv, cachesize=0) has to be committed
# there. It is written only when something changes: a configure of a dnsmasq
# that already forwards to sing-box, a restore or failsafe without Forkop
# settings and a kill-switch refresh that changes nothing write nothing. A
# restore puts back exactly what the configure found, options that were not
# set included. The edit works on a private copy of the committed file, so
# what someone staged with `uci set` (in /tmp/.uci) is neither read nor
# committed. A commit the overlay refuses (read-only or full) leaves the
# file as it was and fails the operation.
#
# Part 1 runs the real dns/apply.uc on the UCI fixture; part 2 on a dhcp file
# through the OpenWrt uci CLI (skipped without one: the test shim takes no
# @type[n] references).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
APPLY="$LIB/dns/apply.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  for log in "$WORK/syslog" "$WORK/dnsmasq.log" "$WORK/uci.log" "$WORK/uci.argv"; do
    [ ! -s "$log" ] || sed "s|^|  $(basename "$log"): |" "$log" >&2
  done
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }

mkdir -p "$WORK/bin" "$WORK/run" "$WORK/killswitch"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$WORK/syslog" >"$WORK/bin/logger"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$WORK/dnsmasq.log" >"$WORK/bin/dnsmasq-init"
chmod 0755 "$WORK/bin/logger" "$WORK/bin/dnsmasq-init"
export PATH="$WORK/bin:$PATH"
export DNSMASQ_INIT="$WORK/bin/dnsmasq-init"
export FORKOP_RUNTIME_STATE_DIR="$WORK/run"
export KILLSWITCH_STATE_DIR="$WORK/killswitch"
export FORKOP_CONFIG_NAME=forkop
export SB_DNS_INBOUND_ADDRESS=127.0.0.42

# dns_apply <mode> [force]: the exit status in STATUS.
dns_apply() {
  : >"$WORK/syslog"
  : >"$WORK/dnsmasq.log"
  STATUS=0
  ucode -L "$LIB" "$APPLY" "$@" || STATUS=$?
}
restarted() { grep -Fxq restart "$WORK/dnsmasq.log"; }

# ---- 1. the UCI fixture --------------------------------------------------------

STATE="$WORK/uci.state"
export FORKOP_UCI_STATE_FILE="$STATE"
export FORKOP_UCI_LOG_FILE="$WORK/uci.log"
export FORKOP_DNSMASQ_CONFIG_FILE="$WORK/no-dhcp"

# fixture <line...>: the dhcp state, with Forkop's settings.
fixture() {
  printf '%s\n' "forkop.settings=settings" "$@" >"$STATE"
  : >"$WORK/uci.log"
}
committed() { grep -Fxq 'commit dhcp' "$WORK/uci.log"; }
dhcp_lines() { grep '^dhcp\.' "$STATE" | sort; }

complete=(
  'dhcp.@dnsmasq[0].server=127.0.0.42'
  'dhcp.@dnsmasq[0].noresolv=1'
  'dhcp.@dnsmasq[0].cachesize=0'
  'dhcp.@dnsmasq[0].forkop_server=1.1.1.1'
  'dhcp.@dnsmasq[0].forkop_unset=noresolv cachesize'
)

# a. Nothing changes, nothing is written.
fixture "${complete[@]}"
dns_apply configure force
[ "$STATUS" = 0 ] || fail "configure of a dnsmasq that forwards to sing-box failed"
committed && fail "configure committed dhcp settings that did not change"
restarted || fail "a forced configure did not restart dnsmasq"
fixture 'dhcp.@dnsmasq[0].server=1.1.1.1'
for mode in "restore force" failsafe-restore killswitch-refresh; do
  # shellcheck disable=SC2086
  dns_apply $mode
  [ "$STATUS" = 0 ] || fail "$mode without Forkop settings failed"
  committed && fail "$mode without Forkop settings committed dhcp"
done
ok "dhcp settings that do not change are not written"

# b. A restore puts back what the configure found.
round_trip() {
  fixture "$@"
  dhcp_lines >"$WORK/before"
  dns_apply configure force
  [ "$STATUS" = 0 ] && committed || fail "configure did not save the dnsmasq settings"
  grep -Fxq 'dhcp.@dnsmasq[0].server=127.0.0.42' "$STATE" || fail "configure did not forward dnsmasq to sing-box"
  : >"$WORK/uci.log"
  dns_apply configure force
  committed && fail "a second configure wrote the same dhcp settings again"
  dns_apply restore force
  [ "$STATUS" = 0 ] && committed || fail "restore did not save the dnsmasq settings"
  dhcp_lines >"$WORK/after"
  cmp -s "$WORK/before" "$WORK/after" ||
    fail "restore did not put back the dnsmasq settings: $(diff "$WORK/before" "$WORK/after" | tr '\n' ' ')"
}
round_trip 'dhcp.@dnsmasq[0].server=1.1.1.1 8.8.8.8' 'dhcp.@dnsmasq[0].domain=lan'
round_trip 'dhcp.@dnsmasq[0].domain=lan'
round_trip 'dhcp.@dnsmasq[0].server=9.9.9.9' 'dhcp.@dnsmasq[0].noresolv=0' 'dhcp.@dnsmasq[0].cachesize=1000'
round_trip 'dhcp.@dnsmasq[0].noresolv=1' 'dhcp.@dnsmasq[0].cachesize=0'
ok "a restore puts back the dnsmasq settings as the configure found them, unset options included"

# c. Releases before UC-236 kept no record of an unset option: the dnsmasq
# defaults undo the Forkop values.
fixture 'dhcp.@dnsmasq[0].server=127.0.0.42' 'dhcp.@dnsmasq[0].noresolv=1' 'dhcp.@dnsmasq[0].cachesize=0' \
  'dhcp.@dnsmasq[0].forkop_server=1.1.1.1'
dns_apply restore force
grep -Fxq 'dhcp.@dnsmasq[0].noresolv=0' "$STATE" && grep -Fxq 'dhcp.@dnsmasq[0].cachesize=150' "$STATE" &&
  grep -Fxq 'dhcp.@dnsmasq[0].server=1.1.1.1' "$STATE" ||
  fail "a configuration of an older release was not restored: $(dhcp_lines | tr '\n' ' ')"
ok "a configuration of an older release is still restored"

# d. A commit that fails saves nothing.
fixture 'dhcp.@dnsmasq[0].server=1.1.1.1'
dhcp_lines >"$WORK/before"
rm -f "$WORK/uci.log"
mkdir "$WORK/uci.log"
dns_apply configure force
rmdir "$WORK/uci.log"
[ "$STATUS" != 0 ] || fail "a configure whose commit failed reported success"
restarted && fail "a configure whose commit failed restarted dnsmasq"
dhcp_lines | cmp -s "$WORK/before" - || fail "a configure whose commit failed left changes behind: $(dhcp_lines | tr '\n' ' ')"
ok "a configure whose commit fails saves nothing"

unset FORKOP_UCI_STATE_FILE FORKOP_UCI_LOG_FILE

# ---- 2. a dhcp file through the uci CLI ---------------------------------------

UCI_REAL="$(command -v uci 2>/dev/null || true)"
if [ -z "$UCI_REAL" ]; then
  printf 'NOTE: no OpenWrt uci CLI on PATH; the dhcp file checks are skipped\n'
  printf 'dnsmasq dhcp write checks passed\n'
  exit 0
fi

mkdir -p "$WORK/etc" "$WORK/host-uci"
DHCP="$WORK/etc/dhcp"
export FORKOP_DNSMASQ_CONFIG_FILE="$DHCP"
# The CLI as Forkop runs it: every call is logged, and $WORK/host-uci stands
# in for /tmp/.uci, which the real CLI merges into any commit of a package.
cat >"$WORK/bin/uci" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"$WORK/uci.argv"
exec "$UCI_REAL" -p "$WORK/host-uci" "\$@"
SH
chmod 0755 "$WORK/bin/uci"
export FORKOP_UCI_CLI="$WORK/bin/uci"
host_uci() { "$UCI_REAL" -q -c "$WORK/etc" -t "$WORK/host-uci" "$@"; }
options() { "$UCI_REAL" -q -c "$(dirname "$1")" show "$(basename "$1")" | sort; }

cat >"$WORK/dhcp.orig" <<'EOF'
config dnsmasq
	option domainneeded '1'
	option localise_queries '1'
	option local '/lan/'
	option domain 'lan'
	list server '1.1.1.1'
	list server '8.8.8.8'
	option cachesize '1000'
	option resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'

config dhcp 'lan'
	option interface 'lan'
	option start '100'
	option limit '150'
	option leasetime '12h'
EOF
cp "$WORK/dhcp.orig" "$DHCP"
chmod 0644 "$DHCP"
options "$DHCP" >"$WORK/options.orig"

# Changes staged with `uci set` and never committed: one of an option Forkop
# reads, one elsewhere.
host_uci set dhcp.@dnsmasq[0].cachesize=5000
host_uci set dhcp.lan.leasetime=1h
cp "$WORK/host-uci/dhcp" "$WORK/staged.orig"

: >"$WORK/uci.argv"
dns_apply configure force
[ "$STATUS" = 0 ] || fail "configure through the uci CLI failed"
restarted || fail "configure did not restart dnsmasq"
[ "$(host_uci get dhcp.@dnsmasq[0].server)" = 127.0.0.42 ] && [ "$(host_uci get dhcp.@dnsmasq[0].noresolv)" = 1 ] ||
  fail "configure did not forward dnsmasq to sing-box: $(cat "$DHCP")"
grep -q "leasetime '1h'" "$DHCP" && fail "configure committed a change someone else staged"
grep -q "5000" "$DHCP" && fail "configure saved a value someone else staged"
[ "$(host_uci get dhcp.@dnsmasq[0].forkop_cachesize)" = 1000 ] || fail "configure did not keep the committed cache size"
cmp -s "$WORK/staged.orig" "$WORK/host-uci/dhcp" || fail "configure changed what someone else staged"
grep -q 'commit dhcp\| dhcp\.' "$WORK/uci.argv" && fail "configure went through the live dhcp package"
[ "$(stat -c %a "$DHCP")" = 644 ] || fail "configure changed the mode of the dhcp file"
ok "configure saves only its own changes and reads the committed settings"

stamp() { stat -c '%i %Y %s' "$DHCP"; }
before="$(stamp)"
sleep 1
: >"$WORK/uci.argv"
dns_apply configure force
[ "$STATUS" = 0 ] || fail "a second configure failed"
[ "$(stamp)" = "$before" ] || fail "a second configure rewrote the dhcp file"
grep -q ' commit ' "$WORK/uci.argv" && fail "a second configure committed"
ok "a configure that changes nothing leaves the dhcp file alone"

dns_apply restore force
[ "$STATUS" = 0 ] || fail "restore through the uci CLI failed"
options "$DHCP" | cmp -s "$WORK/options.orig" - ||
  fail "restore did not put back the dhcp settings: $(options "$DHCP" | diff "$WORK/options.orig" - | tr '\n' ' ')"
cmp -s "$WORK/staged.orig" "$WORK/host-uci/dhcp" || fail "restore changed what someone else staged"
ok "restore puts back the dhcp settings exactly and leaves staged changes staged"

# A read-only or full overlay refuses the write: the file stays as it was,
# dnsmasq is not restarted and the operation fails.
overlay() {
  local kind="$1" mode="$2"
  cp "$WORK/dhcp.orig" "$WORK/dhcp.copy"
  unshare -rm sh -c '
    set -e
    etc="$1"; kind="$2"; shift 2
    if [ "$kind" = read-only ]; then
      mount --bind "$etc" "$etc"
      mount -o remount,bind,ro "$etc"
    else
      mount -t tmpfs -o size=16k tmpfs "$etc"
      cp "$WORK/dhcp.copy" "$etc/dhcp"
      dd if=/dev/zero of="$etc/fill" bs=1k 2>/dev/null || true
    fi
    status=0
    ucode -L "$LIB" "$APPLY" "$@" || status=$?
    cp "$etc/dhcp" "$WORK/dhcp.after"
    exit "$status"
  ' sh "$WORK/etc" "$kind" "$mode" force >/dev/null 2>&1 && STATUS=0 || STATUS=$?
}
export WORK LIB APPLY
cp "$WORK/dhcp.orig" "$DHCP"
if ! unshare -rm true 2>/dev/null; then
  printf 'NOTE: no user and mount namespaces; the overlay checks are skipped\n'
else
  for kind in read-only full; do
    : >"$WORK/syslog"
    : >"$WORK/dnsmasq.log"
    overlay "$kind" configure
    [ "$STATUS" != 0 ] || fail "configure on a $kind overlay reported success"
    restarted && fail "configure on a $kind overlay restarted dnsmasq"
    cmp -s "$WORK/dhcp.orig" "$WORK/dhcp.after" || fail "configure on a $kind overlay changed the dhcp file: $(cat "$WORK/dhcp.after")"
    grep -q 'Could not save the dnsmasq settings' "$WORK/syslog" || fail "configure on a $kind overlay logged no error"
  done
  ok "a read-only or full overlay fails the configure and keeps the dhcp file"
fi

printf 'dnsmasq dhcp write checks passed\n'
