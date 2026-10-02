#!/bin/sh
set -eu

# Why a snapshot was taken, as the snapshot list reports it for the History
# page (UC-067). The lifecycle's snapshot at the start of a reload ("create
# automatic", reason before-reload) is taken after the change was
# committed: it holds the configuration that the reload applies. Save &
# Apply on the Rules and Settings pages takes its own before LuCI applies
# ("create before-apply", reason before-apply): it holds the configuration
# before the change. Both are automatic snapshots and reuse a snapshot that
# already holds the same configuration; the list keeps both reasons.
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$1"; }

mkdir -p "$WORK/bin" "$WORK/run" "$WORK/etc"
export FORKOP_CONFIG_FILE="$WORK/etc/forkop"
export FORKOP_SNAPSHOT_DIR="$WORK/snapshots"
export FORKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
export FORKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export FORKOP_AUTOTUNE_APPLY_STATE="$WORK/autotune-apply.json"
export FORKOP_LIB="$LIB"
export FORKOP_BIN="$WORK/bin/forkop"
export FORKOP_HISTORY_FILE="$WORK/history.jsonl"
export FORKOP_RUNTIME_STATE_DIR="$WORK/run"
printf '#!/bin/sh\necho 1.0.32-test\n' > "$WORK/bin/forkop"
chmod +x "$WORK/bin/forkop"

config() {
  printf "config settings 'settings'\n\toption dns_rewrite_ttl '%s'\n" "$1" > "$FORKOP_CONFIG_FILE"
}
snapshot() { ucode -L "$LIB" "$SCRIPT" create "$1" || true; }
field() { node -e 'let v=JSON.parse(require("fs").readFileSync(0,"utf8"));for(const k of process.argv[1].split("."))v=v?.[k];console.log(v===undefined?"":v)' "$1"; }

# Save & Apply: the configuration as it is before LuCI applies the change.
config 60
before="$(snapshot before-apply)"
[ "$(printf '%s' "$before" | field status)" = created ] || fail "before-apply snapshot not created: $before"
[ "$(printf '%s' "$before" | field snapshot.reason)" = before-apply ] || fail "before-apply reason: $before"
[ "$(printf '%s' "$before" | field snapshot.kind)" = automatic ] || fail "a before-apply snapshot is automatic: $before"
before_id="$(printf '%s' "$before" | field snapshot.id)"
again="$(snapshot before-apply)"
[ "$(printf '%s' "$again" | field status)" = existing ] || fail "same configuration snapshotted twice: $again"
[ "$(printf '%s' "$again" | field snapshot.id)" = "$before_id" ] || fail "existing snapshot not reused: $again"
ok "Save & Apply snapshot: before-apply, automatic, reused for the same configuration"

# The committed change, then the reload that applies it.
config 30
reload="$(snapshot automatic)"
[ "$(printf '%s' "$reload" | field snapshot.reason)" = before-reload ] || fail "reload snapshot reason: $reload"
reload_id="$(printf '%s' "$reload" | field snapshot.id)"
ucode -L "$LIB" "$SCRIPT" list > "$WORK/list.json"
node -e '
const list = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const reason = (id) => list.find((item) => item.id === id)?.reason;
if (reason(process.argv[2]) !== "before-apply" || reason(process.argv[3]) !== "before-reload")
  throw Error(JSON.stringify(list));
if (list.some((item) => item.kind !== "automatic")) throw Error(JSON.stringify(list));
' "$WORK/list.json" "$before_id" "$reload_id" || fail "the list lost a reason: $(cat "$WORK/list.json")"
grep -q "dns_rewrite_ttl '60'" "$FORKOP_SNAPSHOT_DIR/$before_id.json" || fail "before-apply holds the configuration before the change"
grep -q "dns_rewrite_ttl '30'" "$FORKOP_SNAPSHOT_DIR/$reload_id.json" || fail "before-reload holds the configuration the reload applies"
ok "list keeps before-apply (configuration before the change) and before-reload (configuration the reload applies)"

# Only known snapshot kinds.
other="$(snapshot nonsense)"
[ "$(printf '%s' "$other" | field status)" = failed ] || fail "unknown snapshot kind accepted: $other"
[ "$(find "$FORKOP_SNAPSHOT_DIR" -name '*.json' | wc -l)" -eq 2 ] || fail "an unknown kind wrote a snapshot"
ok "unknown snapshot kind refused"
