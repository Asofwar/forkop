#!/usr/bin/env bash
set -euo pipefail

# Forkop stopped by the user is told apart from Forkop that is down without a
# stop (a failed start, a crash) in the UI state, the service status and
# health (UC-056, D-15(a)).
#
# Before: both were "stopped but enabled" / running 0, and health reported
# the service as "error" either way, so the Overview could not say "stopped
# by the user" and a deliberate stop looked like a failure.
#
# Now service/ui.uc get-ui-state and diagnostics/runtime.uc get-status report
# stopped_by_user while the explicit stop holds the runtime down, and
# diagnostics/health.uc reports the service as "stopped" (not "error") then.
# A restore recorded as not started (the runtime was not started) is no
# failure either.
#
# ui.uc, runtime.uc, state.uc and health.uc are real; nothing here runs a
# runtime, so it is down.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/tmp" "$WORK_DIR/ui"
printf 'forkop.settings=settings\n' >"$WORK_DIR/uci.state"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export FORKOP_LIB="$LIB"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export FORKOP_HISTORY_FILE="$WORK_DIR/history.jsonl"
export FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export FORKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/reload.pending"
export FORKOP_START_IN_PROGRESS_FILE="$WORK_DIR/run/start.in-progress"
export FORKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export FORKOP_BIN="$WORK_DIR/bin/forkop"
export FORKOP_UI_STATE_DIR="$WORK_DIR/ui"
export FORKOP_UI_SERVICE_ACTION_DIR="$WORK_DIR/ui/service-actions"
export FORKOP_UI_SERVICE_ACTION_LOCK_DIR="$WORK_DIR/ui/service-actions.lock"
export FORKOP_UI_LATENCY_ACTION_DIR="$WORK_DIR/ui/latency-actions"
export FORKOP_UI_COMPONENT_ACTION_DIR="$WORK_DIR/ui/component-actions"
export FORKOP_UI_SUBSCRIPTION_ACTION_DIR="$WORK_DIR/ui/subscription-actions"
export FORKOP_UI_SING_BOX_VERSION_CACHE_FILE="$WORK_DIR/ui/sing-box-version"
export FORKOP_UI_SING_BOX_VARIANT_STATE_FILE="$WORK_DIR/missing-variant"
export FORKOP_UI_SING_BOX_BIN_PATH="$WORK_DIR/missing-sing-box"
export ZAPRET_PROVIDER_NFQWS_BIN="$WORK_DIR/missing-nfqws"
export ZAPRET2_PROVIDER_NFQWS2_BIN="$WORK_DIR/missing-nfqws2"
export BYEDPI_BIN="$WORK_DIR/missing-ciadpi"
unset FORKOP_UI_ACTION_TRACKED
STOP_MARKER="$WORK_DIR/run/stop.requested"

# Nothing here may reach the host's syslog, nftables, procd or services.
for tool in logger nft ubus ip init forkop; do
  printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/$tool"
done
chmod +x "$WORK_DIR/bin/"*

forkop_field() { # forkop_field <json file> <field>
  ucode -e 'let v = json(require("fs").readfile(ARGV[0])); v = v.service ? v.service.forkop : v; print(v[ARGV[1]], "\n");' \
    "$1" "$2"
}
ui_state() { ucode -L "$LIB" "$LIB/service/ui.uc" get-ui-state >"$WORK_DIR/ui.json"; }
get_status() { ucode -L "$LIB" "$LIB/diagnostics/runtime.uc" get-status >"$WORK_DIR/status.json"; }
health() { # health <forkop object> [events]
  printf '{"ui":{"service":{"forkop":%s,"sing_box":{"running":0}}},"guard":false,"package_pending":false,"events":%s}\n' \
    "$1" "${2:-[]}" >"$WORK_DIR/fixture.json"
  ucode -L "$LIB" "$LIB/diagnostics/health.uc" fixture "$WORK_DIR/fixture.json" >"$WORK_DIR/health.json"
}
health_field() {
  ucode -e 'let v = json(require("fs").readfile(ARGV[0])); for (let k in split(ARGV[1], ".")) v = v[k]; print(v, "\n");' \
    "$WORK_DIR/health.json" "$1"
}

# 1. Down after an explicit stop: stopped by the user.
printf 'stop\n' >"$STOP_MARKER"
ui_state
[ "$(forkop_field "$WORK_DIR/ui.json" running)" = 0 ] || fail "fixture: the runtime is running: $(cat "$WORK_DIR/ui.json")"
[ "$(forkop_field "$WORK_DIR/ui.json" stopped_by_user)" = 1 ] ||
  fail "the UI state does not say Forkop was stopped by the user: $(cat "$WORK_DIR/ui.json")"
get_status
[ "$(forkop_field "$WORK_DIR/status.json" stopped_by_user)" = 1 ] ||
  fail "get_status does not say Forkop was stopped by the user: $(cat "$WORK_DIR/status.json")"

# 2. Down without a stop (a failed start, a crash): not stopped by the user.
rm -f "$STOP_MARKER"
ui_state
[ "$(forkop_field "$WORK_DIR/ui.json" stopped_by_user)" = 0 ] ||
  fail "the UI state calls a runtime down without a stop stopped by the user: $(cat "$WORK_DIR/ui.json")"
get_status
[ "$(forkop_field "$WORK_DIR/status.json" stopped_by_user)" = 0 ] ||
  fail "get_status calls a runtime down without a stop stopped by the user: $(cat "$WORK_DIR/status.json")"

# 3. Health: stopped by the user is "stopped", not a failure; down without a
#    stop stays an error; a failed change still is one.
health '{"running":0,"stopped_by_user":1}'
[ "$(health_field service.forkop)" = stopped ] || fail "health: $(cat "$WORK_DIR/health.json")"
[ "$(health_field overall)" = stopped ] || fail "health overall while stopped by the user: $(cat "$WORK_DIR/health.json")"
[ "$(health_field recovery.pending)" = false ] || fail "health: a stop is no pending recovery"
health '{"running":0,"stopped_by_user":0}'
[ "$(health_field service.forkop)" = error ] || fail "health of a runtime down without a stop: $(cat "$WORK_DIR/health.json")"
[ "$(health_field overall)" = error ] || fail "health overall of a runtime down without a stop"
health '{"running":0,"stopped_by_user":1}' '[{"kind":"reload","status":"failure","timestamp":42}]'
[ "$(health_field overall)" = error ] || fail "a failed change while stopped by the user is not an error"
# A restore that left the runtime stopped is recorded and is no failure.
health '{"running":0,"stopped_by_user":1}' '[{"kind":"restore","status":"not_started","timestamp":42}]'
[ "$(health_field recovery.last_event.status)" = not_started ] || fail "a not-started restore is not kept: $(cat "$WORK_DIR/health.json")"
[ "$(health_field overall)" = stopped ] || fail "a not-started restore made health an error"
ucode -L "$LIB" "$LIB/diagnostics/health.uc" record restore not_started || fail "a not-started restore cannot be recorded"
grep -Eq '"status": *"not_started"' "$FORKOP_HISTORY_FILE" || fail "a not-started restore is not in the history"

printf 'stopped by user state checks passed\n'
