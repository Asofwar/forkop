#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
holder=""
cleanup() {
  [ -z "$holder" ] || kill "$holder" 2>/dev/null || true
  # The retry that the blocked start scheduled.
  pkill -KILL -f "$WORK_DIR/run/start-retry.pid" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
# The lock and its owner are read through service/state.uc (core/runtime_lock.uc).
state() { ucode -L "$FORKOP_LIB" "$FORKOP_LIB/service/state.uc" "$@"; }
export REAL_LIB="$FORKOP_LIB" START_OWNER="$$"

mkdir -p "$WORK_DIR/run" "$WORK_DIR/lib/dns"
printf 'forkop.settings=settings\n' >"$WORK_DIR/uci.state"
printf 'exit(0);\n' >"$WORK_DIR/lib/dns/apply.uc"
cat >"$WORK_DIR/forkop" <<'SH'
#!/bin/sh
[ "$1" = start ] || exit 50
# The start runs under its own reload.lock.
[ "$(ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" runtime-dir-lock-owner "$FORKOP_RELOAD_LOCK_DIR")" = "$START_OWNER" ] || exit 51
printf 'start\n' >>"$START_TEST_LOG"
exit "${START_TEST_STATUS:-0}"
SH
chmod +x "$WORK_DIR/forkop"
# The init script that a scheduled start retry runs. The retry is due after
# 1 s: a start that cancels it signals only its shell (service/initd.uc), and
# the shell's `sleep` lives on, reparented, until the delay ends.
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/init"
chmod +x "$WORK_DIR/init"

start() {
  env FORKOP_LIB="$WORK_DIR/lib" FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
    FORKOP_UI_ACTION_TRACKED=1 FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run" \
    FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock" \
    FORKOP_START_RUNTIME_LOCK_WAIT_SECONDS="${START_TEST_WAIT:-0}" \
    FORKOP_SERVICE_INIT="$WORK_DIR/init" FORKOP_START_DEFERRED_RETRY_DELAY_SECONDS=1 \
    FORKOP_BIN="${START_TEST_BIN:-$WORK_DIR/forkop}" \
    START_TEST_LOG="$WORK_DIR/start.log" START_TEST_STATUS="${START_TEST_STATUS:-0}" \
    ucode -L "$FORKOP_LIB" "$FORKOP_LIB/service/initd.uc" start-service manual "$$"
}

# A reload holds the lock under its own live owner.
sleep 300 >/dev/null 2>&1 &
holder=$!
state acquire-runtime-dir-lock "$WORK_DIR/run/reload.lock" "$holder" || fail "the reload could not take the lock"
if start; then fail "start ignored an active reload"; fi
[ ! -e "$WORK_DIR/start.log" ] || fail "blocked start invoked the backend"
[ "$(state runtime-dir-lock-owner "$WORK_DIR/run/reload.lock")" = "$holder" ] ||
  fail "blocked start removed another owner's lock"
# It is deferred, not dropped: it is retried once the lock is released.
grep -qx 'reason=start_deferred' "$WORK_DIR/run/start.retry" 2>/dev/null ||
  fail "blocked start scheduled no retry"

(
  sleep 1
  state release-runtime-dir-lock "$WORK_DIR/run/reload.lock" "$holder"
) &
release_pid=$!
START_TEST_WAIT=5 start || fail "start did not resume after reload released its lock"
wait "$release_pid"
[ "$(cat "$WORK_DIR/start.log")" = start ] || fail "backend did not start exactly once"
[ ! -d "$WORK_DIR/run/reload.lock" ] || fail "successful start leaked its lock"
[ ! -e "$WORK_DIR/run/start.retry" ] || fail "successful start left the deferred start pending"

# A failed backend may suppress retry; its runtime lock must still be released.
printf 'blocked\n' >"$WORK_DIR/run/start.failure"
status=0
START_TEST_STATUS=23 start || status=$?
[ "$status" = 23 ] || fail "backend failure status was lost"
[ ! -d "$WORK_DIR/run/reload.lock" ] || fail "failed start leaked its lock"

if START_TEST_BIN="$WORK_DIR/missing" start; then fail "missing backend was accepted"; fi
[ ! -d "$WORK_DIR/run/reload.lock" ] || fail "missing backend leaked its lock"
printf 'start/reload serialization checks passed\n'
