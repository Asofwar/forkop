#!/usr/bin/env bash
set -euo pipefail

# A crontab that another writer changed between Forkop's `crontab` and its
# read-back is not overwritten (S5 integration, UC-159).
#
# Forkop reads the crontab back after `crontab`, because BusyBox crontab
# renames a copy cut short by a full overlay over the crontab and exits 0
# (tests/crontab_partial_write.sh). Only a crontab that holds Forkop's own
# new text cut short is Forkop's failed write: the previous crontab is put
# back then. Any other content is someone else's change made in between (a
# LuCI Scheduled Tasks save, an opkg postinst, the autotune manager or the
# list update cron refresh): putting the previous crontab back would erase
# it. The rewrite fails and says so, and the crontab keeps that change.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
UPDATES_UC="$FORKOP_LIB/components/updates.uc"
MANAGER_UC="$FORKOP_LIB/autotune/manager.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK/bin" "$WORK/tmp"
# BusyBox crontab <file>: installs the file. With $WORK/foreign present,
# another writer replaces the crontab right after it, once.
cat >"$WORK/bin/crontab" <<SH
#!/bin/sh
printf '%s\n' "\$1" >>"$WORK/crontab.calls"
cp "\$1" "$WORK/crontab"
if [ -e "$WORK/foreign" ]; then
  cp "$WORK/foreign" "$WORK/crontab"
  rm -f "$WORK/foreign"
fi
exit 0
SH
cat >"$WORK/bin/logger" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"$WORK/syslog"
SH
chmod +x "$WORK/bin/crontab" "$WORK/bin/logger"
export PATH="$WORK/bin:$PATH"
export FORKOP_CRONTAB_FILE="$WORK/crontab" FORKOP_AUTOTUNE_CRONTAB="$WORK/bin/crontab" FORKOP_AUTOTUNE_TMPDIR="$WORK/tmp"
export TMPDIR="$WORK/tmp"

cat >"$WORK/crontab.orig" <<'CRON'
0 4 * * * /usr/local/bin/backup.sh
0 0 * * * /usr/bin/forkop list_update_if_due # forkop-list-update
*/15 * * * * /usr/bin/forkop autotune_if_due >/dev/null 2>&1 # forkop-autotune
CRON
# What the other writer saves: the crontab as it read it, plus its own job.
{
  cat "$WORK/crontab.orig"
  printf '%s\n' '30 2 * * * /usr/local/bin/rotate-logs.sh'
} >"$WORK/crontab.foreign"

setup() {
  cp "$WORK/crontab.orig" "$WORK/crontab"
  cp "$WORK/crontab.foreign" "$WORK/foreign"
  : >"$WORK/syslog"
  : >"$WORK/crontab.calls"
}
json_get() {
  node -e 'const v=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify(v[process.argv[2]]))' "$1" "$2"
}

# The cron refresh of components/updates.uc.
setup
status=0
ucode -L "$FORKOP_LIB" "$UPDATES_UC" remove-cron-jobs '# forkop-list-update' '# forkop-subscription-update' \
  '# forkop-component-update' >"$WORK/remove.out" 2>&1 || status=$?
[ "$status" != 0 ] || fail "a crontab another writer changed meanwhile was reported as written"
cmp -s "$WORK/crontab.foreign" "$WORK/crontab" ||
  fail "the change another writer made to the crontab was overwritten: $(cat "$WORK/crontab")"
[ "$(wc -l <"$WORK/crontab.calls")" = 1 ] || fail "crontab was called again after the read-back: $(cat "$WORK/crontab.calls")"
grep -F "$WORK/crontab" "$WORK/syslog" | grep -F '[error]' | grep -Fq 'another writer' ||
  fail "the conflict was not logged as an error naming the crontab: $(cat "$WORK/syslog")"
printf 'ok - the cron refresh keeps a change another writer made meanwhile and fails\n'

# The autotune cron line.
setup
ucode -L "$FORKOP_LIB" "$MANAGER_UC" cron-remove >"$WORK/autotune.json" 2>&1 || true
[ "$(json_get "$WORK/autotune.json" status)" = '"failed"' ] ||
  fail "an autotune cron rewrite that another writer overtook was reported as done: $(cat "$WORK/autotune.json")"
[ "$(json_get "$WORK/autotune.json" reason)" = '"crontab_changed"' ] ||
  fail "the autotune cron rewrite must report the conflict: $(cat "$WORK/autotune.json")"
cmp -s "$WORK/crontab.foreign" "$WORK/crontab" ||
  fail "the autotune cron rewrite overwrote the change of another writer: $(cat "$WORK/crontab")"
[ "$(wc -l <"$WORK/crontab.calls")" = 1 ] || fail "the autotune manager called crontab again after the read-back"
grep -F '[error]' "$WORK/syslog" | grep -Fi autotune | grep -Fq 'another writer' ||
  fail "the autotune cron conflict was not logged as an error: $(cat "$WORK/syslog")"
printf 'ok - the autotune cron rewrite keeps a change another writer made meanwhile and fails\n'

printf 'crontab foreign change checks passed\n'
