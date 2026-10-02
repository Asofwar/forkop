#!/usr/bin/env bash
# D-23 with the real nft and real packets: only the excluded devices of
# sections that exempt them bypass the kill-switch's DNS block while Forkop
# is stopped; every other client stays blocked, and so do the names of every
# section that does not exempt the device.
#
# A private network namespace stands in for the router: a TUN interface is
# its LAN bridge, clients' DNS queries are written into it and their answers
# read back. tests/helpers/dns_tun.py answers like the router's resolvers
# (the main dnsmasq with the shared block list, one per group of excluded
# devices with the configuration the kill-switch generated for it). The
# kill-switch itself is the production code: its sync applies the policy
# from a real live ForkopTable, its watcher puts the redirect into the real
# table, and the kernel routes the packets.
#
# Skipped only when such a namespace, nft, python3 or a TUN device is not
# available.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
KS_UC="$FORKOP_LIB/killswitch/runtime.uc"
NFT_UC="$FORKOP_LIB/nft/apply.uc"
DNS_UC="$FORKOP_LIB/dns/apply.uc"
HELPER="$ROOT_DIR/tests/helpers/dns_tun.py"
NAMESPACE=(unshare --user --map-root-user --net --mount)

namespaces() { printf '%s %s' "$(readlink /proc/self/ns/net)" "$(readlink /proc/self/ns/mnt)"; }

if [ "${1:-}" != "--in-namespace" ]; then
  skip() {
    printf 'SKIP: killswitch_dns_exempt_nft_real: %s\n' "$1"
    exit 0
  }
  command -v nft >/dev/null 2>&1 || skip 'nft is not installed'
  command -v unshare >/dev/null 2>&1 || skip 'unshare is not installed'
  command -v python3 >/dev/null 2>&1 || skip 'python3 is not installed'
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
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"
RESOLVERS=""
cleanup() {
  [ -z "$RESOLVERS" ] || owned_kill TERM "$RESOLVERS" || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'live ruleset:\n' >&2
  nft list ruleset >&2 2>/dev/null || true
  printf 'resolver log:\n' >&2
  cat "$WORK_DIR/resolvers.log" >&2 2>/dev/null || true
  printf 'logger:\n' >&2
  cat "$WORK_DIR/logger.log" >&2 2>/dev/null || true
  exit 1
}
ok() { printf 'ok - %s\n' "$1"; }

if ! setup="$(python3 "$HELPER" setup br-lan 192.168.1.1/24 fd00::1/64 2>"$WORK_DIR/setup.err")"; then
  printf 'SKIP: killswitch_dns_exempt_nft_real: no TUN interface in the namespace: %s\n' "$(cat "$WORK_DIR/setup.err")"
  exit 0
fi
# The rules for IPv6 clients are checked in the kernel's ruleset either way;
# their packets only where the kernel has IPv6.
IPV6=1
if [ "$setup" != "ipv6 available" ]; then
  IPV6=0
  printf 'NOTE: this kernel has no IPv6; IPv6 clients are not queried\n'
fi
if ! printf 'add table inet ks_probe\nadd chain inet ks_probe c { type nat hook prerouting priority -102; policy accept; }\nadd rule inet ks_probe c fib daddr type local udp dport 53 redirect to :1\n' |
  nft -c -f - >/dev/null 2>&1; then
  printf 'SKIP: killswitch_dns_exempt_nft_real: this kernel has no nft redirect or fib expression\n'
  exit 0
fi

STATE_DIR="$WORK_DIR/ks"
CONF_DIR="$WORK_DIR/conf"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/stub" "$WORK_DIR/run" "$WORK_DIR/gen" "$STATE_DIR" "$CONF_DIR"
for name in logger dnsmasq-init killswitch-init; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/%s.log"\n' "$WORK_DIR" "$name" >"$WORK_DIR/bin/$name"
done
# The watcher's dig: a real query.
printf '#!/bin/sh\nexec python3 "%s" dig "$@"\n' "$HELPER" >"$WORK_DIR/bin/dig"
# Only to learn which live sets the render reads; never on PATH otherwise.
cat >"$WORK_DIR/stub/nft" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "list set" ]; then printf 'table inet %s {\n\tset %s {\n\t\ttype ipv4_addr\n\t}\n}\n' "$4" "$5"; fi
exit 0
EOF
chmod 0755 "$WORK_DIR/bin/"* "$WORK_DIR/stub/nft"

export PATH="$WORK_DIR/bin:$PATH"
export FORKOP_LIB
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export KILLSWITCH_STATE_DIR="$STATE_DIR"
export KILLSWITCH_CACHE_DIR="$CONF_DIR"
export KILLSWITCH_NFT_INCLUDE="$WORK_DIR/90-forkop-killswitch.nft"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export FORKOP_KILLSWITCH_INIT="$WORK_DIR/bin/killswitch-init"
export FORKOP_KILLSWITCH_WATCH_INTERVAL_MS=1
export DNS_TUN_LOG="$WORK_DIR/resolvers.log"
SERVERS="$STATE_DIR/dnsmasq.servers"
EXEMPT="$STATE_DIR/dns-exempt.json"

ks() { ucode -L "$FORKOP_LIB" "$KS_UC" "$@"; }

# ---- a running Forkop with four protected sections ----------------------------

printf '{"version":3,"rules":[{"domain_suffix":["second-list.example"]}]}\n' >"$WORK_DIR/gen/second.json"
outbound_json() {
  printf '{\\"type\\":\\"http\\",\\"tag\\":\\"%s\\",\\"server\\":\\"proxy.example\\",\\"server_port\\":8080}' "$1"
}
cat >"$WORK_DIR/gen/fixture.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "77.88.8.8" },
  "section": [
    { ".name": "main", ".type": "section", "enabled": "1", "action": "connection", "kill_switch": "1",
      "outbound_jsons": [ "$(outbound_json a)" ], "domain_suffix": [ "main-inline.example" ],
      "ip_cidr": [ "3.3.3.0/24" ], "excluded_source_ip_cidr": [ "192.168.1.50" ] },
    { ".name": "excl", ".type": "section", "enabled": "1", "action": "connection", "kill_switch": "1",
      "outbound_jsons": [ "$(outbound_json b)" ], "domain_suffix": [ "excl-inline.example", "shared.example" ],
      "rule_set": [ "$WORK_DIR/gen/second.json" ],
      "excluded_source_ip_cidr": [ "192.168.1.50", "192.168.1.0/28", "fd00::50" ] },
    { ".name": "excl2", ".type": "section", "enabled": "1", "action": "connection", "kill_switch": "1",
      "outbound_jsons": [ "$(outbound_json c)" ], "domain_suffix": [ "excl2-inline.example" ],
      "excluded_source_ip_cidr": [ "192.168.1.5" ] },
    { ".name": "late", ".type": "section", "enabled": "1", "action": "connection", "kill_switch": "1",
      "outbound_jsons": [ "$(outbound_json d)" ], "domain_suffix": [ "shared.example" ] }
  ]
}
JSON
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/generator.uc" generate-config-fixture \
  "$WORK_DIR/gen/fixture.json" "$WORK_DIR/config.json" 192.168.1.1 0 1 '' 1.13.0 >/dev/null ||
  fail "the generator fixture could not be generated"

# $1: whether excl and excl2 exempt their excluded devices; $2: the server
# dnsmasq forwards to (127.0.0.42 while Forkop runs).
write_uci() {
  {
    printf 'forkop.settings=settings\nforkop.settings.source_network_interfaces=br-lan\n'
    printf 'forkop.settings.config_path=%s\n' "$WORK_DIR/config.json"
    printf 'forkop.main=section\nforkop.main.action=connection\nforkop.main.kill_switch=1\n'
    printf 'forkop.main.ip_cidr=3.3.3.0/24\nforkop.main.excluded_source_ip_cidr=192.168.1.50\n'
    printf 'forkop.excl=section\nforkop.excl.action=connection\nforkop.excl.kill_switch=1\n'
    printf 'forkop.excl.excluded_source_ip_cidr=192.168.1.50 192.168.1.0/28 fd00::50\n'
    printf 'forkop.excl2=section\nforkop.excl2.action=connection\nforkop.excl2.kill_switch=1\n'
    printf 'forkop.excl2.excluded_source_ip_cidr=192.168.1.5\n'
    if [ "$1" = 1 ]; then
      printf 'forkop.excl.kill_switch_dns_exempt=1\nforkop.excl2.kill_switch_dns_exempt=1\n'
    fi
    printf 'forkop.late=section\nforkop.late.action=connection\nforkop.late.kill_switch=1\n'
    printf 'dhcp.@dnsmasq[0]=dnsmasq\ndhcp.@dnsmasq[0].server=%s\ndhcp.@dnsmasq[0].forkop_server=1.1.1.1\n' "$2"
    printf 'dhcp.@dnsmasq[0].serversfile=%s\n' "$SERVERS"
  } >"$FORKOP_UCI_STATE_FILE"
}

write_uci 1 127.0.0.42
PATH="$WORK_DIR/stub:$PATH" ucode -L "$FORKOP_LIB" "$NFT_UC" killswitch-render ForkopTable ForkopKillswitch \
  "$WORK_DIR/sets.nft" 198.18.0.0/15 fc00::/18 >/dev/null || fail "could not render the set layout"
{
  printf 'add table inet ForkopTable\n'
  grep '^add set inet ForkopKillswitch forkop_rule_' "$WORK_DIR/sets.nft" | sed 's/ ForkopKillswitch / ForkopTable /'
  printf 'add element inet ForkopTable forkop_rule_main_subnets { 3.3.3.0/24 }\n'
} >"$WORK_DIR/live.nft"
nft -f "$WORK_DIR/live.nft" || fail "could not create the live ForkopTable"

ks sync start || fail "sync from the real live table failed"
nft list table inet ForkopKillswitch >/dev/null 2>&1 || fail "the synced policy is not live"
[ -s "$EXEMPT" ] || fail "the groups of excluded devices must be saved"
cp "$STATE_DIR/policy.nft" "$WORK_DIR/policy.exempt"
if grep -q redirect "$WORK_DIR/policy.exempt"; then fail "the saved firewall policy redirects nothing"; fi

# Forkop stops: dnsmasq answers with the shared block list.
write_uci 1 1.1.1.1
ucode -L "$FORKOP_LIB" "$DNS_UC" killswitch-refresh || fail "DNS refresh failed"
grep -Fqx 'server=/excl-inline.example/' "$SERVERS" || fail "a stopped Forkop blocks the names of excl for every client"

ks exempt-configs "$CONF_DIR" >"$WORK_DIR/confs" || fail "exempt-configs failed"
[ "$(wc -l <"$WORK_DIR/confs")" = 2 ] || fail "two groups of excluded devices expected: $(cat "$WORK_DIR/confs")"
# shellcheck disable=SC2046
python3 "$HELPER" serve "$SERVERS" $(cat "$WORK_DIR/confs") >"$WORK_DIR/serve.out" 2>&1 &
RESOLVERS=$!
resolvers_ready() { grep -qx ready "$WORK_DIR/serve.out"; }
wait_until 10 resolvers_ready || fail "the resolvers did not start: $(cat "$WORK_DIR/serve.out")"

FORKOP_KILLSWITCH_WATCH_ITERATIONS=2 ks watch || fail "watch failed"
chain="$(nft list chain inet ForkopKillswitch ks_dns)"
grep -Fq 'ip saddr 192.168.1.5 fib daddr type local udp dport 53 counter' <<<"$chain" ||
  fail "the kernel must hold the redirect of the excluded devices: $chain"
grep -Fq 'ip6 saddr fd00::50 fib daddr type local' <<<"$chain" || fail "the IPv6 excluded device must be redirected: $chain"

# ---- what the clients get --------------------------------------------------------

ask() { python3 "$HELPER" query br-lan "$1" "$2" "$3"; }
expect() {
  local src="$1" name="$2" want="$3" dst="${4:-192.168.1.1}" got
  if [[ "$src" == *:* ]]; then
    [ "$IPV6" = 1 ] || return 0
    [ "$dst" != 192.168.1.1 ] || dst=fd00::1
  fi
  got="$(ask "$src" "$dst" "$name")"
  case "$want" in
    blocked) [[ "$got" == "rcode=3 "* ]] || fail "$src must get NXDOMAIN for $name, got: $got" ;;
    exempt) [[ "$got" =~ ^rcode=0\ answer=203\.0\.113\.5[5-8]\ sport=53$ ]] ||
      fail "$src must resolve $name through its own resolver, got: $got" ;;
    shared) [[ "$got" == "rcode=0 answer=203.0.113.53 sport=53" ]] ||
      fail "$src must resolve $name through the main dnsmasq, got: $got" ;;
    noreply) [ "$got" = noreply ] || fail "$src must get no answer for $name from $dst, got: $got" ;;
  esac
}
# Excluded from excl only (and from main, which does not exempt it).
expect 192.168.1.50 excl-inline.example exempt
expect 192.168.1.50 second-list.example exempt
expect 192.168.1.50 unrelated.example exempt
expect 192.168.1.50 main-inline.example blocked
expect 192.168.1.50 excl2-inline.example blocked
expect 192.168.1.50 shared.example blocked
expect 192.168.1.10 excl-inline.example exempt
expect 192.168.1.10 excl2-inline.example blocked
# Excluded from excl and excl2.
expect 192.168.1.5 excl2-inline.example exempt
expect 192.168.1.5 excl-inline.example exempt
expect 192.168.1.5 main-inline.example blocked
expect fd00::50 excl-inline.example exempt
ok "the excluded devices of exempting sections resolve those sections' names"

# Every other client keeps the shared block list.
for client in 192.168.1.70 192.168.1.16 fd00::70; do
  expect "$client" excl-inline.example blocked
  expect "$client" excl2-inline.example blocked
  expect "$client" second-list.example blocked
  expect "$client" unrelated.example shared
done
ok "every other client stays blocked"

# Only DNS for the router itself goes to their resolvers.
: >"$WORK_DIR/resolvers.log"
expect 192.168.1.50 excl-inline.example noreply 192.168.1.99
[ ! -s "$WORK_DIR/resolvers.log" ] || fail "DNS for another server must not reach the router's resolvers: $(cat "$WORK_DIR/resolvers.log")"
ok "DNS for other servers is not redirected"

# A firewall reload loads the saved policy without the redirect; the
# watcher puts it back.
nft delete table inet ForkopKillswitch
nft -f "$STATE_DIR/policy.nft" || fail "the saved policy does not load"
expect 192.168.1.50 excl-inline.example blocked
FORKOP_KILLSWITCH_WATCH_ITERATIONS=1 ks watch || fail "watch failed"
expect 192.168.1.50 excl-inline.example exempt
ok "the watcher restores the redirect after a firewall reload"

# ---- without the option: as before ------------------------------------------------

write_uci 0 127.0.0.42
ks sync start || fail "sync without the option failed"
[ ! -e "$EXEMPT" ] || fail "without the option no groups may be saved"
cmp -s "$STATE_DIR/policy.nft" "$WORK_DIR/policy.exempt" || fail "the option must not change the firewall policy"
write_uci 0 1.1.1.1
ucode -L "$FORKOP_LIB" "$DNS_UC" killswitch-refresh || fail "DNS refresh failed"
[ -z "$(ks exempt-configs "$CONF_DIR")" ] || fail "without the option no resolver of excluded devices may run"
FORKOP_KILLSWITCH_WATCH_ITERATIONS=1 ks watch || fail "watch failed"
if grep -q redirect <<<"$(nft list chain inet ForkopKillswitch ks_dns)"; then
  fail "without the option nothing may be redirected"
fi
for client in 192.168.1.50 192.168.1.5 fd00::50 192.168.1.70; do
  expect "$client" excl-inline.example blocked
done
expect 192.168.1.50 unrelated.example shared
ok "without the option every client keeps the shared block list"

# ---- the owner goes: nothing stays --------------------------------------------------

write_uci 1 127.0.0.42
ks sync start || fail "sync failed"
write_uci 1 1.1.1.1
ucode -L "$FORKOP_LIB" "$DNS_UC" killswitch-refresh || fail "DNS refresh failed"
ks exempt-configs "$CONF_DIR" >/dev/null || fail "exempt-configs failed"
FORKOP_KILLSWITCH_WATCH_ITERATIONS=1 ks watch || fail "watch failed"
expect 192.168.1.50 excl-inline.example exempt
ks release "package removal" || fail "release failed"
if nft list table inet ForkopKillswitch >/dev/null 2>&1; then fail "the package removal must remove the table"; fi
[ ! -e "$EXEMPT" ] || fail "the package removal must remove the groups"
ls "$CONF_DIR"/exempt-*.conf >/dev/null 2>&1 && fail "the package removal must remove the resolver configurations"
expect 192.168.1.50 excl-inline.example shared
expect 192.168.1.70 excl-inline.example shared
ok "the package removal lifts the exemption with the rest of the kill-switch"

printf 'killswitch_dns_exempt_nft_real: PASS\n'
