#!/usr/bin/env bash
set -euo pipefail

# The deadline helper that install.sh writes (install-deadline.sh) returns as
# soon as its command does (UC-240).
#
# run_command starts the command and a watchdog subshell, which sleeps for
# the deadline in a child (sleep &) and waits for it. Once the command is
# done, run_command stops the watchdog with TERM, and the watchdog's trap sent
# TERM to the sleep and waited for it. A sleep child that has not exec'd yet
# still runs the watchdog's trap handler: it took that TERM as caught, exec'd
# sleep, and the call waited the whole deadline (up to 60 s for the
# installer's service actions) for a command done in milliseconds. A TERM
# that came before the watchdog knew the sleep's pid left the sleep running
# for the deadline. Now the sleep is killed with KILL, which no handler
# takes, in both cases.
#
# 1. A sleep that ignores TERM, as that child did, comes first on PATH: a
#    fast command returns well before the deadline every time, and no sleep
#    is left.
# 2. The real sleep, many calls at once: none of them takes the deadline,
#    and no sleep is left.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"
WORK="$(mktemp -d)"

# shellcheck source=tests/helpers/wait.sh
source "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
source "$ROOT_DIR/tests/helpers/owned_processes.sh"

cleanup() {
  local pid
  if [ -r "${WORK:?}/sleeps" ]; then
    while IFS= read -r pid; do
      owned_kill KILL "$pid" || true
    done <"${WORK:?}/sleeps"
  fi
  rm -rf "${WORK:?}"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }

HELPER="$WORK/install-deadline.sh"
awk '
  /cat > "\$deadline_helper_path" <<'\''EOF'\''/ { capture = 1; next }
  capture && /^EOF$/ { exit }
  capture { print }
' "$INSTALLER" >"$HELPER"
[ -s "$HELPER" ] || fail "failed to extract the installer deadline helper"
chmod 0700 "$HELPER"

REAL_SLEEP="$(command -v sleep)"
mkdir -p "$WORK/bin" "$WORK/calls"
: >"$WORK/sleeps"
export REAL_SLEEP SLEEPS="$WORK/sleeps"

# deadline_call NAME SECONDS COMMAND...: one call of the helper; records its
# status and how long it took in milliseconds in $WORK/calls/NAME.
deadline_call() {
  local name="$1" seconds="$2" started status=0
  shift 2
  started="$(date +%s%N)"
  "$HELPER" run "$seconds" "$WORK/calls/$name.result" "$@" >/dev/null 2>&1 || status=$?
  printf '%s %s\n' "$status" "$((($(date +%s%N) - started) / 1000000))" >"$WORK/calls/$name"
}

# check_call NAME LIMIT_MS: the call succeeded, did not time out and returned
# within LIMIT_MS.
check_call() {
  local status elapsed
  read -r status elapsed <"$WORK/calls/$1" || fail "call $1 recorded nothing"
  [ "$status" = 0 ] || fail "call $1 of a fast command failed with status $status"
  [ ! -e "$WORK/calls/$1.result.timeout" ] || fail "the watchdog of call $1 of a fast command fired"
  [ "$elapsed" -lt "$2" ] ||
    fail "call $1 of a fast command took ${elapsed} ms: it waited for the watchdog's deadline"
}

sleep_left() {
  local pid
  while IFS= read -r pid; do
    owned_process "$pid" && return 0
  done <"$WORK/sleeps"
  return 1
}
no_sleep_left() { ! sleep_left; }

# ---- 1. a sleep that takes TERM as caught ----------------------------------------

# The watchdog's sleep, logged, ignoring TERM. The command itself runs the
# real sleep by its path, long enough that the watchdog has started its
# sleep when run_command stops it.
cat >"$WORK/bin/sleep" <<'SH'
#!/bin/sh
printf '%s\n' "$$" >>"$SLEEPS"
trap '' TERM
exec "$REAL_SLEEP" "$@"
SH
chmod 0755 "$WORK/bin/sleep"
for n in 1 2 3 4 5; do
  PATH="$WORK/bin:$PATH" deadline_call "ignored-$n" 10 "$REAL_SLEEP" 0.5
  check_call "ignored-$n" 5000
done
[ -s "$WORK/sleeps" ] || fail "no watchdog started the sleep on PATH"
wait_until 5 no_sleep_left || fail "a watchdog's sleep outlived its call"
ok "a fast command returns at once although the watchdog's sleep takes TERM as caught"

# ---- 2. many calls at once --------------------------------------------------------

# The watchdog's sleep, logged; it takes TERM as sleep does.
cat >"$WORK/bin/sleep" <<'SH'
#!/bin/sh
printf '%s\n' "$$" >>"$SLEEPS"
exec "$REAL_SLEEP" "$@"
SH
: >"$WORK/sleeps"
round=1
while [ "$round" -le 12 ]; do
  for n in 1 2 3 4 5 6 7 8; do
    PATH="$WORK/bin:$PATH" deadline_call "parallel-$round-$n" 10 true &
  done
  wait
  for n in 1 2 3 4 5 6 7 8; do
    check_call "parallel-$round-$n" 5000
  done
  round=$((round + 1))
done
wait_until 5 no_sleep_left || fail "a watchdog's sleep outlived its call"
ok "none of 96 calls at once of a fast command waits for the deadline"

printf 'installer_deadline_fast_command: PASS\n'
