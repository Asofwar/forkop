#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB_DIR="$ROOT_DIR/forkop/files/usr/lib"
SUPERVISOR="$ROOT_DIR/tests/fixtures/dpi_snapshot_supervisor.uc"
CLI="$ROOT_DIR/tests/fixtures/dpi_snapshot_cli.uc"
STATE_DIR="$(mktemp -d)"
PID_DIR="$STATE_DIR/pid"
CHILD_DIR="$STATE_DIR/child-pid"
LOG_DIR="$STATE_DIR/log"
SNAPSHOT="$STATE_DIR/previous.json"
mkdir -p "$PID_DIR" "$CHILD_DIR" "$LOG_DIR"

cleanup() {
    for file in "$PID_DIR"/*.pid "$CHILD_DIR"/*.pid; do
        [ -f "$file" ] || continue
        pid="$(cat "$file")"
        case "$pid" in *[!0-9]*|'') continue;; esac
        kill "$pid" 2>/dev/null || true
    done
    rm -rf "$STATE_DIR"
}
trap cleanup EXIT HUP INT TERM

ucode -L "$LIB_DIR" "$SUPERVISOR" supervisor example 4000 old "$CHILD_DIR/example.pid" >"$LOG_DIR/example.log" 2>&1 &
old_pid=$!
echo "$old_pid" > "$PID_DIR/example.pid"
sleep 1
[ -s "$CHILD_DIR/example.pid" ] || exit 1

ucode -L "$LIB_DIR" "$CLI" snapshot "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"
[ -s "$SNAPSHOT" ] || exit 1

kill "$old_pid" "$(cat "$CHILD_DIR/example.pid")"
wait "$old_pid" 2>/dev/null || true
rm -f "$PID_DIR/example.pid" "$CHILD_DIR/example.pid"

ucode -L "$LIB_DIR" "$CLI" restore "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"
new_pid="$(cat "$PID_DIR/example.pid")"
[ "$new_pid" != "$old_pid" ] || exit 1
kill -0 "$new_pid"
kill -0 "$(cat "$CHILD_DIR/example.pid")"

printf 'dpi_runtime_snapshot: PASS\n'
