#!/bin/sh
set -eu
# The read-only section view names a DPI rule's strategy (provider, known
# strategy id or "default", custom flag) without ever returning the raw
# nfqws_opt / nfqws2_opt / byedpi_cmd_opts text.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

cat >"$WORK_DIR/forkop" <<'CONF'
config settings 'settings'
config section 'youtube'
config section 'spaces'
config section 'plain'
config section 'custom'
config section 'z2'
config section 'bye'
config section 'vpn'
CONF
cat >"$WORK_DIR/state" <<'STATE'
forkop.settings=settings
forkop.youtube=section
forkop.youtube.action=zapret
forkop.youtube.nfqws_opt=--filter-tcp=443 --dpi-desync=multisplit --dpi-desync-split-pos=1,midsld
forkop.spaces=section
forkop.spaces.action=zapret
forkop.spaces.nfqws_opt=  --filter-tcp=443   --dpi-desync=multidisorder --dpi-desync-split-pos=1,midsld  
forkop.plain=section
forkop.plain.action=zapret
forkop.custom=section
forkop.custom.action=zapret
forkop.custom.nfqws_opt=--filter-tcp=443 --dpi-desync=fake --hostlist=/etc/private-secret-list.txt
forkop.z2=section
forkop.z2.action=zapret2
forkop.z2.nfqws2_opt=--lua-desync=private-z2-secret
forkop.bye=section
forkop.bye.action=byedpi
forkop.vpn=section
forkop.vpn.action=vpn
STATE

FORKOP_CONFIG="$WORK_DIR/forkop" FORKOP_UCI_STATE_FILE="$WORK_DIR/state" \
  ucode -L "$LIB" "$LIB/diagnostics/runtime.uc" get-readonly-config-sections >"$WORK_DIR/sections.json"

node - "$WORK_DIR/sections.json" <<'NODE'
const assert = require('node:assert/strict');
const text = require('node:fs').readFileSync(process.argv[2], 'utf8');
const byName = Object.fromEntries(JSON.parse(text).map((s) => [s['.name'], s]));
const view = (name) => [byName[name].dpi_provider, byName[name].dpi_strategy, byName[name].dpi_strategy_custom];
assert.deepEqual(view('youtube'), ['zapret', 'multisplit', false]);
assert.deepEqual(view('spaces'), ['zapret', 'multidisorder', false]);
assert.deepEqual(view('plain'), ['zapret', 'default', false]);
assert.deepEqual(view('custom'), ['zapret', '', true]);
assert.deepEqual(view('z2'), ['zapret2', '', true]);
assert.deepEqual(view('bye'), ['byedpi', 'default', false]);
assert.equal(byName.vpn.dpi_provider, undefined, 'non-DPI rules carry no strategy view');
assert.doesNotMatch(text, /nfqws|byedpi_cmd_opts|dpi-desync|lua-desync|secret/,
  'raw strategy text must stay admin-only');
NODE

echo "read-only DPI strategy checks passed"
