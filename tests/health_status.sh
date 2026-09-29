#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
# Recorded events must stay out of /etc/forkop and /var/run/forkop.
export FORKOP_HISTORY_FILE="$TEST_DIR/history.jsonl"
export FORKOP_RUNTIME_STATE_DIR="$TEST_DIR"
cat > "$TEST_DIR/fixture.json" <<'JSON'
{"ui":{"service":{"forkop":{"running":1,"dns_configured":1},"sing_box":{"running":1}}},"guard":false,"package_pending":false,"events":[]}
JSON
ucode "$ROOT/forkop/files/usr/lib/diagnostics/health.uc" fixture "$TEST_DIR/fixture.json" > "$TEST_DIR/output.json"
node - "$TEST_DIR/output.json" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const value = JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(value.overall, 'ok');
assert.equal(value.dns.status, 'unknown');
assert.equal(value.dns.configured, true);
assert.equal(value.recovery.pending, false);
assert.equal(JSON.stringify(value).includes('secret'), false);
JS
cat > "$TEST_DIR/fixture.json" <<'JSON'
{"ui":{"service":{"forkop":{"running":1,"dns_configured":1},"sing_box":{"running":1}}},"guard":true,"package_pending":false,"events":[{"kind":"recovery","status":"recovered","timestamp":42}]}
JSON
ucode "$ROOT/forkop/files/usr/lib/diagnostics/health.uc" fixture "$TEST_DIR/fixture.json" > "$TEST_DIR/output.json"
node - "$TEST_DIR/output.json" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const value = JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(value.overall, 'error');
assert.equal(value.guard.active, true);
assert.equal(value.recovery.last_event.status, 'recovered');
JS
cat > "$TEST_DIR/fixture.json" <<'JSON'
{"ui":{"service":{"forkop":{"running":1,"dns_configured":1},"sing_box":{"running":1}}},"guard":false,"package_pending":false,"events":[{"kind":"recovery","status":"recovered","timestamp":42}]}
JSON
ucode "$ROOT/forkop/files/usr/lib/diagnostics/health.uc" fixture "$TEST_DIR/fixture.json" > "$TEST_DIR/output.json"
node - "$TEST_DIR/output.json" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
assert.equal(JSON.parse(fs.readFileSync(process.argv[2])).overall, 'recovered');
JS
cat > "$TEST_DIR/fixture.json" <<'JSON'
{"ui":{"service":{"forkop":{"running":1,"dns_configured":1},"sing_box":{"running":1}}},"guard":false,"package_pending":true,"events":[]}
JSON
ucode "$ROOT/forkop/files/usr/lib/diagnostics/health.uc" fixture "$TEST_DIR/fixture.json" > "$TEST_DIR/output.json"
node - "$TEST_DIR/output.json" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const result = JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(result.overall, 'error');
assert.equal(result.package_recovery.pending, true);
JS
cat > "$TEST_DIR/fixture.json" <<'JSON'
{"ui":{"service":{"forkop":{"running":1},"sing_box":{"running":1}}},"guard":false,"package_pending":false,"events":[{"kind":"restore","status":"failure","timestamp":42}]}
JSON
ucode "$ROOT/forkop/files/usr/lib/diagnostics/health.uc" fixture "$TEST_DIR/fixture.json" > "$TEST_DIR/output.json"
node - "$TEST_DIR/output.json" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const result = JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(result.overall, 'error');
assert.equal(result.recovery.pending, true);
JS
printf '{broken' > "$TEST_DIR/fixture.json"
ucode "$ROOT/forkop/files/usr/lib/diagnostics/health.uc" fixture "$TEST_DIR/fixture.json" > "$TEST_DIR/output.json"
node - "$TEST_DIR/output.json" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
assert.equal(JSON.parse(fs.readFileSync(process.argv[2])).overall, 'unknown');
JS
FORKOP_RUNTIME_STATE_DIR="$TEST_DIR" ucode "$ROOT/forkop/files/usr/lib/diagnostics/health.uc" record reload success
test "$(stat -c %a "$TEST_DIR/health-events.json")" = 600
for n in 1 2 3 4 5 6 7 8 9 10 11; do
  FORKOP_RUNTIME_STATE_DIR="$TEST_DIR" ucode "$ROOT/forkop/files/usr/lib/diagnostics/health.uc" record reload failure
done
node - "$TEST_DIR/health-events.json" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
assert.equal(JSON.parse(fs.readFileSync(process.argv[2])).events.length, 10);
JS
test "$(grep -c '"kind": *"reload"' "$FORKOP_HISTORY_FILE")" = 12
printf 'health_status: PASS\n'
