#!/usr/bin/env bash
# The backend package of the OpenWrt SDK recipe (forkop/Makefile) is the
# package build.sh builds for the releases (D-21 (a), UC-082): the same
# files with the same modes and contents, the same conffiles, and package
# scripts that do the same.
#
# Before, the SDK package lacked /etc/init.d/forkop-torrserver-direct
# (TorrServer Direct could not be enabled), installed the configuration
# 0600, copied the library with whatever modes the checkout had, refused an
# x.y.z-N release version (so did the LuCI app's recipe), never stopped
# Forkop before an apk upgrade (apk runs no pre-upgrade script of a package
# without Package/preinst), and OpenWrt's default package scripts, which
# the SDK wraps around a package's own, enabled Forkop on its first install
# and started it after every install and upgrade: also a Forkop the user
# had stopped (D-15) and, on apk, before its configuration was migrated.
#
# The SDK recipe runs through GNU make against a stand-in of the SDK's
# rules.mk and package.mk with OpenWrt's install commands and its way of
# writing a package script (shexport, echo); the default package scripts
# follow OpenWrt's lib/functions.sh and include/package-pack.mk (24.10
# ipk, 25.12 apk); the init script is the real one behind an rc.common
# stand-in.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/build.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR:?}"' EXIT
trap 'exit 1' HUP INT TERM
# shellcheck source=tests/helpers/build_recipe.sh
. "$ROOT_DIR/tests/helpers/build_recipe.sh"

EVENTS="$WORK_DIR/events"
export EVENTS WORK_DIR
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$EVENTS" ] || sed 's/^/  event: /' "$EVENTS" >&2
  exit 1
}

command -v make >/dev/null 2>&1 || fail "GNU make is required to read forkop/Makefile"

# ---- the SDK recipe through make -------------------------------------------

mkdir -p "$WORK_DIR/sdk/include"
cat >"$WORK_DIR/sdk/rules.mk" <<'MK'
# OpenWrt's rules.mk, as far as a package recipe uses it.
SHELL:=/usr/bin/env bash
INCLUDE_DIR:=$(TOPDIR)/include
CP:=cp -fpR
INSTALL_BIN:=install -m0755
INSTALL_DIR:=install -d -m0755
INSTALL_DATA:=install -m0644
INSTALL_CONF:=install -m0600
define shvar
V_$(subst .,_,$(subst -,_,$(subst /,_,$(1))))
endef
define shexport
export $(call shvar,$(1))=$$(call $(1))
endef
MK
cat >"$WORK_DIR/sdk/include/package.mk" <<'MK'
define BuildPackage
endef
MK
# What include/package-pack.mk does with a package: its files, and its
# scripts written as BuildPackVariable writes them.
cat >"$WORK_DIR/sdk/stage.mk" <<'MK'
include Makefile
$(eval $(call shexport,Package/forkop/conffiles))
$(eval $(call shexport,Package/forkop/preinst))
$(eval $(call shexport,Package/forkop/postinst))
$(eval $(call shexport,Package/forkop/prerm))
.PHONY: stage
stage:
	rm -rf $(STAGE)
	mkdir -p $(STAGE)/root $(STAGE)/control
	$(call Package/forkop/install,$(STAGE)/root)
	echo "$$V_Package_forkop_conffiles" > $(STAGE)/control/conffiles
	echo "$$V_Package_forkop_preinst" > $(STAGE)/control/preinst
	echo "$$V_Package_forkop_postinst" > $(STAGE)/control/postinst-pkg
	echo "$$V_Package_forkop_prerm" > $(STAGE)/control/prerm-pkg
	chmod 0755 $(STAGE)/control/preinst $(STAGE)/control/postinst-pkg $(STAGE)/control/prerm-pkg
	printf '%s|%s\n' '$(PKG_VERSION)' '$(PKG_RELEASE)' > $(STAGE)/version
MK
# Both recipes build from a checkout whose modes are not the package's (a
# umask of 077, a checkout that marks files executable): an executable and
# a private file in the library, a private library directory, a private
# configuration.
SRC="$WORK_DIR/src"
mkdir -p "$SRC"
cp -R "$BUILD_SCRIPT" "$ROOT_DIR/forkop" "$SRC/"
chmod 0755 "$SRC/forkop/files/usr/lib/core/constants.uc"
chmod 0600 "$SRC/forkop/files/usr/lib/service/package.uc"
chmod 0700 "$SRC/forkop/files/usr/lib/core" "$SRC/forkop/files/usr/lib"
chmod 0600 "$SRC/forkop/files/etc/config/forkop"
sdk_stage() {
  local version="$1" out="$2"
  (umask 077 && make -s -C "$SRC/forkop" -f "$WORK_DIR/sdk/stage.mk" TOPDIR="$WORK_DIR/sdk" \
    STAGE="$out" FORKOP_PACKAGE_VERSION="$version" stage) >"$WORK_DIR/make.log" 2>&1
}
sdk_stage 1.2.3 "$WORK_DIR/sdk-stage" || fail "make could not build the SDK recipe: $(cat "$WORK_DIR/make.log")"
(umask 077 && build_recipe_root "$SRC/build.sh" 1.2.3 "$WORK_DIR/build-root") ||
  fail "could not build build.sh's backend root"
build_recipe_scripts "$BUILD_SCRIPT" "$WORK_DIR/build-scripts" || fail "could not write build.sh's package scripts"
SDK="$WORK_DIR/sdk-stage"
BUILD="$WORK_DIR/build-scripts"

# ---- files, modes, contents ------------------------------------------------

listing() {
  (cd "$1" && find . -mindepth 1 -printf '%y %m %p\n' | LC_ALL=C sort)
}
listing "$WORK_DIR/build-root" >"$WORK_DIR/build.list"
listing "$SDK/root" >"$WORK_DIR/sdk.list"
diff -u "$WORK_DIR/build.list" "$WORK_DIR/sdk.list" >"$WORK_DIR/list.diff" ||
  fail "the SDK package's files or modes differ from build.sh's: $(cat "$WORK_DIR/list.diff")"
diff -r "$WORK_DIR/build-root" "$SDK/root" >"$WORK_DIR/content.diff" ||
  fail "the SDK package's file contents differ from build.sh's: $(head -n 20 "$WORK_DIR/content.diff")"
grep -Fq '1.2.3' "$SDK/root/usr/lib/forkop/core/constants.uc" ||
  fail "the SDK package does not carry its version in core/constants.uc"
cmp -s "$BUILD/ipk/conffiles" "$SDK/control/conffiles" ||
  fail "the SDK package's conffiles differ: $(cat "$SDK/control/conffiles")"

# A release with a package revision, as build.sh takes it.
sdk_stage 1.2.3-4 "$WORK_DIR/sdk-revision" ||
  fail "the SDK recipe refused the release version 1.2.3-4: $(cat "$WORK_DIR/make.log")"
[ "$(cat "$WORK_DIR/sdk-revision/version")" = '1.2.3|4' ] ||
  fail "the SDK package of 1.2.3-4 must be version 1.2.3, release 4: $(cat "$WORK_DIR/sdk-revision/version")"
grep -Fq '1.2.3-4' "$WORK_DIR/sdk-revision/root/usr/lib/forkop/core/constants.uc" ||
  fail "the SDK package of 1.2.3-4 must report 1.2.3-4, as build.sh's does"
for version in 1.2 1.2.3-r4 1.2.3-; do
  if sdk_stage "$version" "$WORK_DIR/sdk-invalid"; then
    fail "the SDK recipe must refuse the release version $version"
  fi
done
# The LuCI app of the same SDK build takes the same versions.
mkdir -p "$WORK_DIR/sdk/feeds/luci"
: >"$WORK_DIR/sdk/feeds/luci/luci.mk"
cat >"$WORK_DIR/sdk/version.mk" <<'MK'
include Makefile
.PHONY: version
version:
	printf '%s|%s|%s\n' '$(PKG_VERSION)' '$(PKG_RELEASE)' '$(FORKOP_COMPILED_VERSION)'
MK
luci_version() {
  make -s -C "$ROOT_DIR/luci-app-forkop" -f "$WORK_DIR/sdk/version.mk" TOPDIR="$WORK_DIR/sdk" \
    FORKOP_PACKAGE_VERSION="$1" version 2>"$WORK_DIR/make.log"
}
for version in 1.2.3 1.2.3-4; do
  expected="1.2.3||$version"
  [ "$version" = 1.2.3 ] || expected="1.2.3|4|$version"
  actual="$(luci_version "$version")" || fail "the LuCI app's recipe refused $version: $(cat "$WORK_DIR/make.log")"
  [ "$actual" = "$expected" ] || fail "the LuCI app's recipe reads $version as $actual, not $expected"
done
if luci_version 1.2.3-r4 >/dev/null; then
  fail "the LuCI app's recipe must refuse the release version 1.2.3-r4"
fi

# ---- package scripts --------------------------------------------------------

# The install and upgrade script is build.sh's own text.
cmp -s "$BUILD/ipk/postinst" "$SDK/control/postinst-pkg" ||
  fail "the SDK postinst differs from build.sh's: $(diff "$BUILD/ipk/postinst" "$SDK/control/postinst-pkg" | tr '\n' ' ')"

# The installed /usr/bin/forkop records what the package scripts ask; the
# rest of the package is not there.
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/forkop" <<'SH'
#!/bin/sh
printf 'forkop %s\n' "$*" >>"$EVENTS"
exit "${FORKOP_PRERM_STATUS:-0}"
SH
cat >"$WORK_DIR/bin/mirror-migration" <<'SH'
#!/bin/sh
printf 'mirror-migration\n' >>"$EVENTS"
SH
for name in logger ln; do
  # shellcheck disable=SC2016 # expanded by the stub when it runs
  printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >>"$EVENTS"\n' "$name" >"$WORK_DIR/bin/$name"
done
chmod 0755 "$WORK_DIR/bin/"*
local_paths() {
  sed -e "s#/usr/share/forkop/mirror-migration.sh#$WORK_DIR/bin/mirror-migration#g" \
    -e "s#/usr/bin/forkop#$WORK_DIR/bin/forkop#g" \
    -e "s#/usr/lib/forkop#$WORK_DIR/no-lib#g" "$1" >"$2"
  chmod 0755 "$2"
}
local_paths "$BUILD/ipk/prerm" "$WORK_DIR/ipk-prerm"
local_paths "$BUILD/apk/backend-pre-upgrade.sh" "$WORK_DIR/apk-pre-upgrade"
local_paths "$BUILD/apk/backend-pre-deinstall.sh" "$WORK_DIR/apk-pre-deinstall"
local_paths "$SDK/control/prerm-pkg" "$WORK_DIR/sdk-prerm-pkg"
local_paths "$SDK/control/preinst" "$WORK_DIR/sdk-preinst"
# package-pack.mk (25.12): an apk's pre-upgrade is "export PKG_UPGRADE=1"
# and Package/preinst without its #! lines; its pre-install is preinst;
# its pre-deinstall runs default_prerm and then Package/prerm.
{
  printf '#!/bin/sh\nexport PKG_UPGRADE=1\n'
  sed '/^\s*#!/d' "$WORK_DIR/sdk-preinst"
} >"$WORK_DIR/sdk-pre-upgrade"
chmod 0755 "$WORK_DIR/sdk-pre-upgrade"

called() {
  : >"$EVENTS"
  local status=0
  PATH="$WORK_DIR/bin:$PATH" "$@" >/dev/null 2>&1 || status=$?
  printf '%s|%s\n' "$status" "$(tr '\n' ';' <"$EVENTS")"
}
# opkg runs the installed "prerm upgrade <new>" or "prerm remove"; the
# ipk's prerm sources prerm-pkg from default_prerm with its own $0 first.
# It runs the incoming "preinst upgrade <old>" with PKG_UPGRADE=1, which
# must not stop Forkop a second time.
for args in "upgrade 1.2.4" "remove"; do
  # shellcheck disable=SC2086 # the package manager's arguments
  expected="$(called ucode "$WORK_DIR/ipk-prerm" $args)"
  [ "$expected" = "0|forkop package_prerm $args;" ] || fail "build.sh's prerm $args: $expected"
  # shellcheck disable=SC2016,SC2086 # expanded by sh; the package manager's arguments
  sdk="$(called sh -c '. "$1"' /usr/lib/opkg/info/forkop.prerm "$WORK_DIR/sdk-prerm-pkg" $args)"
  [ "$sdk" = "$expected" ] || fail "the SDK prerm $args does not do what build.sh's does: $sdk"
done
sdk="$(called env PKG_UPGRADE=1 sh "$WORK_DIR/sdk-preinst" upgrade 1.2.3)"
[ "$sdk" = "0|" ] || fail "the SDK preinst of an opkg upgrade must leave the stop to prerm: $sdk"
sdk="$(called sh "$WORK_DIR/sdk-preinst" install)"
[ "$sdk" = "0|" ] || fail "the SDK preinst of an install must do nothing: $sdk"
# apk runs the incoming "pre-upgrade <new> <old>", whose failure keeps the
# installed release (UC-197), and "pre-deinstall <old>" for a removal.
for status in 0 3; do
  expected="$(FORKOP_PRERM_STATUS=$status called ucode "$WORK_DIR/apk-pre-upgrade" 1.2.4 1.2.3)"
  [ "$expected" = "$status|forkop package_prerm upgrade 1.2.4;" ] || fail "build.sh's pre-upgrade: $expected"
  sdk="$(FORKOP_PRERM_STATUS=$status called env APK_SCRIPT=pre-upgrade sh "$WORK_DIR/sdk-pre-upgrade" 1.2.4 1.2.3)"
  [ "$sdk" = "$expected" ] || fail "the SDK apk pre-upgrade does not do what build.sh's does: $sdk"
done
sdk="$(called env APK_SCRIPT=pre-install sh "$WORK_DIR/sdk-preinst" 1.2.4)"
[ "$sdk" = "0|" ] || fail "the SDK apk pre-install must do nothing: $sdk"
expected="$(called ucode "$WORK_DIR/apk-pre-deinstall" 1.2.3)"
[ "$expected" = "0|forkop package_prerm remove;" ] || fail "build.sh's pre-deinstall: $expected"
sdk="$(called env APK_SCRIPT=pre-deinstall sh "$WORK_DIR/sdk-prerm-pkg" 1.2.3)"
[ "$sdk" = "$expected" ] || fail "the SDK apk pre-deinstall does not do what build.sh's does: $sdk"

# ---- OpenWrt's default package scripts around them ---------------------------

# The SDK package's init scripts in an installed root. /etc/init.d/forkop
# is the real one behind an rc.common stand-in that records what reaches
# service/initd.uc; the others record their actions.
INSTALLED="$WORK_DIR/installed"
mkdir -p "$INSTALLED/etc/init.d" "$INSTALLED/real" "$INSTALLED/opkg-info"
cp "$SDK/root/etc/init.d/forkop" "$INSTALLED/real/forkop"
cat >"$WORK_DIR/rc.common" <<'SH'
#!/bin/sh
# OpenWrt's /etc/rc.common as far as enable and a procd script's start
# go; procd's service registration is left out.
initscript=$1
action=${2:-help}
shift 2
enable() {
	err=1
	name="$(basename "${initscript}")"
	[ "$START" ] && ln -sf "../init.d/$name" "$IPKG_INSTROOT/etc/rc.d/S${START}${name##S[0-9][0-9]}" && err=0
	[ "$STOP" ] && ln -sf "../init.d/$name" "$IPKG_INSTROOT/etc/rc.d/K${STOP}${name##K[0-9][0-9]}" && err=0
	return $err
}
. "$initscript"
initd_ucode() {
	printf 'initd %s\n' "$*" >>"$EVENTS"
}
start() {
	start_service "$@"
	service_started "$@"
}
"$action" "$@"
SH
cat >"$INSTALLED/etc/init.d/forkop" <<SH
#!/bin/sh
exec sh "$WORK_DIR/rc.common" "$INSTALLED/real/forkop" "\$@"
SH
for name in forkop-killswitch forkop-torrserver-direct; do
  # shellcheck disable=SC2016 # expanded by the stub when it runs
  printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >>"$EVENTS"\n' "$name" >"$INSTALLED/etc/init.d/$name"
done
chmod 0755 "$INSTALLED/etc/init.d/"*
# The package's init scripts, as the package manager lists its files.
(cd "$SDK/root" && find . -path './etc/init.d/*' | sed 's#^\.##' | LC_ALL=C sort) >"$INSTALLED/files.list"
grep -Fxq /etc/init.d/forkop-torrserver-direct "$INSTALLED/files.list" ||
  fail "the SDK package must ship /etc/init.d/forkop-torrserver-direct"
local_paths "$SDK/control/postinst-pkg" "$INSTALLED/postinst-pkg"

# lib/functions.sh default_postinst for an installed root: an ipk's own
# script (opkg's info directory) runs first, in a subshell; then every init
# script of the package is enabled on a first install and started.
cat >"$WORK_DIR/functions.sh" <<'SH'
default_postinst() {
	local ret=0
	if [ -f "$OPKG_INFO/forkop.postinst-pkg" ]; then
		( . "$OPKG_INFO/forkop.postinst-pkg" )
		ret=$?
	fi
	for i in $(grep -s "^/etc/init.d/" "$INSTALLED/files.list"); do
		if [ "$PKG_UPGRADE" != "1" ]; then
			"$INSTALLED$i" enable
		fi
		"$INSTALLED$i" start
	done
	return $ret
}
add_group_and_user() {
	return 0
}
SH
cp "$INSTALLED/postinst-pkg" "$INSTALLED/opkg-info/forkop.postinst-pkg"
export INSTALLED
# The ipk's postinst (package-pack.mk), and the apk's post-install, whose
# own script follows default_postinst (25.12); its post-upgrade exports
# PKG_UPGRADE=1 first.
cat >"$WORK_DIR/ipk-postinst" <<SH
#!/bin/sh
. "$WORK_DIR/functions.sh"
default_postinst \$0 \$@
SH
{
  printf '#!/bin/sh\n. "%s/functions.sh"\nexport root=""\nexport pkgname="forkop"\n' "$WORK_DIR"
  printf 'add_group_and_user\ndefault_postinst\n'
  sed '/^\s*#!/d' "$INSTALLED/postinst-pkg"
} >"$WORK_DIR/apk-post-install"
chmod 0755 "$WORK_DIR/ipk-postinst" "$WORK_DIR/apk-post-install"

for label in "ipk install" "ipk upgrade" "apk install" "apk upgrade"; do
  : >"$EVENTS"
  case "$label" in
    "ipk install") set -- env OPKG_INFO="$INSTALLED/opkg-info" PKG_ROOT=/ PKG_UPGRADE=0 sh "$WORK_DIR/ipk-postinst" configure ;;
    "ipk upgrade") set -- env OPKG_INFO="$INSTALLED/opkg-info" PKG_ROOT=/ PKG_UPGRADE=1 sh "$WORK_DIR/ipk-postinst" configure ;;
    "apk install") set -- env OPKG_INFO="$INSTALLED/none" APK_SCRIPT=post-install sh "$WORK_DIR/apk-post-install" 1.2.4 ;;
    "apk upgrade") set -- env OPKG_INFO="$INSTALLED/none" APK_SCRIPT=post-upgrade PKG_UPGRADE=1 sh "$WORK_DIR/apk-post-install" 1.2.4 1.2.3 ;;
  esac
  PATH="$WORK_DIR/bin:$PATH" "$@" >/dev/null 2>&1 || true
  grep -Fxq "forkop package_postinst" "$EVENTS" || fail "$label: the package's own script did not run"
  if grep -q '^initd start-service' "$EVENTS"; then
    fail "$label: OpenWrt's default package script started Forkop; only package_postinst decides that"
  fi
  if grep -q '^ln .*S99forkop' "$EVENTS"; then
    fail "$label: OpenWrt's default package script enabled Forkop's autostart"
  fi
  grep -q '^forkop-killswitch start' "$EVENTS" || fail "$label: the default script did not reach the other init scripts"
done

# Every other start and enable stays as it was: Forkop's own start inside a
# package script (start-and-wait passes its request), a start with a reason
# (deferred, triggered), any start or enable outside a package manager, and
# the enable of an image build.
initd_started() {
  : >"$EVENTS"
  PATH="$WORK_DIR/bin:$PATH" "$@" >/dev/null 2>&1 || true
  grep -q '^initd start-service' "$EVENTS"
}
initd_started env PKG_ROOT=/ FORKOP_START_REQUEST=1.2.3 "$INSTALLED/etc/init.d/forkop" start ||
  fail "Forkop's own start inside a package script must start it"
initd_started env APK_SCRIPT=post-upgrade "$INSTALLED/etc/init.d/forkop" start deferred ||
  fail "a deferred start inside a package script must start Forkop"
initd_started env -u PKG_ROOT -u APK_SCRIPT "$INSTALLED/etc/init.d/forkop" start ||
  fail "a start outside a package manager must start Forkop"
: >"$EVENTS"
PATH="$WORK_DIR/bin:$PATH" env -u PKG_ROOT -u APK_SCRIPT "$INSTALLED/etc/init.d/forkop" enable >/dev/null 2>&1 || true
grep -Fxq 'ln -sf ../init.d/forkop /etc/rc.d/S99forkop' "$EVENTS" ||
  fail "an enable outside a package manager must enable Forkop"
: >"$EVENTS"
PATH="$WORK_DIR/bin:$PATH" env PKG_ROOT="$WORK_DIR/image" IPKG_INSTROOT="$WORK_DIR/image" \
  "$INSTALLED/etc/init.d/forkop" enable >/dev/null 2>&1 || true
grep -Fxq "ln -sf ../init.d/forkop $WORK_DIR/image/etc/rc.d/S99forkop" "$EVENTS" ||
  fail "an image build must enable Forkop as every init script"

printf 'package recipe parity checks passed\n'
