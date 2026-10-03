#!/usr/bin/env bash
set -euo pipefail

# The forkop package ships two init scripts besides the kill-switch:
# forkop and forkop-torrserver-direct. A package change handles both (UC-083).
#
# Before: the package's prerm stopped only Forkop. A removal left the
# TorrServer Direct worker running from the loaded script, with its nft table
# that marks TorrServer's traffic, and the rc.d links of both services behind
# (S99forkop, S100forkop-torrserver-direct, K9forkop-torrserver-direct). An
# upgrade kept the worker of the previous release running until a reboot.
#
# Now a removal stops TorrServer Direct and disables both services. An
# upgrade restarts TorrServer Direct on the new code when it is switched on
# and enabled. The links of releases with START=100 and STOP=9 (UC-161),
# which rc.common's disable never removed and enabled no longer sees, are
# replaced with the current ones, or only removed when TorrServer Direct is
# switched off.
#
# The real service/package.uc runs against init scripts that record what they
# are asked to do and keep their rc.d links as rc.common does.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
PACKAGE_UC="$LIB/service/package.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK_DIR/events"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$EVENTS" ] || sed 's/^/  event: /' "$EVENTS" >&2
  printf '  rc.d: %s\n' "$(find "$RC_D" -mindepth 1 -printf '%f ')" >&2
  exit 1
}

RC_D="$WORK_DIR/rc.d"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$RC_D" "$WORK_DIR/component-update-checks"
export PATH="$WORK_DIR/bin:$PATH"
export EVENTS RC_D
export FORKOP_LIB="$LIB"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_CONFIG_PATH="$WORK_DIR/config-forkop"
export FORKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/default-forkop"
export FORKOP_INIT="$WORK_DIR/forkop-init"
export FORKOP_TORRSERVER_DIRECT_INIT="$WORK_DIR/torrserver-init"
export FORKOP_RC_D_DIR="$RC_D"
export FORKOP_BIN="$WORK_DIR/bin/forkop"
export FORKOP_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc"
export FORKOP_KILLSWITCH_UC="$WORK_DIR/missing-killswitch.uc"
export FORKOP_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init"
export FORKOP_SING_BOX_BIN="$WORK_DIR/missing-sing-box"
export FORKOP_SING_BOX_CRONET="$WORK_DIR/missing-libcronet.so"
export FORKOP_RT_TABLES="$WORK_DIR/rt_tables"
export FORKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/package-was-running"
export FORKOP_LEGACY_GUARD_ROOT="$WORK_DIR/legacy-guard"
export FORKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR="$WORK_DIR/component-update-checks"
export FORKOP_COMPONENT_UPDATE_CHECK_STATE_FILE="$WORK_DIR/component-update-check.timestamp"
export FORKOP_CRONTAB_FILE="$WORK_DIR/crontab"
export KILLSWITCH_NFT_POLICY="$WORK_DIR/killswitch-policy.nft"
printf "config settings 'settings'\n" >"$FORKOP_CONFIG_PATH"
cp "$FORKOP_CONFIG_PATH" "$FORKOP_DEFAULT_CONFIG_PATH"

# An init script as rc.common runs it: enable and disable keep the links of
# its START and STOP (rc.common's disable removes only S?? and K??), and
# enabled looks for exactly those. Every call is recorded.
init_script() { # init_script <path> <name> <START> [STOP]
  cat >"$1" <<SH
#!/bin/sh
name=$2
START=$3
STOP=${4:-}
SH
  cat >>"$1" <<'SH'
printf '%s %s\n' "$name" "$1" >>"$EVENTS"
case "$1" in
  status) exit 1 ;;
  enable)
    ln -sf "../init.d/$name" "$RC_D/S$START$name"
    [ -z "$STOP" ] || ln -sf "../init.d/$name" "$RC_D/K$STOP$name"
    ;;
  disable) rm -f "$RC_D"/S??"$name" "$RC_D"/K??"$name" ;;
  enabled)
    [ -L "$RC_D/S$START$name" ] || exit 1
    [ -z "$STOP" ] || [ -L "$RC_D/K$STOP$name" ]
    ;;
esac
exit 0
SH
  chmod +x "$1"
}
init_script "$FORKOP_INIT" forkop 99
init_script "$FORKOP_TORRSERVER_DIRECT_INIT" forkop-torrserver-direct 99 10
printf '#!/bin/sh\nexit 0\n' >"$FORKOP_BIN"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
# Nothing is left of Forkop's interception after its stop.
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
chmod +x "$FORKOP_BIN" "$WORK_DIR/bin/"*

reset_case() { # reset_case <torrserver_direct_enabled>
  : >"$EVENTS"
  rm -f "$RC_D"/* "$FORKOP_PACKAGE_UPGRADE_STATE"
  printf '100 main\n105 forkop\n' >"$FORKOP_RT_TABLES"
  printf 'forkop.settings=settings\nforkop.settings.dont_touch_dhcp=1\nforkop.settings.torrserver_direct_enabled=%s\n' \
    "$1" >"$FORKOP_UCI_STATE_FILE"
}
link() { ln -sf "../init.d/${1#[SK][0-9][0-9]}" "$RC_D/$1"; }
legacy_links() {
  ln -sf ../init.d/forkop-torrserver-direct "$RC_D/S100forkop-torrserver-direct"
  ln -sf ../init.d/forkop-torrserver-direct "$RC_D/K9forkop-torrserver-direct"
}
links_of() { find "$RC_D" -mindepth 1 -name "[SK]*$1" -printf '%f\n' | LC_ALL=C sort | tr '\n' ' '; }
called() { grep -Fqx "$1" "$EVENTS"; }
prerm() { ucode -L "$LIB" "$PACKAGE_UC" prerm "$@" >>"$EVENTS" 2>&1 || true; }
postinst() { ucode -L "$LIB" "$PACKAGE_UC" postinst >>"$EVENTS" 2>&1 || fail "postinst failed"; }

# 1. A removal stops TorrServer Direct and leaves no rc.d link of the
#    package's services, also none that an older release made.
reset_case 1
link S99forkop
legacy_links
prerm remove
called 'forkop-torrserver-direct stop' || fail "a removal did not stop TorrServer Direct"
called 'forkop-torrserver-direct disable' || fail "a removal did not disable TorrServer Direct"
called 'forkop disable' || fail "a removal did not disable Forkop"
[ -z "$(links_of forkop)$(links_of forkop-torrserver-direct)" ] ||
  fail "a removal left rc.d links behind: $(links_of forkop)$(links_of forkop-torrserver-direct)"

# 2. An upgrade keeps both services enabled and TorrServer Direct running
#    until postinst.
reset_case 1
link S99forkop
link S99forkop-torrserver-direct
link K10forkop-torrserver-direct
prerm upgrade 1.0.40
! grep -Eq '^(forkop-torrserver-direct (disable|stop)|forkop disable)$' "$EVENTS" ||
  fail "an upgrade stopped TorrServer Direct or disabled a service before postinst"
[ "$(links_of forkop-torrserver-direct)" = 'K10forkop-torrserver-direct S99forkop-torrserver-direct ' ] ||
  fail "an upgrade changed the rc.d links of TorrServer Direct: $(links_of forkop-torrserver-direct)"

# 3. postinst restarts TorrServer Direct on the new code when it is on.
: >"$EVENTS"
postinst
called 'forkop-torrserver-direct restart' || fail "postinst did not restart TorrServer Direct after the upgrade"
! called 'forkop-torrserver-direct enable' || fail "postinst made the links of an enabled TorrServer Direct again"

# 4. Switched off, or not enabled at boot: postinst leaves it alone.
reset_case 0
link S99forkop-torrserver-direct
link K10forkop-torrserver-direct
postinst
! grep -Eq '^forkop-torrserver-direct (restart|start|enable)$' "$EVENTS" ||
  fail "postinst started TorrServer Direct although it is switched off"
reset_case 1
postinst
! grep -Eq '^forkop-torrserver-direct (restart|start|enable)$' "$EVENTS" ||
  fail "postinst started TorrServer Direct although it is not enabled at boot"

# 5. Links of a release with START=100 and STOP=9 become the current ones
#    (UC-161), and TorrServer Direct restarts on the new code.
reset_case 1
legacy_links
postinst
[ "$(links_of forkop-torrserver-direct)" = 'K10forkop-torrserver-direct S99forkop-torrserver-direct ' ] ||
  fail "postinst did not replace the links of an older release: $(links_of forkop-torrserver-direct)"
called 'forkop-torrserver-direct restart' || fail "postinst did not restart TorrServer Direct enabled by an older release"

# 6. ... and only go when TorrServer Direct is switched off: the disable of an
#    older release never removed them.
reset_case 0
legacy_links
postinst
[ -z "$(links_of forkop-torrserver-direct)" ] ||
  fail "postinst kept or remade the links of a switched-off TorrServer Direct: $(links_of forkop-torrserver-direct)"
! grep -Eq '^forkop-torrserver-direct (restart|start|enable)$' "$EVENTS" ||
  fail "postinst started a switched-off TorrServer Direct"

printf 'package TorrServer Direct checks passed\n'
