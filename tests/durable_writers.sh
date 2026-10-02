#!/usr/bin/env bash
# One writer for files on flash (core/durable.uc). Every file that Forkop
# replaces on flash is written to a temporary file next to it, read back
# (a full filesystem takes the write of a small file and keeps none of it,
# UC-241) and renamed over it; the rare, critical ones are flushed (sync)
# before and after the rename (UC-025).
#
# A symlink stays one, as with a libuci commit: the file it points to is
# replaced, through a temporary file next to that file, and a symlink that
# points to nothing is not replaced by a regular file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$1"; }

mkdir -p "$WORK/bin" "$WORK/sync"
# sync: every call keeps a copy of the watched directories ($SYNC_WATCH) as
# they are at that moment in $SYNC_LOG/<n>/.
cat >"$WORK/bin/sync" <<'SH'
#!/bin/sh
n=$(( $(cat "$SYNC_LOG/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$SYNC_LOG/count"
for dir in $SYNC_WATCH; do
  mkdir -p "$SYNC_LOG/$n$dir"
  cp -a "$dir/." "$SYNC_LOG/$n$dir/" 2>/dev/null || true
done
exit 0
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
chmod 0755 "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" SYNC_LOG="$WORK/sync" SYNC_WATCH=""
export LIB WORK

durable_uc() { ucode -L "$LIB" -e "let durable = require('core.durable'); let fs = require('fs'); $1"; }
watch() { rm -rf "$WORK/sync"; mkdir -p "$WORK/sync"; SYNC_WATCH="$*"; }
sync_count() { cat "$WORK/sync/count" 2>/dev/null || echo 0; }
# leftovers DIR: files in DIR other than the ones named after it.
leftovers() { find "$1" -mindepth 1 -maxdepth 1 -name '*forkop-*' -printf '%f ' 2>/dev/null; }

# ---- 1. a symlink stays one ----------------------------------------------------

mkdir -p "$WORK/link/etc" "$WORK/link/real"
REAL="$WORK/link/real/config"
LINK="$WORK/link/etc/config"
printf 'old\n' >"$REAL"
chmod 0640 "$REAL"
ln -s ../real/config "$LINK"
watch "$WORK/link/etc" "$WORK/link/real"
result="$(LINK="$LINK" durable_uc 'print(durable.durable_replace(getenv("LINK") + ".tmp", getenv("LINK"), "new\n", 0600));')"
[ "$result" = true ] || fail "a durable write through a symlink failed: $result"
[ -L "$LINK" ] || fail "a durable write replaced the symlink with a regular file"
[ "$(readlink "$LINK")" = ../real/config ] || fail "a durable write changed where the symlink points: $(readlink "$LINK")"
[ "$(cat "$REAL")" = new ] || fail "a durable write through a symlink did not reach the file it points to: $(cat "$REAL")"
[ "$(stat -c %a "$REAL")" = 600 ] || fail "a durable write through a symlink did not give the file its mode"
[ -z "$(leftovers "$WORK/link/etc")$(find "$WORK/link" -name '*.tmp' -printf '%f ')" ] ||
  fail "a durable write through a symlink left its temporary file"
# The temporary file was next to the file it replaced, flushed there before
# the rename, and the rename was flushed after it.
n=1 before="" after=""
while [ "$n" -le "$(sync_count)" ]; do
  snap="$WORK/sync/$n$WORK/link/real"
  if [ -z "$before" ] && [ -f "$snap/config.tmp" ] && [ "$(cat "$snap/config.tmp")" = new ] && [ "$(cat "$snap/config")" = old ]; then
    before=$n
  elif [ -n "$before" ] && [ "$(cat "$snap/config")" = new ] && [ ! -e "$snap/config.tmp" ]; then
    after=$n
  fi
  n=$((n + 1))
done
[ -n "$before" ] && [ -n "$after" ] || fail "a durable write through a symlink was not flushed next to its target before and after the rename"

# durable_rewrite keeps the mode of the file it replaces, through the
# symlink; checked_replace (no flush) keeps the symlink as well.
chmod 0640 "$REAL"
watch
result="$(LINK="$LINK" durable_uc 'print(durable.durable_rewrite(getenv("LINK"), "rewritten\n", 0644));')"
[ "$result" = true ] && [ -L "$LINK" ] && [ "$(cat "$REAL")" = rewritten ] && [ "$(stat -c %a "$REAL")" = 640 ] ||
  fail "a rewrite through a symlink: $result, $(stat -c '%F %a' "$LINK" "$REAL" | tr '\n' ' ')"
[ "$(sync_count)" -ge 2 ] || fail "a rewrite was not flushed"
[ -z "$(leftovers "$WORK/link/real")" ] || fail "a rewrite left its temporary file: $(leftovers "$WORK/link/real")"
watch
result="$(LINK="$LINK" durable_uc 'print(durable.checked_replace(getenv("LINK") + ".tmp", getenv("LINK"), "checked\n", 0600));')"
[ "$result" = true ] && [ -L "$LINK" ] && [ "$(cat "$REAL")" = checked ] ||
  fail "a checked write through a symlink: $result, $(stat -c '%F' "$LINK")"
[ "$(sync_count)" = 0 ] || fail "a checked write must not flush"

# A new file gets new_mode; an existing one keeps its own.
result="$(NEW="$WORK/link/real/new" durable_uc 'print(durable.durable_rewrite(getenv("NEW"), "x\n", 0604));')"
[ "$result" = true ] && [ "$(stat -c %a "$WORK/link/real/new")" = 604 ] || fail "a new file did not get its mode: $result"

# A symlink that points to nothing is left as it is: the write fails.
ln -s ../real/missing "$WORK/link/etc/dangling"
for fn in 'durable.durable_replace(getenv("P") + ".tmp", getenv("P"), "x\n", 0600)' \
  'durable.durable_rewrite(getenv("P"), "x\n", 0600)' 'durable.checked_replace(getenv("P") + ".tmp", getenv("P"), "x\n")'; do
  result="$(P="$WORK/link/etc/dangling" durable_uc "print($fn);")"
  [ "$result" = false ] || fail "a write through a symlink that points to nothing succeeded: $fn"
  [ -L "$WORK/link/etc/dangling" ] && [ ! -e "$WORK/link/real/missing" ] ||
    fail "a write through a symlink that points to nothing replaced it: $fn"
done
[ -z "$(find "$WORK/link" -name '*.tmp' -printf '%f ')$(leftovers "$WORK/link/etc")$(leftovers "$WORK/link/real")" ] ||
  fail "a refused write left a temporary file"
ok "a symlink stays one: the file it points to is replaced"

# ---- 2. the rename step --------------------------------------------------------

# swap() renames in place of a plain rename, between the two flushes; when
# it declines, nothing is replaced and no temporary file stays.
printf 'kept\n' >"$WORK/swap"
watch "$WORK"
result="$(F="$WORK/swap" durable_uc '
  let calls = [];
  let ok = durable.durable_replace(getenv("F") + ".tmp", getenv("F"), "new\n", null, function(tmp, target) {
      push(calls, fs.readfile(tmp) == "new\n" && target == getenv("F") && fs.readfile(getenv("SYNC_LOG") + "/count") == "1\n");
      return false;
  });
  print(ok, " ", calls, "\n");')"
[ "$result" = 'false [ true ]' ] || fail "a declined swap: $result"
[ "$(cat "$WORK/swap")" = kept ] && [ ! -e "$WORK/swap.tmp" ] || fail "a declined swap replaced the file or left its temporary file"
result="$(F="$WORK/swap" durable_uc '
  print(durable.durable_replace(getenv("F") + ".tmp", getenv("F"), "new\n", null, function(tmp, target) { return fs.rename(tmp, target); }));')"
[ "$result" = true ] && [ "$(cat "$WORK/swap")" = new ] || fail "a swap that renames: $result"
[ "$(sync_count)" -ge 3 ] || fail "the rename of a swap was not flushed after it"
ok "a swap renames between the two flushes or leaves the file"

printf 'durable_writers: PASS\n'
