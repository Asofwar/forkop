#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB_DIR="$ROOT_DIR/forkop/files/usr/lib"
CLI="$ROOT_DIR/tests/fixtures/process_identity_cli.uc"
STATE_DIR="$(mktemp -d)"
sleep 300 &
foreign_pid=$!
cleanup() {
    kill "$foreign_pid" 2>/dev/null || true
    if [ -n "${worker_pid:-}" ]; then
        kill "$worker_pid" 2>/dev/null || true
    fi
    if [ -n "${supervisor_pid:-}" ]; then
        kill "$supervisor_pid" 2>/dev/null || true
    fi
    if [ -f "$STATE_DIR/legacy-child.pid" ]; then
        kill "$(head -n 1 "$STATE_DIR/legacy-child.pid")" 2>/dev/null || true
    fi
    rm -rf "$STATE_DIR"
}
trap cleanup EXIT HUP INT TERM

PID_FILE="$STATE_DIR/worker.pid"
ucode -L "$LIB_DIR" "$CLI" record "$PID_FILE" "$foreign_pid"
[ "$(wc -l < "$PID_FILE")" -eq 2 ] || exit 1
ucode -L "$LIB_DIR" "$LIB_DIR/core/pidfile_cli.uc" record "$foreign_pid" "$STATE_DIR/child.pid"
[ "$(wc -l < "$STATE_DIR/child.pid")" -eq 2 ] || exit 1

# A live but unrelated PID must never be signalled as a Forkop ucode worker.
if ucode -L "$LIB_DIR" "$CLI" signal "$PID_FILE" ucode worker KILL; then
    exit 1
fi
kill -0 "$foreign_pid"

# Reused PID simulation: executable/cmdline still match, but starttime does not.
printf '%s\n%s\n' "$foreign_pid" 1 > "$PID_FILE"
if ucode -L "$LIB_DIR" "$CLI" signal "$PID_FILE" sleep 300 KILL; then
    exit 1
fi
kill -0 "$foreign_pid"

# Legacy PID-only files may not trigger KILL even for a matching executable.
printf '%s\n' "$foreign_pid" > "$PID_FILE"
if ucode -L "$LIB_DIR" "$CLI" signal "$PID_FILE" sleep 300 KILL; then
    exit 1
fi
kill -0 "$foreign_pid"

WORKER="$STATE_DIR/worker.uc"
printf '%s\n' 'while (true) system("sleep 1");' > "$WORKER"
ucode -L "$LIB_DIR" "$WORKER" worker >/dev/null 2>&1 &
worker_pid=$!
ucode -L "$LIB_DIR" "$CLI" record "$PID_FILE" "$worker_pid"
ucode -L "$LIB_DIR" "$CLI" worker-signal "$PID_FILE" "$LIB_DIR" "$WORKER" TERM
wait "$worker_pid" 2>/dev/null || true
if kill -0 "$worker_pid" 2>/dev/null; then
    exit 1
fi
ucode -L "$LIB_DIR" "$WORKER" worker >/dev/null 2>&1 &
worker_pid=$!
ucode -L "$LIB_DIR" "$CLI" record "$PID_FILE" "$worker_pid"
ucode -L "$LIB_DIR" "$CLI" worker-signal "$PID_FILE" "$LIB_DIR" "$WORKER" KILL
wait "$worker_pid" 2>/dev/null || true
if kill -0 "$worker_pid" 2>/dev/null; then
    exit 1
fi

SUPERVISOR="$ROOT_DIR/tests/fixtures/dpi_snapshot_supervisor.uc"
ucode -L "$LIB_DIR" "$SUPERVISOR" supervisor example 4000 old "$STATE_DIR/legacy-child.pid" >/dev/null 2>&1 &
supervisor_pid=$!
printf '%s\n' "$supervisor_pid" > "$STATE_DIR/legacy-supervisor.pid"
sleep 1
[ -s "$STATE_DIR/legacy-child.pid" ] || exit 1
ucode -L "$LIB_DIR" "$CLI" promote-child "$STATE_DIR/legacy-child.pid" "$STATE_DIR/legacy-supervisor.pid" "$LIB_DIR" "$SUPERVISOR"
[ "$(wc -l < "$STATE_DIR/legacy-child.pid")" -eq 2 ] || exit 1
printf '%s\n' "$foreign_pid" > "$STATE_DIR/foreign-child.pid"
if ucode -L "$LIB_DIR" "$CLI" promote-child "$STATE_DIR/foreign-child.pid" "$STATE_DIR/legacy-supervisor.pid" "$LIB_DIR" "$SUPERVISOR"; then
    exit 1
fi
kill -0 "$foreign_pid"

printf 'process_identity: PASS\n'
