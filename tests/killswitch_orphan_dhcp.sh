#!/usr/bin/env bash
# The kill-switch watcher that finds its package gone detaches the DNS block
# list from dnsmasq through the edit core/uci.uc gives every dhcp writer
# (S5 integration, UC-236): /etc/config/dhcp is replaced only while it holds
# what the edit read, and what someone staged for dhcp with `uci set` (an
# unsaved LuCI change) is neither committed nor lost. It committed through
# the libuci binding, whose commit also commits those staged changes (and
# without the binding, which some ucode builds lack, it detached nothing).
#
# The real watcher (killswitch/runtime.uc watch) on a dhcp file through the
# OpenWrt uci CLI; skipped without one (the test shim does not resolve
# @dnsmasq[0]).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
KS_UC="$FORKOP_LIB/killswitch/runtime.uc"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

WATCHER=""
cleanup() {
  [ -z "$WATCHER" ] || owned_kill TERM "$WATCHER" || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'dhcp:\n' >&2
  cat "$WORK_DIR/etc/config/dhcp" >&2 2>/dev/null || true
  printf 'logger:\n' >&2
  cat "$WORK_DIR/logger.log" >&2 2>/dev/null || true
  exit 1
}

UCI_REAL="$(command -v uci 2>/dev/null || true)"
if [ -z "$UCI_REAL" ]; then
  printf 'NOTE: no OpenWrt uci CLI on PATH; the dhcp checks of the orphaned watcher are skipped\n'
  printf 'killswitch_orphan_dhcp: PASS\n'
  exit 0
fi

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/ks" "$WORK_DIR/cache" "$WORK_DIR/etc/config" \
  "$WORK_DIR/foreign-save" "$WORK_DIR/package/killswitch"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
for name in logger dnsmasq-init ubus; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/%s.log"\n' "$WORK_DIR" "$name" >"$WORK_DIR/bin/$name"
done
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/dig"
# The uci CLI: the router's default configuration directory and staging
# directory (/etc/config, /tmp/.uci) are the ones under $WORK_DIR.
cat >"$WORK_DIR/bin/uci" <<SH
#!/bin/sh
case " \$* " in
  *" -c "*) exec "$UCI_REAL" "\$@" ;;
esac
exec "$UCI_REAL" -c "$WORK_DIR/etc/config" -t "$WORK_DIR/foreign-save" "\$@"
SH
chmod 0755 "$WORK_DIR/bin/"*

export WORK_DIR
export PATH="$WORK_DIR/bin:$PATH"
unset FORKOP_UCI_STATE_FILE FORKOP_UCI_LOG_FILE
export FORKOP_LIB
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export FORKOP_DNSMASQ_CONFIG_FILE="$WORK_DIR/etc/config/dhcp"
export FORKOP_UCI_CLI="$WORK_DIR/bin/uci"
export KILLSWITCH_STATE_DIR="$WORK_DIR/ks"
export KILLSWITCH_NFT_INCLUDE="$WORK_DIR/ruleset-post/90-forkop-killswitch.nft"
export KILLSWITCH_CACHE_DIR="$WORK_DIR/cache"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export FORKOP_KILLSWITCH_INIT="$WORK_DIR/bin/killswitch-init"

SERVERS="$KILLSWITCH_STATE_DIR/dnsmasq.servers"
cat >"$WORK_DIR/etc/config/dhcp" <<EOF
config dnsmasq
	option domain 'lan'
	list server '1.1.1.1'
	option serversfile '$SERVERS'

config dhcp 'lan'
	option interface 'lan'
	option leasetime '12h'
EOF
printf 'server=/example.com/\n' >"$SERVERS"
cp "$SERVERS" "$KILLSWITCH_STATE_DIR/dns-blocked.servers"
# An unsaved LuCI change to dhcp, staged with `uci set`.
uci set dhcp.lan.leasetime=1h
[ -s "$WORK_DIR/foreign-save/dhcp" ] || fail "the foreign change was not staged"
uci_get() { "$UCI_REAL" -q -c "$WORK_DIR/etc/config" -t "$WORK_DIR/empty-save" get "$1" || true; }

# A copy of the watcher's module stands for the package's file: removing it
# is what a removal or a downgrade without its scripts does.
cp "$KS_UC" "$WORK_DIR/package/killswitch/runtime.uc"
FORKOP_KILLSWITCH_WATCH_ITERATIONS=20000 FORKOP_KILLSWITCH_WATCH_INTERVAL_MS=1 \
  ucode -L "$FORKOP_LIB" "$WORK_DIR/package/killswitch/runtime.uc" watch &
WATCHER=$!
sleep 0.3
rm -f "$WORK_DIR/package/killswitch/runtime.uc"
wait_until 15 sh -c "! kill -0 $WATCHER 2>/dev/null" || fail "the watcher did not stop once its package was gone"
wait "$WATCHER" 2>/dev/null || true
WATCHER=""

[ -z "$(uci_get 'dhcp.@dnsmasq[0].serversfile')" ] || fail "the watcher did not detach the block list from dnsmasq"
[ "$(uci_get 'dhcp.@dnsmasq[0].domain')" = lan ] || fail "the watcher changed more of dhcp than the block list"
[ "$(uci_get 'dhcp.lan.leasetime')" = 12h ] ||
  fail "the watcher committed a change someone else had staged for dhcp: leasetime $(uci_get 'dhcp.lan.leasetime')"
grep -q "leasetime" "$WORK_DIR/foreign-save/dhcp" 2>/dev/null || fail "the change someone else had staged for dhcp was lost"
grep -Fqx restart "$WORK_DIR/dnsmasq-init.log" || fail "dnsmasq was not restarted without the block list"
for file in "$WORK_DIR"/etc/config/.dhcp.* "$WORK_DIR"/etc/config/dhcp.*; do
  [ ! -e "$file" ] || fail "a temporary file was left next to dhcp: ${file##*/}"
done
printf 'killswitch_orphan_dhcp: PASS\n'
