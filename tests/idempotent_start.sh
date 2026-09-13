#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Execute the actual start/retry functions with deterministic runtime doubles.
# No live process, nftables state or router service is touched.
python3 - "$ROOT_DIR" "$WORK_DIR/probe.uc" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]) / 'forkop/files/usr/lib/service'
functions = []
for filename, names in [
    ('state.uc', ['forkop_stably_running']),
    ('lifecycle.uc', ['start']),
    ('initd.uc', ['retry_start_on_wan_up_action', 'retry_start_on_wan_up']),
]:
    source = (root / filename).read_text()
    for name in names:
        match = re.search(r'^function ' + name + r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
        if not match:
            raise SystemExit('missing service function: ' + name)
        functions.append(match.group())

prelude = r'''
const STATE_UC = "state.uc";
const RT_TABLE_NAME = "forkop";
const NFT_TABLE_NAME = "forkop";
const NFT_FAKEIP_MARK = "0x123";
const RUNTIME_STABLE_MIN_AGE = 2;
const MANAGED_UPGRADE_SING_BOX_MARKER = "/test/upgrade.marker";
const MANAGED_UPGRADE_SING_BOX_WAIT_SECONDS = 20;
const MANAGED_UPGRADE_SING_BOX_MARKER_MAX_AGE_SECONDS = 120;
const SERVICE_INIT = "/etc/init.d/forkop";
const SERVICE_NAME = "forkop";
const START_RETRY_FILE = "/test/start.retry";
let marker_present = false;
let marker_resolved = true;
let conflict = false;
let transition_guard = false;
let health = [true, true, true, true, true];
let calls = [];
let logs = [];
let released = 0;
let cold_starts = 0;
let cleanups = 0;
let retry_status = 0;
let retry_running = false;
let retry_enabled = true;
let retry_pending = true;
let fs = { stat: function(path) {
    check(path == MANAGED_UPGRADE_SING_BOX_MARKER, "unexpected stat");
    return marker_present ? {} : null;
} };
function as_string(value) { return value == null ? "" : "" + value; }
function bool_text(value) { return value == "1"; }
function die(message) { warn("FAIL: " + message + "\n"); exit(1); }
function check(condition, message) { if (!condition) die(message); }
function sing_box_single_owned_service_runtime() { return health[0]; }
function sing_box_service_stable(age) {
    check(age == RUNTIME_STABLE_MIN_AGE, "stable age changed");
    return health[1];
}
function sing_box_runtime_ports_ready() { return health[2]; }
function sing_box_clash_api_ready() { return health[3]; }
function forkop_runtime_network_configured(rt, nft, mark) {
    check(rt == RT_TABLE_NAME && nft == NFT_TABLE_NAME && mark == NFT_FAKEIP_MARK,
        "network readiness parameters changed");
    return health[4];
}
function module_success(path, args) {
    check(path == STATE_UC, "unexpected start helper");
    push(calls, args[0]);
    if (args[0] == "wait-managed-upgrade-sing-box-exit") return marker_resolved;
    if (args[0] == "sing-box-process-conflict") return conflict;
    if (args[0] == "forkop-stably-running")
        return forkop_stably_running(args[1], args[2], args[3], args[4]);
    die("unexpected state helper");
}
function log_message(message, level) { push(logs, level + ":" + message); }
function release_start_subscription_update_lock() { released++; }
function start_impl() { cold_starts++; return 23; }
function cleanup_failed_runtime() { cleanups++; }
function runtime_is_running() { return retry_running; }
function service_is_enabled() { return retry_enabled; }
function start_retry_pending(path) { return retry_pending; }
function clear_start_retry(path) { push(calls, "clear-retry"); }
function command_status_from_args(args) {
    check(join(" ", args) == SERVICE_INIT + " start triggered", "retry used destructive restart");
    push(calls, "retry-start");
    return retry_status;
}
function command_success_from_args(args) {
    if (args[0] == "nft") {
        check(join(" ", args) == "nft list chain inet " + NFT_TABLE_NAME + " forkop_transition_guard",
            "unexpected nft command during duplicate start");
        return transition_guard;
    }
    push(logs, join(" ", args));
    return true;
}
function reset_probe() {
    marker_present = false; marker_resolved = true; conflict = false; transition_guard = false;
    health = [true, true, true, true, true];
    calls = []; logs = []; released = 0; cold_starts = 0; cleanups = 0;
    retry_status = 0; retry_running = false; retry_enabled = true; retry_pending = true;
}
'''
cases = r'''
reset_probe();
check(start() == 0, "duplicate stable start was not successful");
check(join(",", calls) == "sing-box-process-conflict,forkop-stably-running",
    "stable check bypassed ownership guard");
check(released == 1 && cold_starts == 0 && cleanups == 0,
    "duplicate stable start changed existing runtime or leaked subscription lock");

reset_probe();
transition_guard = true;
check(start() == 1, "retained fail-closed guard was reported as successful recovery");
check(released == 1 && cold_starts == 0 && cleanups == 0,
    "duplicate start altered the retained fail-closed runtime");

reset_probe();
marker_present = true;
check(start() == 0, "resolved managed upgrade prevented duplicate start");
check(join(",", calls) == "wait-managed-upgrade-sing-box-exit,sing-box-process-conflict,forkop-stably-running",
    "managed upgrade provenance was checked after runtime adoption");

reset_probe();
marker_present = true; marker_resolved = false;
check(start() == 1, "unresolved managed upgrade was accepted");
check(join(",", calls) == "wait-managed-upgrade-sing-box-exit" &&
    released == 1 && cold_starts == 0 && cleanups == 0,
    "unresolved managed upgrade changed existing runtime");

reset_probe();
conflict = true;
check(start() == 1, "ambiguous runtime was adopted");
check(join(",", calls) == "sing-box-process-conflict" &&
    released == 1 && cold_starts == 0 && cleanups == 0,
    "ambiguous runtime reached stable adoption or cleanup");

// Every part of the full stable-runtime predicate remains mandatory. A partial
// runtime follows the original guarded cold-start path, never the success path.
for (let failed_check = 0; failed_check < 5; failed_check++) {
    reset_probe();
    health[failed_check] = false;
    check(start() == 23, "partial runtime was incorrectly accepted as stable");
    check(cold_starts == 1 && released == 1 && cleanups == 1,
        "partial runtime bypassed original cold-start error handling");
}

reset_probe();
check(retry_start_on_wan_up("123") == 0, "successful retry lost its status");
check(index(join("\n", logs), "[info] Forkop recovered automatically after a failed start") >= 0,
    "successful retry outcome is not logged");

reset_probe();
retry_status = 19;
check(retry_start_on_wan_up("123") == 19, "failed retry lost its status");
check(index(join("\n", logs), "[error] Forkop automatic recovery attempt failed") >= 0,
    "failed retry outcome is not logged");

for (let skipped in ["running", "disabled", "no-retry"]) {
    reset_probe();
    retry_running = skipped == "running";
    retry_enabled = skipped != "disabled";
    retry_pending = skipped != "no-retry";
    check(retry_start_on_wan_up("123") == 0, "skipped retry failed");
    check(index(join(",", calls), "retry-start") < 0 && length(logs) == 0,
        "skipped retry started a service or falsely announced recovery");
}
print("idempotent start and retry outcome checks passed\n");
'''
pathlib.Path(sys.argv[2]).write_text(prelude + '\n\n'.join(functions) + cases)
PY

ucode "$WORK_DIR/probe.uc"
