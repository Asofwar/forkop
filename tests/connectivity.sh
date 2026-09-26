#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
SCRIPT="$LIB/diagnostics/connectivity.uc"
ucode -L "$LIB" "$SCRIPT" fixture example.org TCP 443 0 | node -e '
let s=""; process.stdin.on("data", x=>s+=x).on("end",()=>{
 const r=JSON.parse(s); if(r.status!=="ok"||r.origin!=="router"||r.type!=="TCP")process.exit(1)
})'
ucode -L "$LIB" "$SCRIPT" fixture example.org DNS '' 124 | node -e '
let s=""; process.stdin.on("data", x=>s+=x).on("end",()=>{
 const r=JSON.parse(s); if(r.status!=="timeout"||r.type!=="DNS")process.exit(1)
})'
if ucode -L "$LIB" "$SCRIPT" fixture 'bad;touch /tmp/forkop-injected' TCP 443 0 >/dev/null; then exit 1; fi
node - "$LIB" "$SCRIPT" <<'JS'
const { execFileSync } = require('node:child_process');
const assert = require('node:assert/strict');
const [lib, script] = process.argv.slice(2);
function args(host, type, port) {
  return JSON.parse(execFileSync('ucode', ['-L', lib, script, 'fixture-args', host, type, port, '0']));
}
assert.deepEqual(args('192.0.2.1', 'TCP', '443').slice(-2), ['192.0.2.1', '443']);
assert.equal(args('192.0.2.1', 'TLS', '443').at(-1), 'https://192.0.2.1:443/');
assert.equal(args('example.org', 'HTTP', '80').at(-1), 'http://example.org:80/');
assert.deepEqual(args('2001:db8::1', 'TCP', '443').slice(-2), ['2001:db8::1', '443']);
assert.equal(args('2001:db8::1', 'TLS', '443').at(-1), 'https://[2001:db8::1]:443/');
assert.equal(args('2001:db8::1', 'HTTP', '80').at(-1), 'http://[2001:db8::1]:80/');
assert.equal(args('::ffff:192.0.2.1', 'TLS', '443').at(-1), 'https://[::ffff:192.0.2.1]:443/');
for (const host of ['[2001:db8::1]', '[[2001:db8::1]]', 'fe80::1%eth0'])
  assert.throws(() => args(host, 'HTTP', '80'));
JS
printf 'connectivity: PASS\n'
