#!/usr/bin/env bash
set -euo pipefail

# Tests signal only their own processes (UC-233).
#
# A test stores the PID of a process it starts and signals that PID later:
# when it cleans up, between its cases, or after the code under test may
# already have ended the process. By then the number can name another
# process: PIDs are reused once a process has exited and been reaped, and
# under tests/run.sh that is often a process of another test. A cleanup that
# ran `kill -KILL -- "-$pid" || kill -KILL "$pid"`, `pkill -P "$pid"` or
# `kill "$pid" 2>/dev/null || true` killed that process, or its whole process
# group; deferred_start_retry killed a process of worker_pid_reuse so.
#
# tests/helpers/owned_processes.sh signals a PID, its process group or its
# children only while they carry the mark of the test or are children of the
# shell that signals, checked right before the signal. Part 1 holds the
# helper against processes under PIDs the test stored that are not its own
# (what a stored PID names once the number was reused): a host process, a
# process and a process group of another test.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

WORK_DIR="$(mktemp -d)"
OWN_MARK="$FORKOP_TEST_OWNER"
# The processes of "another test" carry a mark of their own.
OTHER_MARK="other-$OWN_MARK"
OTHERS=()
OWN=()
cleanup() {
  FORKOP_TEST_OWNER="$OTHER_MARK" owned_kill KILL "${OTHERS[@]}" || true
  FORKOP_TEST_OWNER="$OWN_MARK" owned_kill KILL "${OWN[@]}" || true
  # The host processes end with the work directory.
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# shellcheck disable=SC2016 # expanded by the sh that runs it
GATE_LOOP='while [ -d "$1" ]; do sleep 0.1; done'
# A group whose leader exits at once and leaves a member behind.
# shellcheck disable=SC2016
ORPHANING='(while [ -d "$1" ]; do sleep 0.1; done) & exit 0'
# sh -c "$ORPHAN" orphan COMMAND...: starts COMMAND through a shell that
# exits at once, so that it is no child of the test's shell, in the
# environment of that shell, and prints its PID.
# shellcheck disable=SC2016
ORPHAN='"$@" </dev/null >/dev/null 2>&1 & echo "$!"'
SH_EXE="$(basename "$(readlink -f /bin/sh)")"
running() { process_running "$1"; }
carries_mark() {
  local environ
  environ="$(tr '\0' '\n' <"/proc/$1/environ")" || return 1
  case "$environ" in *"FORKOP_TEST_OWNER=$2"*) return 0 ;; esac
  return 1
}
group_members() { pgrep -g "$1" 2>/dev/null | while read -r pid; do process_running "$pid" && echo "$pid"; done; }
group_size() { group_members "$1" | wc -l; }

# --- Part 1: the helper ------------------------------------------------------

# 1. A stored PID that names a host process: neither the process, nor its
#    children, nor a group of that number is signalled.
HOST="$(env -u FORKOP_TEST_OWNER sh -c "$ORPHAN" orphan sh -c "$GATE_LOOP" host "$WORK_DIR")"
wait_until 10 process_exec_is "$HOST" "$SH_EXE" || fail "a host process did not start"
owned_process "$HOST" && fail "a host process counts as the test's"
if owned_kill KILL "$HOST"; then fail "owned_kill reported a host process as signalled"; fi
owned_kill_children KILL "$HOST"
sleep 0.2
running "$HOST" || fail "owned_kill signalled a host process"
wait_until 10 test -n "$(pgrep -P "$HOST")" || fail "the host process has no child to check"
for child in $(pgrep -P "$HOST"); do
  owned_process "$child" && fail "the child of a host process counts as the test's"
done

# 2. A stored PID that names a process of another test, and a stored number
#    that is the process group of another test (started under setsid, like
#    the actors of the lifecycle tests), with its leader alive or gone.
OTHER="$(FORKOP_TEST_OWNER="$OTHER_MARK" sh -c "$ORPHAN" orphan sh -c "$GATE_LOOP" other "$WORK_DIR")"
OTHER_GROUP="$(FORKOP_TEST_OWNER="$OTHER_MARK" sh -c "$ORPHAN" orphan setsid sh -c "$GATE_LOOP" other-group "$WORK_DIR")"
ORPHANED_GROUP="$(FORKOP_TEST_OWNER="$OTHER_MARK" sh -c "$ORPHAN" orphan setsid sh -c "$ORPHANING" orphaned "$WORK_DIR")"
OTHERS+=("$OTHER" "$OTHER_GROUP" "$ORPHANED_GROUP")
wait_until 10 process_gone "$ORPHANED_GROUP" || fail "the leader of another test's group did not exit"
wait_until 10 test "$(group_size "$OTHER_GROUP")" -ge 2 || fail "another test's process group did not start"
wait_until 10 test "$(group_size "$ORPHANED_GROUP")" -ge 1 || fail "another test's leaderless group did not start"
for pid in "$OTHER" "$OTHER_GROUP" "$ORPHANED_GROUP"; do
  if owned_kill KILL "$pid"; then fail "owned_kill reported a process or group of another test ($pid) as signalled"; fi
  owned_kill_children KILL "$pid"
done
sleep 0.2
running "$OTHER" || fail "owned_kill signalled another test's process"
running "$OTHER_GROUP" || fail "owned_kill signalled another test's process group"
[ "$(group_size "$ORPHANED_GROUP")" -ge 1 ] || fail "owned_kill signalled another test's group whose leader had exited"
# Its own mark reaches all of them, a group whose leader has exited too: the
# helper keeps what `kill -- -$pid` did for a test's own group.
FORKOP_TEST_OWNER="$OTHER_MARK" owned_kill KILL "$OTHER" "$OTHER_GROUP" "$ORPHANED_GROUP" ||
  fail "owned_kill did not signal processes under their own mark"
wait_until 10 process_gone "$OTHER" || fail "a process was not killed under its own mark"
wait_until 10 test "$(group_size "$OTHER_GROUP")" = 0 || fail "a process group was not killed under its own mark"
wait_until 10 test "$(group_size "$ORPHANED_GROUP")" = 0 || fail "a group whose leader had exited was not killed under its own mark"

# 3. The test's own processes, which are no children of its shell: a
#    process, a group whose leader has exited, and the children of a
#    process, the host's child among them left alone.
MINE="$(sh -c "$ORPHAN" orphan sleep 300)"
OWN+=("$MINE")
wait_until 10 process_exec_is "$MINE" sleep || fail "the test's process did not start"
owned_process "$MINE" || fail "the test's own process does not count as its own"
owned_kill TERM "$MINE" || fail "owned_kill did not signal the test's process"
wait_until 10 process_gone "$MINE" || fail "the test's process was not signalled"
# Its PID, once the process has exited, names nothing of the test's.
if owned_kill TERM "$MINE"; then fail "owned_kill reported a process that has exited as signalled"; fi

OWN_GROUP="$(sh -c "$ORPHAN" orphan setsid sh -c "$ORPHANING" own-orphaned "$WORK_DIR")"
OWN+=("$OWN_GROUP")
wait_until 10 process_gone "$OWN_GROUP" || fail "the leader of the test's group did not exit"
wait_until 10 test "$(group_size "$OWN_GROUP")" -ge 1 || fail "the test's leaderless group did not start"
owned_kill KILL "$OWN_GROUP" || fail "owned_kill did not signal the test's group whose leader had exited"
wait_until 10 test "$(group_size "$OWN_GROUP")" = 0 || fail "the test's group whose leader had exited survived"

# shellcheck disable=SC2016 # expanded by the parent sh
PARENT="$(sh -c "$ORPHAN" orphan sh -c 'sleep 300 & env -u FORKOP_TEST_OWNER sh -c "$1" host-child "$2" & wait' \
  parent "$GATE_LOOP" "$WORK_DIR")"
OWN+=("$PARENT")
# One child of the test's (sleep) and one of the host's (sh once env has
# exec'd it without the mark).
children_started() {
  local child marked=0 host=0
  for child in $(pgrep -P "$PARENT"); do
    if process_exec_is "$child" sleep && owned_process "$child"; then
      marked=$((marked + 1))
      MARKED_CHILD=$child
    elif process_exec_is "$child" "$SH_EXE" && ! owned_process "$child"; then
      host=$((host + 1))
      HOST_CHILD=$child
    fi
  done
  [ "$marked" = 1 ] && [ "$host" = 1 ]
}
wait_until 10 children_started || fail "the test's process did not start one child of its own and one of the host's"
owned_kill_children KILL "$PARENT"
wait_until 10 process_gone "$MARKED_CHILD" || fail "owned_kill_children did not signal the test's child"
sleep 0.2
running "$HOST_CHILD" || fail "owned_kill_children signalled a host process"
owned_kill KILL "$PARENT" || true

# 3b. A subshell job of the test's shell shows the environment of that shell,
#     from before the mark was set: it is the test's as a child of the shell
#     that signals it, and of no other shell.
(while [ -d "$WORK_DIR" ]; do sleep 0.1; done) &
JOB=$!
disown "$JOB"
OWN+=("$JOB")
carries_mark "$JOB" "$OWN_MARK" && fail "fixture: a subshell job carries the mark"
owned_process "$JOB" || fail "a subshell job of the test's shell does not count as the test's"
(owned_process "$JOB") && fail "a job of the test's shell counts as one of a subshell's"
owned_kill TERM "$JOB" || fail "owned_kill did not signal a subshell job of the test's shell"
wait_until 10 process_gone "$JOB" || fail "the subshell job was not signalled"

# 4. Never the test's own shell or a subshell of it, never a zombie, and a
#    variable that only holds the mark is no mark.
owned_process "$$" && fail "the test's own shell counts as one of its processes"
(owned_process "$BASHPID") && fail "a subshell of the test counts as one of its processes"
ZOMBIE_PARENT="$(sh -c "$ORPHAN" orphan sh -c 'sleep 0 & exec sleep 300' zombie-parent)"
OWN+=("$ZOMBIE_PARENT")
zombie_child() {
  local child state
  child="$(pgrep -P "$ZOMBIE_PARENT")" || return 1
  state="$(sed 's/.*) //' "/proc/$child/stat" | cut -d' ' -f1)"
  [ "$state" = Z ] && ZOMBIE="$child"
}
wait_until 10 zombie_child || fail "no zombie to check"
owned_process "$ZOMBIE" && fail "a zombie counts as a process of the test"
owned_kill KILL "$ZOMBIE_PARENT" || true
HOSTILE="$(env -u FORKOP_TEST_OWNER "X_FORKOP_TEST_OWNER=$OWN_MARK" "FORKOP_TEST_OWNER_COPY=$OWN_MARK" \
  sh -c "$ORPHAN" orphan sh -c "$GATE_LOOP" hostile "$WORK_DIR")"
LONGER="$(FORKOP_TEST_OWNER="${OWN_MARK}x" sh -c "$ORPHAN" orphan sh -c "$GATE_LOOP" longer "$WORK_DIR")"
wait_until 10 process_exec_is "$HOSTILE" "$SH_EXE" || fail "the process did not start"
wait_until 10 process_exec_is "$LONGER" "$SH_EXE" || fail "the process did not start"
owned_process "$HOSTILE" && fail "a process with the mark in another variable counts as the test's"
owned_process "$LONGER" && fail "a process with a longer mark counts as the test's"

# 5. A group of cases sets a mark of its own: the processes of the test
#    before it are not the group's, and the group's are not the test's.
BEFORE="$(sh -c "$ORPHAN" orphan sleep 300)"
OWN+=("$BEFORE")
wait_until 10 process_exec_is "$BEFORE" sleep || fail "the test's process did not start"
(
  owned_processes_init
  [ "$FORKOP_TEST_OWNER" != "$OWN_MARK" ] || fail "a group of cases kept the test's mark"
  owned_process "$BEFORE" && fail "a process of the test counts as the group's"
  group_process="$(sh -c "$ORPHAN" orphan sleep 300)"
  printf '%s\n' "$group_process" >"$WORK_DIR/group.pid"
  wait_until 10 process_exec_is "$group_process" sleep || fail "the group's process did not start"
  owned_process "$group_process" || fail "the group's process does not count as the group's"
)
GROUP_PROCESS="$(cat "$WORK_DIR/group.pid")"
owned_process "$GROUP_PROCESS" && fail "a process of a group of cases counts as the test's"
[ "$FORKOP_TEST_OWNER" = "$OWN_MARK" ] || fail "a group of cases changed the test's mark"
FORKOP_TEST_OWNER="$(tr '\0' '\n' <"/proc/$GROUP_PROCESS/environ" | sed -n 's/^FORKOP_TEST_OWNER=//p')" \
  owned_kill KILL "$GROUP_PROCESS" || fail "the group's process was not killed under its mark"
owned_kill KILL "$BEFORE" || fail "the test's process was not killed"

printf 'owned processes checks passed\n'
