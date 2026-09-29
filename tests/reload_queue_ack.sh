#!/bin/sh
set -eu

# Queued reload acknowledgement (UC-005, UC-047). When another lifecycle
# action owns reload.lock, service/initd.uc only queues a reload and still
# exits 0. Callers that must not mistake that for a completed reload (a list
# worker, a snapshot restore, an autotune apply) pass their own reason and
# get the `queued` token on stdout, through the real init.d script. Other
# reasons keep their output and status. Every queued request rewrites
# reload.pending with a unique marker, so a second request in the same second
# is still visible to a caller comparing markers.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
INITD_UC="$LIB/service/initd.uc"
STATE_UC="$LIB/service/state.uc"
INITD="$ROOT/forkop/files/etc/init.d/forkop"
REAL_UCODE="$(command -v ucode)"
WORK="$(mktemp -d)"
holder=""
cleanup() {
  [ -z "$holder" ] || kill "$holder" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/run"
export FORKOP_LIB="$LIB" TEST_LIB="$LIB" REAL_INITD="$INITD" REAL_UCODE
export FORKOP_BIN="$WORK/bin/forkop"
export FORKOP_RUNTIME_STATE_DIR="$WORK/run/forkop"
export FORKOP_PENDING_RELOAD_FILE="$WORK/run/forkop/reload.pending"
export FORKOP_RELOAD_LOCK_DIR="$WORK/run/forkop.reload.lock"
export FORKOP_SERVICE_INIT="$WORK/init.d"
export PATH="$WORK/bin:$PATH"

# UI state and dnsmasq failsafe are outside this contract.
cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */service/ui.uc|*/dns/apply.uc) exit 0 ;;
esac
exec "$REAL_UCODE" "$@"
STUB
cat > "$WORK/bin/forkop" <<'STUB'
#!/bin/sh
case "$1" in
  get_status) echo '{"running":true}' ;;
  reload) echo "runtime reload $*" >> "$FORKOP_RUNTIME_STATE_DIR/runtime.log" ;;
esac
exit 0
STUB
# rc.common stand-in: `<init> reload [reason]` runs the real init script's
# reload_service with the remaining arguments, as OpenWrt's rc.common does.
cat > "$WORK/init.d" <<'STUB'
#!/bin/sh
action="$1"; shift
initscript="$REAL_INITD"
. "$REAL_INITD"
FORKOP_LIB="$TEST_LIB"
FORKOP_INITD_UC="$TEST_LIB/service/initd.uc"
[ "$action" = reload ] || exit 1
reload_service "$@"
STUB
chmod +x "$WORK/bin/ucode" "$WORK/bin/forkop" "$WORK/init.d"

# A live lifecycle action owns the reload lock.
mkdir -p "$FORKOP_RUNTIME_STATE_DIR" "$FORKOP_RELOAD_LOCK_DIR"
sleep 300 >/dev/null 2>&1 &
holder=$!
echo "$holder" > "$FORKOP_RELOAD_LOCK_DIR/pid"

initd() { "$REAL_UCODE" -L "$LIB" "$INITD_UC" reload-service "$1" "$$"; }
stamp() { printf '%s:%s' "$(stat -c '%Y:%s' "$FORKOP_PENDING_RELOAD_FILE")" "$(cat "$FORKOP_PENDING_RELOAD_FILE")"; }

# 1. initd.uc: restore, autotune and list-content requests are acknowledged
#    as queued; the status stays 0 and the request is kept in reload.pending.
for reason in config-restore autotune list-content; do
  rm -f "$FORKOP_PENDING_RELOAD_FILE"
  out="$(initd "$reason")" || fail "$reason: queued reload changed the exit status"
  [ "$out" = queued ] || fail "$reason: queued reload printed '$out' instead of 'queued'"
  [ "$(sed -n 1p "$FORKOP_PENDING_RELOAD_FILE")" = "reason=$reason" ] || fail "$reason: pending reason not kept"
  grep -Eq '^updated_at=[0-9]+$' "$FORKOP_PENDING_RELOAD_FILE" || fail "$reason: pending marker lost updated_at"
done

# 2. Other callers keep their contract: no token, status 0.
for reason in "" badwan_interface_up ruleset-cache subscription_deferred_recovery; do
  rm -f "$FORKOP_PENDING_RELOAD_FILE"
  out="$(initd "$reason")" || fail "'$reason': queued reload changed the exit status"
  [ -z "$out" ] || fail "'$reason': ordinary reload printed '$out'"
  [ -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "'$reason': reload was not queued"
done

# 3. The real init.d script forwards the token and the status.
rm -f "$FORKOP_PENDING_RELOAD_FILE"
out="$("$WORK/init.d" reload config-restore)" || fail "init.d changed the status of a queued restore reload"
[ "$out" = queued ] || fail "init.d did not forward the queued token (got '$out')"
out="$("$WORK/init.d" reload autotune)" || fail "init.d changed the status of a queued autotune reload"
[ "$out" = queued ] || fail "init.d did not forward the queued autotune token (got '$out')"
out="$("$WORK/init.d" reload)" || fail "init.d changed the status of an ordinary queued reload"
[ -z "$out" ] || fail "init.d printed '$out' for an ordinary reload"
[ ! -e "$FORKOP_RUNTIME_STATE_DIR/runtime.log" ] || fail "a queued request reached the runtime"

# 4. Every queued request leaves a distinct marker, also within one second
#    and with the same reason (initd.uc and state.uc writers alike).
for _ in 1 2 3; do
  initd config-restore > /dev/null
  first="$(stamp)"
  initd config-restore > /dev/null
  [ "$(stamp)" != "$first" ] || fail "initd.uc rewrote an identical pending marker"
  "$REAL_UCODE" -L "$LIB" "$STATE_UC" mark-pending-reload "$FORKOP_PENDING_RELOAD_FILE" reload_busy
  first="$(stamp)"
  "$REAL_UCODE" -L "$LIB" "$STATE_UC" mark-pending-reload "$FORKOP_PENDING_RELOAD_FILE" reload_busy
  [ "$(stamp)" != "$first" ] || fail "state.uc rewrote an identical pending marker"
  [ "$(sed -n 1p "$FORKOP_PENDING_RELOAD_FILE")" = "reason=reload_busy" ] || fail "state.uc marker lost its reason"
done

# 5. A free lock runs the reload: no token, the runtime reload happens.
kill "$holder"; wait "$holder" 2>/dev/null || true; holder=""
rm -f "$FORKOP_RELOAD_LOCK_DIR/pid"; rmdir "$FORKOP_RELOAD_LOCK_DIR"
rm -f "$FORKOP_PENDING_RELOAD_FILE"
out="$("$WORK/init.d" reload config-restore)" || fail "a completed restore reload failed"
[ -z "$out" ] || fail "a completed restore reload printed '$out'"
grep -q '^runtime reload reload config-restore$' "$FORKOP_RUNTIME_STATE_DIR/runtime.log" || fail "restore reload did not run"
[ ! -e "$FORKOP_RELOAD_LOCK_DIR" ] || fail "reload lock not released"

printf 'reload_queue_ack: PASS\n'
