#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
OVERRIDE_UC="$FORKOP_LIB/config/urltest_override.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

: >"$WORK_DIR/config.state"
FORKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
  ucode -L "$FORKOP_LIB" "$OVERRIDE_UC" save main group \
    https://example.com/generate_204 70s 175 30m 1

grep -Fq 'forkop.cfg000001=urltest_override' "$WORK_DIR/config.state" ||
  fail "save must create a URLTest override section"
grep -Fq 'forkop.cfg000001.testing_url=https://example.com/generate_204' "$WORK_DIR/config.state" ||
  fail "save must persist the testing URL"

cat >"$WORK_DIR/apply.uc" <<'EOF'
let override = require("config.urltest_override");
let outbound = { type: "urltest", url: "source", interval: "3m", tolerance: 50, idle_timeout: "30m", interrupt_exist_connections: false };
override.apply(outbound, "main", "group");
print(outbound.url, "|", outbound.interval, "|", outbound.tolerance, "|", outbound.idle_timeout, "|", outbound.interrupt_exist_connections, "\n");
EOF
applied="$(FORKOP_UCI_STATE_FILE="$WORK_DIR/config.state" ucode -L "$FORKOP_LIB" "$WORK_DIR/apply.uc")"
[ "$applied" = 'https://example.com/generate_204|70s|175|30m|true' ] ||
  fail "apply must overlay all URLTest runtime fields"

if FORKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
  ucode -L "$FORKOP_LIB" "$OVERRIDE_UC" save main group bad-url 0s '' nope 2; then
  fail "save must reject invalid values"
fi

FORKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
  ucode -L "$FORKOP_LIB" "$OVERRIDE_UC" reset main group
if grep -Fq 'urltest_override' "$WORK_DIR/config.state"; then
  fail "reset must remove the URLTest override section"
fi

printf 'URLTest override checks passed\n'

cat >"$WORK_DIR/source.state" <<'EOF'
forkop.ut_main=urltest
forkop.ut_main.section=main
forkop.ut_main.name=Fastest
forkop.old=urltest_override
forkop.old.rule=main
forkop.old.tag=main-urltest-ut_main-out
EOF
FORKOP_UCI_STATE_FILE="$WORK_DIR/source.state" \
  ucode -L "$FORKOP_LIB" "$OVERRIDE_UC" save main main-urltest-ut_main-out \
  https://example.com/check 90s 80 15m 0
grep -Fxq 'forkop.ut_main.testing_url=https://example.com/check' "$WORK_DIR/source.state" ||
  fail "configured URLTest settings must be updated at their source"
grep -Fxq 'forkop.ut_main.interrupt_exist_connections=0' "$WORK_DIR/source.state" ||
  fail "configured URLTest settings must preserve the interrupt option"
if grep -Fq 'urltest_override' "$WORK_DIR/source.state"; then
  fail "saving a configured group must remove its obsolete runtime override"
fi

# The dashboard save accepts what the validator accepts at start: a URL with
# a host and a tolerance from 0 to 10000, the range of the URLTest group of
# a rule. A value outside it would be committed and the reload refused, for
# an override and for the group section the save writes to alike.
: >"$WORK_DIR/range.state"
for args in 'http:///generate_204 70s 175' 'https://example.com/generate_204 70s 10001'; do
  # shellcheck disable=SC2086 # the URL, interval and tolerance are words
  if FORKOP_UCI_STATE_FILE="$WORK_DIR/range.state" \
    ucode -L "$FORKOP_LIB" "$OVERRIDE_UC" save main group $args 30m 1; then
    fail "save must reject what the validator refuses: $args"
  fi
done
[ ! -s "$WORK_DIR/range.state" ] || fail "a refused save must not write UCI"
FORKOP_UCI_STATE_FILE="$WORK_DIR/range.state" \
  ucode -L "$FORKOP_LIB" "$OVERRIDE_UC" save main group https://example.com:8443/generate_204 70s 10000 30m 1 ||
  fail "save must accept a tolerance of 10000"
grep -Fxq 'forkop.cfg000001.tolerance=10000' "$WORK_DIR/range.state" ||
  fail "save must persist a tolerance of 10000"
cp "$WORK_DIR/source.state" "$WORK_DIR/source-range.state"
if FORKOP_UCI_STATE_FILE="$WORK_DIR/source-range.state" \
  ucode -L "$FORKOP_LIB" "$OVERRIDE_UC" save main main-urltest-ut_main-out \
  https://example.com/check 90s 20000 15m 0; then
  fail "save must not write a tolerance the URLTest group check refuses"
fi
cmp -s "$WORK_DIR/source.state" "$WORK_DIR/source-range.state" ||
  fail "a refused save must leave the URLTest group section unchanged"
