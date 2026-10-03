#!/usr/bin/env bash
# install.sh moves the package feeds to the mirror once (D-3 (a), UC-081).
#
# The Forkop package records the move as mirror_infotechtg_ru_v1 in
# forkop.settings.applied_migrations (mirror-migration.sh, which every
# package change runs), and a recorded move leaves the package feeds alone,
# also official feeds the user put back. install.sh moved the feeds again on
# every run (configure_package_mirror), before it installed the package, and
# asked the mirror whether it serves the platform: running the installer
# again to repair or update Forkop undid the user's choice of feeds, and put
# the mirror's key and the Forkop feed back on apk.
#
# Now a recorded move leaves the feeds, keys and the Forkop feed as they are
# and asks the mirror for nothing. Feeds on the retired mirror, which serves
# nothing, still move, as in mirror-migration.sh. A mirror named for this
# run (FORKOP_MIRROR_BASE_URL) is the user's request to move the feeds to
# it, and so is a run without a record (a first install).
#
# install.sh runs as a library with the feeds, keys and Forkop feed of each
# case under its own root; the mirror, the package manager and the record
# that the installer's UCI helper reads are test doubles.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR="https://mirror.infotechtg.ru"
RECORDED="interface_sections mirror_infotechtg_ru_v1"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'installer_mirror_once: FAIL: %s\n' "$1" >&2
  [ ! -s "${CASE:-}/out" ] || sed 's/^/  output: /' "$CASE/out" >&2
  [ ! -s "${CASE:-}/events" ] || sed 's/^/  event: /' "$CASE/events" >&2
  exit 1
}

PLATFORMS="$WORK/platforms.tsv"
printf '%s\n' 'mediatek/filogic aarch64_cortex-a53 24.10.5 ipk' \
  'rockchip/armv8 aarch64_generic 25.12.4 apk' >"$PLATFORMS"
export PLATFORMS

# new_case NAME MANAGER [retired]: a router on the official OpenWrt feeds
# of MANAGER (apk or opkg), or with retired on the retired mirror.
new_case() {
  CASE="$WORK/$1"
  MANAGER="$2"
  ROOT="$CASE/root"
  mkdir -p "$CASE/tmp"
  if [ "$MANAGER" = apk ]; then
    mkdir -p "$ROOT/etc/apk/repositories.d"
    printf '%s\n' 'https://downloads.openwrt.org/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb' \
      >"$ROOT/etc/apk/repositories"
    printf '%s\n' 'https://downloads.openwrt.org/releases/25.12.4/packages/aarch64_generic/base/packages.adb' \
      >"$ROOT/etc/apk/repositories.d/distfeeds.list"
  else
    mkdir -p "$ROOT/etc/opkg"
    printf '%s\n' 'src/gz openwrt_core https://downloads.openwrt.org/releases/24.10.5/targets/mediatek/filogic/packages' \
      'src/gz openwrt_base https://downloads.openwrt.org/releases/24.10.5/packages/aarch64_cortex-a53/base' \
      >"$ROOT/etc/opkg/distfeeds.conf"
  fi
  if [ "${3:-}" = retired ]; then
    find "$ROOT/etc" -type f -exec sed -i 's#https://downloads\.openwrt\.org/#https://mirror.51343.ru/openwrt/#' {} +
  fi
  # install.sh with the apk files of the case's root.
  sed -e '/^main "\$@"$/d' -e "s#/etc/apk#$ROOT/etc/apk#g" "$ROOT_DIR/install.sh" >"$CASE/install-library.sh"
}

# state: every file of the case's root with its content.
state() {
  (cd "$ROOT" && find . -printf '%p %y %s\n' | LC_ALL=C sort && find . -type f -exec md5sum {} + | LC_ALL=C sort)
}

# run_installer RECORD [MIRROR]: install.sh's mirror check and feed setup
# (check_system, configure_package_mirror) with RECORD as
# forkop.settings.applied_migrations ("" for no record) and MIRROR as
# FORKOP_MIRROR_BASE_URL. Sets RC.
run_installer() {
  : >"$CASE/events"
  RC=0
  (
    if [ -n "${2:-}" ]; then
      export FORKOP_MIRROR_BASE_URL="$2"
    else
      unset FORKOP_MIRROR_BASE_URL
    fi
    export FORKOP_OPKG_DISTFEEDS_FILE="$ROOT/etc/opkg/distfeeds.conf" CASE RECORD="$1"
    # shellcheck disable=SC1091
    . "$CASE/install-library.sh"
    # shellcheck disable=SC2034 # read by install.sh
    TMP_DIR="$CASE/tmp" FETCHER=curl
    if [ "$MANAGER" = apk ]; then
      # shellcheck disable=SC2034 # read by install.sh
      PKG_IS_APK=1 OPENWRT_RELEASE=25.12.4 OPENWRT_TARGET=rockchip/armv8 OPENWRT_ARCHITECTURE=aarch64_generic
    else
      # shellcheck disable=SC2034 # read by install.sh
      PKG_IS_APK=0 OPENWRT_RELEASE=24.10.5 OPENWRT_TARGET=mediatek/filogic OPENWRT_ARCHITECTURE=aarch64_cortex-a53
    fi
    # The mirror; every request is an event.
    # shellcheck disable=SC2317 # called by install.sh
    download_file_once() {
      printf 'download %s\n' "$1" >>"$CASE/events"
      case "$1" in
        */openwrt/forkop-platforms.tsv) cp "$PLATFORMS" "$2" ;;
        */forkop/forkop-apk.pem)
          printf '%s\n' '-----BEGIN PUBLIC KEY-----' 'mirror-key' '-----END PUBLIC KEY-----' >"$2" ;;
        *) return 22 ;;
      esac
    }
    # shellcheck disable=SC2317 # called by install.sh
    download_with_retry() { download_file_once "$1" "$2"; }
    # shellcheck disable=SC2317 # called by install.sh
    pkg_list_update() { printf 'package lists update\n' >>"$CASE/events"; }
    # shellcheck disable=SC2317 # called by install.sh
    command_exists() { return 0; }
    # The installer's UCI helper (install-json.uc uci-get) on the router's
    # /etc/config/forkop.
    # shellcheck disable=SC2317 # called by install.sh
    install_json_ucode() {
      [ "$1" = uci-get ] && [ "$2" = forkop.settings.applied_migrations ] || return 1
      [ -z "$RECORD" ] || printf '%s\n' "$RECORD"
    }
    check_mirror_platform_support
    configure_package_mirror
  ) >"$CASE/out" 2>&1 || RC=$?
}

official_feeds_left() {
  grep -rlE 'https?://(downloads|archive)\.openwrt\.org/' "$ROOT/etc" --include=distfeeds.conf \
    --include=distfeeds.list --include=repositories || true
}

# expect_moved WHAT TO: the run WHAT moved the official feeds to mirror TO.
expect_moved() {
  [ "$RC" -eq 0 ] || fail "$1: the installer failed (status $RC)"
  [ -z "$(official_feeds_left)" ] || fail "$1: official feeds are left: $(official_feeds_left)"
  if grep -rq 'mirror\.51343\.ru' "$ROOT/etc" --include=distfeeds.conf --include=distfeeds.list --include=repositories; then
    fail "$1: feeds are left on the retired mirror"
  fi
  grep -Fxq "download $2/openwrt/forkop-platforms.tsv" "$CASE/events" || fail "$1: the mirror's platform index was not checked"
  grep -Fxq 'package lists update' "$CASE/events" || fail "$1: the package lists were not updated from the mirror"
  if [ "$MANAGER" = apk ]; then
    grep -Fxq "$2/openwrt/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb" "$ROOT/etc/apk/repositories" ||
      fail "$1: the target feed is not on the mirror"
    grep -Fxq 'mirror-key' "$ROOT/etc/apk/keys/forkop-mirror.pem" || fail "$1: the mirror key is missing"
    grep -Fxq "$2/forkop/mirror/current/packages.adb" "$ROOT/etc/apk/repositories.d/forkop.list" ||
      fail "$1: the Forkop feed is missing"
  else
    grep -Fxq "src/gz openwrt_core $2/openwrt/releases/24.10.5/targets/mediatek/filogic/packages" \
      "$ROOT/etc/opkg/distfeeds.conf" || fail "$1: the feeds are not on the mirror"
  fi
}

for manager in opkg apk; do
  # 1. The move is recorded and the user is back on the official feeds,
  #    without the mirror's key and the Forkop feed: install.sh leaves them
  #    and asks the mirror for nothing.
  new_case "recorded-$manager" "$manager"
  before="$(state)"
  case="$manager, recorded move"
  run_installer "$RECORDED"
  [ "$RC" -eq 0 ] || fail "$case: the installer failed (status $RC)"
  [ "$(state)" = "$before" ] || fail "$case: feeds, keys or the Forkop feed changed:
$(diff <(printf '%s\n' "$before") <(state) || true)"
  [ ! -s "$CASE/events" ] || fail "$case: asked the mirror or updated the package lists"
  grep -q 'left as they are' "$CASE/out" || fail "$case: the installer does not say why the feeds stay"

  # 2. No record (a first install, or a configuration of a release before
  #    the record): the feeds move.
  new_case "first-$manager" "$manager"
  run_installer ""
  expect_moved "$manager, no record" "$MIRROR"

  # 3. A mirror named for this run is the user's request to move the feeds,
  #    also after the recorded move.
  new_case "explicit-$manager" "$manager"
  run_installer "$RECORDED" https://alt.example/
  expect_moved "$manager, recorded move, explicit mirror" https://alt.example

  # 4. Feeds on the retired mirror serve nothing: they move to this one
  #    also after the recorded move, as in mirror-migration.sh.
  new_case "retired-$manager" "$manager" retired
  run_installer "$RECORDED"
  expect_moved "$manager, recorded move, feeds on the retired mirror" "$MIRROR"
done

printf 'installer_mirror_once: PASS\n'
