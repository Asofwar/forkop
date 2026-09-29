#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The imported ops/mirror module must not leave byte code in the repository.
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT_DIR/tests/helpers/test_zapret_mirror_cache.py"
