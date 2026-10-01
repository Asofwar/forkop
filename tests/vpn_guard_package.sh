#!/usr/bin/env bash
# Exercise the real manual package payload builder without downloading SDKs.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
RELEASE_VERSION=0.0.0
sed -n \
    -e '/^make_dir() {/,/^}/p' \
    -e '/^normalize_package_root_modes() {/,/^}/p' \
    -e '/^build_backend_root() {/,/^}/p' \
    "$ROOT_DIR/build.sh" > "$work/builder.sh"
# shellcheck disable=SC1091
source "$work/builder.sh"
build_backend_root "$work/payload"
for script in etc/init.d/forkop-guard etc/hotplug.d/iface/95-forkop-guard \
    usr/share/forkop/vpn-guard-firewall.sh; do
    [[ $(stat -c %a "$work/payload/$script") == 755 ]]
done
[[ -s "$work/payload/usr/lib/forkop/nft/fail_closed.uc" ]]
[[ $(stat -c %a "$work/payload/lib/upgrade/keep.d/forkop-guard") == 644 ]]
grep -Fxq '/etc/forkop/vpn-guard/' "$work/payload/lib/upgrade/keep.d/forkop-guard"
echo 'PASS: real package payload contains executable guard hooks, policy module and sysupgrade retention'
