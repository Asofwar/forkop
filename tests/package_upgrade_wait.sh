#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
PACKAGE_UC="$FORKOP_LIB/service/package.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# prerm stops the service, but its sing-box child exits asynchronously. postinst
# must not reach the guarded start while that process is still around: the start
# refuses an ambiguous runtime by design, which would leave Forkop stopped after
# an ordinary package upgrade.

cat >"$WORK_DIR/init" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"${FORKOP_TEST_INIT_LOG:?}"
exit 0
SH
chmod 0755 "$WORK_DIR/init"

printf "config settings 'settings'\n" >"$WORK_DIR/forkop.conf"
printf 'forkop.settings=settings\n' >"$WORK_DIR/uci.state"

# A fake /proc: one process whose exe resolves to a binary named sing-box.
mkdir -p "$WORK_DIR/proc/4242" "$WORK_DIR/proc/7/" "$WORK_DIR/bin"
: >"$WORK_DIR/bin/sing-box"
: >"$WORK_DIR/bin/unrelated"
ln -s "$WORK_DIR/bin/unrelated" "$WORK_DIR/proc/7/exe"

run_postinst() {
  : >"$WORK_DIR/init.log"
  printf '1\n' >"$WORK_DIR/was-running"
  FORKOP_INIT="$WORK_DIR/init" \
  FORKOP_TEST_INIT_LOG="$WORK_DIR/init.log" \
  FORKOP_CONFIG_PATH="$WORK_DIR/forkop.conf" \
  FORKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/forkop.conf" \
  FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  FORKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/was-running" \
  FORKOP_PROC_DIR="$WORK_DIR/proc" \
  FORKOP_UPGRADE_SING_BOX_WAIT_SECONDS="${1:-15}" \
    ucode -L "$FORKOP_LIB" "$PACKAGE_UC" postinst
}

# 1. No sing-box left: the restore proceeds immediately.
run_postinst 15 || fail "postinst must restore the service once sing-box has exited"
grep -Fxq start "$WORK_DIR/init.log" ||
  fail "postinst must start Forkop when no sing-box process remains"
[ ! -e "$WORK_DIR/was-running" ] ||
  fail "postinst must consume the upgrade marker after a successful restore"

# 2. A surviving sing-box: the start must not be attempted at all.
ln -s "$WORK_DIR/bin/sing-box" "$WORK_DIR/proc/4242/exe"
start=$(date +%s)
if run_postinst 2 2>/dev/null; then
  fail "postinst must fail while the previous sing-box runtime is still present"
fi
elapsed=$(( $(date +%s) - start ))
[ ! -s "$WORK_DIR/init.log" ] ||
  fail "postinst must not start Forkop while an ambiguous sing-box runtime survives"
[ -e "$WORK_DIR/was-running" ] ||
  fail "a timed-out restore must keep the marker so the next attempt can retry"
[ "$elapsed" -ge 2 ] ||
  fail "postinst must actually wait for the configured timeout"

# 3. The scan matches the executable name, not any process that happens to exist.
rm -f "$WORK_DIR/proc/4242/exe"
run_postinst 2 || fail "an unrelated process must not be mistaken for sing-box"
grep -Fxq start "$WORK_DIR/init.log" ||
  fail "postinst must start Forkop when only unrelated processes are running"

printf 'package upgrade wait checks passed\n'
