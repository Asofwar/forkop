#!/usr/bin/env bash
set -euo pipefail

# Full uninstall waits, bounded, for a configuration change of Forkop that
# began before it (UC-084).
#
# Before: the removal stopped Forkop and deleted its files without looking
# at the snapshot and autotune transactions. One that was running when the
# removal started (a restore from another LuCI tab, an autotune run or
# apply, a change of the autotune policy, an URLTest override) went on
# beside it: it could write /etc/config/forkop, the snapshots or the crontab
# again after the files phase, or keep its nft guard, behind a removal that
# reported "complete".
#
# Now, before it stops anything, the removal waits while such a transaction
# runs: a process that runs `ucode -L <lib> <lib>/<module> <mode>` for one
# of them, the identity their locks accept as an owner. The CLI refuses new
# ones meanwhile (tests/full_uninstall_command_gate.sh). One that does not
# end within the wait fails the removal with nothing stopped or removed, in
# the phase "transactions" the UI explains.
#
# full-uninstall.sh runs against a fixture root; the transactions are real
# ucode processes with that identity, run from stand-in modules.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/forkop/files/usr/lib/full-uninstall.sh"
REAL_SLEEP="$(command -v sleep)"
WORK="$(cd "$(mktemp -d)" && pwd -P)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

pids=()
cleanup() {
  local pid
  owned_kill KILL "${pids[@]}" || true
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

ROOT=""
fail() {
  printf 'FAIL: %s: %s\n' "$CASE" "$1" >&2
  [ -z "$ROOT" ] || cat "$ROOT"/tmp/forkop-uninstall.*/output.log 2>/dev/null | sed 's/^/  log: /' >&2 || true
  exit 1
}

# sleep: the status cleanup (sleep 300) lasts as long as this test; a second
# of the removal's wait is shortened.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/sleep" <<SH
#!/bin/sh
case "\$1" in
  300) while [ -d "$WORK" ]; do "$REAL_SLEEP" 0.1; done; exit 0 ;;
  1) exec "$REAL_SLEEP" 0.05 ;;
esac
exec "$REAL_SLEEP" "\$@"
SH
chmod +x "$WORK/bin/sleep"
export PATH="$WORK/bin:$PATH"

fixture() {
  CASE="$1"
  ROOT="$WORK/$1"
  LIB="$ROOT/usr/lib/forkop"
  mkdir -p "$ROOT/etc/opkg" "$ROOT/usr/bin" "$ROOT/bin" "$ROOT/packages" "$ROOT/etc/forkop" \
    "$ROOT/etc/config" "$ROOT/etc/init.d" "$LIB/config" "$LIB/autotune"
  : >"$ROOT/calls"
  printf 'original vendor repositories\n' >"$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
  printf 'https://mirror.51343.ru/openwrt/releases/test\n' >"$ROOT/etc/opkg/distfeeds.conf"
  printf 'subscription secret\n' >"$ROOT/etc/config/forkop"
  touch "$ROOT/packages/forkop" "$ROOT/packages/luci-app-forkop"
  printf '#!/bin/sh\nprintf "forkop %%s\\n" "$*" >>"$FORKOP_UNINSTALL_ROOT/calls"\n' >"$ROOT/usr/bin/forkop"
  printf '#!/bin/sh\nprintf "init.d/forkop %%s\\n" "$1" >>"$FORKOP_UNINSTALL_ROOT/calls"\n' >"$ROOT/etc/init.d/forkop"
  cat >"$ROOT/bin/opkg" <<'SH'
#!/bin/sh
case "$1" in
  status) [ -e "$FORKOP_UNINSTALL_ROOT/packages/$2" ] && echo 'Status: install ok installed' ;;
  remove) shift; for p in "$@"; do rm -f "$FORKOP_UNINSTALL_ROOT/packages/$p"; done ;;
  *) exit 1 ;;
esac
SH
  # Nothing of Forkop's runtime is in place: never the host's nft and ip.
  printf '#!/bin/sh\nexit 1\n' >"$ROOT/bin/nft"
  printf '#!/bin/sh\nexit 0\n' >"$ROOT/bin/ip"
  chmod +x "$ROOT/usr/bin/forkop" "$ROOT/etc/init.d/forkop" "$ROOT/bin/opkg" "$ROOT/bin/nft" "$ROOT/bin/ip"
}

# transaction MODULE MODE: a process with the identity of that transaction.
# It writes the configuration, as a restore would, once released, or never
# ends without a release.
transaction() {
  local module="$LIB/$1"
  TXN="$WORK/txn-$CASE-${1//\//_}-$2"
  mkdir -p "$TXN"
  cat >"$module" <<'UCODE'
let fs = require("fs");
let dir = getenv("TXN");
fs.writefile(dir + "/started", "");
while (fs.stat(dir + "/release") == null)
    system("sleep 0.05");
fs.writefile(getenv("TXN_CONFIG"), "written by the transaction\n");
UCODE
  TXN="$TXN" TXN_CONFIG="$ROOT/etc/config/forkop" ucode -L "$LIB" "$module" "$2" x </dev/null >/dev/null 2>&1 &
  TXN_PID=$!
  pids+=("$TXN_PID")
  wait_until 20 test -e "$TXN/started" || fail "the transaction $1 $2 did not start"
}

settled() {
  status="$(cat "$ROOT"/www/forkop-uninstall.*.json 2>/dev/null)"
  case "$status" in *'"state":"complete"'* | *'"state":"failed"'*) return 0 ;; esac
  return 1
}
waiting_or_settled() {
  settled && return 0
  case "$status" in *'"phase":"transactions"'*) return 0 ;; esac
  return 1
}

start_removal() {
  FORKOP_UNINSTALL_ROOT="$ROOT" FORKOP_MIRROR_BASE_URL=https://mirror.51343.ru PATH="$ROOT/bin:$PATH" \
    sh "$SCRIPT" start >"$ROOT/response" || fail "the removal did not start: $(cat "$ROOT/response")"
}

# 1. Each transaction holds the removal until it ends, before anything is
#    stopped; what it wrote meanwhile goes with the rest.
for transaction in "config/snapshots.uc restore" "config/snapshots.uc create" \
  "config/snapshots.uc delete" "autotune/apply.uc apply" "autotune/apply.uc rollback" \
  "autotune/isolation.uc run" "autotune/manager.uc run-job" "autotune/manager.uc apply-job" \
  "autotune/manager.uc policy-set" "autotune/manager.uc target-set" "config/urltest_override.uc save"; do
  fixture "waits-${transaction//[ \/.]/_}"
  read -r module mode <<<"$transaction"
  transaction "$module" "$mode"
  start_removal
  wait_until 30 waiting_or_settled || fail "the removal neither waited nor finished"
  if settled; then
    fail "the removal did not wait for $transaction: $status"
  fi
  if grep -q 'stop' "$ROOT/calls"; then fail "Forkop was stopped while $transaction ran"; fi
  : >"$TXN/release"
  wait_until 30 process_gone "$TXN_PID" || fail "the transaction did not end"
  wait_until 30 settled || fail "the removal did not finish after $transaction ended"
  printf '%s\n' "$status" | grep -q '"state":"complete"' || fail "the removal failed: $status"
  [ ! -e "$ROOT/etc/config/forkop" ] || fail "what $transaction wrote outlived the removal"
  [ ! -e "$ROOT/packages/forkop" ] || fail "the packages were not removed"
done

# 2. What only reads, or is no transaction of this Forkop, holds nothing up.
fixture reads
transaction config/snapshots.uc list
transaction autotune/manager.uc status
transaction autotune/isolation.uc status
LIB_KEPT="$LIB"
LIB="$WORK/other-root/usr/lib/forkop"
mkdir -p "$LIB/config"
transaction config/snapshots.uc restore
LIB="$LIB_KEPT"
start_removal
wait_until 60 settled || fail "the removal did not finish"
printf '%s\n' "$status" | grep -q '"state":"complete"' || fail "the removal waited for no transaction: $status"

# 3. A transaction that does not end within the wait fails the removal before
#    anything is stopped or removed, and the log names it.
fixture timeout
transaction config/snapshots.uc restore
start_removal
wait_until 60 settled || fail "the removal did not give up waiting"
printf '%s\n' "$status" | grep -q '"state":"failed","phase":"transactions"' ||
  fail "the removal did not fail while the transaction ran: $status"
[ ! -s "$ROOT/calls" ] || fail "the removal did more than wait: $(cat "$ROOT/calls")"
[ -e "$ROOT/packages/forkop" ] || fail "packages were removed"
grep -qx 'subscription secret' "$ROOT/etc/config/forkop" || fail "the configuration was removed"
grep -q 'mirror.51343.ru' "$ROOT/etc/opkg/distfeeds.conf" || fail "the feeds were changed"
grep -Fq "config/snapshots.uc restore (pid $TXN_PID)" "$ROOT"/tmp/forkop-uninstall.*/output.log ||
  fail "the log does not name the transaction"
[ ! -e "$ROOT/tmp/forkop-full-uninstall.lock" ] || fail "the removal lock was left behind"

printf 'full_uninstall_transactions: ok\n'
