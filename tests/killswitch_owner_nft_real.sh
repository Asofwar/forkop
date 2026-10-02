#!/usr/bin/env bash
# The VPN kill-switch policy never outlives the package that can lift it
# (UC-191), checked with the real nft.
#
# The production sync renders the policy from a real live ForkopTable, checks
# (-c) and applies (-f) it, and saves it for the boots to come. A "boot" here
# is what fw4 does at every boot and firewall reload: its own table plus every
# file in ruleset-post. With the Forkop package installed the saved policy
# comes back after the boot; once the package is gone (removal, a downgrade
# to a release without the kill-switch, a sysupgrade to an image without
# Forkop) nothing may load it, and no DNS block list may stay attached.
#
# The namespace part is skipped only when such a namespace cannot be created.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
KS_UC="$FORKOP_LIB/killswitch/runtime.uc"
NFT_UC="$FORKOP_LIB/nft/apply.uc"
DNS_UC="$FORKOP_LIB/dns/apply.uc"
LOADER_SOURCE="$ROOT_DIR/forkop/files/usr/share/nftables.d/ruleset-post/90-forkop-killswitch-loader.nft"
KEEP_LIST="$ROOT_DIR/forkop/files/lib/upgrade/keep.d/forkop-killswitch"
NAMESPACE=(unshare --user --map-root-user --net --mount)

namespaces() { printf '%s %s' "$(readlink /proc/self/ns/net)" "$(readlink /proc/self/ns/mnt)"; }

if [ "${1:-}" != "--in-namespace" ]; then
  skip() {
    printf 'SKIP: killswitch_owner_nft_real: %s\n' "$1"
    exit 0
  }
  command -v nft >/dev/null 2>&1 || skip 'nft is not installed'
  command -v unshare >/dev/null 2>&1 || skip 'unshare is not installed'
  if ! probe="$("${NAMESPACE[@]}" nft list ruleset 2>&1)"; then
    skip "nftables is unavailable in an unprivileged network namespace: $probe"
  fi
  FORKOP_NFT_REAL_HOST_NAMESPACES="$(namespaces)" exec "${NAMESPACE[@]}" bash "$0" --in-namespace
fi

# ---- inside the namespace (same guard as tests/nft_real.sh) -----------------

refuse() {
  printf 'FAIL: --in-namespace is only for the private namespace this test creates (%s)\n' "$1" >&2
  exit 1
}
mapfile -t uid_map </proc/self/uid_map
read -r map_inside _ map_count <<<"${uid_map[0]:-}"
if [ "${#uid_map[@]}" != 1 ] || [ "$map_inside" != 0 ] || [ "$map_count" != 1 ]; then
  refuse "not a user namespace mapping only root: ${uid_map[*]:-}"
fi
read -r host_net host_mnt <<<"${FORKOP_NFT_REAL_HOST_NAMESPACES:-}"
read -r own_net own_mnt <<<"$(namespaces)"
if [ -z "${host_net:-}" ] || [ "$own_net" = "$host_net" ] || [ "$own_mnt" = "${host_mnt:-}" ]; then
  refuse "the network or mount namespace is not new"
fi
[ -z "$(nft list ruleset)" ] || refuse "the namespace does not start with an empty ruleset"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'live ruleset:\n' >&2
  nft list ruleset >&2 2>/dev/null || true
  printf 'logger:\n' >&2
  cat "$WORK_DIR/logger.log" >&2 2>/dev/null || true
  exit 1
}
ok() { printf 'ok - %s\n' "$1"; }

# The router's file system: /etc/... of the router is $ROOT/etc/... here.
ROOT="$WORK_DIR/root"
RULESET_POST="$ROOT/usr/share/nftables.d/ruleset-post"
STATE_DIR="$ROOT/etc/forkop/killswitch"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/stub" "$WORK_DIR/run" "$RULESET_POST" "$ROOT/etc/config" "$STATE_DIR"

for name in logger dnsmasq-init killswitch-init sync; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/%s.log"\n' "$WORK_DIR" "$name" >"$WORK_DIR/bin/$name"
done
# Only to learn which live sets the render reads; never on PATH otherwise.
cat >"$WORK_DIR/stub/nft" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "list set" ]; then printf 'table inet %s {\n\tset %s {\n\t\ttype ipv4_addr\n\t}\n}\n' "$4" "$5"; fi
exit 0
EOF
chmod 0755 "$WORK_DIR/bin/"* "$WORK_DIR/stub/nft"

export PATH="$WORK_DIR/bin:$PATH"
export FORKOP_LIB
export FORKOP_UCI_STATE_FILE="$ROOT/etc/config/uci.state"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export KILLSWITCH_STATE_DIR="$STATE_DIR"
export KILLSWITCH_CACHE_DIR="$WORK_DIR/cache"
# The fixed paths the first kill-switch build used and the package's loader.
export KILLSWITCH_NFT_INCLUDE="$RULESET_POST/90-forkop-killswitch.nft"
export KILLSWITCH_NFT_LOADER="$RULESET_POST/90-forkop-killswitch-loader.nft"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export FORKOP_KILLSWITCH_INIT="$WORK_DIR/bin/killswitch-init"

cat >"$WORK_DIR/config.json" <<'JSON'
{ "route": { "rules": [
  { "action": "route", "outbound": "byp-out", "domain_suffix": [ "drive.example.com" ] },
  { "action": "route", "outbound": "main-out", "domain_suffix": [ "example.com" ] }
], "rule_set": [] } }
JSON
write_uci() {
  cat >"$FORKOP_UCI_STATE_FILE" <<EOF
forkop.settings=settings
forkop.settings.source_network_interfaces=br-lan
forkop.settings.config_path=$WORK_DIR/config.json
forkop.byp=section
forkop.byp.action=bypass
forkop.byp.ip_cidr=2.2.2.0/24
forkop.main=section
forkop.main.action=connection
forkop.main.kill_switch=1
forkop.main.ip_cidr=3.3.3.0/24
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].server=$1
EOF
}
uci_value() {
  awk -F= -v key="$2" '$1 == key { print substr($0, length($1) + 2) }' "$1"
}

ks() { ucode -L "$FORKOP_LIB" "$KS_UC" "$@"; }
ks_present() { nft list table inet ForkopKillswitch >/dev/null 2>&1; }

# Installs the package's own file into a root: the loader, as built
# (build.sh, forkop/Makefile), reading the policy from that root.
install_package_files() {
  local root="$1"
  mkdir -p "$root/usr/share/nftables.d/ruleset-post"
  [ -r "$LOADER_SOURCE" ] || return 0
  sed "s#/etc/forkop/killswitch/#$root/etc/forkop/killswitch/#g" "$LOADER_SOURCE" \
    >"$root/usr/share/nftables.d/ruleset-post/90-forkop-killswitch-loader.nft"
}
# A removal, or a downgrade to a release without the kill-switch, takes the
# package's files away and leaves what Forkop created at run time.
remove_package_files() {
  rm -f "$1/usr/share/nftables.d/ruleset-post/90-forkop-killswitch-loader.nft"
}

# A boot (or any fw4 start/reload): the kernel state is gone, fw4 loads its
# table and includes every ruleset-post file of the root.
fw4_boot() {
  local root="$1" file
  nft flush ruleset
  {
    printf 'table inet fw4\nflush table inet fw4\n'
    printf 'table inet fw4 {\n\tchain forward {\n\t\ttype filter hook forward priority 0; policy accept;\n\t}\n}\n'
    for file in "$root"/usr/share/nftables.d/ruleset-post/*.nft; do
      [ -e "$file" ] && printf 'include "%s"\n' "$file"
    done
  } >"$WORK_DIR/fw4.nft"
  nft -f "$WORK_DIR/fw4.nft" || fail "fw4 could not load its ruleset with the ruleset-post includes of $root"
}

# ---- a running Forkop with one protected section ------------------------------

write_uci 127.0.0.42
# The live ForkopTable holds every set the render reads, declared exactly as
# the render declares them.
PATH="$WORK_DIR/stub:$PATH" ucode -L "$FORKOP_LIB" "$NFT_UC" killswitch-render ForkopTable ForkopKillswitch \
  "$WORK_DIR/sets.nft" 198.18.0.0/15 fc00::/18 >/dev/null || fail "could not render the set layout"
{
  printf 'add table inet ForkopTable\n'
  grep '^add set inet ForkopKillswitch forkop_rule_' "$WORK_DIR/sets.nft" | sed 's/ ForkopKillswitch / ForkopTable /'
  printf 'add element inet ForkopTable forkop_rule_byp_subnets { 2.2.2.0/24 }\n'
  printf 'add element inet ForkopTable forkop_rule_main_subnets { 3.3.3.0/24 }\n'
} >"$WORK_DIR/live.nft"
nft -f "$WORK_DIR/live.nft" || fail "could not create the live ForkopTable"

install_package_files "$ROOT"
ks sync start || fail "sync from the real live table failed"
ks_present || fail "the synced policy is not live"
nft list chain inet ForkopKillswitch priority_rules | grep -Fq 'counter name "ks_main" jump ks_reject' ||
  fail "the protected section does not reject"
nft list chain inet ForkopKillswitch priority_rules | grep -Fq '@forkop_rule_byp_subnets return' ||
  fail "the earlier bypass section does not keep its verdict"
nft list set inet ForkopKillswitch forkop_rule_main_subnets | grep -Fq '3.3.3.0/24' ||
  fail "the live set content was not copied"
ks sync reload || fail "re-applying the same policy failed"
ok "the policy rendered from a real live table passes nft -c, -f and a re-apply"

# ---- with the package installed the policy survives a reboot ------------------

fw4_boot "$ROOT"
ks_present || fail "with Forkop installed the policy must come back after a boot"
nft list chain inet ForkopKillswitch priority_rules | grep -Fq 'counter name "ks_main" jump ks_reject' ||
  fail "the policy loaded at boot does not reject protected traffic"
ok "with the package installed the saved policy is loaded at boot"

# ---- removal / downgrade: nothing loads it any more ---------------------------

remove_package_files "$ROOT"
fw4_boot "$ROOT"
if ks_present; then
  fail "without the Forkop package (removal or downgrade) fw4 must not load the kill-switch"
fi
ok "after removal or a downgrade the saved policy is inert"

install_package_files "$ROOT"
fw4_boot "$ROOT"
ks_present || fail "a reinstalled package must find the saved policy again"
ok "a reinstall brings the saved policy back"

# ---- sysupgrade: Forkop stopped, protected names are blocked ------------------

write_uci 1.1.1.1
ucode -L "$FORKOP_LIB" "$DNS_UC" killswitch-refresh || fail "DNS refresh failed"
servers="$(uci_value "$FORKOP_UCI_STATE_FILE" 'dhcp.@dnsmasq[0].serversfile')"
[ -n "$servers" ] || fail "dnsmasq must read the kill-switch servers file"
grep -Fqx 'server=/example.com/' "$servers" || fail "a stopped Forkop must block protected names"

# What sysupgrade carries into the new image: /etc/config and the keep list.
sysupgrade_root() {
  local new_root="$1" path
  rm -rf "$new_root"
  mkdir -p "$new_root/etc"
  cp -a "$ROOT/etc/config" "$new_root/etc/config"
  while IFS= read -r path; do
    case "$path" in '' | '#'*) continue ;; esac
    [ -e "$ROOT$path" ] || continue
    (cd "$ROOT" && cp -a --parents ".${path%/}" "$new_root")
  done <"$KEEP_LIST"
}

NEW_ROOT="$WORK_DIR/new-root"
sysupgrade_root "$NEW_ROOT"
fw4_boot "$NEW_ROOT"
if ks_present; then
  fail "an image without Forkop must not load the kill-switch kept by sysupgrade"
fi
kept_servers="$NEW_ROOT${servers#"$ROOT"}"
if [ -e "$kept_servers" ] && grep -q '^server=/' "$kept_servers"; then
  fail "an image without Forkop must not keep a DNS block list attached to dnsmasq"
fi
ok "a sysupgrade to an image without Forkop keeps no active policy"

install_package_files "$NEW_ROOT"
fw4_boot "$NEW_ROOT"
ks_present || fail "an image with Forkop must load the policy kept by sysupgrade"
ok "a sysupgrade to an image with Forkop keeps the protection"

printf 'killswitch_owner_nft_real: PASS\n'
