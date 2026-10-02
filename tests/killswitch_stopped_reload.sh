#!/usr/bin/env bash
# While Forkop is stopped by the user or not started since boot (D-15), a
# reload never reaches start/reload, which refresh the kill-switch. A
# configuration change that leaves no protected section (unchecking the
# option, deleting the section, restoring a snapshot without it) must still
# lift the protection; one that keeps a protected section keeps the last
# applied protection until the next start (UC-208).
#
# Driven through service/initd.uc reload-begin, the entry point init.d runs
# for every reload: configuration change triggers, UI reloads and snapshot
# restores; and through service/lifecycle.uc reload, which checks again under
# the reload.lock init.d holds for it.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
INITD_UC="$FORKOP_LIB/service/initd.uc"
LIFECYCLE_UC="$FORKOP_LIB/service/lifecycle.uc"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

HOLDER=""
cleanup() {
  [ -z "$HOLDER" ] || owned_kill TERM "$HOLDER" || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'uci state:\n' >&2
  cat "$FORKOP_UCI_STATE_FILE" >&2 2>/dev/null || true
  printf 'logger:\n' >&2
  cat "$WORK_DIR/logger.log" >&2 2>/dev/null || true
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/ks"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
case "$1 $2" in
  "list table")
    [ "$4" = "ForkopKillswitch" ] && { [ -e "$WORK_DIR/ks-present" ]; exit $?; }
    exit 1 ;;
  "delete table") [ "$4" = "ForkopKillswitch" ] && rm -f "$WORK_DIR/ks-present"; exit 0 ;;
esac
exit 0
NFT
for name in logger dnsmasq-init killswitch-init ip ubus; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/%s.log"\n' "$WORK_DIR" "$name" >"$WORK_DIR/bin/$name"
done
chmod 0755 "$WORK_DIR/bin/"*

export WORK_DIR
export PATH="$WORK_DIR/bin:$PATH"
export FORKOP_LIB
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export FORKOP_CONFIG_FILE="$WORK_DIR/forkop.config"
export KILLSWITCH_STATE_DIR="$WORK_DIR/ks"
export KILLSWITCH_NFT_INCLUDE="$WORK_DIR/ruleset-post/90-forkop-killswitch.nft"
export KILLSWITCH_CACHE_DIR="$WORK_DIR/cache"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export FORKOP_KILLSWITCH_INIT="$WORK_DIR/bin/killswitch-init"
export FORKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/reload.pending"
export FORKOP_SERVICE_INIT="$WORK_DIR/bin/no-init"
export FORKOP_KILLSWITCH_LOCK_ATTEMPTS=2
: >"$FORKOP_CONFIG_FILE"

POLICY="$KILLSWITCH_STATE_DIR/policy.nft"
SERVERS="$KILLSWITCH_STATE_DIR/dnsmasq.servers"
BLOCKED="$KILLSWITCH_STATE_DIR/dns-blocked.servers"

uci_value() {
  awk -F= -v key="$1" '$1 == key { print substr($0, length($1) + 2) }' "$FORKOP_UCI_STATE_FILE"
}

# Forkop stopped with the protection of section "main" in place.
arm() {
  cat >"$FORKOP_UCI_STATE_FILE" <<EOF
forkop.settings=settings
forkop.main=section
forkop.main.action=connection
forkop.main.kill_switch=1
forkop.other=section
forkop.other.action=connection
forkop.other.kill_switch=$1
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].server=1.1.1.1
dhcp.@dnsmasq[0].serversfile=$SERVERS
EOF
  printf 'add table inet ForkopKillswitch\n' >"$POLICY"
  printf 'server=/example.com/\n' >"$BLOCKED"
  cp "$BLOCKED" "$SERVERS"
  touch "$WORK_DIR/ks-present"
}

# What init.d runs for a reload of a runtime that is down.
reload() {
  local output
  output="$(ucode -L "$FORKOP_LIB" "$INITD_UC" reload-begin-fixture "$1" 0 0 1 "" 2>&1)" || true
  printf '%s\n' "$output" | grep -Fq "INITD_RELOAD_ACTION='skip'" ||
    fail "a reload of a stopped Forkop must be skipped (D-15): $output"
}

# init.d holds reload.lock while service/lifecycle.uc reloads, recorded the
# way core/runtime_lock records an owner.
hold_reload_lock() {
  sleep 300 &
  HOLDER=$!
  wait_until 5 test -r "/proc/$HOLDER/stat" || fail "the reload.lock holder did not start"
  local ticks
  ticks="$(awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$HOLDER/stat")"
  mkdir -p "$FORKOP_RELOAD_LOCK_DIR"
  printf '%s\n%s\n' "$HOLDER" "$ticks" >"$FORKOP_RELOAD_LOCK_DIR/owner.$HOLDER.$ticks"
}

release_reload_lock() {
  owned_kill TERM "$HOLDER" || true
  wait "$HOLDER" 2>/dev/null || true
  HOLDER=""
  rm -rf "$FORKOP_RELOAD_LOCK_DIR"
}

assert_kept() {
  [ -s "$POLICY" ] || fail "$1: the saved policy must stay"
  [ -e "$WORK_DIR/ks-present" ] || fail "$1: the live policy must stay"
  [ "$(uci_value 'dhcp.@dnsmasq[0].serversfile')" = "$SERVERS" ] || fail "$1: the DNS block list must stay"
}

assert_lifted() {
  [ ! -e "$POLICY" ] || fail "$1: the saved policy must be removed"
  [ ! -e "$WORK_DIR/ks-present" ] || fail "$1: the live policy must be removed"
  [ -z "$(uci_value 'dhcp.@dnsmasq[0].serversfile')" ] || fail "$1: dnsmasq must not read the block list any more"
}

# ---- stopped by the user ----------------------------------------------------

printf 'user\n' >"$FORKOP_RUNTIME_STATE_DIR/stop.requested"

arm 1
reload on_config_change
assert_kept "an unrelated change while stopped"

# Unchecking one of two protected sections keeps the protection: it cannot
# be rendered again without a runtime, and blocking is the safe side.
sed -i 's/^forkop.other.kill_switch=1$/forkop.other.kill_switch=0/' "$FORKOP_UCI_STATE_FILE"
reload on_config_change
assert_kept "one protected section left while stopped"

sed -i 's/^forkop.main.kill_switch=1$/forkop.main.kill_switch=0/' "$FORKOP_UCI_STATE_FILE"
reload on_config_change
assert_lifted "the option unchecked on the last protected section while stopped"

# A snapshot restore reloads with its own reason.
arm 0
sed -i '/^forkop.main/d' "$FORKOP_UCI_STATE_FILE"
reload config-restore
assert_lifted "a restored configuration without a protected section while stopped"

# A configuration libuci cannot load (a parse error after a hand edit, a
# file cut short) reads as no section at all. That proves nothing about the
# protected sections: the protection stays.
arm 1
sed -i '/^forkop\./d' "$FORKOP_UCI_STATE_FILE"
reload on_config_change
assert_kept "a configuration that could not be read while stopped"
grep -Fq 'could not be read' "$KILLSWITCH_STATE_DIR/state.json" ||
  fail "an unreadable configuration must be reported: $(cat "$KILLSWITCH_STATE_DIR/state.json" 2>/dev/null)"

# A stop that lands after init.d let the reload through is caught again by
# service/lifecycle.uc under the reload.lock init.d holds for it.
arm 1
sed -i 's/kill_switch=1$/kill_switch=0/' "$FORKOP_UCI_STATE_FILE"
hold_reload_lock
ucode -L "$FORKOP_LIB" "$LIFECYCLE_UC" reload on_config_change >"$WORK_DIR/lifecycle.out" 2>&1 ||
  fail "the reload of a stopped Forkop failed: $(cat "$WORK_DIR/lifecycle.out")"
assert_lifted "the option unchecked on every section, seen by the reload under reload.lock"
[ -d "$FORKOP_RELOAD_LOCK_DIR" ] || fail "the reload must leave init.d's reload.lock alone"
release_reload_lock

# ---- not started since boot -------------------------------------------------

rm -f "$FORKOP_RUNTIME_STATE_DIR/stop.requested" "$FORKOP_RUNTIME_STATE_DIR/start.explicit"
arm 0
sed -i 's/^forkop.main.action=connection$/forkop.main.action=bypass/' "$FORKOP_UCI_STATE_FILE"
reload on_config_change
assert_lifted "the protected section turned into a bypass while not started"

printf 'killswitch_stopped_reload: PASS\n'
