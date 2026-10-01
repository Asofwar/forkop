#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
export GUARD_MODULE="$FORKOP_LIB/nft/fail_closed.uc"
export GUARD_TEST_DIR
GUARD_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$GUARD_TEST_DIR"' EXIT
python3 "$ROOT_DIR/tests/vpn_fail_closed.py"
