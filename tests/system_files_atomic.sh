#!/usr/bin/env bash
set -euo pipefail

# System files that Forkop shares with other packages are replaced whole
# (UC-076).
#
# /etc/iproute2/rt_tables (other packages name their tables there) and the
# package feeds were truncated and rewritten in place: a crash or a full
# overlay in between lost every entry or broke package management. Now each
# is written to a copy next to it and renamed over it, so a reader (and a
# reboot) sees the previous file or the new one, never a part of one; the
# mode stays, no copy is left behind. When the mirror migration fails, its
# rollback of the feeds and keys says which files it could not restore
# instead of claiming that all were.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
MIGRATION="$ROOT_DIR/forkop/files/usr/share/forkop/mirror-migration.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }

mkdir -p "$WORK/bin" "$WORK/etc/iproute2"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
# Routes and rules of table forkop are in place: only rt_tables is written.
cat >"$WORK/bin/ip" <<'SH'
#!/bin/sh
case "$*" in
  "route list table forkop") echo 'local default dev lo scope host' ;;
  "-6 route list table forkop") echo 'local default dev lo metric 1024 pref medium' ;;
  "-4 rule list"|"-6 rule list") echo '105: from all fwmark 0x100000/0x100000 lookup forkop' ;;
esac
exit 0
SH
chmod 0755 "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"

# replaced_whole <file> <label> <command...>: the command replaces the file
# by a rename. A reader that opened it before still reads the previous
# content, the mode stays and nothing is left next to it.
replaced_whole() {
  local file="$1" label="$2" before mode
  shift 2
  before="$(cat "$file")"
  mode="$(stat -c %a "$file")"
  exec 3<"$file"
  "$@" || fail "$label failed"
  [ "$(cat <&3)" = "$before" ] || fail "$label rewrote $(basename "$file") in place: a reader of the previous file saw it change"
  exec 3<&-
  [ "$(stat -c %a "$file")" = "$mode" ] || fail "$label changed the mode of $(basename "$file")"
  local extra
  extra="$(find "$(dirname "$file")" -mindepth 1 -maxdepth 1 \( -name "$(basename "$file").*" -o -name ".$(basename "$file")*" \) \
    ! -type d ! -name '*.pre-forkop-mirror' -printf '%f ')"
  [ -z "$extra" ] || fail "$label left behind: $extra"
}

# ---- 1. rt_tables -------------------------------------------------------------

RT="$WORK/etc/iproute2/rt_tables"
printf '%s\n' '255 local' '254 main' '200 vendor' >"$RT"
chmod 0640 "$RT"
replaced_whole "$RT" "the start (ensure the table name)" \
  ucode -L "$LIB" "$LIB/nft/apply.uc" ensure-tproxy-route-rule forkop 0x00100000 "$RT"
grep -Fxq '105 forkop' "$RT" && grep -Fxq '200 vendor' "$RT" || fail "the start did not add its table name next to the others: $(cat "$RT")"
before="$(stat -c '%i %y' "$RT")"
ucode -L "$LIB" "$LIB/nft/apply.uc" ensure-tproxy-route-rule forkop 0x00100000 "$RT" || fail "a second start failed"
[ "$(stat -c '%i %y' "$RT")" = "$before" ] || fail "a start rewrote rt_tables that already named its table"

replaced_whole "$RT" "the package removal" \
  env FORKOP_RT_TABLES="$RT" ucode -L "$LIB" "$LIB/service/package.uc" remove-rt-tables-entry
[ "$(cat "$RT")" = "$(printf '%s\n' '255 local' '254 main' '200 vendor')" ] ||
  fail "the package removal did not keep exactly the other entries: $(cat "$RT")"

# A symlink stays one: the file it points to is replaced.
mkdir -p "$WORK/usr-share"
printf '%s\n' '254 main' >"$WORK/usr-share/rt_tables"
rm -f "$RT"
ln -s ../../usr-share/rt_tables "$RT"
ucode -L "$LIB" "$LIB/nft/apply.uc" ensure-tproxy-route-rule forkop 0x00100000 "$RT" || fail "the start through a symlink failed"
[ -L "$RT" ] && grep -Fxq '105 forkop' "$WORK/usr-share/rt_tables" || fail "the start replaced the rt_tables symlink or missed its target"
FORKOP_RT_TABLES="$RT" ucode -L "$LIB" "$LIB/service/package.uc" remove-rt-tables-entry || fail "the removal through a symlink failed"
[ -L "$RT" ] && [ "$(cat "$WORK/usr-share/rt_tables")" = '254 main' ] || fail "the removal replaced the rt_tables symlink or missed its target"
ok "rt_tables is replaced whole by a rename, its mode and other entries kept"

# ---- 2. the package feeds -----------------------------------------------------

cat >"$WORK/bin/curl" <<'SH'
#!/bin/sh
output=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift; output="$1" ;;
    http://*|https://*) url="$1" ;;
  esac
  shift
done
case "$url" in
  */openwrt/forkop-platforms.tsv)
    printf '%s\n' 'rockchip/armv8 aarch64_generic 25.12.4 apk' 'mediatek/filogic aarch64_cortex-a53 24.10.5 ipk' >"$output" ;;
  */forkop/forkop-apk.pem)
    printf '%s\n' '-----BEGIN PUBLIC KEY-----' 'new-key' '-----END PUBLIC KEY-----' >"$output" ;;
  *) exit 22 ;;
esac
SH
# The package index update fails when MIGRATION_UPDATE_FAILS is set; with
# MIGRATION_BREAK_ROLLBACK the feeds directory turns unrestorable first (the
# new Forkop feed file becomes a directory with content).
cat >"$WORK/bin/apk" <<'SH'
#!/bin/sh
[ "$1" = update ] || exit 0
if [ -n "${MIGRATION_BREAK_ROLLBACK:-}" ]; then
  rm -f "$MIGRATION_BREAK_ROLLBACK"
  mkdir -p "$MIGRATION_BREAK_ROLLBACK"
  : >"$MIGRATION_BREAK_ROLLBACK/busy"
fi
[ -z "${MIGRATION_UPDATE_FAILS:-}" ]
SH
cp "$WORK/bin/apk" "$WORK/bin/opkg"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/uci"
chmod 0755 "$WORK/bin/"*

migrate() {
  local root="$1" manager="$2"
  shift 2
  env FORKOP_MIGRATION_ROOT="$root" \
    FORKOP_MIGRATION_APK_BIN="$WORK/bin/$([ "$manager" = apk ] && echo apk || echo missing-apk)" \
    FORKOP_MIGRATION_OPKG_BIN="$WORK/bin/opkg" \
    FORKOP_MIGRATION_CURL_BIN="$WORK/bin/curl" \
    FORKOP_MIGRATION_UCI_BIN="$WORK/bin/uci" \
    "$@" sh "$MIGRATION"
}

OPKG_ROOT="$WORK/opkg-root"
mkdir -p "$OPKG_ROOT/etc/opkg"
printf '%s\n' "DISTRIB_RELEASE='24.10.5'" "DISTRIB_TARGET='mediatek/filogic'" "DISTRIB_ARCH='aarch64_cortex-a53'" \
  >"$OPKG_ROOT/etc/openwrt_release"
FEEDS="$OPKG_ROOT/etc/opkg/distfeeds.conf"
printf '%s\n' 'src/gz openwrt_core https://downloads.openwrt.org/releases/24.10.5/targets/mediatek/filogic/packages' \
  'src/gz vendor https://packages.vendor.example/24.10/base' >"$FEEDS"
chmod 0600 "$FEEDS"
replaced_whole "$FEEDS" "the opkg mirror migration" migrate "$OPKG_ROOT" opkg
grep -Fq 'https://mirror.infotechtg.ru/openwrt/releases/24.10.5/targets/mediatek/filogic/packages' "$FEEDS" &&
  grep -Fxq 'src/gz vendor https://packages.vendor.example/24.10/base' "$FEEDS" ||
  fail "the opkg mirror migration did not rewrite the feeds: $(cat "$FEEDS")"

APK_ROOT="$WORK/apk-root"
mkdir -p "$APK_ROOT/etc/apk/repositories.d" "$APK_ROOT/etc/apk/keys"
printf '%s\n' "DISTRIB_RELEASE='25.12.4'" "DISTRIB_TARGET='rockchip/armv8'" "DISTRIB_ARCH='aarch64_generic'" \
  >"$APK_ROOT/etc/openwrt_release"
REPOS="$APK_ROOT/etc/apk/repositories"
KEY="$APK_ROOT/etc/apk/keys/forkop-mirror.pem"
LIST="$APK_ROOT/etc/apk/repositories.d/forkop.list"
printf '%s\n' 'https://downloads.openwrt.org/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb' >"$REPOS"
printf '%s\n' '-----BEGIN PUBLIC KEY-----' 'old-key' '-----END PUBLIC KEY-----' >"$KEY"
printf '%s\n' 'https://mirror.51343.ru/forkop/mirror/current/packages.adb' >"$LIST"
chmod 0644 "$REPOS" "$KEY" "$LIST"
for file in "$REPOS" "$KEY" "$LIST"; do
  replaced_whole "$file" "the apk mirror migration" migrate "$APK_ROOT" apk
  # The next round migrates the same file again.
  [ "$file" != "$REPOS" ] || printf '%s\n' 'https://downloads.openwrt.org/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb' >"$REPOS"
  [ "$file" != "$REPOS" ] || printf '%s\n' '-----BEGIN PUBLIC KEY-----' 'old-key' '-----END PUBLIC KEY-----' >"$KEY"
  [ "$file" != "$KEY" ] || printf '%s\n' 'https://mirror.51343.ru/forkop/mirror/current/packages.adb' >"$LIST"
done
grep -Fxq new-key "$KEY" && grep -Fq 'mirror.infotechtg.ru/forkop/mirror/current' "$LIST" ||
  fail "the apk mirror migration did not install its key and feed"
ok "the mirror migration replaces feeds and keys whole by a rename, their mode kept"

# ---- 3. a rollback that cannot restore says so ----------------------------------

# Control: a failed migration restores the feeds and says so.
printf '%s\n' 'https://downloads.openwrt.org/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb' >"$REPOS"
rm -f "$KEY" "$LIST"
cp "$REPOS" "$WORK/repos.orig"
status=0
migrate "$APK_ROOT" apk MIGRATION_UPDATE_FAILS=1 2>"$WORK/rollback.err" || status=$?
[ "$status" != 0 ] || fail "a migration whose index update failed reported success"
cmp -s "$WORK/repos.orig" "$REPOS" && [ ! -e "$KEY" ] && [ ! -e "$LIST" ] || fail "the failed migration was not rolled back"
grep -q 'were restored' "$WORK/rollback.err" || fail "a complete rollback did not say so: $(cat "$WORK/rollback.err")"

# The new Forkop feed file cannot be removed again.
status=0
migrate "$APK_ROOT" apk MIGRATION_UPDATE_FAILS=1 MIGRATION_BREAK_ROLLBACK="$LIST" 2>"$WORK/rollback.err" || status=$?
[ "$status" != 0 ] || fail "a migration whose rollback failed reported success"
grep -q 'were restored' "$WORK/rollback.err" && fail "a rollback that could not remove the new feed claimed success: $(cat "$WORK/rollback.err")"
grep -Fq "$LIST" "$WORK/rollback.err" || fail "a rollback that failed did not name the file: $(cat "$WORK/rollback.err")"
cmp -s "$WORK/repos.orig" "$REPOS" || fail "a rollback that failed for one file did not restore the others"
rm -rf "$LIST"

# A read-only overlay: nothing can be restored, and the rollback says so.
if unshare -rm true 2>/dev/null; then
  cat >"$WORK/bin/apk-ro" <<'SH'
#!/bin/sh
[ "$1" = update ] || exit 0
mount --bind "$MIGRATION_RO_DIR" "$MIGRATION_RO_DIR" && mount -o remount,bind,ro "$MIGRATION_RO_DIR"
exit 1
SH
  chmod 0755 "$WORK/bin/apk-ro"
  status=0
  # shellcheck disable=SC2016 # expanded by the sh that runs it
  unshare -rm sh -c 'cp "$1" "$2" && shift 2 && exec "$@"' sh "$WORK/bin/apk-ro" "$WORK/bin/apk" \
    env FORKOP_MIGRATION_ROOT="$APK_ROOT" FORKOP_MIGRATION_APK_BIN="$WORK/bin/apk" \
    FORKOP_MIGRATION_CURL_BIN="$WORK/bin/curl" FORKOP_MIGRATION_UCI_BIN="$WORK/bin/uci" \
    MIGRATION_RO_DIR="$APK_ROOT/etc/apk" sh "$MIGRATION" 2>"$WORK/rollback.err" || status=$?
  cp "$WORK/bin/opkg" "$WORK/bin/apk"
  [ "$status" != 0 ] || fail "a migration on a read-only overlay reported success"
  grep -q 'were restored' "$WORK/rollback.err" && fail "a rollback on a read-only overlay claimed success: $(cat "$WORK/rollback.err")"
  grep -Fq "$REPOS" "$WORK/rollback.err" || fail "a rollback on a read-only overlay did not name the feed it left: $(cat "$WORK/rollback.err")"
else
  printf 'NOTE: no user and mount namespaces; the read-only overlay check is skipped\n'
fi
ok "a rollback that cannot restore every feed and key says which and fails"

printf 'system file replacement checks passed\n'
