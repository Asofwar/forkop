#!/bin/sh
set -eu

# The in-app Forkop upgrade brings Forkop back after the upgrade when the
# user's last request was a start, also when Forkop was down when the action
# began (D-15(a), UC-012).
#
# The user stopped Forkop and then started it while reload.lock was busy: the
# start waits for the lock (service/initd.uc defer_start). The upgrade noted
# that Forkop did not run when it began, stopped it for the install all the
# same, which cancelled the deferred start, and then skipped the start after
# the upgrade ("Forkop was not running before component change"). No prerm
# handed a start over either: the start was cancelled before the package
# manager ran (service/package.uc remember_upgrade_state). Forkop stayed down
# against the user's last request. So did a Forkop that came up while the
# upgrade prepared (the deferred start ran, or the user started it). The
# upgrade now looks again right before its own stop, as prerm does for the
# package manager's own upgrade: Forkop runs, or a deferred start is pending.
# A user's stop with no start after it still holds Forkop down.
#
# The upgrade runs end to end (tests/helpers/forkop_upgrade_harness.sh).

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR:?}"' EXIT HUP INT TERM
# shellcheck source=tests/helpers/forkop_upgrade_harness.sh
. "$ROOT_DIR/tests/helpers/forkop_upgrade_harness.sh"

fail() {
    printf 'forkop_upgrade_deferred_start: FAIL: %s\n' "$1" >&2
    upgrade_harness_dump
    exit 1
}

set_installed() {
    [ "$(upgrade_harness_version forkop)" = "$1" ] &&
        [ "$(upgrade_harness_version luci-app-forkop)" = "$1" ] &&
        [ "$(upgrade_harness_version luci-i18n-forkop-ru)" = "$1" ]
}

stop_request_by() {
    sed -n 's/^by=//p' "$UPGRADE_STATE/run/stop.requested" 2>/dev/null || true
}

# Forkop is down: the user stopped it.
user_stopped() {
    rm -f "$UPGRADE_STATE/running"
    mkdir -p "$UPGRADE_STATE/run"
    printf 'requested\nby=user\n' >"$UPGRADE_STATE/run/stop.requested"
}

# The upgrade completed, and Forkop runs after it.
expect_started() {
    upgrade_harness_succeeded || fail "$1: the upgrade failed: $(upgrade_harness_message)"
    set_installed 1.1.0-r1 || fail "$1: the new release is not installed"
    upgrade_harness_running || fail "$1: Forkop does not run after the upgrade"
    [ ! -e "$UPGRADE_STATE/run/stop.requested" ] || fail "$1: a stop is still recorded ($(stop_request_by))"
    [ ! -e "$UPGRADE_STATE/deferred-start" ] || fail "$1: the deferred start is still pending"
    if grep -q 'not running before component change\|stopped by the user' "$UPGRADE_STATE/logger.log" 2>/dev/null; then
        fail "$1: the start after the upgrade was skipped"
    fi
}

upgrade_harness_setup

for pm in apk opkg; do
    # --- the user's start deferred after the user's stop --------------------
    upgrade_harness_reset "$pm"
    user_stopped
    : >"$UPGRADE_STATE/deferred-start"
    case="$pm, the user's start deferred after the user's stop"
    upgrade_harness_run || fail "$case: the upgrade failed: $(upgrade_harness_message)"
    expect_started "$case"

    # --- Forkop comes up while the upgrade prepares --------------------------
    upgrade_harness_reset "$pm"
    user_stopped
    upgrade_harness_flag start_on_github
    case="$pm, Forkop started while the upgrade prepared"
    upgrade_harness_run || fail "$case: the upgrade failed: $(upgrade_harness_message)"
    expect_started "$case"

    # --- the user's stop, no start after it ----------------------------------
    upgrade_harness_reset "$pm"
    user_stopped
    case="$pm, the user's stop"
    upgrade_harness_run || fail "$case: the upgrade failed: $(upgrade_harness_message)"
    set_installed 1.1.0-r1 || fail "$case: the new release is not installed"
    ! upgrade_harness_running || fail "$case: Forkop runs after the upgrade against the user's stop"
    [ "$(stop_request_by)" = user ] || fail "$case: the user's stop is no longer recorded ($(stop_request_by))"
    if grep -q '^start' "$UPGRADE_STATE/init.log"; then
        fail "$case: Forkop was started against the user's stop"
    fi

    # --- the user's stop while the upgrade prepares cancels the deferred start
    upgrade_harness_reset "$pm"
    user_stopped
    : >"$UPGRADE_STATE/deferred-start"
    upgrade_harness_flag user_stop_on_github
    case="$pm, the user's stop after the deferred start"
    upgrade_harness_run || fail "$case: the upgrade failed: $(upgrade_harness_message)"
    set_installed 1.1.0-r1 || fail "$case: the new release is not installed"
    ! upgrade_harness_running || fail "$case: Forkop runs after the upgrade against the user's stop"
    [ "$(stop_request_by)" = user ] || fail "$case: the user's stop is no longer recorded ($(stop_request_by))"
    if grep -q '^start' "$UPGRADE_STATE/init.log"; then
        fail "$case: Forkop was started against the user's stop"
    fi
done

printf 'forkop_upgrade_deferred_start: PASS\n'
