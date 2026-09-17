#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
STATE_UC="$FORKOP_LIB/service/state.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# procd can keep reporting an exited child for a moment after /proc no longer
# holds any sing-box. Refusing the transition outright there turns a normal
# hand-off into "ownership is ambiguous" and leaves the service down, which
# matters most during a package upgrade. Waiting is safe; signalling the
# reported PID is not, because it may already have been reused.
#
# The CI runner has no sing-box in /proc, so the process count is genuinely 0
# and only the procd side needs a double.

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/ubus" <<'SH'
#!/usr/bin/env bash
# Report a lingering sing-box PID until the marker file disappears.
if [ -e "${STALE_PID_MARKER:?}" ]; then
  printf '{"sing-box":{"instances":{"instance1":{"running":true,"pid":424242}}}}\n'
else
  printf '{}\n'
fi
SH
cat >"$WORK_DIR/bin/sleep" <<'SH'
#!/usr/bin/env bash
printf 'slept\n' >>"${SLEEP_LOG:?}"
exit 0
SH
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LOGGER_LOG:?}"
exit 0
SH
chmod 0755 "$WORK_DIR/bin/"*

export PATH="$WORK_DIR/bin:$PATH"
export STALE_PID_MARKER="$WORK_DIR/stale" SLEEP_LOG="$WORK_DIR/sleep.log" LOGGER_LOG="$WORK_DIR/logger.log"

run_stop() {
  : >"$SLEEP_LOG"; : >"$LOGGER_LOG"
  ucode -L "$FORKOP_LIB" "$STATE_UC" stop-managed-sing-box-runtime "${1:-3}"
}

# 1. procd keeps reporting a PID that never clears: fail closed after the
#    timeout rather than pretending the runtime was stopped.
: >"$STALE_PID_MARKER"
if run_stop 3; then
  fail "a procd PID that never clears must not be reported as a completed stop"
fi
grep -q 'timed out waiting for stale procd PID' "$LOGGER_LOG" ||
  fail "the timeout must be logged as a refused controlled transition"
[ "$(wc -l <"$SLEEP_LOG")" -ge 3 ] ||
  fail "the stale-PID wait must actually retry for the configured timeout"

# 2. The stale PID clears: the stop succeeds without touching the reported PID.
rm -f "$STALE_PID_MARKER"
run_stop 3 || fail "a converged runtime must report a successful stop"
[ ! -s "$SLEEP_LOG" ] ||
  fail "an already converged runtime must not wait at all"
grep -q 'Controlled sing-box transition refused' "$LOGGER_LOG" &&
  fail "a converged runtime must not log a refused transition"

# 3. The wait must never signal the PID procd reported: it may be reused.
grep -rn 'wait_for_stale_sing_box_service_pid' -A 40 "$STATE_UC" |
  sed -n '/function wait_for_stale_sing_box_service_pid/,/^[0-9]*.function /p' |
  grep -qE '(^|[^a-z_])kill( |\()' &&
  fail "the stale-PID wait must never signal the reported PID"

printf 'stale procd PID checks passed\n'
