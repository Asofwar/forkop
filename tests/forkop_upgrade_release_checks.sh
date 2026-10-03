#!/bin/sh
set -eu

# What the in-app Forkop upgrade checks in the release it downloads, before
# it stops Forkop (UC-027).
#
# Before: on a router without the Russian language pack the release plan
# ends in two empty fields, which trim() cut off, and every in-app upgrade
# failed with "Failed to resolve Forkop release packages" (UC-027).
#
# The upgrade runs end to end (tests/helpers/forkop_upgrade_harness.sh).

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
# shellcheck source=tests/helpers/forkop_upgrade_harness.sh
. "$ROOT_DIR/tests/helpers/forkop_upgrade_harness.sh"

fail() {
    printf 'forkop_upgrade_release_checks: FAIL: %s\n' "$1" >&2
    upgrade_harness_dump
    exit 1
}

upgrade_harness_setup

for pm in apk opkg; do
    # --- a router without the Russian language pack -------------------------
    # The release plan has no i18n package; the upgrade installs the backend
    # and the LuCI app, and stages and checks the previous release without
    # the language pack.
    upgrade_harness_reset "$pm"
    rm -f "$UPGRADE_STATE/pkg/luci-i18n-forkop-ru"
    case="$pm without the language pack"
    upgrade_harness_run || fail "$case: the upgrade failed: $(upgrade_harness_message)"
    if [ "$(upgrade_harness_version forkop)" != 1.1.0-r1 ] ||
        [ "$(upgrade_harness_version luci-app-forkop)" != 1.1.0-r1 ]; then
        fail "$case: the new release is not installed"
    fi
    [ -z "$(upgrade_harness_version luci-i18n-forkop-ru)" ] || fail "$case: the language pack was installed"
    ! grep -q 'luci-i18n-forkop-ru' "$UPGRADE_STATE/curl.log" || fail "$case: the language pack was downloaded"
    upgrade_harness_running || fail "$case: Forkop does not run after the upgrade"
done

printf 'forkop_upgrade_release_checks: PASS\n'
