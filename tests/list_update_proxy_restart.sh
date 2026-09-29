#!/usr/bin/env bash
set -euo pipefail

# A list download through the service proxy that failed while the proxy was
# being restarted is downloaded again under reload.lock (UC-057 follow-up).
#
# The list worker downloads its sources before it takes reload.lock. A DNS
# failover switch or a subscription update may take the free lock meanwhile
# and stop and start sing-box, the service proxy the downloads go through.
# The worker used to give up on a source after three attempts two seconds
# apart and fail the whole update ("Failed to preflight list source"); when
# a list-source change had started that update, every later reload turned
# into a failing list-content reload until the next successful update. Under
# reload.lock nothing restarts the proxy, so a proxied source that failed is
# downloaded again once the worker holds the lock. A direct download is not:
# its failure does not depend on the proxy, and the update fails without
# holding the lock. A proxied source that fails under the lock as well still
# fails the update, which releases the lock and its record.
#
# The worker is the real components/updates.uc; its locks go through the
# real service/state.uc.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_LIB="$ROOT_DIR/forkop/files/usr/lib"
REAL_SLEEP="$(command -v sleep)"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

pids=()
cleanup() {
  local pid
  for pid in "${pids[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK_DIR/events"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$EVENTS" ] || sed 's/^/  event: /' "$EVENTS" >&2
  [ ! -s "$WORK_DIR/worker.log" ] || sed 's/^/  worker: /' "$WORK_DIR/worker.log" >&2
  exit 1
}

RUN="$WORK_DIR/run"
export RELOAD_LOCK="$RUN/reload.lock" EVENTS WORK_DIR REAL_LIB REAL_SLEEP
mkdir -p "$WORK_DIR/bin" "$RUN" "$WORK_DIR/rulesets"
: >"$EVENTS"

# A library with the real modules and a rule-set cache that changes nothing.
LIB="$WORK_DIR/lib"
mkdir -p "$LIB/singbox"
for entry in "$REAL_LIB"/*; do [ "${entry##*/}" = singbox ] || ln -s "$entry" "$LIB/${entry##*/}"; done
for entry in "$REAL_LIB"/singbox/*; do ln -s "$entry" "$LIB/singbox/${entry##*/}"; done
rm "$LIB/singbox/ruleset_cache.uc"
printf 'exit(1);\n' >"$LIB/singbox/ruleset_cache.uc"

cat >"$WORK_DIR/bin/dig" <<'SH'
#!/bin/sh
printf '192.0.2.1\n'
SH
# curl: with $WORK_DIR/restart present, the first request starts a restart of
# the service proxy: the restarting process (the DNS failover apply) takes
# reload.lock and the proxy refuses connections until $WORK_DIR/proxy.down is
# gone. With $WORK_DIR/unreachable present, the source never answers.
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
if [ -e "$WORK_DIR/restart" ]; then
  rm -f "$WORK_DIR/restart"
  ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" acquire-runtime-dir-lock "$RELOAD_LOCK" "$(cat "$WORK_DIR/holder.pid")" || exit 99
  : >"$WORK_DIR/proxy.down"
fi
if [ -e "$RELOAD_LOCK" ]; then held=held; else held=free; fi
proxy=direct
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -x) proxy=proxied; shift 2 ;;
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if { [ "$proxy" = proxied ] && [ -e "$WORK_DIR/proxy.down" ]; } || [ -e "$WORK_DIR/unreachable" ]; then
  printf 'download %s lock=%s fail\n' "$proxy" "$held" >>"$EVENTS"
  exit 7
fi
printf 'download %s lock=%s ok\n' "$proxy" "$held" >>"$EVENTS"
printf 'new.example\n' >"$output"
SH
# The pause between download attempts, shortened.
cat >"$WORK_DIR/bin/sleep" <<'SH'
#!/bin/sh
[ "$*" != 2 ] || exec "$REAL_SLEEP" 0.1
exec "$REAL_SLEEP" "$@"
SH
cat >"$WORK_DIR/bin/init-forkop" <<'SH'
#!/bin/sh
printf 'init %s\n' "$*" >>"$EVENTS"
SH
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
[ "$*" = '-j list table inet forkop' ] && printf '{"nftables":[]}\n'
exit 0
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
chmod +x "$WORK_DIR/bin/"*

state() { ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" "$@"; }
failures() { grep -c ' fail$' "$EVENTS" || true; }
three_failures() { [ "$(failures)" -ge 3 ]; }

# start_worker PROXY MARKER: a list update, through the service proxy with
# PROXY=1, with $WORK_DIR/MARKER in place (see curl above).
start_worker() {
  : >"$EVENTS"
  rm -rf "$WORK_DIR/generation" "$WORK_DIR/cache" "$WORK_DIR/ruleset-cache" "${RUN:?}"/*
  rm -f "$WORK_DIR/restart" "$WORK_DIR/proxy.down" "$WORK_DIR/unreachable"
  : >"$WORK_DIR/$2"
  mkdir -p "$WORK_DIR/cache"
  printf '{"version":3,"rules":[{"domain_suffix":["old.example"]}]}\n' >"$WORK_DIR/rulesets/alpha-remote-domains-ruleset.json"
  cat >"$WORK_DIR/uci.state" <<'UCI'
forkop.settings=settings
forkop.settings.update_interval=1d
forkop.alpha=section
forkop.alpha.enabled=1
forkop.alpha.action=connection
forkop.alpha.remote_domain_lists=https://lists.test/domains.txt
UCI
  if [ "$1" = 1 ]; then
    printf 'forkop.settings.download_lists_via_proxy=1\nforkop.settings.download_lists_via_proxy_section=alpha\n' \
      >>"$WORK_DIR/uci.state"
  fi
  env PATH="$WORK_DIR/bin:$PATH" \
    FORKOP_LIB="$LIB" \
    FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
    FORKOP_RUNTIME_LIST_GENERATION_DIR="$WORK_DIR/generation" \
    FORKOP_RULESET_CACHE_DIR="$WORK_DIR/ruleset-cache" \
    TMP_RULESET_FOLDER="$WORK_DIR/rulesets" \
    FORKOP_RUNTIME_STATE_DIR="$RUN" \
    FORKOP_RELOAD_LOCK_DIR="$RELOAD_LOCK" \
    FORKOP_LIST_UPDATE_PID_FILE="$RUN/list.pid" \
    FORKOP_PENDING_RELOAD_FILE="$RUN/reload.pending" \
    FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/cache" \
    FORKOP_SERVICE_INIT="$WORK_DIR/bin/init-forkop" \
    NFT_TABLE_NAME=forkop \
    ucode -L "$LIB" "$LIB/components/updates.uc" list-update >"$WORK_DIR/worker.log" 2>&1 &
  worker=$!
  pids+=("$worker")
}

# finish_worker: the worker's exit status in $status.
finish_worker() {
  wait_until 60 process_gone "$worker" || fail "$1: the list update did not finish"
  status=0
  wait "$worker" || status=$?
  [ ! -e "$RELOAD_LOCK" ] || fail "$1: reload.lock was left behind"
  [ ! -e "$RUN/list.pid" ] || fail "$1: the list update left its PID file behind"
}

applied() { grep -q 'new.example' "$WORK_DIR/rulesets/alpha-remote-domains-ruleset.json"; }

# 1. The service proxy restarts while the worker downloads through it; the
#    restart ends after all three attempts failed.
"$REAL_SLEEP" 600 &
holder=$!
pids+=("$holder")
printf '%s\n' "$holder" >"$WORK_DIR/holder.pid"
start_worker 1 restart
wait_until 30 three_failures || fail "1: the downloads did not fail while the service proxy restarted"
rm -f "$WORK_DIR/proxy.down"
state release-runtime-dir-lock "$RELOAD_LOCK" "$holder" || fail "1: the restart could not release reload.lock"
finish_worker 1
[ "$status" = 0 ] || fail "1: the list update failed after the service proxy restarted (status $status)"
grep -qx 'download proxied lock=held ok' "$EVENTS" || fail "1: the failed source was not downloaded again under reload.lock"
applied || fail "1: the list update did not apply the source"
grep -qx 'init reload list-content' "$EVENTS" || fail "1: the list update did not apply its generation"

# 2. A direct download is not retried under reload.lock.
start_worker 0 unreachable
finish_worker 2
[ "$status" != 0 ] || fail "2: the list update with an unreachable source succeeded"
[ "$(failures)" = 3 ] || fail "2: a direct download was attempted $(failures) times"
if grep -q 'lock=held' "$EVENTS"; then
  fail "2: a direct download was retried under reload.lock"
fi
applied && fail "2: the failed list update changed the active rule set"

# 3. A proxied source that fails under reload.lock as well fails the update.
start_worker 1 unreachable
finish_worker 3
[ "$status" != 0 ] || fail "3: the list update with an unreachable proxied source succeeded"
grep -qx 'download proxied lock=held fail' "$EVENTS" || fail "3: the proxied source was not retried under reload.lock"
applied && fail "3: the failed list update changed the active rule set"
if grep -q '^init ' "$EVENTS"; then
  fail "3: the failed list update reloaded"
fi

printf 'list_update_proxy_restart: ok\n'
