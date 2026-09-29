#!/usr/bin/env bash
set -euo pipefail

# UC-016: every backend request to the Clash API controller is bounded. A
# controller that accepts TCP and never answers (a stopped, deadlocked or
# thrashing sing-box) must not hold a UI poll, the readiness probe behind
# start/reload verification, the Priority worker or a latency test for longer
# than the request bounds, and a lock held around the request (reload.lock of
# the automatic latency test) must be released when the bound expires.
#
# The controller double is a ucode socket listener: it accepts connections and
# never answers (or answers GET /proxies only). Requests run through the real
# curl behind a recording wrapper, under a watchdog: before the fix they hang
# until the watchdog kills them.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
RUNTIME_UC="$FORKOP_LIB/diagnostics/runtime.uc"
AUTOTUNE_APPLY_UC="$FORKOP_LIB/autotune/apply.uc"
WORK_DIR="$(mktemp -d)"
LISTENER_PIDS=()
cleanup() {
  local pid
  # Killing the listener closes the held connections, so a curl left behind
  # by a watchdog kill (old code) exits as well.
  for pid in "${LISTENER_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  [ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# shellcheck source=tests/helpers/source_checks.sh
source "$ROOT_DIR/tests/helpers/source_checks.sh"
# shellcheck source=tests/helpers/wait.sh
source "$ROOT_DIR/tests/helpers/wait.sh"

UCODE_BIN="$(command -v ucode)" || fail "ucode is required"
REAL_CURL="$(command -v curl)" || fail "curl is required: the requests run through the real curl"
TIMEOUT_BIN="$(command -v timeout)" || fail "timeout (coreutils) is required as the watchdog"
"$UCODE_BIN" -e 'require("socket");' 2>/dev/null ||
  fail "the ucode socket module is required for the controller double"

# Seconds a request may outlast the bounds its curl carries (process start-up
# of ucode and curl on a loaded CI runner).
SLACK=4
# Watchdog: far past any bound, so a hang is reported as such.
WATCHDOG=30
SECRET='Hung-Controller-Secret'

# --- Static: every curl to the controller carries both bounds ----------------

# The modules that address the controller themselves (its port, its URL
# helper or the external_controller of a generated config) and run curl.
controller_modules=()
while IFS= read -r module; do
  if grep -q -E '"curl"|\bCURL\b|"curl ' "$module"; then
    controller_modules+=("$module")
  fi
done < <(grep -R -l -E 'SB_CLASH_API_CONTROLLER_PORT|clash_api_url\(|external_controller' "$FORKOP_LIB")
printf '%s\n' "${controller_modules[@]}" | grep -Fxq "$RUNTIME_UC" ||
  fail "diagnostics/runtime.uc no longer requests the controller: update this test"
printf '%s\n' "${controller_modules[@]}" | grep -Fxq "$AUTOTUNE_APPLY_UC" ||
  fail "autotune/apply.uc no longer requests the controller: update this test"

# Each curl argument list (`"curl"` or CURL up to the end of its statement)
# names --connect-timeout and --max-time. A curl in a shell string is a
# request of its own line; one to an https:// URL is not the controller, which
# serves plain HTTP only.
static_violations() {
  awk '
    function check(text, where) {
      if (text !~ /--connect-timeout/ || text !~ /--max-time/)
        printf "%s:%d: %s\n", FILENAME, where, first
    }
    /^[[:space:]]*\/\// { next }
    /^[[:space:]]*const[[:space:]]+CURL[[:space:]]*=/ { next }
    /"curl / {
      checked++
      if ($0 !~ /https:\/\//) { first = $0; check($0, FNR) }
      next
    }
    !open && (/"curl"/ || /[[(,][[:space:]]*CURL[[:space:]]*[],]/) {
      open = 1; stmt = ""; start = FNR; first = $0; checked++
    }
    open {
      stmt = stmt $0 "\n"
      if ($0 ~ /;[[:space:]]*$/) { check(stmt, start); open = 0 }
    }
    END {
      if (open) check(stmt, start)
      if (!checked) printf "%s: no curl invocation found\n", FILENAME
    }
  ' "$1"
}
for module in "${controller_modules[@]}"; do
  violations="$(static_violations "$module")"
  [ -z "$violations" ] || {
    printf '%s\n' "$violations" >&2
    fail "a curl to the Clash API controller lacks --connect-timeout or --max-time"
  }
done
clash_connections="$(source_function "$AUTOTUNE_APPLY_UC" clash_connections)" || exit 1
printf '%s\n' "$clash_connections" | grep -Fq -- '"--connect-timeout"' ||
  fail "autotune clash_connections must bound the connect phase"

# --- Controller doubles --------------------------------------------------------

cat >"$WORK_DIR/controller.uc" <<'UC'
// ARGV: mode (hang | answer-proxies), port file.
let socket = require("socket");
let fs = require("fs");
let mode = ARGV[0], port_file = ARGV[1];
let srv = socket.listen("127.0.0.1", 0, null, 64);
if (!srv) {
    warn("listen failed: ", socket.error(), "\n");
    exit(1);
}
fs.writefile(port_file + ".tmp", srv.sockname().port + "\n");
fs.rename(port_file + ".tmp", port_file);
let held = [];
while (true) {
    let conn = srv.accept();
    if (!conn)
        continue;
    if (mode == "answer-proxies") {
        let request = conn.recv(8192) || "";
        if (match(request, /^GET \/proxies HTTP/)) {
            let body = '{"proxies":{"direct":{"type":"Direct"},"proxy-a":{"type":"VLESS"}}}';
            conn.send(sprintf("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
                length(body), body));
            conn.close();
            continue;
        }
    }
    // Accepted and never answered.
    push(held, conn);
}
UC

# start_controller MODE: starts the double in this shell (a command
# substitution would wait for the listener's stdout) and leaves its port in
# CONTROLLER_PORT.
start_controller() {
  local mode="$1" port_file="$WORK_DIR/$1.port"
  "$UCODE_BIN" "$WORK_DIR/controller.uc" "$mode" "$port_file" \
    </dev/null >"$WORK_DIR/$mode.log" 2>&1 &
  LISTENER_PIDS+=("$!")
  wait_until 10 file_nonempty "$port_file" || fail "the $mode controller double did not start"
  CONTROLLER_PORT="$(cat "$port_file")"
}
start_controller hang
HUNG_PORT="$CONTROLLER_PORT"
start_controller answer-proxies
PROXIES_PORT="$CONTROLLER_PORT"

# --- Fixture ---------------------------------------------------------------------

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/etc"
# Records each command line on one line (a newline inside an argument, as in
# -w '\n%{http_code}', becomes a space), then runs the real curl.
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
{
  printf 'ARGV:'
  for arg in "$@"; do printf ' %s' "$(printf '%s' "$arg" | tr '\n' ' ')"; done
  printf '\n'
} >>"${CLASH_TEST_CURL_LOG:?}"
exec "${CLASH_TEST_REAL_CURL:?}" "$@"
SH
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${CLASH_TEST_LOGGER_LOG:-/dev/null}"
SH
chmod 0755 "$WORK_DIR/bin/curl" "$WORK_DIR/bin/logger"

cat >"$WORK_DIR/sing-box.json" <<'JSON'
{"outbounds":[{"type":"direct","tag":"direct"},{"type":"vless","tag":"proxy-a","server":"one.test","server_port":443}]}
JSON
cat >"$WORK_DIR/etc/forkop" <<EOF
config settings 'settings'
	option service_listen_address '127.0.0.1'
	option config_path '$WORK_DIR/sing-box.json'
EOF
printf '%s\n' 'forkop.settings=settings' \
  'forkop.settings.service_listen_address=127.0.0.1' \
  "forkop.settings.config_path=$WORK_DIR/sing-box.json" \
  "forkop.settings.yacd_secret_key=$SECRET" >"$WORK_DIR/uci-state"

# run_case NAME PORT ARGS... runs runtime.uc ARGS in the background against
# the controller on PORT; wait_cases collects them.
CASE_PIDS=()
run_case() {
  local name="$1" port="$2" dir="$WORK_DIR/case/$1"
  shift 2
  mkdir -p "$dir/tmp"
  : >"$dir/curl.log"
  (
    start="$(date +%s%N)"
    rc=0
    env PATH="$WORK_DIR/bin:$PATH" \
      FORKOP_LIB="$FORKOP_LIB" \
      FORKOP_CONFIG="$WORK_DIR/etc/forkop" \
      FORKOP_CONFIG_FILE="$WORK_DIR/etc/forkop" \
      FORKOP_UCI_STATE_FILE="$WORK_DIR/uci-state" \
      FORKOP_UCI_LOG_FILE="$dir/uci-log" \
      FORKOP_RUNTIME_STATE_DIR="$dir/run" \
      SB_CLASH_API_CONTROLLER_PORT="$port" \
      CLASH_TEST_CURL_LOG="$dir/curl.log" \
      CLASH_TEST_REAL_CURL="$REAL_CURL" \
      CLASH_TEST_LOGGER_LOG="$dir/logger.log" \
      TMPDIR="$dir/tmp" \
      "${CASE_ENV[@]}" \
      "$TIMEOUT_BIN" -k 2 "$WATCHDOG" "$UCODE_BIN" -L "$FORKOP_LIB" "$RUNTIME_UC" "$@" \
      >"$dir/out" 2>"$dir/err" </dev/null || rc=$?
    end="$(date +%s%N)"
    printf '%s %s\n' "$rc" "$(((end - start) / 1000000))" >"$dir/result"
  ) &
  CASE_PIDS+=("$!")
}
CASE_ENV=()
wait_cases() {
  local pid
  for pid in "${CASE_PIDS[@]}"; do wait "$pid"; done
  CASE_PIDS=()
}

# check_bounded NAME [MIN_DELAY_MAX_TIME]: the request failed on its own
# within the bounds its curl invocations carry; each invocation carried both
# bounds (a small one, or for a delay request at least MIN_DELAY_MAX_TIME so
# that curl outlives sing-box's own delay timeout) and aimed at a controller
# double; the secret stayed off the command line and its header file was
# removed afterwards.
check_bounded() {
  local name="$1" min_delay="${2:-}" dir="$WORK_DIR/case/$1" rc elapsed line budget=0 connect max
  read -r rc elapsed <"$dir/result"
  case "$rc" in
    124 | 137) fail "$name: still blocked on the hung controller after ${WATCHDOG}s (watchdog)" ;;
  esac
  [ -s "$dir/curl.log" ] || fail "$name: no request reached curl"
  while IFS= read -r line; do
    case "$line" in ARGV:*) ;; *) continue ;; esac
    connect="$(printf '%s\n' "$line" | sed -n 's/.* --connect-timeout \([0-9][0-9]*\) .*/\1/p')"
    max="$(printf '%s\n' "$line" | sed -n 's/.* --max-time \([0-9][0-9]*\) .*/\1/p')"
    [ -n "$connect" ] || fail "$name: curl without --connect-timeout: $line"
    [ -n "$max" ] || fail "$name: curl without --max-time: $line"
    if [ "$connect" -lt 1 ] || [ "$connect" -gt "$max" ]; then
      fail "$name: connect timeout $connect outside 1..$max: $line"
    fi
    case "$line" in
      */delay*)
        [ -n "$min_delay" ] || fail "$name: unexpected delay request: $line"
        [ "$max" -ge "$min_delay" ] ||
          fail "$name: --max-time $max would cut sing-box's own delay timeout (needs >= $min_delay): $line"
        ;;
      *) [ "$max" -le 10 ] || fail "$name: --max-time $max is not a small bound: $line" ;;
    esac
    case "$line" in
      *"127.0.0.1:$HUNG_PORT/"* | *"127.0.0.1:$PROXIES_PORT/"*) ;;
      *) fail "$name: request did not reach the controller double: $line" ;;
    esac
    case "$line" in *"$SECRET"*) fail "$name: the Clash secret is on the curl command line" ;; esac
    case "$line" in *" -H @"*) ;; *) fail "$name: request without the Authorization header file: $line" ;; esac
    budget=$((budget + max))
  done <"$dir/curl.log"
  [ "$elapsed" -le $(((budget + SLACK) * 1000)) ] ||
    fail "$name: took ${elapsed} ms, past its bounds (${budget} s + ${SLACK} s)"
  [ -z "$(find "$dir/tmp" -type f)" ] || fail "$name: the Authorization header file was left behind"
  [ "$rc" != 0 ] || fail "$name: a request to a hung controller reported success"
}

# json_value FILE KEY prints KEY of the JSON object in FILE, <none> when it
# is missing and <invalid> when FILE holds no JSON object.
json_value() {
  "$UCODE_BIN" -e '
    let v = null;
    try { v = json(require("fs").readfile(ARGV[0])); } catch (e) {}
    if (type(v) != "object") { print("<invalid>"); exit(0); }
    let r = v[ARGV[1]];
    print(r == null ? "<none>" : r);
  ' "$1" "$2"
}

# --- Control: the fixture reaches the controller --------------------------------

run_case control-ready "$PROXIES_PORT" clash-api-ready
wait_cases
read -r rc _ <"$WORK_DIR/case/control-ready/result"
[ "$rc" = 0 ] || fail "control: clash-api-ready must pass against an answering controller (rc=$rc)"

# --- Hung controller: every request fails on its own, in bounds -----------------

run_case ready "$HUNG_PORT" clash-api-ready
run_case get_proxies "$HUNG_PORT" clash-api get_proxies
run_case get_connections "$HUNG_PORT" clash-api get_connections
run_case get_proxy_latency "$HUNG_PORT" clash-api get_proxy_latency proxy-a 1000
run_case get_group_latency "$HUNG_PORT" clash-api get_group_latency group-a 3000
run_case get_proxy_latencies "$HUNG_PORT" clash-api get_proxy_latencies '["proxy-a"]' 1000
run_case set_group_proxy "$HUNG_PORT" clash-api set_group_proxy group-a proxy-a
run_case close_connection "$HUNG_PORT" clash-api close_connection conn-1
run_case close_all_connections "$HUNG_PORT" clash-api close_all_connections
# Behind the readiness map, only the delay request hangs.
run_case latencies_after_map "$PROXIES_PORT" clash-api get_proxy_latencies '["proxy-a"]' 1000
wait_cases

check_bounded ready
for action in get_proxies get_connections set_group_proxy close_connection close_all_connections; do
  check_bounded "$action"
  [ "$(json_value "$WORK_DIR/case/$action/out" error)" = clash_api_timeout ] ||
    fail "$action: a timed-out request must report {\"error\":\"clash_api_timeout\"}, got: $(cat "$WORK_DIR/case/$action/out")"
done
# A delay request outlives sing-box's own timeout (1000 ms, 3000 ms).
check_bounded get_proxy_latency 2
check_bounded get_group_latency 4
for action in get_proxy_latency get_group_latency; do
  [ "$(json_value "$WORK_DIR/case/$action/out" error)" = clash_api_timeout ] ||
    fail "$action: a timed-out delay request must report {\"error\":\"clash_api_timeout\"}, got: $(cat "$WORK_DIR/case/$action/out")"
done
# Without the proxy map the batch fails once instead of waiting out every tag.
check_bounded get_proxy_latencies
[ "$(json_value "$WORK_DIR/case/get_proxy_latencies/out" error)" = clash_api_unavailable ] ||
  fail "get_proxy_latencies: an unanswered proxy map must report {\"error\":\"clash_api_unavailable\"}, got: $(cat "$WORK_DIR/case/get_proxy_latencies/out")"
[ "$(grep -c '^ARGV:' "$WORK_DIR/case/get_proxy_latencies/curl.log")" = 1 ] ||
  fail "get_proxy_latencies: delay requests followed an unanswered proxy map"
check_bounded latencies_after_map 2
[ "$(json_value "$WORK_DIR/case/latencies_after_map/out" failed)" = true ] ||
  fail "latencies_after_map: a timed-out delay request must count as failed, got: $(cat "$WORK_DIR/case/latencies_after_map/out")"
[ "$(grep -c '^ARGV:' "$WORK_DIR/case/latencies_after_map/curl.log")" = 2 ] ||
  fail "latencies_after_map: expected the proxy map and one delay request"

# --- A lock held around the request is released -----------------------------------

# The automatic latency test holds reload.lock (and its own lock) around its
# Clash API requests. A state stub hands out both as directories.
cat >"$WORK_DIR/state-stub.uc" <<'UC'
let fs = require("fs");
let mode = ARGV[0] || "", path = ARGV[1] || "";
if (mode == "acquire-runtime-dir-lock" || mode == "acquire-runtime-dir-lock-wait")
    exit(fs.mkdir(path) ? 0 : 1);
if (mode == "release-runtime-dir-lock") {
    fs.rmdir(path);
    exit(0);
}
if (mode == "sing-box-service-runtime-pid") {
    print("123\n");
    exit(0);
}
exit(0);
UC
SIGNATURE="$(env FORKOP_LIB="$FORKOP_LIB" "$UCODE_BIN" -L "$FORKOP_LIB" "$RUNTIME_UC" proxy-outbounds-signature "$WORK_DIR/sing-box.json")"
[ -n "$SIGNATURE" ] || fail "the proxy signature of the fixture was not produced"

run_locked_case() {
  local name="$1" port="$2" dir="$WORK_DIR/case/$1"
  mkdir -p "$dir"
  printf '{"format":"1","signature":"%s","scheduled_at":1,"failures":0,"retry_after":0}\n' "$SIGNATURE" >"$dir/pending"
  CASE_ENV=(
    FORKOP_SERVICE_STATE_UC="$WORK_DIR/state-stub.uc"
    FORKOP_AUTOMATIC_LATENCY_PENDING_FILE="$dir/pending"
    FORKOP_AUTOMATIC_LATENCY_TEST_LOCK_DIR="$dir/latency.lock"
    FORKOP_RELOAD_LOCK_DIR="$dir/reload.lock"
    FORKOP_AUTOMATIC_LATENCY_CLASH_READY_ATTEMPTS=1
    FORKOP_AUTOMATIC_LATENCY_RETRY_BASE_SECONDS=300
  )
  run_case "$name" "$port" automatic-latency-test new
  CASE_ENV=()
}
lock_dir_present() { [ -d "$1" ]; }

# The readiness map hangs; then the delay request hangs behind a map.
run_locked_case locked_map "$HUNG_PORT"
run_locked_case locked_delay "$PROXIES_PORT"
for name in locked_map locked_delay; do
  wait_until 10 lock_dir_present "$WORK_DIR/case/$name/reload.lock" ||
    fail "$name: the automatic latency test did not take reload.lock before the request"
done
wait_cases

check_bounded locked_map
check_bounded locked_delay 6
for name in locked_map locked_delay; do
  dir="$WORK_DIR/case/$name"
  [ ! -e "$dir/reload.lock" ] || fail "$name: reload.lock is still held after the bounded request"
  [ ! -e "$dir/latency.lock" ] || fail "$name: the automatic latency test lock is still held"
  [ "$(json_value "$dir/pending" failures)" = 1 ] ||
    fail "$name: a timed-out latency test must keep its marker with a recorded failure: $(cat "$dir/pending" 2>/dev/null)"
done
grep -q '/delay' "$WORK_DIR/case/locked_delay/curl.log" ||
  fail "locked_delay: the delay request was not reached"

printf 'Clash API requests are bounded; a hung controller releases held locks\n'
