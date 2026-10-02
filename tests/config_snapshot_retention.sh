#!/bin/sh
set -eu

# Snapshot retention (D-14 (a)+(b), UC-022, UC-225). RETENTION is 10, and two
# places are reserved for the automatic safety snapshots: before a restore,
# before Save & Apply (and a reload), before an autotune apply, the
# last-known-working one and a concurrent edit. Manual snapshots stop at
# RETENTION-2 = 8 with a reason the UI names, and nothing ever removes a
# manual snapshot. An automatic snapshot is never refused for room: the
# automatic ones rotate among themselves, oldest first, and never push out
# the last-known-working snapshot, a manual one or one that the running
# operation still needs. An install that already holds 10 manual snapshots
# (taken before the cap) keeps every one of them and still restores, confirms
# the last-known-working configuration and applies autotune.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
REAL_UCODE="$(command -v ucode)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$1"; }

mkdir -p "$WORK/bin" "$WORK/run" "$WORK/state" "$WORK/etc" "$WORK/uci-save"
export FORKOP_CONFIG_FILE="$WORK/etc/forkop"
export FORKOP_SNAPSHOT_DIR="$WORK/snapshots"
export FORKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
export FORKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export FORKOP_AUTOTUNE_APPLY_STATE="$WORK/autotune-apply.json"
export FORKOP_LIB="$LIB"
export FORKOP_BIN="$WORK/bin/forkop"
export FORKOP_RELOAD_COMMAND="$WORK/reload"
export FORKOP_PENDING_RELOAD_FILE="$WORK/run/reload.pending"
export FORKOP_RELOAD_LOCK_DIR="$WORK/run/reload.lock"
export FORKOP_LIST_UPDATE_PID_FILE="$WORK/run/list-update.pid"
export FORKOP_HISTORY_FILE="$WORK/history.jsonl"
export FORKOP_RUNTIME_STATE_DIR="$WORK/run"
export FORKOP_UCI_SAVEDIR="$WORK/uci-save"
export STATE="$WORK/state"

# The restore guard, validation and the history are recorded, not run; no
# fail-closed guard of a failed lifecycle transition is installed.
cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */nft/apply.uc)
    echo "$4" >> "$STATE/events"
    case "$4" in
      dpi-transition-guard-state) echo absent ;;
    esac
    exit 0 ;;
  */config/validator.uc) echo validate >> "$STATE/events"; exit 0 ;;
  */diagnostics/health.uc) echo "health:$5:$6" >> "$STATE/events"; exit 0 ;;
esac
exit 0
STUB
cat > "$WORK/bin/nft" <<'STUB'
#!/bin/sh
exit 1
STUB
cat > "$WORK/bin/forkop" <<'STUB'
#!/bin/sh
echo test
STUB
cat > "$WORK/reload" <<'STUB'
#!/bin/sh
echo "reload:$*" >> "$STATE/events"
[ "${FAIL_RELOAD:-0}" = 1 ] && exit 1
exit 0
STUB
chmod +x "$WORK/bin/ucode" "$WORK/bin/nft" "$WORK/bin/forkop" "$WORK/reload"

config() { printf "config settings 'settings'\n\toption dns_server '1.1.1.1'\n\toption marker '%s'\n" "$1" > "$FORKOP_CONFIG_FILE"; }
marker() { grep -o "marker '[a-z0-9]*'" "$FORKOP_CONFIG_FILE" | sed "s/marker '\(.*\)'/\1/"; }
hash() { sha256sum "$FORKOP_CONFIG_FILE" | cut -d' ' -f1; }
# snapshots.uc <args>: the answer in result.json, the exit status in $code.
run() {
  : > "$STATE/events"
  code=0
  PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" "$@" > "$WORK/result.json" || code=$?
}
field() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));let v=r;for(const k of process.argv[2].split("."))v=v==null?v:v[k];console.log(v===undefined||v===null?"":v)' "$WORK/result.json" "$1"; }
answer() { tr -d '\n' < "$WORK/result.json"; }
events() { tr '\n' ' ' < "$STATE/events"; }
lkg() { cat "$FORKOP_SNAPSHOT_DIR/last-known-working"; }
# What the store holds, from the list the UI reads: "<total> <manual>".
store() {
  "$REAL_UCODE" -L "$LIB" "$SCRIPT" list |
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=JSON.parse(s);console.log(r.length+" "+r.filter(x=>x.kind==="manual").length)})'
}
manual_ids() {
  "$REAL_UCODE" -L "$LIB" "$SCRIPT" list |
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).filter(x=>x.kind==="manual").map(x=>x.id).sort().join(" ")))'
}
exists() { [ -f "$FORKOP_SNAPSHOT_DIR/$1.json" ]; }
holds() { grep -q "marker '$2'" "$FORKOP_SNAPSHOT_DIR/$1.json"; }

# 1. Manual snapshots stop at RETENTION-2 = 8; the refusal names the limit
#    and changes nothing.
for n in 1 2 3 4 5 6 7 8; do
  config "m$n"; run create manual
  [ "$(field status)" = created ] || fail "manual snapshot $n: $(answer)"
done
manual_before="$(manual_ids)"
config m9; run create manual
[ "$code" != 0 ] && [ "$(field status)" = failed ] && [ "$(field reason)" = manual_limit_reached ] &&
  [ "$(field limit)" = 8 ] || fail "ninth manual snapshot: $(answer)"
[ "$(store)" = "8 8" ] && [ "$(manual_ids)" = "$manual_before" ] || fail "the refused manual snapshot changed the store: $(store)"
! grep -q '^health:' "$STATE/events" || fail "a refused manual snapshot was recorded: $(events)"
ok "manual snapshots stop at 8 with manual_limit_reached; nothing is removed or recorded"

# 2. With 8 manual snapshots the automatic ones rotate in the two reserved
#    places; the last-known-working one is never pushed out.
config a1; run confirm-working
[ "$(field status)" = confirmed ] || fail "confirm-working next to 8 manual snapshots: $(answer)"
lkg_a1="$(lkg)"
for n in 2 3 4 5; do
  config "a$n"; run create automatic
  [ "$(field status)" = created ] || fail "automatic snapshot a$n: $(answer)"
  [ "$(store)" = "10 8" ] && exists "$lkg_a1" || fail "automatic snapshot a$n: store $(store), LKG $lkg_a1"
done
target="$(field snapshot.id)"
[ "$(manual_ids)" = "$manual_before" ] || fail "an automatic snapshot removed a manual one"
ok "automatic snapshots rotate among themselves next to 8 manual snapshots; LKG and manual snapshots stay"

# A restore of an automatic snapshot: the pre-restore snapshot is taken
# although only the LKG, the target and manual snapshots are left.
config a6; run restore "$target"
[ "$(field status)" = success ] && [ "$(marker)" = a5 ] && [ "$(lkg)" = "$target" ] ||
  fail "restore next to 8 manual snapshots and LKG: $(answer)"
grep -q '^health:restore:success$' "$STATE/events" || fail "the restore was not recorded: $(events)"
pre=""
for file in "$FORKOP_SNAPSHOT_DIR"/*.json; do
  grep -q '"reason": *"pre-restore"' "$file" && pre="$(basename "$file" .json)"
done
[ -n "$pre" ] && holds "$pre" a6 || fail "no pre-restore snapshot of the replaced configuration"
[ "$(manual_ids)" = "$manual_before" ] && exists "$lkg_a1" || fail "the restore removed a protected snapshot"
# The next automatic snapshot rotates the unprotected automatic ones out,
# oldest first, back to RETENTION.
config a7; run create automatic
[ "$(field status)" = created ] && [ "$(store)" = "10 8" ] && exists "$target" ||
  fail "rotation after the restore: $(answer), store $(store)"
! exists "$lkg_a1" && ! exists "$pre" || fail "former LKG and pre-restore snapshots did not rotate out"
ok "restore next to 8 manual snapshots: pre-restore snapshot taken, history recorded, store back to 10 afterwards"

# An autotune apply next to 8 manual snapshots: the before-autotune snapshot
# survives the confirmation of the candidate, so the rollback still works.
printf "config settings 'settings'\n\toption dns_server '1.1.1.1'\n\toption marker 'cand'\n" > "$WORK/candidate"
run apply "$WORK/candidate" "$(hash)"
[ "$(field status)" = success ] && [ "$(marker)" = cand ] || fail "autotune apply next to 8 manual snapshots: $(answer)"
before_autotune="$(field pre_snapshot)"
exists "$before_autotune" && holds "$before_autotune" a7 || fail "no before-autotune snapshot"
run confirm-working autotune "$before_autotune"
[ "$(field status)" = confirmed ] && exists "$before_autotune" && [ "$(lkg)" != "$before_autotune" ] ||
  fail "confirming the candidate removed its before-autotune snapshot: $(answer)"
run restore "$before_autotune" "$(hash)"
[ "$(field status)" = success ] && [ "$(marker)" = a7 ] && [ "$(lkg)" = "$before_autotune" ] ||
  fail "rollback of the autotune apply: $(answer)"
[ "$(manual_ids)" = "$manual_before" ] || fail "autotune removed a manual snapshot"
ok "autotune next to 8 manual snapshots: applied, confirmed and rolled back"

# Below the cap a manual snapshot is taken again; it pushes out only
# automatic snapshots that nothing protects.
lkg_now="$(lkg)"
victim="${manual_before%% *}"
run delete "$victim"
[ "$(field status)" = deleted ] || fail "delete: $(answer)"
config m10; run create manual
[ "$(field status)" = created ] && [ "$(store)" = "10 8" ] && exists "$lkg_now" ||
  fail "manual snapshot below the cap: $(answer), store $(store)"
ok "a manual snapshot below the cap is taken; LKG stays"

# 3. Upgrade: 10 manual snapshots taken before the cap, the newest of them
#    the last-known-working one. Nothing is removed; safety operations work.
export FORKOP_SNAPSHOT_DIR="$WORK/legacy-snapshots"
node - "$FORKOP_SNAPSHOT_DIR" <<'JS'
const fs = require('node:fs');
const crypto = require('node:crypto');
const dir = process.argv[2];
fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
for (let i = 1; i <= 10; i++) {
  const content = `config settings 'settings'\n\toption dns_server '1.1.1.1'\n\toption marker 'm${i}'\n`;
  const id = `${1700000000 + i}_${i}`;
  const snapshot = { id, created_at: 1700000000 + i, kind: 'manual', reason: 'manual',
    config_hash: crypto.createHash('sha256').update(content).digest('hex'), forkop_version: 'old', content };
  fs.writeFileSync(`${dir}/${id}.json`, `${JSON.stringify(snapshot)}\n`, { mode: 0o600 });
}
fs.writeFileSync(`${dir}/last-known-working`, `${1700000000 + 10}_10\n`);
JS
legacy="$(manual_ids)"
[ "$(store)" = "10 10" ] || fail "fixture: $(store)"
config m10

config m11; run create manual
[ "$(field status)" = failed ] && [ "$(field reason)" = manual_limit_reached ] || fail "manual snapshot over the cap: $(answer)"
[ "$(manual_ids)" = "$legacy" ] || fail "a refused manual snapshot removed one"

config s1; run create automatic
[ "$(field status)" = created ] || fail "Save & Apply snapshot next to 10 manual snapshots: $(answer)"
s1="$(field snapshot.id)"
run confirm-working
[ "$(field status)" = confirmed ] && [ "$(lkg)" = "$s1" ] || fail "confirm-working next to 10 manual snapshots: $(answer)"

run restore 1700000003_3
[ "$(field status)" = success ] && [ "$(marker)" = m3 ] && [ "$(lkg)" = 1700000003_3 ] ||
  fail "restore of a manual snapshot next to 10 manual snapshots: $(answer)"
grep -q '^health:restore:success$' "$STATE/events" || fail "the restore was not recorded: $(events)"
run restore "$s1"
[ "$(field status)" = success ] && [ "$(marker)" = s1 ] && [ "$(lkg)" = "$s1" ] ||
  fail "restore of an automatic snapshot next to 10 manual snapshots: $(answer)"
for n in 2 3 4 5; do
  config "s$n"; run create automatic
  [ "$(field status)" = created ] && [ "$(store)" = "12 10" ] && exists "$s1" ||
    fail "automatic snapshot s$n next to 10 manual snapshots: $(answer), store $(store)"
done
ok "upgrade with 10 manual snapshots: manual refused with the reason; Save & Apply snapshot, LKG and restores work; two automatic places rotate"

run apply "$WORK/candidate" "$(hash)"
[ "$(field status)" = success ] && [ "$(marker)" = cand ] || fail "autotune apply next to 10 manual snapshots: $(answer)"
before_autotune="$(field pre_snapshot)"
run confirm-working autotune "$before_autotune"
[ "$(field status)" = confirmed ] && exists "$before_autotune" || fail "autotune confirmation next to 10 manual snapshots: $(answer)"
run restore "$before_autotune" "$(hash)"
[ "$(field status)" = success ] && [ "$(marker)" = s5 ] && [ "$(lkg)" = "$before_autotune" ] ||
  fail "autotune rollback next to 10 manual snapshots: $(answer)"
config s6; run create automatic
[ "$(field status)" = created ] && [ "$(store)" = "12 10" ] && exists "$before_autotune" ||
  fail "rotation after the autotune rollback: $(answer), store $(store)"
[ "$(manual_ids)" = "$legacy" ] || fail "a manual snapshot taken before the cap was removed"
ok "upgrade with 10 manual snapshots: autotune applied, confirmed and rolled back; no manual snapshot removed"

printf 'config_snapshot_retention: PASS\n'
