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
printf 'connectivity: PASS\n'
