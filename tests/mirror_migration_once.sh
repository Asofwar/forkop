#!/usr/bin/env bash
# The package feeds move to the mirror once (D-3 (a), UC-081).
#
# Every install and upgrade of the backend package runs mirror-migration.sh
# (build.sh write_backend_postinst). It records the move as
# mirror_infotechtg_ru_v1 in forkop.settings.applied_migrations, and a
# recorded move leaves the package feeds, the mirror key and the Forkop feed
# alone. Here the record lives where it does on a router, in
# /etc/config/forkop written by the uci CLI, across package changes:
#
#  - a first install, with the configuration the package ships, moves the
#    official OpenWrt feeds to the mirror and records it (the shipped
#    configuration listed the move as done, and a first install left the
#    feeds as they were);
#  - a later install or upgrade, after the user put the official feeds back
#    and removed the mirror key, changes no feed, key or setting and asks
#    the mirror for nothing;
#  - an upgrade from a release whose configuration has no record moves the
#    feeds as every package change did before, once; a move the mirror
#    could not serve is not recorded and runs again on the next change;
#  - a mirror chosen explicitly (install.sh FORKOP_MIRROR_BASE_URL) after
#    the recorded move is saved, and the feeds stay as they are.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION="$ROOT_DIR/forkop/files/usr/share/forkop/mirror-migration.sh"
SHIPPED_CONFIG="$ROOT_DIR/forkop/files/etc/config/forkop"
MIRROR="https://mirror.infotechtg.ru"
WORK="$(mktemp -d)"
# A call the uci test shim refused fails the test, even one it tolerated.
cleanup() {
  local rc=$?
  uci_cli_report || [ "$rc" != 0 ] || rc=1
  rm -rf "${WORK:?}"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# mirror-migration.sh reads and records the move with the uci CLI.
# shellcheck source=tests/helpers/uci_cli/select.sh
source "$ROOT_DIR/tests/helpers/uci_cli/select.sh"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "${CASE_DIR:-}/out" ] || sed 's/^/  output: /' "$CASE_DIR/out" >&2
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }

unset FORKOP_MIRROR_BASE_URL
mkdir -p "$WORK/bin" "$WORK/tmp"
export TMPDIR="$WORK/tmp" UCI_CLI PLATFORMS="$WORK/platforms.tsv"
printf '%s\n' 'mediatek/filogic aarch64_cortex-a53 24.10.5 ipk' \
  'rockchip/armv8 aarch64_generic 25.12.4 apk' >"$PLATFORMS"
# The mirror: its platform index and its APK key. Every request is an event.
cat >"$WORK/bin/curl" <<'EOF'
#!/bin/sh
output="" url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift; output="$1" ;;
    http://*|https://*) url="$1" ;;
  esac
  shift
done
printf 'curl %s\n' "$url" >>"${CASE_DIR:?}/events"
[ "${MIRROR_DOWN:-0}" = 0 ] || exit 7
case "$url" in
  https://mirror.infotechtg.ru/openwrt/forkop-platforms.tsv) cp "${PLATFORMS:?}" "$output" ;;
  https://mirror.infotechtg.ru/forkop/forkop-apk.pem)
    printf '%s\n' '-----BEGIN PUBLIC KEY-----' 'mirror-key' '-----END PUBLIC KEY-----' >"$output" ;;
  *) exit 22 ;;
esac
EOF
for manager in apk opkg; do
  # shellcheck disable=SC2016 # expanded by the stub when it runs
  printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >>"${CASE_DIR:?}/events"\n' "$manager" >"$WORK/bin/$manager"
done
# /etc/config/forkop of the case, through the uci CLI the test chose.
cat >"$WORK/bin/uci" <<'EOF'
#!/bin/sh
exec "${UCI_CLI:?}" -c "${CASE_DIR:?}/config" -t "${CASE_DIR:?}/uci-save" "$@"
EOF
chmod 0755 "$WORK/bin/"*

# new_case NAME MANAGER CONFIG: a router on the official OpenWrt feeds of
# MANAGER (apk or opkg), with CONFIG as /etc/config/forkop.
new_case() {
  CASE_DIR="$WORK/$1"
  MANAGER="$2"
  ROOT="$CASE_DIR/root"
  mkdir -p "$CASE_DIR/config" "$CASE_DIR/uci-save" "$ROOT/etc"
  cp "$3" "$CASE_DIR/config/forkop"
  if [ "$MANAGER" = apk ]; then
    mkdir -p "$ROOT/etc/apk/repositories.d"
    printf '%s\n' "DISTRIB_RELEASE='25.12.4'" "DISTRIB_TARGET='rockchip/armv8'" \
      "DISTRIB_ARCH='aarch64_generic'" >"$ROOT/etc/openwrt_release"
    printf '%s\n' 'https://downloads.openwrt.org/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb' \
      >"$ROOT/etc/apk/repositories"
    printf '%s\n' 'https://downloads.openwrt.org/releases/25.12.4/packages/aarch64_generic/base/packages.adb' \
      'https://downloads.openwrt.org/releases/25.12.4/packages/aarch64_generic/luci/packages.adb' \
      >"$ROOT/etc/apk/repositories.d/distfeeds.list"
  else
    mkdir -p "$ROOT/etc/opkg"
    printf '%s\n' "DISTRIB_RELEASE='24.10.5'" "DISTRIB_TARGET='mediatek/filogic'" \
      "DISTRIB_ARCH='aarch64_cortex-a53'" >"$ROOT/etc/openwrt_release"
    printf '%s\n' 'src/gz openwrt_core https://downloads.openwrt.org/releases/24.10.5/targets/mediatek/filogic/packages' \
      'src/gz openwrt_base https://downloads.openwrt.org/releases/24.10.5/packages/aarch64_cortex-a53/base' \
      >"$ROOT/etc/opkg/distfeeds.conf"
  fi
  mkdir -p "$CASE_DIR/official"
  cp -a "$ROOT/etc" "$CASE_DIR/official/etc"
}

# package_change: mirror-migration.sh as the package scripts run it.
# Sets RUN_RC; the requests and package manager calls go to the events.
package_change() {
  local apk_bin="$WORK/bin/missing-apk"
  [ "$MANAGER" != apk ] || apk_bin="$WORK/bin/apk"
  : >"$CASE_DIR/events"
  RUN_RC=0
  CASE_DIR="$CASE_DIR" FORKOP_MIGRATION_ROOT="$ROOT" FORKOP_MIGRATION_APK_BIN="$apk_bin" \
    FORKOP_MIGRATION_OPKG_BIN="$WORK/bin/opkg" FORKOP_MIGRATION_CURL_BIN="$WORK/bin/curl" \
    FORKOP_MIGRATION_UCI_BIN="$WORK/bin/uci" FORKOP_PACKAGE_POSTINST=1 \
    sh "$MIGRATION" >"$CASE_DIR/out" 2>&1 || RUN_RC=$?
}

# The user puts the official OpenWrt feeds back and drops the mirror's key
# and the Forkop feed.
restore_official_feeds() {
  local feed
  for feed in etc/apk/repositories etc/apk/repositories.d/distfeeds.list etc/opkg/distfeeds.conf; do
    [ ! -e "$CASE_DIR/official/$feed" ] || cp "$CASE_DIR/official/$feed" "$ROOT/$feed"
  done
  rm -f "$ROOT/etc/apk/keys/forkop-mirror.pem" "$ROOT/etc/apk/repositories.d/forkop.list"
}

# Every file of the router and of UCI: name, type, size, time and content;
# with arguments, of those parts only (root, config, uci-save).
state() {
  local parts=(root config uci-save)
  [ "$#" -eq 0 ] || parts=("$@")
  (cd "$CASE_DIR" &&
    find "${parts[@]}" -printf '%p %y %s %T@\n' | LC_ALL=C sort &&
    find "${parts[@]}" -type f -exec md5sum {} + | LC_ALL=C sort)
}

case_uci() {
  CASE_DIR="$CASE_DIR" "$WORK/bin/uci" -q get "forkop.settings.$1" 2>/dev/null || true
}
# How often the configuration records the move.
recorded() {
  case_uci applied_migrations | tr ' ' '\n' | grep -cFx mirror_infotechtg_ru_v1 || true
}

# The feeds of the case (not their .pre-forkop-mirror backups).
feeds() {
  if [ "$MANAGER" = apk ]; then
    printf '%s\n' "$ROOT/etc/apk/repositories" "$ROOT/etc/apk/repositories.d/distfeeds.list"
  else
    printf '%s\n' "$ROOT/etc/opkg/distfeeds.conf"
  fi
}
official_feeds_left() {
  local feed
  for feed in $(feeds); do
    grep -lE 'https?://(downloads|archive)\.openwrt\.org/' "$feed" || true
  done
}

# expect_moved WHAT: the package change WHAT moved the feeds to the mirror
# and recorded it once.
expect_moved() {
  [ "$RUN_RC" -eq 0 ] || fail "$1: the move failed (status $RUN_RC)"
  [ -z "$(official_feeds_left)" ] || fail "$1: official feeds are left: $(official_feeds_left)"
  grep -Fq 'curl https://mirror.infotechtg.ru/openwrt/forkop-platforms.tsv' "$CASE_DIR/events" ||
    fail "$1: the mirror's platform index was not checked"
  if [ "$MANAGER" = apk ]; then
    grep -Fxq "$MIRROR/openwrt/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb" \
      "$ROOT/etc/apk/repositories" || fail "$1: the target feed is not on the mirror"
    grep -Fxq "$MIRROR/openwrt/releases/25.12.4/packages/aarch64_generic/base/packages.adb" \
      "$ROOT/etc/apk/repositories.d/distfeeds.list" || fail "$1: the package feeds are not on the mirror"
    grep -Fxq 'mirror-key' "$ROOT/etc/apk/keys/forkop-mirror.pem" || fail "$1: the mirror key is missing"
    grep -Fxq "$MIRROR/forkop/mirror/current/packages.adb" "$ROOT/etc/apk/repositories.d/forkop.list" ||
      fail "$1: the Forkop feed is missing"
  else
    grep -Fxq "src/gz openwrt_core $MIRROR/openwrt/releases/24.10.5/targets/mediatek/filogic/packages" \
      "$ROOT/etc/opkg/distfeeds.conf" || fail "$1: the feeds are not on the mirror"
  fi
  [ "$(recorded)" = 1 ] || fail "$1: the move is recorded $(recorded) times"
  [ "$(case_uci mirror_base_url)" = "$MIRROR" ] ||
    fail "$1: the mirror is not saved: '$(case_uci mirror_base_url)'"
  [ ! -s "$CASE_DIR/uci-save/forkop" ] || fail "$1: UCI changes were left uncommitted"
}

# expect_left_alone WHAT BEFORE: the package change WHAT touched nothing.
expect_left_alone() {
  [ "$RUN_RC" -eq 0 ] || fail "$1: the recorded move failed (status $RUN_RC)"
  [ "$(state)" = "$2" ] || fail "$1: feeds, keys or the configuration changed:
$(diff <(printf '%s\n' "$2") <(state) || true)"
  [ ! -s "$CASE_DIR/events" ] || fail "$1: asked the mirror or ran the package manager: $(cat "$CASE_DIR/events")"
}

# 1. A first install, with the configuration the package ships, and later
# package changes after the user went back to the official feeds.
for manager in opkg apk; do
  new_case "first-$manager" "$manager" "$SHIPPED_CONFIG"
  [ "$(recorded)" = 0 ] || fail "$manager: the shipped configuration records the move of feeds it never moved"
  package_change
  expect_moved "$manager first install"
  restore_official_feeds
  before="$(state)"
  package_change
  expect_left_alone "$manager install after the user restored the official feeds" "$before"
  package_change
  expect_left_alone "$manager upgrade after the user restored the official feeds" "$before"
  [ -n "$(official_feeds_left)" ] || fail "$manager: the official feeds are gone"
  [ ! -e "$ROOT/etc/apk/keys/forkop-mirror.pem" ] || fail "$manager: the mirror key came back"
  ok "$manager: the first install moves the feeds once; restored official feeds stay"
done

# 2. An upgrade from a release that did not record the move (the retired
# mirror in its settings). An unreachable mirror is no move: nothing is
# recorded and the next package change moves the feeds, once.
cat >"$WORK/older-release.uci" <<'UCI'
config settings 'settings'
	option config_version '1.0.5'
	list applied_migrations 'interface_sections'
	list applied_migrations 'enable_component_checks'
	option mirror_base_url 'https://mirror.51343.ru'
UCI
new_case upgrade-opkg opkg "$WORK/older-release.uci"
before="$(state)"
MIRROR_DOWN=1 package_change
[ "$RUN_RC" -ne 0 ] || fail "upgrade: an unreachable mirror was reported as a move"
[ "$(state)" = "$before" ] || fail "upgrade: an unreachable mirror changed feeds or the configuration"
[ "$(recorded)" = 0 ] || fail "upgrade: an unreachable mirror recorded the move"
package_change
expect_moved "upgrade without a record"
restore_official_feeds
before="$(state)"
package_change
expect_left_alone "upgrade after the recorded move" "$before"
ok "upgrade without a record: moved once, after the mirror could serve it"

# 3. An upgrade from a release before this mirror, which moved the feeds
# to the retired mirror and recorded only that: the feeds move to this
# mirror once, and the official feeds the user restores afterwards stay.
cat >"$WORK/retired-release.uci" <<'UCI'
config settings 'settings'
	option config_version '1.0.4'
	list applied_migrations 'interface_sections'
	list applied_migrations 'mirror_51343_ru_v1'
	option mirror_base_url 'https://mirror.51343.ru'
UCI
new_case upgrade-apk apk "$WORK/retired-release.uci"
sed -i 's#https://downloads\.openwrt\.org/releases/#https://mirror.51343.ru/openwrt/releases/#' \
  "$ROOT/etc/apk/repositories" "$ROOT/etc/apk/repositories.d/distfeeds.list"
package_change
expect_moved "upgrade from the retired mirror"
# shellcheck disable=SC2046 # feeds: paths without blanks
! grep -q 'mirror\.51343\.ru' $(feeds) || fail "upgrade: feeds were left on the retired mirror"
restore_official_feeds
before="$(state)"
package_change
expect_left_alone "upgrade after the move from the retired mirror" "$before"
ok "upgrade from the retired mirror: moved once, restored official feeds stay"

# 4. install.sh run again with another mirror (FORKOP_MIRROR_BASE_URL),
# after the recorded move: the package scripts still save the mirror Forkop
# downloads from (lists, rule sets, full uninstall), as before the move was
# recorded, and leave the feeds and keys alone. The same mirror again
# writes nothing.
new_case explicit-opkg opkg "$SHIPPED_CONFIG"
package_change
expect_moved "explicit mirror: first install"
restore_official_feeds
before="$(state root)"
FORKOP_MIRROR_BASE_URL=https://alt.example/ package_change
[ "$RUN_RC" -eq 0 ] || fail "explicit mirror: the package change failed (status $RUN_RC)"
[ "$(case_uci mirror_base_url)" = https://alt.example ] ||
  fail "explicit mirror: not saved: '$(case_uci mirror_base_url)'"
[ "$(recorded)" = 1 ] || fail "explicit mirror: the move is recorded $(recorded) times"
[ ! -s "$CASE_DIR/uci-save/forkop" ] || fail "explicit mirror: UCI changes were left uncommitted"
[ "$(state root)" = "$before" ] || fail "explicit mirror: feeds or keys changed:
$(diff <(printf '%s\n' "$before") <(state root) || true)"
[ ! -s "$CASE_DIR/events" ] || fail "explicit mirror: asked a mirror or ran the package manager: $(cat "$CASE_DIR/events")"
before="$(state)"
FORKOP_MIRROR_BASE_URL=https://alt.example package_change
expect_left_alone "the explicit mirror saved before" "$before"
ok "explicit mirror after the recorded move: saved, feeds and keys left alone"
