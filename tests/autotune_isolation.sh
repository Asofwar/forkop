#!/usr/bin/env bash
set -euo pipefail

# DPI autotune stages 1-3: candidate catalog, probe classifier and the
# isolated probe path with its idempotent cleanup. nft, curl, dig and nfqws
# are stubs; process identity, pidfiles and the run lock are real.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
WORK="$(mktemp -d)"
FOREIGN_PIDS=()
cleanup_test() {
  for pid in "${FOREIGN_PIDS[@]}"; do kill -9 "$pid" 2>/dev/null || true; done
  pkill -9 -f "$WORK/bin/nfqws" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup_test EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/nft/tables" "$WORK/nft/counters" "$WORK/proc_net" "$WORK/child-pid" "$WORK/log"
export FORKOP_LIB="$LIB"
export FORKOP_AUTOTUNE_STATE_DIR="$WORK/run/autotune"
export FORKOP_AUTOTUNE_PROC_QUEUE="$WORK/nfnetlink_queue"
export FORKOP_AUTOTUNE_PORT_RANGE_FILE="$WORK/ip_local_port_range"
export FORKOP_AUTOTUNE_PROC_NET="$WORK/proc_net"
export FORKOP_AUTOTUNE_CURL="$WORK/bin/curl"
export FORKOP_AUTOTUNE_DIG="$WORK/bin/dig"
export FORKOP_AUTOTUNE_LISTENER_WAIT=2
export FORKOP_AUTOTUNE_DRAIN_TIMEOUT=1 FORKOP_AUTOTUNE_HOLD_TIMEOUT=2
FIXTURES="$ROOT/tests/fixtures/autotune"
export FORKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export ZAPRET_NFQWS_BIN="$WORK/bin/nfqws"
export ZAPRET_CHILD_PID_DIR="$WORK/child-pid"
export NFT_STATE="$WORK/nft" STUB_LOG="$WORK/log"
export PATH="$WORK/bin:$PATH"
PROD_QUEUE_LINE=" 4000  29676     0 2 65531     0     0       51  1"
export NFQWS_STUB_QUEUE_FILE="$FORKOP_AUTOTUNE_PROC_QUEUE"
export NFQWS_STUB_QUEUE_BASE="$PROD_QUEUE_LINE"$'\n'

# nfqws stand-in: a real binary named nfqws so /proc identity checks apply.
# A watcher releases its queue line when it dies, as the kernel would.
cat > "$WORK/nfqws.c" <<'C'
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  const char *reject = getenv("NFQWS_STUB_REJECT");
  for (int i = 1; i < argc; i++)
    if (!strcmp(argv[i], "--dry-run")) {
      for (int j = 1; j < argc; j++) if (reject && *reject && strstr(argv[j], reject)) return 1;
      return 0;
    }
  if (getenv("NFQWS_STUB_EXIT")) return 1;
  const char *qfile = getenv("NFQWS_STUB_QUEUE_FILE"), *qbase = getenv("NFQWS_STUB_QUEUE_BASE");
  if (getenv("NFQWS_STUB_IGNORE_TERM")) signal(SIGTERM, SIG_IGN);
  if (qfile && !getenv("NFQWS_STUB_NO_LISTENER")) {
    FILE *f = fopen(qfile, "w");
    if (f) { fputs(qbase ? qbase : "", f); fprintf(f, " %s %8d     0 2 65531     0     0        0  1\n", getenv("FORKOP_AUTOTUNE_QUEUE") ? getenv("FORKOP_AUTOTUNE_QUEUE") : "4600", getpid()); fclose(f); }
    char script[1024];
    snprintf(script, sizeof script, "while kill -0 %d 2>/dev/null && [ \"$(cut -d' ' -f3 /proc/%d/stat)\" != Z ]; do sleep 0.05; done; printf '%%s' \"$NFQWS_STUB_QUEUE_BASE\" > '%s'", getpid(), getpid(), qfile);
    if (fork() == 0) { setsid(); execl("/bin/sh", "sh", "-c", script, (char *)0); _exit(1); }
  }
  for (;;) pause();
}
C
cc -O0 -o "$WORK/bin/nfqws" "$WORK/nfqws.c"

cat > "$WORK/bin/nft" <<'SH'
#!/usr/bin/env bash
S="$NFT_STATE"; T="$S/tables"
echo "nft $*" >> "$STUB_LOG/nft.log"
case "$*" in
  "list tables") for t in "$T"/*; do [ -e "$t" ] && echo "table inet ${t##*/}"; done; exit 0 ;;
  "list table inet "*) [ -e "$T/$4" ]; exit ;;
  "-j list table inet "*)
    [ -e "$T/$5" ] || exit 1
    if [ "$5" = ForkopAutotuneProbe ]; then
      [ -z "${NFT_STUB_FAIL_PROBE_LISTING:-}" ] || exit 1
      target="$(cat "$S/probe.target" 2>/dev/null)"
      probe="probe"; [ ! -e "$S/released" ] || probe="released"
      rule() {
        read -r p b < "$S/counters/$2"
        printf '{"rule":{"family":"inet","table":"ForkopAutotuneProbe","chain":"%s","handle":%s,"comment":"%s","expr":[{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"daddr"}},"right":"%s"}},{"counter":{"packets":%s,"bytes":%s}}]}}' "$1" "$3" "$2" "$target" "$p" "$b"
      }
      printf '{"nftables":[{"table":{"family":"inet","name":"ForkopAutotuneProbe","handle":90}},%s,%s,%s,%s,%s]}\n' \
        "$(rule premark probe_mark 2)" "$(rule output reinjected 3)" "$(rule output reinjected_bare 4)" "$(rule output "$probe" 5)" "$(rule output unexpected 6)"
    else cat "$T/$5"; fi
    exit 0 ;;
  "list ruleset") cat "$S/ruleset"; [ -e "$T/ForkopAutotuneProbe" ] && echo "queue to 4600"; exit 0 ;;
  "-j -t list ruleset") [ -z "${NFT_STUB_FAIL_RULESET:-}" ] || exit 1; cat "$S/ruleset.json"; exit 0 ;;
  "-j list set inet ForkopTable forkop_interfaces")
    printf '{"nftables":[{"set":{"family":"inet","name":"forkop_interfaces","table":"ForkopTable","type":"ifname","elem":%s}}]}\n' "${NFT_STUB_INTERFACES:-[\"br-lan\"]}"; exit 0 ;;
  "-f "*)
    if grep -q '^replace rule inet ForkopAutotuneProbe output handle 5 ' "$2"; then
      [ -z "${NFT_STUB_FAIL_REPLACE:-}" ] || exit 1
      cp "$2" "$S/release.nft"; touch "$S/released"; echo "0 0" > "$S/counters/released"; exit 0
    fi
    [ -z "${NFT_STUB_FAIL_SETUP:-}" ] || exit 1
    grep -q '^create table inet ForkopAutotuneProbe$' "$2" && [ -e "$T/ForkopAutotuneProbe" ] && exit 1
    cp "$2" "$S/last.nft"; touch "$T/ForkopAutotuneProbe"; rm -f "$S/released"
    sed -n 's/.* ip daddr \([0-9.]*\) .*/\1/p' "$2" | head -n 1 > "$S/probe.target"
    for c in probe_mark reinjected reinjected_bare probe released unexpected; do echo "0 0" > "$S/counters/$c"; done; exit 0 ;;
  "delete table inet "*) [ -z "${NFT_STUB_FAIL_DELETE:-}" ] || exit 1; rm -f "$T/$4"; exit 0 ;;
esac
exit 1
SH

# curl stand-in: prints the -w record for the requested scenario and emulates
# the probe traffic in the stub counters and the queue statistics.
cat > "$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_LOG/curl.args"
ip="$(printf '%s\n' "$@" | sed -n 's/^[^:]*:443:\(.*\)$/\1/p')"
if [ -e "$NFT_STATE/tables/ForkopAutotuneProbe" ]; then
  echo "5 400" > "$NFT_STATE/counters/probe_mark"; echo "5 400" > "$NFT_STATE/counters/probe"; echo "3 900" > "$NFT_STATE/counters/reinjected"
  [ -z "${CURL_STUB_UNEXPECTED:-}" ] || echo "1 60" > "$NFT_STATE/counters/unexpected"
  sed -i "s/^\( 4600 *[0-9]* *0 2 65531 *0 *0 *\)0 /\1${CURL_STUB_QUEUED:-7} /" "$FORKOP_AUTOTUNE_PROC_QUEUE"
  [ -z "${CURL_STUB_ROUTE_CHANGE:-}" ] || touch "$NFT_STATE/route.changed"
  if [ -n "${CURL_STUB_PENDING:-}" ]; then
    sed -i "s/^\( 4600 *[0-9]* *\)0 /\11 /" "$FORKOP_AUTOTUNE_PROC_QUEUE"
    # Only the subshell is backgrounded; it must not hold curl's stdout open.
    if [ "$CURL_STUB_PENDING" != forever ]; then
      ( sleep "$CURL_STUB_PENDING"; sed -i "s/^\( 4600 *[0-9]* *\)1 /\10 /" "$FORKOP_AUTOTUNE_PROC_QUEUE" ) >/dev/null 2>&1 &
    fi
  fi
fi
# Sockets of the probe tuple (target 93.184.216.34:443 from port 61000):
# optionally closing first, then TIME_WAIT until they expire.
if [ -n "${CURL_STUB_SOCKET:-}" ]; then
  state=06; [ -z "${CURL_STUB_CLOSING:-}" ] || state=04
  printf '   9: 0A00000A:EE48 22D8B85D:01BB %s 00000000:00000000\n' "$state" >> "$FORKOP_AUTOTUNE_PROC_NET/tcp"
  (
    [ -z "${CURL_STUB_CLOSING:-}" ] || { sleep "$CURL_STUB_CLOSING"; sed -i 's/22D8B85D:01BB 04/22D8B85D:01BB 06/' "$FORKOP_AUTOTUNE_PROC_NET/tcp"; }
    sleep "$CURL_STUB_SOCKET"; sed -i '/22D8B85D:01BB/d' "$FORKOP_AUTOTUNE_PROC_NET/tcp"
  ) >/dev/null 2>&1 &
fi
# Live production traffic moves counters but not the table structure.
sed -i 's/"packets": *[0-9]*/"packets": 999/' "$NFT_STATE/tables/ForkopTable"
[ -z "${CURL_STUB_TOUCH_PROD:-}" ] || sed -i 's/"handle": 48/"handle": 49/' "$NFT_STATE/tables/ForkopTable"
[ -z "${CURL_STUB_SLEEP:-}" ] || sleep "$CURL_STUB_SLEEP"
mode="${CURL_STUB_MODE:-success}"
if [ "$mode" = alternate ]; then
  n=$(( $(cat "$STUB_LOG/curl.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_LOG/curl.count"
  mode=success; [ $((n % 3)) -ne 0 ] || mode=reset
fi
case "$mode" in
  success) echo "0|61000|$ip|204|0.012|0.061|0.090|0.091|" ;;
  moved) echo "0|61001|$ip|301|0.012|0.061|0.090|0.091|" ;;
  forbidden) echo "0|61002|$ip|403|0.012|0.061|0.090|0.091|" ;;
  refused) echo "7|0||000|0.000000|0.000000|0.000000|0.004|Failed to connect to x port 443 after 4 ms: Connection refused"; exit 7 ;;
  unreachable) echo "7|0||000|0.000000|0.000000|0.000000|0.004|Failed to connect to x port 443 after 4 ms: No route to host"; exit 7 ;;
  connect_timeout) echo "28|0||000|0.000000|0.000000|0.000000|5.001|Connection timed out after 5001 milliseconds"; exit 28 ;;
  tls) echo "35|61003|$ip|000|0.012|0.000000|0.000000|0.070|mbedTLS: (-0x7780) SSL - A fatal alert message was received from our peer"; exit 35 ;;
  tls_timeout) echo "28|61003|$ip|000|0.012|0.000000|0.000000|10.0|Operation timed out after 10000 milliseconds with 0 bytes received"; exit 28 ;;
  reset) echo "35|61004|$ip|000|0.012|0.000000|0.000000|0.050|Recv failure: Connection reset by peer"; exit 35 ;;
  http_transport) echo "56|61005|$ip|000|0.012|0.061|0.000000|0.100|Recv failure: Connection reset by peer"; exit 56 ;;
  empty_reply) echo "52|61006|$ip|000|0.012|0.061|0.000000|0.100|Empty reply from server"; exit 52 ;;
esac
SH
# ip stand-in: policy rules from the router fixture and the probe route.
cat > "$WORK/bin/ip" <<'SH'
#!/usr/bin/env bash
echo "ip $*" >> "$STUB_LOG/ip.log"
case "$*" in
  "-j rule") [ -z "${IP_STUB_RULE_FAIL:-}" ] || exit 1; cat "$NFT_STATE/iprule.json" ;;
  "-j route get "*" ipproto tcp sport 61000 dport 443 uid 0")
    if [ -n "${IP_STUB_ROUTE_LOCAL:-}" ]; then printf '[{"type":"local","dst":"%s","dev":"lo","prefsrc":"203.0.113.10","uid":0,"flags":[],"cache":["local"]}]\n' "$4"
    elif [ -e "$NFT_STATE/route.changed" ]; then printf '[{"dst":"%s","gateway":"100.64.0.99","dev":"pppoe-wan","prefsrc":"203.0.113.10","uid":0,"flags":[],"cache":[]}]\n' "$4"
    elif [ -n "${IP_STUB_ROUTE_DIFFERS:-}" ] && [ "$6" = 0 ]; then printf '[{"dst":"%s","dev":"vpn1","prefsrc":"10.8.0.2","uid":0,"flags":[],"cache":[]}]\n' "$4"
    else printf '[{"dst":"%s","gateway":"100.64.0.1","dev":"pppoe-wan","prefsrc":"203.0.113.10","uid":0,"flags":[],"cache":[]}]\n' "$4"; fi ;;
  *) exit 1 ;;
esac
SH
cat > "$WORK/bin/dig" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_LOG/dig.args"
printf '%b' "${DIG_STUB_ANSWER-93.184.216.34\n}"
SH
chmod +x "$WORK/bin/nft" "$WORK/bin/curl" "$WORK/bin/dig" "$WORK/bin/ip"

json() { node -e 'const a=require("node:assert/strict");const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));'"$1" "$2"; }

# Production stand-ins that must survive every scenario untouched.
sleep 600 & PROD_NFQWS=$!; FOREIGN_PIDS+=("$PROD_NFQWS")
ucode -L "$LIB" "$LIB/core/pidfile_cli.uc" record "$PROD_NFQWS" "$WORK/child-pid/WardogsGame.pid"
# The ForkopTable listing (hashed and contract-checked by the run) as the
# production part of the current terse ruleset.
production_from_ruleset() {
  node -e '
const fs = require("fs");
const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).nftables;
const own = (x) => x.metainfo || (x.table && x.table.name === "ForkopTable") ||
  ["chain", "rule", "set"].some((k) => x[k] && x[k].table === "ForkopTable");
fs.writeFileSync(process.argv[2], JSON.stringify({ nftables: r.filter(own) }, null, 1) + "\n");' "$NFT_STATE/ruleset.json" "$NFT_STATE/tables/ForkopTable"
}
# Surgery on the production output path by meaning (never by handle).
mutate_ruleset() {
  node -e '
const fs = require("fs");
const file = process.argv[1];
const r = JSON.parse(fs.readFileSync(file, "utf8"));
const PROBE = 0x08000000;
const bypass = (x) => x.rule && x.rule.table === "ForkopTable" && x.rule.chain === "mangle_output" &&
  x.rule.expr.some((e) => e.match && e.match.left.meta && e.match.left.meta.key === "mark" && e.match.right === PROBE);
if (process.argv[2] === "remove-bypass") r.nftables = r.nftables.filter((x) => !bypass(x));
fs.writeFileSync(file, JSON.stringify(r, null, 1) + "\n");' "$1" "$2"
}
reset_state() {
  unset CURL_STUB_MODE CURL_STUB_TOUCH_PROD CURL_STUB_SLEEP NFT_STUB_FAIL_SETUP NFT_STUB_FAIL_DELETE \
    NFQWS_STUB_EXIT NFQWS_STUB_NO_LISTENER NFQWS_STUB_REJECT NFQWS_STUB_IGNORE_TERM DIG_STUB_ANSWER FORKOP_AUTOTUNE_QUEUE \
    CURL_STUB_UNEXPECTED CURL_STUB_PENDING CURL_STUB_SOCKET CURL_STUB_CLOSING NFT_STUB_FAIL_RULESET \
    IP_STUB_RULE_FAIL IP_STUB_ROUTE_LOCAL IP_STUB_ROUTE_DIFFERS NFT_STUB_INTERFACES NFT_STUB_FAIL_REPLACE \
    CURL_STUB_QUEUED CURL_STUB_ROUTE_CHANGE FORKOP_AUTOTUNE_QUIET_TIMEOUT \
    NFT_STUB_FAIL_PROBE_LISTING
  rm -f "$WORK/proc_net/ip_tables_names" "$WORK/proc_net/ip6_tables_names" "$STUB_LOG/curl.count" "$STUB_LOG/ip.log" \
    "$NFT_STATE/released" "$NFT_STATE/release.nft" "$NFT_STATE/route.changed"
  export FORKOP_AUTOTUNE_DRAIN_TIMEOUT=1 FORKOP_AUTOTUNE_HOLD_TIMEOUT=2
  rm -rf "$FORKOP_AUTOTUNE_STATE_DIR" "$FORKOP_SNAPSHOT_LOCK_DIR" "$NFT_STATE/tables"/* "$NFT_STATE/last.nft"
  printf '%s\n' "$PROD_QUEUE_LINE" > "$FORKOP_AUTOTUNE_PROC_QUEUE"
  printf '32768\t60999\n' > "$FORKOP_AUTOTUNE_PORT_RANGE_FILE"
  printf '  sl  local_address rem_address   st\n' > "$WORK/proc_net/tcp"
  printf '  sl  local_address rem_address   st\n' > "$WORK/proc_net/tcp6"
  printf 'table inet ForkopTable {\n\tqueue flags bypass to 4000\n}\n' > "$NFT_STATE/ruleset"
  cp "$FIXTURES/ruleset.json" "$NFT_STATE/ruleset.json"
  cp "$FIXTURES/iprule.json" "$NFT_STATE/iprule.json"
  production_from_ruleset
}
iso() { ucode -L "$LIB" "$LIB/autotune/isolation.uc" "$@" > "$WORK/out.json" || true; }
run_probe() { iso run "$1" example.com "${2:-3}" 192.0.2.53; }
assert_clean() {
  [ ! -e "$NFT_STATE/tables/ForkopAutotuneProbe" ] || fail "$1: temporary table left behind"
  ! grep -q ' 4600 ' "$FORKOP_AUTOTUNE_PROC_QUEUE" || fail "$1: queue 4600 left behind"
  ! pgrep -f "$WORK/bin/nfqws --qnum" >/dev/null || fail "$1: temporary nfqws left behind"
  for leftover in active.json nfqws.pid work; do
    [ ! -e "$FORKOP_AUTOTUNE_STATE_DIR/$leftover" ] || fail "$1: temporary state $leftover left behind"
  done
  [ ! -e "$FORKOP_AUTOTUNE_STATE_DIR/lock" ] || fail "$1: run lock left behind"
  [ ! -e "$FORKOP_AUTOTUNE_STATE_DIR" ] || fail "$1: runtime directory left behind: $(ls -A "$FORKOP_AUTOTUNE_STATE_DIR")"
  kill -0 "$PROD_NFQWS" || fail "$1: production nfqws stand-in was signalled"
  grep -q '^ 4000 ' "$FORKOP_AUTOTUNE_PROC_QUEUE" || fail "$1: production queue line lost"
}
pass=0
ok() { pass=$((pass + 1)); printf 'ok %s\n' "$1"; }

# --- catalog -------------------------------------------------------------
reset_state
ucode -L "$LIB" "$LIB/autotune/catalog.uc" validate > "$WORK/catalog.json"
json '
const ids = r.map((e) => e.id);
a.deepEqual(ids, ["direct","multisplit","fake","multidisorder","fakedsplit","fake_multisplit","hostfakesplit","fake_multidisorder","udp_fake"]);
for (const e of r) {
  a.ok(e.id && e.protocol && typeof e.rank === "number" && typeof e.nfqws_opt === "string" && typeof e.enabled === "boolean");
  a.doesNotMatch(e.nfqws_opt, /--qnum|--hostlist|--ipset|--dpi-desync-fwmark|--daemon|<HOSTLIST/);
  if (e.protocol === "tcp") { a.equal(e.state, "supported", JSON.stringify(e)); a.equal(e.enabled, true); }
  if (e.nfqws_opt) a.match(e.nfqws_opt, e.protocol === "tcp" ? /^--filter-tcp=443 / : /^--filter-udp=443 /);
}
const udp = r.find((e) => e.id === "udp_fake");
a.equal(udp.state, "unsupported"); a.equal(udp.reason, "quic_probe_unavailable");
a.ok(r.find((e) => e.id === "direct").rank < r.find((e) => e.id === "fake_multidisorder").rank);
' "$WORK/catalog.json"
ok "catalog valid"

NFQWS_STUB_REJECT=hostfakesplit ucode -L "$LIB" "$LIB/autotune/catalog.uc" validate hostfakesplit > "$WORK/one.json"
json 'a.equal(r.state, "unsupported"); a.equal(r.reason, "nfqws_dry_run_rejected"); a.equal(r.enabled, false);' "$WORK/one.json"
ZAPRET_NFQWS_BIN="$WORK/missing" ucode -L "$LIB" "$LIB/autotune/catalog.uc" validate fake > "$WORK/one.json"
json 'a.equal(r.state, "unsupported"); a.equal(r.reason, "nfqws_unavailable");' "$WORK/one.json"
NFQWS_STUB_REJECT=hostfakesplit run_probe hostfakesplit
json 'a.equal(r.status, "unsupported"); a.equal(r.reason, "nfqws_dry_run_rejected"); a.equal(r.probes.length, 0);' "$WORK/out.json"
[ ! -e "$NFT_STATE/last.nft" ] || fail "unsupported candidate created nft state"
assert_clean "unsupported"
ok "unsupported strategy"

# --- probe classifier through the full isolated path ---------------------
expect_class() {
  reset_state; export CURL_STUB_MODE="$1"; run_probe multisplit 1
  json "a.equal(r.status, 'completed', JSON.stringify(r)); const p = r.probes[0];
    a.equal(p.class, '$2'); a.equal(p.connect, '$3'); a.equal(p.tls, '$4'); a.equal(p.http, '$5');
    a.equal(p.resolved_ip, '93.184.216.34'); a.equal(typeof p.curl_exit_code, 'number');
    for (const k of ['time_connect_ms','time_appconnect_ms','time_starttransfer_ms','time_total_ms']) a.equal(typeof p[k], 'number');
    a.equal(r.cleanup.status, 'clean'); a.equal(r.production.unchanged, true);" "$WORK/out.json"
  assert_clean "$1"
  ok "classify $1 -> $2"
}
expect_class success success ok ok ok
expect_class moved success ok ok ok
expect_class forbidden success ok ok ok
expect_class refused tcp_reset reset not_attempted not_attempted
expect_class unreachable connect_failure failed not_attempted not_attempted
expect_class connect_timeout connect_timeout timeout not_attempted not_attempted
expect_class tls tls_failure ok failed not_attempted
expect_class tls_timeout tls_failure ok timeout not_attempted
expect_class reset tcp_reset ok reset not_attempted
expect_class http_transport http_transport_failure ok ok reset
expect_class empty_reply http_transport_failure ok ok failed
json 'a.equal(r.probes[0].http_status, 0); a.equal(r.probes[0].curl_exit_code, 52);' "$WORK/out.json"
ucode -L "$LIB" "$LIB/autotune/probe.uc" classify 6 0 0 0 "Could not resolve host" > "$WORK/c.json"
json 'a.equal(r.class, "dns_failure");' "$WORK/c.json"

# Success details and HTTP status as information only.
reset_state; export CURL_STUB_MODE=forbidden; run_probe multisplit 3
json '
a.equal(r.summary.successes, 3); a.equal(r.summary.success_rate, 1);
const p = r.probes[0]; a.equal(p.http_status, 403); a.equal(p.local_port, 61002); a.equal(p.time_appconnect_ms, 61);
a.equal(r.counters.probe_mark.packets, 5); a.equal(r.counters.probe.packets, 5); a.equal(r.counters.reinjected.packets, 3); a.equal(r.counters.unexpected.packets, 0);
a.ok(r.cleanup.actions.includes("probe_rule:released")); a.ok(r.teardown.quiet_before_creation.quiet); a.ok(r.teardown.quiet_before_removal.quiet);
a.equal(r.counters.queue.packets_queued, 7);
const steps = r.timeline.map((t) => t.step); a.deepEqual(steps, ["T0","T1","T2","T3","T4","T5","T6","T7","T8"]);
a.ok(!JSON.stringify(r).match(/cookie|authorization|set-cookie/i));
' "$WORK/out.json"
args="$(cat "$STUB_LOG/curl.args")"
grep -qx -- '--local-port' <<<"$args" || fail "curl without dedicated source ports"
grep -qx -- '61000-61031' <<<"$args" || fail "curl without the dedicated source-port range"
grep -qx -- 'example.com:443:93.184.216.34' <<<"$args" || fail "curl without pinned address"
grep -qx -- '/dev/null' <<<"$args" || fail "curl keeps the body"
! grep -qxE -- '-b|-c|-D|-H|-u|--cookie|--cookie-jar|--dump-header|-i|-v' <<<"$args" || fail "curl records headers or cookies"
grep -qx -- '@192.0.2.53' "$STUB_LOG/dig.args" || fail "dig not pinned to the upstream resolver"
batch="$(cat "$NFT_STATE/last.nft")"
grep -qx 'create table inet ForkopAutotuneProbe' <<<"$batch" || fail "table not created atomically"
grep -q 'type route hook output priority -151; policy accept;' <<<"$batch" || fail "wrong hook/priority"
[ "$(grep -c '^add rule' <<<"$batch")" = 5 ] || fail "unexpected rule count"
T='ip daddr 93.184.216.34 tcp dport 443 tcp sport 61000-61031'
expect_line() { sed -n "$1p" "$NFT_STATE/last.nft" | grep -qxF -- "$2" || fail "batch line $1: $(sed -n "$1p" "$NFT_STATE/last.nft")"; }
expect_line 2 'add chain inet ForkopAutotuneProbe premark { type route hook output priority -152; policy accept; }'
expect_line 3 "add rule inet ForkopAutotuneProbe premark $T meta mark 0x00000000 meta mark set 0x08000000 counter accept comment \"probe_mark\""
expect_line 4 'add chain inet ForkopAutotuneProbe output { type route hook output priority -151; policy accept; }'
expect_line 5 "add rule inet ForkopAutotuneProbe output $T meta mark 0x48000000 meta mark set 0x08000000 counter return comment \"reinjected\""
expect_line 6 "add rule inet ForkopAutotuneProbe output $T meta mark 0x40000000 meta mark set 0x08000000 counter return comment \"reinjected_bare\""
expect_line 7 "add rule inet ForkopAutotuneProbe output $T meta mark 0x08000000 counter queue num 4600 comment \"probe\""
expect_line 8 "add rule inet ForkopAutotuneProbe output $T counter drop comment \"unexpected\""
! grep -q '0x48000000 counter return\|& 0x40000000' <<<"$batch" || fail "an injected packet may leave the probe chain unnormalized"
grep -qxF "replace rule inet ForkopAutotuneProbe output handle 5 $T meta mark 0x08000000 counter accept comment \"released\"" "$NFT_STATE/release.nft" ||
  fail "the candidate queue is not released to the bypass before nfqws stops"
grep -qx 'ip -j route get 93.184.216.34 mark 0x08000000 ipproto tcp sport 61000 dport 443 uid 0' "$STUB_LOG/ip.log" || fail "route not resolved with the probe mark and tuple"
grep -qx 'ip -j route get 93.184.216.34 mark 0 ipproto tcp sport 61000 dport 443 uid 0' "$STUB_LOG/ip.log" || fail "socket route not compared"
! grep -q 'bypass' <<<"$batch" || fail "probe queue must fail closed (no bypass)"
ok "success record, counters, timeline and request hygiene"

# Control candidate: marked direct path, no nfqws.
reset_state; run_probe direct 1
json 'a.equal(r.status, "completed"); a.equal(r.counters.queue, undefined); a.ok(!r.timeline.some((t) => t.step === "T2"));' "$WORK/out.json"
sed -n '7p' "$NFT_STATE/last.nft" | grep -q 'meta mark 0x08000000 counter accept comment "probe"' || fail "control rule must not queue"
grep -q 'meta mark 0x08000000 counter accept comment "released"' "$NFT_STATE/release.nft" || fail "control candidate not released"
assert_clean "direct"
ok "direct control candidate"

# --- DNS -------------------------------------------------------------------
reset_state; export DIG_STUB_ANSWER='198.18.6.193\n10.0.0.1\n'; run_probe multisplit
json 'a.equal(r.status, "completed"); a.equal(r.reason, "dns_failure"); a.equal(r.probes[0].class, "dns_failure"); a.equal(r.probes[0].detail, "non_public_answer");' "$WORK/out.json"
[ ! -e "$NFT_STATE/last.nft" ] || fail "dns failure created nft state"
reset_state; export DIG_STUB_ANSWER=''; run_probe multisplit
json 'a.equal(r.probes[0].detail, "no_address");' "$WORK/out.json"
assert_clean "dns"
ok "dns failure"

# --- failures during setup ---------------------------------------------
reset_state; export NFQWS_STUB_EXIT=1; run_probe multisplit
json 'a.equal(r.status, "failed"); a.equal(r.reason, "nfqws_start_failed"); a.equal(r.cleanup.status, "clean"); a.equal(r.probes.length, 0);' "$WORK/out.json"
assert_clean "nfqws failure"
ok "cleanup after nfqws failure"

reset_state; export NFQWS_STUB_NO_LISTENER=1; run_probe multisplit
json 'a.equal(r.reason, "nfqws_listener_missing"); a.equal(r.cleanup.status, "clean"); a.ok(r.cleanup.actions.includes("pidfile:stopped"));' "$WORK/out.json"
assert_clean "listener missing"
ok "cleanup after nfqws without queue listener"

reset_state; export NFT_STUB_FAIL_SETUP=1; run_probe multisplit
json 'a.equal(r.reason, "nft_setup_failed"); a.equal(r.cleanup.status, "clean"); a.ok(!r.cleanup.actions.some((x) => x.startsWith("pidfile")));' "$WORK/out.json"
assert_clean "nft setup failure"
ok "cleanup after nft setup failure"

reset_state; export CURL_STUB_MODE=connect_timeout; run_probe multisplit 3
json 'a.equal(r.status, "completed"); a.equal(r.summary.successes, 0); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
assert_clean "curl failure"
ok "cleanup after curl failure"

reset_state; export NFQWS_STUB_IGNORE_TERM=1; run_probe multisplit 1
json 'a.equal(r.status, "completed"); a.ok(r.cleanup.actions.includes("pidfile:killed"), r.cleanup.actions);' "$WORK/out.json"
assert_clean "term ignored"
ok "cleanup escalates to KILL for an identified nfqws"

# --- preconditions -------------------------------------------------------
refused() {
  run_probe multisplit
  json "a.equal(r.status, 'refused'); a.equal(r.reason, '$1');" "$WORK/out.json"
  [ ! -e "$NFT_STATE/last.nft" ] || fail "$1 created nft state"
  pgrep -f "$WORK/bin/nfqws --qnum" >/dev/null && fail "$1 started nfqws"
  ok "refused: $1"
}
reset_state; printf '%s\n 4600  31337     0 2 65531     0     0        0  1\n' "$PROD_QUEUE_LINE" > "$FORKOP_AUTOTUNE_PROC_QUEUE"; refused queue_in_use
grep -q ' 4600  31337' "$FORKOP_AUTOTUNE_PROC_QUEUE" || fail "foreign queue listener was touched"
reset_state; printf 'table inet other {\n\tqueue to 4590-4610\n}\n' >> "$NFT_STATE/ruleset"; refused queue_referenced
reset_state; export FORKOP_AUTOTUNE_QUEUE=4001; refused queue_overlaps_forkop_range
reset_state; printf '32768\t61010\n' > "$FORKOP_AUTOTUNE_PORT_RANGE_FILE"; refused port_range_overlaps_ephemeral
reset_state; printf '   0: 0100007F:EE4D 01010101:01BB 01\n' >> "$WORK/proc_net/tcp"; refused port_range_in_use
reset_state; printf '   0: 0100007F:EE4D 01010101:01BB 06\n' >> "$WORK/proc_net/tcp"; run_probe multisplit 1
json 'a.equal(r.status, "completed");' "$WORK/out.json"; ok "TIME_WAIT leftovers accepted"
reset_state; touch "$NFT_STATE/tables/ForkopConfigRestoreDpiGuard"; refused guard_active
[ -e "$NFT_STATE/tables/ForkopConfigRestoreDpiGuard" ] || fail "guard was removed"
reset_state; touch "$NFT_STATE/tables/ForkopTableDpiGuard"; refused guard_active
reset_state; mkdir -p "$FORKOP_SNAPSHOT_LOCK_DIR"; refused snapshot_operation_in_progress

# --- stale state -----------------------------------------------------------
reset_state; touch "$NFT_STATE/tables/ForkopAutotuneProbe"; run_probe multisplit 1
json 'a.equal(r.status, "completed"); a.ok(r.recovered.includes("table:removed"));' "$WORK/out.json"
assert_clean "stale table"
ok "temporary table already exists"
reset_state; touch "$NFT_STATE/tables/ForkopAutotuneProbe"; export NFT_STUB_FAIL_DELETE=1; run_probe multisplit 1
json 'a.equal(r.status, "refused"); a.equal(r.reason, "stale_probe_state");' "$WORK/out.json"
unset NFT_STUB_FAIL_DELETE; iso cleanup
json 'a.equal(r.status, "clean"); a.ok(r.actions.includes("table:removed"));' "$WORK/out.json"
assert_clean "stale table undeletable"
ok "undeletable stale table blocks the run"

stale_pid() {
  reset_state; mkdir -p "$FORKOP_AUTOTUNE_STATE_DIR"
  sleep 600 & local victim=$!; FOREIGN_PIDS+=("$victim")
  local ticks; ticks="$(ucode -L "$LIB" -e 'print(require("core.process_identity").start_ticks(ARGV[0]))' "$victim")"
  printf '%s\n%s\n' "$victim" "${1:-$ticks}" > "$FORKOP_AUTOTUNE_STATE_DIR/nfqws.pid"
  printf '{"argv":["%s","--qnum=4600","--dpi-desync-fwmark=0x40000000"]}\n' "$ZAPRET_NFQWS_BIN" > "$FORKOP_AUTOTUNE_STATE_DIR/active.json"
  iso cleanup
  json 'a.equal(r.status, "clean"); a.ok(r.actions.includes("pidfile:stale"), r.actions);' "$WORK/out.json"
  kill -0 "$victim" || fail "cleanup killed an unrelated process ($2)"
  assert_clean "$2"
  ok "stale pid protection: $2"
}
stale_pid "" "PID reused by an unrelated process"
stale_pid 1 "start time mismatch"
reset_state; mkdir -p "$FORKOP_AUTOTUNE_STATE_DIR"; printf '999999\n1\n' > "$FORKOP_AUTOTUNE_STATE_DIR/nfqws.pid"; iso cleanup
json 'a.equal(r.status, "clean"); a.ok(r.actions.includes("pidfile:stale"));' "$WORK/out.json"
assert_clean "dead pid"; ok "stale pidfile of a dead process"
reset_state; iso cleanup; json 'a.equal(r.status, "clean"); a.deepEqual(r.actions, []);' "$WORK/out.json"
iso cleanup; json 'a.equal(r.status, "clean");' "$WORK/out.json"; ok "cleanup idempotent when nothing exists"

# Orphan without pidfile (process exists, table missing): found by identity.
reset_state
( "$ZAPRET_NFQWS_BIN" --qnum=4600 --dpi-desync-fwmark=0x40000000 --filter-tcp=443 >/dev/null 2>&1 & )
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$WORK/bin/nfqws --qnum" >/dev/null && break; sleep 0.1; done
iso cleanup
json 'a.equal(r.status, "clean"); a.ok(r.actions.includes("orphan:stopped"), r.actions);' "$WORK/out.json"
assert_clean "orphan"; ok "process exists, table missing"
# A production-like nfqws on another queue is never an orphan.
( "$ZAPRET_NFQWS_BIN" --qnum=4000 --dpi-desync-fwmark=0x40000000 >/dev/null 2>&1 & )
sleep 0.3; iso cleanup
pgrep -f "$WORK/bin/nfqws --qnum=4000" >/dev/null || fail "production-queue nfqws was killed"
pkill -f "$WORK/bin/nfqws --qnum=4000"; ok "production-queue nfqws ignored by orphan scan"

# --- interruption ----------------------------------------------------------
wait_active() {
  for _ in $(seq 1 50); do
    [ -e "$NFT_STATE/tables/ForkopAutotuneProbe" ] && pgrep -f "$WORK/bin/nfqws --qnum" >/dev/null && return 0
    sleep 0.1
  done
  fail "probe run did not become active"
}
reset_state; export CURL_STUB_SLEEP=1
ucode -L "$LIB" "$LIB/autotune/isolation.uc" run multisplit example.com 2 192.0.2.53 > "$WORK/first.json" &
runner=$!; wait_active
iso run multisplit example.com 1 192.0.2.53
json 'a.equal(r.status, "busy"); a.equal(r.reason, "autotune_in_progress");' "$WORK/out.json"
wait "$runner" || true
json 'a.equal(r.status, "completed"); a.equal(r.cleanup.status, "clean");' "$WORK/first.json"
assert_clean "concurrent run"
ok "second run refused while a run is active"

reset_state; export CURL_STUB_SLEEP=2
ucode -L "$LIB" "$LIB/autotune/isolation.uc" run multisplit example.com 3 192.0.2.53 > "$WORK/out.json" &
runner=$!
wait_active
kill -TERM "$runner"; wait "$runner" || true
json 'a.equal(r.status, "interrupted"); a.equal(r.reason, "interrupted"); a.equal(r.cleanup.status, "clean"); a.ok(r.probes.length < 3);' "$WORK/out.json"
assert_clean "SIGTERM"
ok "interrupted probe (SIGTERM) tears down"

reset_state; export CURL_STUB_SLEEP=2
ucode -L "$LIB" "$LIB/autotune/isolation.uc" run multisplit example.com 3 192.0.2.53 > "$WORK/out.json" &
runner=$!
wait_active
kill -KILL "$runner"; wait "$runner" 2>/dev/null || true
[ -e "$NFT_STATE/tables/ForkopAutotuneProbe" ] || fail "SIGKILL scenario did not leave state"
pkill -f "$WORK/bin/curl" 2>/dev/null || true
unset CURL_STUB_SLEEP; iso cleanup
json 'a.equal(r.status, "clean"); a.ok(r.actions.includes("pidfile:stopped")); a.ok(r.actions.includes("table:removed"));' "$WORK/out.json"
assert_clean "SIGKILL"
ok "killed run recovered by cleanup (stale lock reclaimed)"

# --- production bypass contract (checked before any probe path exists) -----
no_probe_path() {
  [ ! -e "$NFT_STATE/last.nft" ] || fail "$1: probe path created"
  ! pgrep -f "$WORK/bin/nfqws --qnum" >/dev/null || fail "$1: nfqws started"
  assert_clean "$1"
}
reset_state; mutate_ruleset "$NFT_STATE/ruleset.json" remove-bypass; run_probe multisplit 1
json 'a.equal(r.status, "unsupported"); a.equal(r.reason, "isolation_unavailable"); a.equal(r.isolation.unavailable, "bypass_contract");
  a.ok(r.contract.violations.some((v) => v.code === "bypass_rule_missing")); a.equal(r.probes.length, 0); a.equal(r.timeline.length, 0);' "$WORK/out.json"
no_probe_path "bypass missing"
ok "missing production bypass: refused before creating the probe path"
reset_state; mutate_ruleset "$NFT_STATE/tables/ForkopTable" remove-bypass; run_probe multisplit 1
json 'a.equal(r.status, "unsupported"); a.equal(r.isolation.unavailable, "bypass_contract_changed");' "$WORK/out.json"
no_probe_path "snapshot contract"
ok "production table changed after the contract check: refused"
reset_state; export IP_STUB_ROUTE_LOCAL=1; run_probe multisplit 1
json 'a.equal(r.status, "unsupported"); a.equal(r.isolation.unavailable, "probe_route_local"); a.equal(r.target.route.dev, "lo");' "$WORK/out.json"
no_probe_path "local route"
ok "probe mark routed locally: refused"
reset_state; export IP_STUB_RULE_FAIL=1; run_probe multisplit 1
json 'a.equal(r.status, "unsupported"); a.ok(r.contract.violations.some((v) => v.code === "ip_rules_unavailable"));' "$WORK/out.json"
no_probe_path "ip rules unavailable"
ok "policy rules unavailable: refused"
reset_state; export NFT_STUB_FAIL_RULESET=1; run_probe multisplit 1
json 'a.equal(r.status, "unsupported"); a.ok(r.contract.violations.some((v) => v.code === "production_table_absent"));' "$WORK/out.json"
no_probe_path "ruleset unavailable"
ok "ruleset unavailable: refused"
reset_state; run_probe multisplit 1
json 'a.equal(r.status, "completed"); a.equal(r.contract.ok, true); a.equal(r.contract.bypass.length, 1);
  a.equal(r.contract.bypass[0].chain, "ForkopTable/mangle_output"); a.equal(r.target.route.dev, "pppoe-wan");
  a.deepEqual(r.isolation.rules.map((x) => x.chain + "/" + x.comment), ["premark/probe_mark", "output/reinjected", "output/reinjected_bare", "output/probe", "output/unexpected"]);
  a.equal(r.target.route.unmarked.dev, "pppoe-wan"); a.deepEqual(r.contract.sets, { forkop_interfaces: ["br-lan"] });' "$WORK/out.json"
ok "contract and route recorded for a completed run"

# --- teardown: drain and hold ---------------------------------------------
reset_state; export CURL_STUB_UNEXPECTED=1; run_probe multisplit 1
json 'a.equal(r.status, "failed"); a.equal(r.reason, "unexpected_probe_packets"); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
assert_clean "unexpected"
ok "packets outside the modelled paths fail the run"
reset_state; export CURL_STUB_PENDING=2 FORKOP_AUTOTUNE_DRAIN_TIMEOUT=6; run_probe multisplit 1
json 'a.equal(r.status, "completed"); a.equal(r.teardown.drain.settled, true); a.ok(r.teardown.drain.waited_s >= 1);' "$WORK/out.json"
assert_clean "pending"
ok "drain waits for queued verdicts before stopping nfqws"
reset_state; export CURL_STUB_PENDING=forever; run_probe multisplit 1
json 'a.equal(r.status, "completed"); a.equal(r.teardown.drain.settled, false); a.equal(r.teardown.drain.queue_pending, 1); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
assert_clean "pending timeout"
ok "drain timeout proceeds to the release and teardown"
reset_state; export CURL_STUB_SOCKET=2 CURL_STUB_CLOSING=2 FORKOP_AUTOTUNE_DRAIN_TIMEOUT=6 FORKOP_AUTOTUNE_HOLD_TIMEOUT=8; run_probe multisplit 1
json '
a.equal(r.status, "completed");
a.equal(r.teardown.drain.settled, true); a.ok(r.teardown.drain.waited_s >= 1, "drain waited for the closing socket");
a.equal(r.teardown.hold.settled, true); a.ok(r.teardown.hold.waited_s >= 1, "table held while TIME_WAIT sockets exist");
const t6 = r.timeline.find((t) => t.step === "T6"), t7 = r.timeline.find((t) => t.step === "T7");
a.ok(r.timeline.indexOf(t6) < r.timeline.indexOf(t7), "nfqws stopped before the table is removed");
a.ok(r.cleanup.actions.indexOf("pidfile:stopped") < r.cleanup.actions.indexOf("hold:settled"));
a.ok(r.cleanup.actions.indexOf("hold:settled") < r.cleanup.actions.indexOf("table:removed"));
a.equal(typeof r.teardown.counters_at_stop.probe.packets, "number"); a.equal(typeof r.teardown.counters_at_removal.released.packets, "number"); a.equal(r.teardown.counters_at_removal.probe, undefined);
' "$WORK/out.json"
assert_clean "hold"
ok "table kept (drop-only) until the probe sockets are gone, then removed"
reset_state; export CURL_STUB_SOCKET=30 FORKOP_AUTOTUNE_HOLD_TIMEOUT=1; run_probe multisplit 1
json 'a.equal(r.status, "failed"); a.equal(r.reason, "isolation_hold_timeout"); a.equal(r.teardown.hold.settled, false);
  a.ok(r.cleanup.actions.includes("hold:timeout")); a.ok(r.cleanup.actions.includes("table:kept")); a.equal(r.cleanup.status, "failed");' "$WORK/out.json"
[ -e "$NFT_STATE/tables/ForkopAutotuneProbe" ] || fail "table removed while probe sockets are alive"
[ -e "$NFT_STATE/released" ] || fail "kept table still queues to the stopped candidate"
[ -e "$FORKOP_AUTOTUNE_STATE_DIR/active.json" ] || fail "recovery data dropped with the table kept"
iso cleanup; json 'a.equal(r.status, "failed"); a.ok(r.actions.includes("table:kept"));' "$WORK/out.json"
sed -i '/22D8B85D:01BB/d' "$WORK/proc_net/tcp"
iso cleanup; json 'a.equal(r.status, "clean"); a.ok(r.actions.includes("probe_rule:already_released")); a.ok(r.actions.includes("table:removed"));' "$WORK/out.json"
assert_clean "hold timeout"
ok "hold timeout keeps the released table until a later cleanup finds no probe socket"

# --- review follow-ups ------------------------------------------------------
reset_state; export IP_STUB_ROUTE_DIFFERS=1; run_probe multisplit 1
json 'a.equal(r.status, "unsupported"); a.equal(r.isolation.unavailable, "probe_route_differs_from_socket_route");' "$WORK/out.json"
no_probe_path "route differs"
ok "probe-mark route differing from the socket route: refused"
reset_state; printf 'mangle\n' > "$WORK/proc_net/ip_tables_names"; run_probe multisplit 1
json 'a.equal(r.status, "unsupported"); a.ok(r.contract.violations.some((v) => v.code === "legacy_iptables_present"));' "$WORK/out.json"
no_probe_path "legacy iptables"
ok "legacy iptables tables loaded: refused"
reset_state; export NFT_STUB_INTERFACES='["br-lan","pppoe-wan"]'; run_probe multisplit 1
json 'a.equal(r.status, "unsupported"); a.ok(r.contract.violations.some((v) => v.code === "reply_path_unsafe"));' "$WORK/out.json"
no_probe_path "reply path"
ok "replies classified by production (WAN in forkop_interfaces): refused"
reset_state; export CURL_STUB_MODE=alternate; run_probe multisplit 3
json 'a.equal(r.status, "completed"); a.equal(r.summary.successes, 2); a.ok(Math.abs(r.summary.success_rate - 2 / 3) < 1e-9, String(r.summary.success_rate));' "$WORK/out.json"
ok "partial success rate is fractional"
reset_state; export NFT_STUB_FAIL_PROBE_LISTING=1; run_probe multisplit 1
json 'a.equal(r.status, "failed"); a.equal(r.reason, "counters_unavailable");' "$WORK/out.json"
unset NFT_STUB_FAIL_PROBE_LISTING; iso cleanup; assert_clean "counters unavailable"
ok "unreadable counters fail the run"
reset_state; export NFT_STUB_FAIL_REPLACE=1; run_probe multisplit 1
json 'a.equal(r.status, "failed"); a.ok(r.cleanup.actions.includes("probe_rule:failed")); a.equal(r.cleanup.status, "failed");' "$WORK/out.json"
unset NFT_STUB_FAIL_REPLACE; iso cleanup; assert_clean "release failure"
ok "failed release of the candidate queue is reported, cleanup recovers"
reset_state; export CURL_STUB_SOCKET=4 FORKOP_AUTOTUNE_HOLD_TIMEOUT=10
ucode -L "$LIB" "$LIB/autotune/isolation.uc" run multisplit example.com 1 192.0.2.53 > "$WORK/out.json" &
runner=$!
for _ in $(seq 1 100); do [ -e "$NFT_STATE/released" ] && break; sleep 0.1; done
sleep 1.5
kill -TERM "$runner"; wait "$runner" || true
json 'a.equal(r.status, "interrupted"); a.equal(r.teardown.hold.settled, true); a.ok(r.teardown.hold.waited_s >= 1, "hold continued after the signal"); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
assert_clean "SIGTERM during hold"
ok "a signal during teardown does not cut the hold short"
reset_state; mkdir -p "$FORKOP_AUTOTUNE_STATE_DIR"; touch "$NFT_STATE/tables/ForkopAutotuneProbe"
echo 93.184.216.34 > "$NFT_STATE/probe.target"; for c in probe_mark reinjected reinjected_bare probe unexpected; do echo "0 0" > "$NFT_STATE/counters/$c"; done
printf '{broken' > "$FORKOP_AUTOTUNE_STATE_DIR/active.json"; iso cleanup
json 'a.equal(r.status, "clean"); a.ok(r.actions.includes("hold:settled"), r.actions); a.ok(r.actions.includes("table:removed"));' "$WORK/out.json"
assert_clean "malformed active"
ok "malformed active.json: target recovered from the table itself"
reset_state; cp "$ZAPRET_NFQWS_BIN" "$WORK/nfqws-other"
( "$WORK/nfqws-other" --qnum=4600 --dpi-desync-fwmark=0x40000000 >/dev/null 2>&1 & )
sleep 0.3; iso cleanup
pgrep -f "$WORK/nfqws-other" >/dev/null || fail "an nfqws with another binary path was treated as an orphan"
pkill -f "$WORK/nfqws-other"; ok "orphan scan requires the exact binary path"
reset_state; export FORKOP_AUTOTUNE_QUEUE=4001
for m in cleanup status; do
  iso "$m"; json 'a.equal(r.status, "refused"); a.equal(r.reason, "queue_overlaps_forkop_range");' "$WORK/out.json"
done
ok "a production queue number is refused by every mode"
unset FORKOP_AUTOTUNE_QUEUE
cat > "$WORK/ipfrag.uc" <<'UC'
let c = require("autotune.catalog");
print(sprintf("%J
", c.validate_entry({ id: "x", family: "f", protocol: "tcp", port: 443, rank: 9,
    nfqws_opt: "--filter-tcp=443 --dpi-desync=fake,ipfrag2" })));
UC
ucode -L "$LIB" "$WORK/ipfrag.uc" > "$WORK/c.json"
json 'a.equal(r.state, "unsupported"); a.equal(r.reason, "ipfrag_unsupported_by_isolation");' "$WORK/c.json"
ok "ipfrag candidates are unsupported by the isolation"
reset_state; export FORKOP_AUTOTUNE_QUIET_TIMEOUT=0
printf '%s\n 4300  777     2 2 65531     0     0       10  1\n' "$PROD_QUEUE_LINE" > "$FORKOP_AUTOTUNE_PROC_QUEUE"; run_probe multisplit 1
json 'a.equal(r.status, "failed"); a.equal(r.reason, "production_queue_busy"); a.equal(r.teardown.quiet_before_creation.pending, 2);' "$WORK/out.json"
[ ! -e "$NFT_STATE/last.nft" ] || fail "hooks registered while production packets were queued"
ok "production packets waiting in an NFQUEUE: no hook registration"
reset_state; export CURL_STUB_QUEUED=3; run_probe multisplit 1
json 'a.equal(r.status, "failed"); a.equal(r.reason, "candidate_bypassed"); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
assert_clean "fail-open"
ok "queue fail-open (probe packets not queued) invalidates the run"
reset_state; export CURL_STUB_ROUTE_CHANGE=1; run_probe multisplit 1
json 'a.equal(r.status, "failed"); a.equal(r.reason, "production_changed"); a.notDeepEqual(r.production.before.route, r.production.after.route);' "$WORK/out.json"
assert_clean "route change"
ok "a routing change during the run is detected"

# --- production integrity ---------------------------------------------------
reset_state; export CURL_STUB_TOUCH_PROD=1; run_probe multisplit 1
json 'a.equal(r.status, "failed"); a.equal(r.reason, "production_changed"); a.equal(r.production.unchanged, false);
  a.notEqual(r.production.before.forkop_table_hash, r.production.after.forkop_table_hash); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
assert_clean "prod mismatch"
ok "production nft hash mismatch detected"
reset_state; run_probe multisplit 1
json 'a.equal(r.status, "completed"); a.equal(r.production.unchanged, true); a.match(r.production.before.forkop_table_hash, /^[0-9a-f]{64}$/);
  a.deepEqual(r.production.before.queues, ["4000:29676"]); a.equal(r.production.before.zapret_children.length, 1);' "$WORK/out.json"
ok "live counter changes are not a production change"

printf 'autotune_isolation: PASS (%d checks)\n' "$pass"
