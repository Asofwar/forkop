#!/bin/sh
# A temporary loopback-only resolver. No production firewall/config changes.
set -eu
work=$(mktemp -d /tmp/forkop-vpn-dns-test.XXXXXX)
conf=$work/dns.conf
export FORKOP_GUARD_DNS_TEST_CONF="$conf"
ucode -e 'let fs = require("fs"); let p = json(fs.readfile("/etc/forkop/vpn-guard/policy.json")); let lines = filter(split(p.dns.profiles[0].config, "\n"), function(line) { return index(line, "nftset=") != 0; }); fs.writefile(getenv("FORKOP_GUARD_DNS_TEST_CONF"), join("\n", lines) + "\nport=18953\nlisten-address=127.0.0.1\n");'
pid=
ticks=
cleanup() {
    rm -rf "$work"
    [ -n "$pid" ] || return 0
    [ "$(readlink /proc/$pid/exe 2>/dev/null)" = /usr/sbin/dnsmasq ] || return 0
    [ "$(awk '{print $22}' /proc/$pid/stat 2>/dev/null)" = "$ticks" ] || return 0
    grep -Fq -- "$conf" /proc/$pid/cmdline || return 0
    kill "$pid"
    wait "$pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
dnsmasq --keep-in-foreground --conf-file="$conf" --pid-file= > "$work/dns-test.log" 2>&1 &
pid=$!
ticks=$(awk '{print $22}' /proc/$pid/stat)
sleep 1
kill -0 "$pid"
dig @127.0.0.1 -p 18953 chatgpt.com A +time=3 +tries=1 > "$work/blocked.txt"
grep -q 'status: NXDOMAIN' "$work/blocked.txt"
dig @127.0.0.1 -p 18953 example.org A +time=3 +tries=1 > "$work/ordinary.txt"
grep -q 'status: NOERROR' "$work/ordinary.txt"
grep -Eq 'IN[[:space:]]+A[[:space:]]+[0-9]' "$work/ordinary.txt"
dig @127.0.0.1 -p 18953 forkop-vpn-guard.invalid A +time=1 +tries=1 +comments | grep -q 'status: NXDOMAIN'
echo 'PASS: router dnsmasq returns NXDOMAIN for VPN domain; ordinary DNS and readiness query work without sing-box upstream'
