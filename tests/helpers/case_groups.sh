# shellcheck shell=bash
# Groups of cases of one slow test file that run at the same time. A test
# whose cases mostly wait (the one-second steps of the production code, the
# stand-ins' delays) runs independent groups of them at once instead of one
# after another. Every group must be hermetic: it runs in a subshell of its
# own and builds its own fixture (temporary directory, stand-ins, state), so
# nothing one group does is seen by another.
#
# run_case_groups DIR FUNCTION GROUP...
# Runs `FUNCTION GROUP` for every GROUP at once, each in a background
# subshell with its output in DIR/GROUP.log, waits for all of them and then
# prints the logs in the order of the groups. Returns 1, naming the group,
# when one of them failed.
#
# Call it as a plain command under set -e, never as a condition (after if,
# while or "!", or in a || or && list): bash ignores set -e in everything such
# a condition runs, and a group would then go on after a failed check. It
# refuses to run there.
run_case_groups() {
  local dir="$1" fn="$2" group status=0 errexit=0 i=0
  local -a pids=()
  shift 2
  ( false; true ) &
  wait "$!" || errexit=1
  if [ "$errexit" = 0 ]; then
    printf 'FAIL: run_case_groups runs in a condition or without set -e: a failed check would not stop its group\n' >&2
    return 1
  fi
  mkdir -p "$dir"
  for group in "$@"; do
    ( "$fn" "$group" ) </dev/null >"$dir/$group.log" 2>&1 &
    pids+=("$!")
  done
  for group in "$@"; do
    if wait "${pids[i]}"; then
      cat "$dir/$group.log"
    else
      cat "$dir/$group.log"
      printf 'FAIL: the group of cases %s failed\n' "$group" >&2
      status=1
    fi
    i=$((i + 1))
  done
  return "$status"
}
