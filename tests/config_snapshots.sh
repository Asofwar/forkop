#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
export FORKOP_CONFIG_FILE="$WORK/forkop"
export FORKOP_SNAPSHOT_DIR="$WORK/snapshots"
export FORKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
export FORKOP_LIB="$LIB"
cat > "$FORKOP_CONFIG_FILE" <<'UCI'
config settings 'settings'
 option dns_server '1.1.1.1'
 option password 'top-secret'
UCI
ucode -L "$LIB" "$SCRIPT" create manual > "$WORK/create.json" || { cat "$WORK/create.json" >&2; exit 1; }
ucode -L "$LIB" "$SCRIPT" create automatic > "$WORK/duplicate.json"
ucode -L "$LIB" "$SCRIPT" list > "$WORK/list.json"
node - "$WORK" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const dir = process.argv[2];
const created = JSON.parse(fs.readFileSync(`${dir}/create.json`));
const duplicate = JSON.parse(fs.readFileSync(`${dir}/duplicate.json`));
const list = JSON.parse(fs.readFileSync(`${dir}/list.json`));
assert.equal(created.status, 'created');
assert.equal(duplicate.status, 'existing');
assert.equal(list.length, 1);
assert.equal(JSON.stringify(list).includes('top-secret'), false);
fs.writeFileSync(`${dir}/id`, created.snapshot.id);
JS
id="$(cat "$WORK/id")"
test "$(stat -c %a "$FORKOP_SNAPSHOT_DIR")" = 700
test "$(stat -c %a "$FORKOP_SNAPSHOT_DIR/$id.json")" = 600
cat > "$FORKOP_CONFIG_FILE" <<'UCI'
config settings 'settings'
 option dns_server '8.8.8.8'
 option password 'new-secret'
UCI
ucode -L "$LIB" "$SCRIPT" diff "$id" > "$WORK/diff.json"
node - "$WORK/diff.json" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const rows = JSON.parse(fs.readFileSync(process.argv[2]));
assert.deepEqual(rows.find(row => row.option === 'dns_server'), {
  section: 'settings', option: 'dns_server', before: '1.1.1.1', after: '8.8.8.8'
});
assert.deepEqual(rows.find(row => row.option === 'password'), {
  section: 'settings', option: 'password', before: '***', after: '***'
});
assert.equal(JSON.stringify(rows).includes('secret'), false);
JS
if ucode -L "$LIB" "$SCRIPT" diff '../etc/passwd' >/dev/null; then exit 1; fi
mkdir "$WORK/bin"
cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
if [ "${FAIL_GUARD:-0}" = 1 ] && [ "${4:-}" = 'install-dpi-transition-guard' ]; then exit 1; fi
exit 0
STUB
cat > "$WORK/reload" <<'STUB'
#!/bin/sh
if [ "${FAIL_ALL:-0}" = 1 ]; then exit 1; fi
if [ "${FAIL_OLD_CONFIG:-0}" = 1 ] && grep -q '1.1.1.1' "$FORKOP_CONFIG_FILE"; then exit 1; fi
exit 0
STUB
chmod +x "$WORK/bin/ucode" "$WORK/reload"
export FORKOP_RELOAD_COMMAND="$WORK/reload"
REAL_UCODE="$(command -v ucode)"
PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" restore "$id" > "$WORK/restore.json"
node - "$WORK/restore.json" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
assert.equal(JSON.parse(fs.readFileSync(process.argv[2])).status, 'success');
JS
grep -q '1.1.1.1' "$FORKOP_CONFIG_FILE"
test "$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")" = "$id"
cat > "$FORKOP_CONFIG_FILE" <<'UCI'
config settings 'settings'
 option dns_server '8.8.8.8'
 option password 'new-secret'
UCI
FAIL_OLD_CONFIG=1 PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" restore "$id" > "$WORK/restore-failed.json"
node - "$WORK/restore-failed.json" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
assert.equal(JSON.parse(fs.readFileSync(process.argv[2])).status, 'recovered');
JS
grep -q '8.8.8.8' "$FORKOP_CONFIG_FILE"
recovered_id="$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")"
grep -q '8.8.8.8' "$FORKOP_SNAPSHOT_DIR/$recovered_id.json"
if FAIL_ALL=1 PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" restore "$id" > "$WORK/restore-unknown.json"; then exit 1; fi
node - "$WORK/restore-unknown.json" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const result = JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(result.status, 'needs_attention');
assert.equal(result.guard, 'active');
JS
grep -q '8.8.8.8' "$FORKOP_CONFIG_FILE"
if FAIL_ALL=1 FAIL_GUARD=1 PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" restore "$id" > "$WORK/restore-unprotected.json"; then exit 1; fi
node - "$WORK/restore-unprotected.json" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const result = JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(result.status, 'failed');
assert.equal(result.reason, 'guard_unavailable');
JS
mkdir "$FORKOP_SNAPSHOT_DIR/.lock"
if ucode -L "$LIB" "$SCRIPT" create manual >/dev/null; then exit 1; fi
rmdir "$FORKOP_SNAPSHOT_DIR/.lock"
printf '{invalid' > "$FORKOP_SNAPSHOT_DIR/bad.json"
if ucode -L "$LIB" "$SCRIPT" diff bad >/dev/null; then exit 1; fi
for n in 1 2 3 4 5 6 7 8 9 10 11; do
  printf "config settings 'settings'\n option dns_server '10.0.0.%s'\n" "$n" > "$FORKOP_CONFIG_FILE"
  ucode -L "$LIB" "$SCRIPT" create automatic >/dev/null
done
ucode -L "$LIB" "$SCRIPT" list > "$WORK/retention.json"
node - "$WORK/retention.json" "$id" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const rows = JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(rows.length, 10);
assert.ok(rows.some(row => row.id === process.argv[3] && row.kind === 'manual'));
JS
printf 'config_snapshots: PASS\n'
