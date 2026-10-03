#!/usr/bin/env bash
set -euo pipefail

# Seeded and exhaustive properties of config/domain.uc against UTS46
# (url.domainToASCII, as browsers and the LuCI form process a domain): any
# letter case gives the punycode a DNS query carries (UC-087). PROPERTY_SEED
# and PROPERTY_CASES override the fixed seed and case count; see
# tests/helpers/property/scaffold.js.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT HUP INT TERM
export PROPERTY_WORK="$WORK"

node "$ROOT_DIR/tests/helpers/property/domain.js" "$ROOT_DIR/forkop/files/usr/lib" "$WORK"
