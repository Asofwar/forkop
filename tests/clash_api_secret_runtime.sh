#!/usr/bin/env bash
set -euo pipefail

# D-1 (b), UC-007: the Clash API secret is mandatory and the validator refuses
# to start without one. The package postinst migration generates it, but a
# configuration that never went through the postinst (Forkop built into a
# firmware image, a keep-settings sysupgrade or a restored backup of an older
# config) must not fail closed: start and reload fill in an absent or blank
# secret before validation and never replace an existing one.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
LIFECYCLE="$FORKOP_LIB/service/lifecycle.uc"
WORK_DIR="$(mktemp -d)"
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

UCODE_BIN="$(command -v ucode)" || fail "ucode is required"

extract() {
  awk -v name="$1" '
    $0 ~ "^function " name "\\(" { copy=1 }
    copy { print }
    copy && /^}/ { exit }
  ' "$LIFECYCLE"
}

{
  cat <<'UCODE'
let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
const CONFIG_NAME = "forkop";
let guard_marks = 0;
function as_string(value) { return value == null ? "" : "" + value; }
function log_message(message, level) { print(level, ": ", message, "\n"); }
function mark_internal_config_guard() { guard_marks++; }
UCODE
  for fn in config_get config_set config_commit ensure_clash_api_secret; do
    extract "$fn" | grep -q . || fail "lifecycle.uc has no $fn()"
    extract "$fn"
  done
  cat <<'UCODE'
let ok = ensure_clash_api_secret();
print("result=", ok ? "ok" : "failed", " guard=", guard_marks, "\n");
UCODE
} >"$WORK_DIR/ensure.uc"

run_ensure() {
  local name="$1"
  : >"$WORK_DIR/$name.log"
  FORKOP_UCI_STATE_FILE="$WORK_DIR/$name.state" \
  FORKOP_UCI_LOG_FILE="$WORK_DIR/$name.log" \
    "$UCODE_BIN" -L "$FORKOP_LIB" "$WORK_DIR/ensure.uc" >"$WORK_DIR/$name.out" 2>&1 ||
    fail "ensure_clash_api_secret crashed for $name: $(cat "$WORK_DIR/$name.out")"
}

state() {
  local name="$1"
  shift
  printf '%s\n' 'forkop.settings=settings' 'forkop.settings.enable_yacd=0' "$@" >"$WORK_DIR/$name.state"
}

secret_of() {
  sed -n 's/^forkop\.settings\.yacd_secret_key=//p' "$WORK_DIR/$1.state"
}

# The shipped config of a firmware image: no secret at all.
state absent
run_ensure absent
grep -Fq 'result=ok guard=1' "$WORK_DIR/absent.out" || fail "a missing secret must be generated: $(cat "$WORK_DIR/absent.out")"
secret_of absent | grep -Eq '^[0-9a-f]{64}$' || fail "the generated secret must be 256-bit hex, got '$(secret_of absent)'"
grep -Fxq 'commit forkop' "$WORK_DIR/absent.log" || fail "the generated secret must be committed"
grep -Fq "$(secret_of absent)" "$WORK_DIR/absent.out" && fail "the log must not quote the generated secret"

# A blank secret is no secret.
state blank 'forkop.settings.yacd_secret_key=   '
run_ensure blank
secret_of blank | grep -Eq '^[0-9a-f]{64}$' || fail "a blank secret must be replaced"

# An existing user secret is never touched and nothing is committed.
state user 'forkop.settings.yacd_secret_key=my own secret'
cp "$WORK_DIR/user.state" "$WORK_DIR/user.before"
run_ensure user
grep -Fq 'result=ok guard=0' "$WORK_DIR/user.out" || fail "an existing secret needs no work: $(cat "$WORK_DIR/user.out")"
cmp -s "$WORK_DIR/user.state" "$WORK_DIR/user.before" || fail "an existing secret must never be replaced"
grep -q . "$WORK_DIR/user.log" && fail "nothing may be committed when a secret exists"

# Without a random source nothing is written; the validator then reports the
# missing secret.
state norandom
cp "$WORK_DIR/norandom.state" "$WORK_DIR/norandom.before"
FORKOP_SECRET_RANDOM_SOURCE="$WORK_DIR/missing-random" run_ensure norandom
grep -Fq 'result=failed' "$WORK_DIR/norandom.out" || fail "a failed generation must be reported"
cmp -s "$WORK_DIR/norandom.state" "$WORK_DIR/norandom.before" || fail "nothing may be written without a random source"

# Start and reload fill the secret in before validation; reload does it before
# it fingerprints the configuration, so the generated secret does not queue a
# second reload.
body_of() {
  awk -v name="$1" '
    $0 ~ "^function " name "\\(" { copy=1 }
    copy { print }
    copy && /^}/ { exit }
  ' "$LIFECYCLE"
}
line_in() {
  body_of "$1" | grep -n -F "$2" | head -n1 | cut -d: -f1
}
ensure_line="$(line_in start_main 'ensure_clash_api_secret();')"
validate_line="$(line_in start_main 'validate_start_config();')"
[ -n "$ensure_line" ] && [ -n "$validate_line" ] && [ "$ensure_line" -lt "$validate_line" ] ||
  fail "start must ensure the Clash API secret before validation"
ensure_line="$(line_in reload 'ensure_clash_api_secret();')"
fingerprint_line="$(line_in reload 'let reload_config_fingerprint = external_config_fingerprint();')"
validate_line="$(line_in reload 'validate_start_config();')"
[ -n "$ensure_line" ] && [ -n "$fingerprint_line" ] && [ "$ensure_line" -lt "$fingerprint_line" ] &&
  [ "$ensure_line" -lt "$validate_line" ] ||
  fail "reload must ensure the Clash API secret before it fingerprints and validates the config"

printf 'Start and reload fill in a missing Clash API secret and keep an existing one\n'
