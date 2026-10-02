#!/usr/bin/env bash
set -euo pipefail

# autotune_groups resolves every target in one process while the page waits
# for it (45s RPC timeout, a read-only session can call it and the page asks
# again every two minutes). Each target may spend the budget of one pass in
# sing-box list questions (routing/resolve.uc), so the call limits the whole
# process: past the limit, lists are undecidable and the remaining targets
# are outside the groups instead of keeping the page waiting (UC-220).
# FORKOP_AUTOTUNE_GROUPS_LIST_SECONDS stands in for the limit here.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK="$(mktemp -d)"
cleanup() {
  pkill -KILL -f -- "$WORK/" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export FORKOP_LIB="$LIB"
export FORKOP_AUTOTUNE_STATE_FILE="$WORK/etc/autotune/state.json"
export FORKOP_AUTOTUNE_LAST_DIR="$WORK/run/last" FORKOP_AUTOTUNE_STATE_DIR="$WORK/run/autotune"
export FORKOP_CONFIG_FILE="$WORK/config/forkop"
export FORKOP_AUTOTUNE_SINGBOX_CONFIG="$WORK/sing-box.json"
export FORKOP_AUTOTUNE_DIG="$WORK/dig"
export FORKOP_AUTOTUNE_UCI_SAVEDIR="$WORK/uci-save" FORKOP_AUTOTUNE_TMPDIR="$WORK/tmp"
export FORKOP_HISTORY_FILE="$WORK/etc/history.jsonl" FORKOP_RUNTIME_STATE_DIR="$WORK/run/state"
export FORKOP_CRONTAB_FILE="$WORK/crontab" FORKOP_AUTOTUNE_CRONTAB="$WORK/crontab-cmd"
mkdir -p "$WORK/config" "$WORK/uci-save" "$WORK/tmp"

cat >"$WORK/sing-box" <<EOF
#!/bin/sh
exec ucode -- "$ROOT_DIR/tests/helpers/sing_box_rule_set_stub.uc" "\$@"
EOF
chmod +x "$WORK/sing-box"
export FORKOP_RULESET_MATCH_BIN="$WORK/sing-box"
export RULESET_STUB_CALLS="$WORK/calls"

# Every target resolves to a FakeIP address.
cat >"$WORK/dig" <<'SH'
#!/bin/sh
echo 198.18.0.$(printf '%s' "$4" | wc -c)
SH
chmod +x "$WORK/dig"

cat >"$WORK/config/forkop" <<'CONF'
config settings 'settings'
config section 'main'
	option action 'connection'
config section 'youtube'
	option action 'zapret'
	option label 'YouTube'
	option nfqws_opt '--filter-tcp=443 --dpi-desync=multisplit'
config autotune_target 't1'
	option host 'www.youtube.com'
config autotune_target 't2'
	option host 'm.youtube.com'
config autotune_target 't3'
	option host 'i.youtube.com'
config autotune_target 't4'
	option host 's.youtube.com'
CONF
# A plain source list above the DPI rule that holds none of the targets.
printf '%s\n' '{ "version": 3, "rules": [ { "domain_suffix": [ "example.org" ] } ] }' >"$WORK/other.json"
cat >"$WORK/sing-box.json" <<JSON
{"route":{"final":"direct-out","rule_set":[{"type":"local","tag":"other","format":"source","path":"$WORK/other.json"}],"rules":[
 {"action":"route","inbound":"tproxy-in","rule_set":["other"],"outbound":"main-out"},
 {"action":"route","inbound":"tproxy-in","domain_suffix":["youtube.com"],"outbound":"youtube-out"}
]},"outbounds":[{"type":"direct","tag":"direct-out"},{"type":"vless","tag":"main-out"},
 {"type":"direct","tag":"youtube-out","routing_mark":16777217}]}
JSON

groups() { # -> groups.json, prints the seconds it took
  local start=$SECONDS
  : >"$WORK/calls"
  timeout 60 ucode -L "$LIB" "$LIB/autotune/manager.uc" groups >"$WORK/groups.json" || fail "groups failed"
  echo $((SECONDS - start))
}
summary() {
  ucode -e 'let g = json(require("fs").readfile(ARGV[0]));
    let o = {}; for (let x in g.outside) o[x.id] = x.detail;
    print(join(",", (g.groups.youtube || { targets: [] }).targets), " ", sprintf("%J", o), "\n");' "$WORK/groups.json"
}
asked() { grep -c '^rule-set match ' "$WORK/calls" || true; }

# Fast answers: every target is asked once and decided.
groups >/dev/null
[ "$(summary)" = 't1,t2,t3,t4 { }' ] || fail "fast lists: got $(summary)"
[ "$(asked)" = 4 ] || fail "fast lists: asked $(asked) times"

# The list hangs for the second target. A budget of 30s per target, the
# whole call limited to 4s: the first target is answered at once, the second
# is killed with what is left of the 4s, the rest are not asked. They are
# outside as undecidable and the call ends in time.
took="$(RULESET_STUB_HANG=m.youtube.com FORKOP_RULESET_MATCH_BUDGET=30 FORKOP_AUTOTUNE_GROUPS_LIST_SECONDS=4 groups)"
[ "$(asked)" = 2 ] || fail "limited: asked $(asked) times"
[ "$(summary)" = 't1 { "t2": "undecidable_matcher", "t3": "undecidable_matcher", "t4": "undecidable_matcher" }' ] ||
  fail "limited: got $(summary)"
[ "$took" -le 8 ] || fail "limited: groups took ${took}s"
if pgrep -f -- "$WORK/other.json" >/dev/null; then fail "limited: the hung sing-box was left running"; fi

echo "autotune_groups_list_budget: ok"
