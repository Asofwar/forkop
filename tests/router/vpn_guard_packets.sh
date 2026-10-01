#!/usr/bin/env bash
# Run as root. All network/filesystem mutations are confined to fresh namespaces.
set -euo pipefail
if [[ ${1:-} != isolated ]]; then
    exec unshare --mount --net --propagation private bash "$0" isolated
fi
[[ $(readlink /proc/self/ns/net) != $(readlink /proc/1/ns/net) ]] || { echo 'Refusing to run outside a network namespace' >&2; exit 1; }
work=$(mktemp -d)
server_pid=
trap '[[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true; ip netns del guard-client 2>/dev/null || true; ip netns del guard-wan 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p /run/netns
mount -t tmpfs tmpfs /run/netns
ip link set lo up
ip netns add guard-client
ip netns add guard-wan
ip link add guard-lan type veth peer name client
ip link set client netns guard-client
ip addr add 192.0.2.254/24 dev guard-lan
ip -6 addr add 2001:db8:1::fe/64 dev guard-lan nodad
ip link set guard-lan up
ip -n guard-client addr add 192.0.2.1/24 dev client
ip -n guard-client -6 addr add 2001:db8:1::1/64 dev client nodad
ip -n guard-client link set client up
ip -n guard-client link set lo up
ip -n guard-client route add default via 192.0.2.254
ip -n guard-client -6 route add default via 2001:db8:1::fe
ip link add wan type veth peer name outside
ip link set outside netns guard-wan
ip addr add 203.0.113.254/24 dev wan
ip addr add 198.51.100.254/24 dev wan
ip -6 addr add 2001:db8:2::fe/64 dev wan nodad
ip -6 addr add 2001:db8:3::fe/64 dev wan nodad
ip link set wan up
ip -n guard-wan addr add 203.0.113.1/24 dev outside
ip -n guard-wan addr add 198.51.100.1/24 dev outside
ip -n guard-wan -6 addr add 2001:db8:2::1/64 dev outside nodad
ip -n guard-wan -6 addr add 2001:db8:3::1/64 dev outside nodad
ip -n guard-wan link set outside up
ip -n guard-wan link set lo up
ip -n guard-wan route add default via 203.0.113.254
ip -n guard-wan -6 route add default via 2001:db8:2::fe
sysctl -qw net.ipv4.ip_forward=1
sysctl -qw net.ipv6.conf.all.forwarding=1
cat > "$work/server.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import socket
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'OK')
    def log_message(self, *args): pass
class DualStack(HTTPServer):
    address_family = socket.AF_INET6
DualStack(('::', 8080), Handler).serve_forever()
PY
ip netns exec guard-wan python3 "$work/server.py" &
server_pid=$!
for _ in {1..30}; do
    if curl --noproxy '*' --max-time 1 -fsS http://198.51.100.1:8080/ > /dev/null 2>&1; then break; fi
    sleep 0.05
done
# IPv6 link-local DAD and neighbor discovery must finish before assertions.
for _ in {1..6}; do
    if ip netns exec guard-client curl --noproxy '*' --max-time 1 -fsS 'http://[2001:db8:3::1]:8080/' > /dev/null 2>&1; then break; fi
done
export FORKOP_LIB
FORKOP_LIB=$(cd "$(dirname "$0")/../../forkop/files/usr/lib" && pwd)
export GUARD_MODULE="$FORKOP_LIB/nft/fail_closed.uc"
export GUARD_TEST_DIR="$work"
python3 "$(dirname "$0")/../vpn_fail_closed.py" > /dev/null
sed 's/"lo"/"guard-lan"/g' "$work/guard.nft" > "$work/packets.nft"
nft -f "$work/packets.nft"
curl_client() { ip netns exec guard-client curl --noproxy '*' --max-time 2 -fsS "$1"; }
[[ $(curl_client http://198.51.100.1:8080/) == OK ]]
[[ $(curl_client 'http://[2001:db8:3::1]:8080/') == OK ]]
if curl_client 'http://[2001:db8:2::1]:8080/' >/dev/null 2>&1; then exit 1; fi
if curl_client http://203.0.113.1:8080/ >/dev/null 2>&1; then
    echo 'FAIL: protected destination reached WAN' >&2; exit 1
fi
# A DNS exception belongs only to the matching source profile, for both families.
nft 'add element inet ForkopVpnGuard dns_except_04 { 203.0.113.1 }'
nft 'add element inet ForkopVpnGuard dns_except_06 { 2001:db8:2::1 }'
if curl_client http://203.0.113.1:8080/ >/dev/null 2>&1; then exit 1; fi
if curl_client 'http://[2001:db8:2::1]:8080/' >/dev/null 2>&1; then exit 1; fi
nft 'flush set inet ForkopVpnGuard dns_except_04'
nft 'flush set inet ForkopVpnGuard dns_except_06'
nft 'add element inet ForkopVpnGuard dns_except_14 { 203.0.113.1 }'
[[ $(curl_client http://203.0.113.1:8080/) == OK ]]
ip -n guard-client addr add 192.0.2.2/24 dev client
if ip netns exec guard-client curl --interface 192.0.2.2 --noproxy '*' --max-time 2 -fsS http://203.0.113.1:8080/ >/dev/null 2>&1; then exit 1; fi
nft 'flush set inet ForkopVpnGuard dns_except_14'
nft 'add element inet ForkopVpnGuard dns_except_16 { 2001:db8:2::1 }'
[[ $(curl_client 'http://[2001:db8:2::1]:8080/') == OK ]]
ip -n guard-client -6 addr add 2001:db8:1::2/64 dev client nodad
if ip netns exec guard-client curl --interface 2001:db8:1::2 --noproxy '*' --max-time 2 -fsS 'http://[2001:db8:2::1]:8080/' >/dev/null 2>&1; then exit 1; fi
nft 'flush set inet ForkopVpnGuard dns_except_16'
# Removing all of Forkop's runtime rules does not remove the independent guard.
nft add table inet ForkopTable
nft delete table inet ForkopTable
[[ $(curl_client http://198.51.100.1:8080/) == OK ]]
if curl_client http://203.0.113.1:8080/ >/dev/null 2>&1; then exit 1; fi
# Cached FakeIP must not be forwarded after teardown, even with a WAN route.
ip route add 198.18.0.0/15 dev wan
if curl_client http://198.18.0.1:8080/ >/dev/null 2>&1; then exit 1; fi
# A marked outbound cannot fall back to WAN, independently of SO_BINDTODEVICE.
python3 - <<'PY'
import socket
s = socket.socket()
s.settimeout(2)
s.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, 0x28010000)
try:
    s.connect(('203.0.113.1', 8080))
    raise AssertionError('marked outbound reached WAN')
except OSError:
    pass
finally:
    s.close()
PY
# The same marked socket succeeds when its actual output interface is the VPN.
ip link set wan name wg-test
python3 - <<'PY'
import socket
for family, address in [(socket.AF_INET, '203.0.113.1'), (socket.AF_INET6, '2001:db8:2::1')]:
    with socket.socket(family) as s:
        s.settimeout(2)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, 0x28010000)
        s.connect((address, 8080))
        s.sendall(b'GET / HTTP/1.0\r\n\r\n')
        assert b'200 OK' in s.recv(1024)
PY
ip link set wg-test name wan
# Restore the persisted policy after a firewall reload in this isolated namespace.
nft delete table inet ForkopVpnGuard
nft -f "$work/packets.nft"
[[ $(curl_client http://198.51.100.1:8080/) == OK ]]
if curl_client http://203.0.113.1:8080/ >/dev/null 2>&1; then exit 1; fi
nft list table inet ForkopVpnGuard > "$work/counters.txt"
grep -Eq 'counter packets [1-9][0-9]* bytes [0-9]+ reject' "$work/counters.txt"
echo 'PASS: real IPv4/IPv6 packets; normal/DPI works; protected subnet/WAN fallback rejected; DNS exception source isolation; marked VPN output succeeds; FakeIP blocked; table deletion and guard restoration'
