#!/usr/bin/env ucode

// Autotune product layer: policy, targets, groups, cached results,
// hysteresis, scheduling and safe application on top of the Stage 3-5
// tools (autotune/isolation.uc tune, autotune/apply.uc plan/apply/rollback),
// which are called as they are and never bypassed.
//
// Modes:
//   status          policy, targets and cached results (read-only)
//   target <id>     the last full tune output of one target (read-only)
//
// Must be invoked as: ucode -L <lib> <lib>/autotune/manager.uc <mode> ...
let fs = require("fs");
let resolver = require("routing.resolve");
let policy_module = require("autotune.policy");
let state_module = require("autotune.state");

const CONFIG_FILE = getenv("FORKOP_CONFIG_FILE") || "/etc/config/forkop";

function as_string(v) { return v == null ? "" : "" + v; }

function config_sections() {
    let text = fs.readfile(CONFIG_FILE);
    return text == null ? null : resolver.parse_config(text);
}

// ---- read-only views -----------------------------------------------------

function status() {
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let read = policy_module.read(sections);
    let state = state_module.read();
    return {
        status: "ok",
        policy: read.policy,
        errors: read.errors,
        targets: map(read.targets, (t) => ({ ...t, last: state.targets[t.id] || null })),
        groups: state.groups,
        next_run_at: state.next_run_at,
        worker: state.worker
    };
}

function target(id) {
    if (!state_module.valid_id(id)) return { status: "failed", reason: "invalid_target" };
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let known = filter(policy_module.read(sections).targets, (t) => t.id == id);
    if (length(known) == 0) return { status: "failed", reason: "unknown_target" };
    let state = state_module.read();
    return { status: "ok", target: known[0], last: state.targets[id] || null, full: state_module.load_full(id) };
}

// ---- entry ---------------------------------------------------------------

if (sourcepath(1) != null && sourcepath(1) != "")
    return { status, target };

let mode = ARGV[0] || "";
let output = null;
if (mode == "status") output = status();
else if (mode == "target") output = target(ARGV[1]);
else {
    warn("Usage: autotune/manager.uc <status|target <id>>\n");
    exit(1);
}
print(sprintf("%J\n", output));
exit(output.status == "ok" ? 0 : 1);
