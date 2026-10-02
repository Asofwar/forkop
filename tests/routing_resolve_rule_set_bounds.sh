#!/usr/bin/env bash
set -euo pipefail

# The cost of asking sing-box about lists (UC-220). route_trace and
# autotune_groups, which a read-only session calls and the UI polls, resolve
# every target, and each question is one sing-box process that parses the
# whole list. So:
# - each question is bounded: sing-box is killed after
#   FORKOP_RULESET_MATCH_TIMEOUT seconds, and the list is undecidable;
# - one process asks each (list file, value) once, however many rules name
#   the list and however many times the target is resolved; a changed file
#   is asked again;
# - one process spends at most FORKOP_RULESET_MATCH_BUDGET seconds in
#   sing-box; after that, lists are undecidable instead of asked.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK="$(mktemp -d)"
cleanup() {
    pkill -KILL -f -- "$WORK/" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cat >"$WORK/sing-box" <<EOF
#!/bin/sh
exec ucode -- "$ROOT_DIR/tests/helpers/sing_box_rule_set_stub.uc" "\$@"
EOF
chmod +x "$WORK/sing-box"
export FORKOP_RULESET_MATCH_BIN="$WORK/sing-box"
export RULESET_STUB_CALLS="$WORK/calls"
: >"$WORK/calls"

binary_list() { printf 'SRS\n%s\n' "$2" >"$WORK/$1"; }
binary_list youtube.srs '{ "version": 3, "rules": [ { "domain_suffix": [ "youtube.com" ] } ] }'
for n in 1 2 3; do binary_list "other$n.srs" "{ \"version\": 3, \"rules\": [ { \"domain\": [ \"example$n.org\" ] } ] }"; done
binary_list hang.srs '{ "version": 3, "rules": [ { "domain_suffix": [ "youtube.com" ] } ] }'

cat >"$WORK/forkop" <<'EOF'
config settings 'settings'
config section 'youtube'
	option action 'zapret'
	option nfqws_opt '--filter-tcp=443 --dpi-desync=multisplit'
config section 'main'
	option action 'connection'
EOF

# Resolves each step's host in ONE process and reports, per step, the answer
# and how many "rule-set match" questions it took. A step may first rewrite
# a list file.
cat >"$WORK/steps.uc" <<'EOF'
let fs = require("fs"), r = require("routing.resolve");
let sections = r.parse_config(fs.readfile(ARGV[0]));
let c = json(fs.readfile(ARGV[1]));
let asked = () => length(filter(split(fs.readfile(getenv("RULESET_STUB_CALLS")) || "", "\n"), (l) => index(l, "rule-set match ") == 0));
let config = { route: { final: "direct-out", rule_set: c.rule_set, rules: c.rules },
    outbounds: [ { type: "direct", tag: "direct-out" }, { type: "vless", tag: "main-out" },
        { type: "direct", tag: "youtube-out", routing_mark: 16777217 } ] };
let out = [];
for (let step in c.steps) {
    if (step.rewrite != null) fs.writefile(step.rewrite.path, step.rewrite.text);
    let before = asked();
    let got = r.resolve(config, sections, r.target(step.host, "198.18.0.9", { fakeip: true }));
    push(out, join(" ", map([ got.status, got.route_rule, got.section, asked() - before ], (v) => v == null ? "null" : "" + v)));
}
print(join("\n", out), "\n");
EOF

run_steps() { # json -> one line per step: status rule section questions
    printf '%s' "$1" >"$WORK/case.json"
    timeout 30 env FORKOP_LIB="$LIB" ucode -L "$LIB" "$WORK/steps.uc" "$WORK/forkop" "$WORK/case.json" ||
        fail "the resolver did not finish"
}

local_set() { printf '{ "type": "local", "tag": "%s", "format": "binary", "path": "%s" }' "$1" "$WORK/$2"; }
route() { printf '{ "action": "route", "inbound": [ "tproxy-in" ], "rule_set": [ "%s" ], "outbound": "%s" }' "$1" "$2"; }
sets="[ $(local_set yt youtube.srs), $(local_set other1 other1.srs), $(local_set other2 other2.srs),
  $(local_set other3 other3.srs), $(local_set hang hang.srs) ]"

# ---- memoised per process --------------------------------------------------
# Two rules name the same list above the owner: it is asked once. Resolving
# the target again asks nothing; a new name asks each list once; a list file
# that changed (here: its size) is asked again, the others are not.
rewrite="{ \"path\": \"$WORK/youtube.srs\", \"text\": \"SRS\\n{ \\\"version\\\": 3, \\\"rules\\\": [ { \\\"domain_suffix\\\": [ \\\"example.network\\\" ] } ] }\\n\" }"
got="$(run_steps "{ \"rule_set\": $sets,
  \"rules\": [ $(route other1 main-out), $(route other1 main-out), $(route yt youtube-out) ],
  \"steps\": [ { \"host\": \"youtube.com\" }, { \"host\": \"youtube.com\" }, { \"host\": \"www.youtube.com\" },
    { \"host\": \"youtube.com\", \"rewrite\": $rewrite } ] }")"
want="decided 2 youtube 2
decided 2 youtube 0
decided 2 youtube 2
decided null null 1"
[ "$got" = "$want" ] || fail "memoisation: got
$got
want
$want"

# ---- one question is bounded -----------------------------------------------
binary_list youtube.srs '{ "version": 3, "rules": [ { "domain_suffix": [ "youtube.com" ] } ] }'
start=$SECONDS
got="$(RULESET_STUB_HANG=youtube.com FORKOP_RULESET_MATCH_TIMEOUT=1 run_steps "{ \"rule_set\": $sets,
  \"rules\": [ $(route hang youtube-out), $(route yt youtube-out) ], \"steps\": [ { \"host\": \"youtube.com\" } ] }")"
[ "$got" = "undecidable 0 null 1" ] || fail "timeout: got $got"
[ $((SECONDS - start)) -le 8 ] || fail "timeout: the resolver waited $((SECONDS - start))s for a hung sing-box"
if pgrep -f -- "$WORK/hang.srs" >/dev/null; then fail "timeout: the hung sing-box was left running"; fi

# ---- one budget per process ------------------------------------------------
# Every question takes 1.2s and the budget is 2s: the second question uses
# it up, the third list is not asked and is undecidable.
got="$(RULESET_STUB_DELAY_MS=1200 FORKOP_RULESET_MATCH_BUDGET=2 run_steps "{ \"rule_set\": $sets,
  \"rules\": [ $(route other1 main-out), $(route other2 main-out), $(route other3 main-out), $(route yt youtube-out) ],
  \"steps\": [ { \"host\": \"youtube.com\" }, { \"host\": \"www.youtube.com\" } ] }")"
want="undecidable 2 null 2
undecidable 0 null 0"
[ "$got" = "$want" ] || fail "budget: got
$got
want
$want"

echo "routing_resolve_rule_set_bounds: ok"
