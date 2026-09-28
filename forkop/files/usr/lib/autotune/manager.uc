#!/usr/bin/env ucode

// Autotune product layer: policy, targets, groups, cached results,
// hysteresis, scheduling and safe application on top of the Stage 3-5
// tools (autotune/isolation.uc tune, autotune/apply.uc plan/apply/rollback),
// which are called as they are and never bypassed.
//
// Modes:
//   status          policy, targets and cached results (read-only)
//   target <id>     the last full tune output of one target (read-only)
//   groups          targets classified into DPI groups now (read-only; DNS)
//   policy-set <option> <value>                     (write)
//   target-set <id> <host> [enabled] [resolver]     (write)
//   target-remove <id>                              (write)
//
// Must be invoked as: ucode -L <lib> <lib>/autotune/manager.uc <mode> ...
let fs = require("fs");
let resolver = require("routing.resolve");
let policy_module = require("autotune.policy");
let state_module = require("autotune.state");
let groups_module = require("autotune.groups");
let probe_module = require("autotune.probe");

const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const CONFIG_FILE = getenv("FORKOP_CONFIG_FILE") || "/etc/config/forkop";
const CONFIG_PACKAGE = "forkop";
const SINGBOX_CONFIG = getenv("FORKOP_AUTOTUNE_SINGBOX_CONFIG") || "";
const UCI = getenv("FORKOP_AUTOTUNE_UCI") || "uci";
const UCI_SAVEDIR = getenv("FORKOP_AUTOTUNE_UCI_SAVEDIR") || "/tmp/.uci";
const TMP_DIR = getenv("FORKOP_AUTOTUNE_TMPDIR") || "/tmp";
const DIG = getenv("FORKOP_AUTOTUNE_DIG") || "dig";

function as_string(v) { return v == null ? "" : "" + v; }
function quote(v) { return "'" + replace(as_string(v), /'/g, "'\\''") + "'"; }
function command(args) { return join(" ", map(args, quote)); }
function capture(args) {
    let pipe = fs.popen(command(args) + " 2>/dev/null", "r");
    if (!pipe) return { status: -1, output: "" };
    let data = pipe.read("all");
    return { status: int(pipe.close()), output: as_string(data) };
}
function success(args) { return system(command(args) + " >/dev/null 2>&1") == 0; }
function now() { return time(); }

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

// ---- groups ----------------------------------------------------------------

// How production resolves the target: the system resolver, as clients and
// autotune apply do. FakeIP when every answer is in the FakeIP range.
function production_dns(host) {
    let answers = [];
    for (let line in split(capture([ DIG, "+short", "+time=2", "+tries=1", host, "A" ]).output, "\n")) {
        line = trim(line);
        if (probe_module.valid_ipv4(line)) push(answers, line);
    }
    let fake = filter(answers, (a) => resolver.is_fakeip(a));
    return { answers: length(answers), ip: length(answers) > 0 ? answers[0] : null,
        fakeip: length(answers) > 0 && length(fake) == length(answers) };
}

function singbox_config(sections) {
    return resolver.load_json(SINGBOX_CONFIG != "" ? SINGBOX_CONFIG : resolver.singbox_config_path(sections));
}

// Targets classified into groups and the group results from the cached
// target summaries. Strategy identities only, never raw strategies.
function compute_groups(sections, targets, state) {
    let config = singbox_config(sections);
    let groups = {}, outside = [];
    for (let t in targets) {
        if (!t.enabled) { push(outside, { id: t.id, host: t.host, reason: "target_disabled", detail: null }); continue; }
        let dns = production_dns(t.host);
        let r = resolver.resolve(config, sections, resolver.target(t.host, dns.ip, { fakeip: dns.fakeip }));
        let c = groups_module.classify(dns, r);
        if (c.in_group == null) { push(outside, { id: t.id, host: t.host, reason: c.reason, detail: c.detail || null }); continue; }
        let g = groups[c.in_group];
        if (g == null) {
            let section = resolver.find_section(sections, c.in_group);
            g = groups[c.in_group] = { label: c.label, targets: [], current: r.dpi ? r.dpi.strategy : null,
                custom: r.dpi ? r.dpi.custom : null, fingerprint: groups_module.fingerprint(section), result: null };
        }
        push(g.targets, t.id);
    }
    for (let name, g in groups)
        g.result = groups_module.aggregate(map(g.targets, (id) => ({ id, summary: state.targets[id] || null })), g.current);
    return { groups, outside };
}

function groups() {
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let read = policy_module.read(sections);
    return { status: "ok", ...compute_groups(sections, read.targets, state_module.read()) };
}

// ---- policy and targets (write) -----------------------------------------------

function uncommitted_changes() {
    let st = fs.stat(UCI_SAVEDIR + "/" + CONFIG_PACKAGE);
    return st != null && st.size > 0;
}

function history(kind, status) {
    success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", kind, status ]);
}

// Set/delete UCI values with a private save directory, so the commit carries
// exactly these changes and never anything staged by someone else.
function uci_apply(ops) {
    if (uncommitted_changes()) return { status: "refused", reason: "uncommitted_uci_changes" };
    let dir = trim(capture([ "mktemp", "-d", TMP_DIR + "/forkop-autotune-policy.XXXXXX" ]).output);
    if (dir == "") return { status: "failed", reason: "tempdir_unavailable" };
    let base = [ UCI, "-c", fs.dirname(CONFIG_FILE), "-t", dir ];
    let ok = true;
    for (let op in ops) if (ok) ok = success([ ...base, ...op ]);
    if (ok) ok = success([ ...base, "commit", CONFIG_PACKAGE ]);
    system(command([ "rm", "-rf", dir ]));
    return ok ? { status: "ok" } : { status: "failed", reason: "uci_failed" };
}

function policy_set(key, value) {
    let checked = policy_module.check(key, value);
    if (checked.error) return { status: "failed", reason: checked.error, option: as_string(key) };
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let previous = policy_module.read(sections).policy;
    let ops = [];
    if (filter(sections, (s) => s.type == "autotune" && s.name == "autotune")[0] == null)
        push(ops, [ "set", CONFIG_PACKAGE + ".autotune=autotune" ]);
    push(ops, [ "set", CONFIG_PACKAGE + ".autotune." + key + "=" + as_string(checked.value) ]);
    let result = uci_apply(ops);
    if (result.status != "ok") return result;
    if (key == "mode" && previous.mode != checked.value) history("autotune_mode", "success");
    return { status: "ok", option: key, value: checked.value, previous: previous[key] };
}

function target_set(id, host, enabled, resolver_ip) {
    if (!policy_module.valid_target_id(id)) return { status: "failed", reason: "invalid_target_id" };
    host = lc(as_string(host));
    if (!probe_module.valid_host(host)) return { status: "failed", reason: "invalid_host" };
    enabled = enabled == null || as_string(enabled) == "" ? "1" : as_string(enabled);
    if (index([ "0", "1" ], enabled) < 0) return { status: "failed", reason: "invalid_enabled" };
    resolver_ip = as_string(resolver_ip);
    if (resolver_ip != "" && !probe_module.valid_ipv4(resolver_ip)) return { status: "failed", reason: "invalid_resolver" };
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let existing = filter(sections, (s) => s.name == id)[0];
    if (existing != null && existing.type != "autotune_target") return { status: "failed", reason: "id_in_use" };
    if (existing == null && length(filter(sections, (s) => s.type == "autotune_target")) >= policy_module.MAX_TARGETS)
        return { status: "refused", reason: "too_many_targets" };
    let path = CONFIG_PACKAGE + "." + id;
    let ops = [ [ "set", path + "=autotune_target" ], [ "set", path + ".host=" + host ], [ "set", path + ".enabled=" + enabled ] ];
    if (resolver_ip != "") push(ops, [ "set", path + ".resolver=" + resolver_ip ]);
    // uci delete of a missing option fails: only delete what exists.
    else if (existing != null && existing.options.resolver != null) push(ops, [ "delete", path + ".resolver" ]);
    let result = uci_apply(ops);
    if (result.status != "ok") return result;
    // Results measured for another host say nothing about the new one.
    if (existing != null && lc(as_string(existing.options.host)) != host) {
        let state = state_module.read();
        delete state.targets[id];
        state_module.write(state);
    }
    return { status: "ok", target: { id, host, enabled: enabled == "1", resolver: resolver_ip || null } };
}

function target_remove(id) {
    if (!policy_module.valid_target_id(id)) return { status: "failed", reason: "invalid_target_id" };
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let existing = filter(sections, (s) => s.name == id && s.type == "autotune_target")[0];
    if (existing == null) return { status: "failed", reason: "unknown_target" };
    let result = uci_apply([ [ "delete", CONFIG_PACKAGE + "." + id ] ]);
    if (result.status != "ok") return result;
    let state = state_module.read();
    delete state.targets[id];
    state_module.write(state);
    return { status: "ok", removed: id };
}

// ---- entry ---------------------------------------------------------------

if (sourcepath(1) != null && sourcepath(1) != "")
    return { status, target, groups, policy_set, target_set, target_remove };

let mode = ARGV[0] || "";
let output = null;
if (mode == "status") output = status();
else if (mode == "target") output = target(ARGV[1]);
else if (mode == "groups") output = groups();
else if (mode == "policy-set") output = policy_set(ARGV[1], ARGV[2]);
else if (mode == "target-set") output = target_set(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "target-remove") output = target_remove(ARGV[1]);
else {
    warn("Usage: autotune/manager.uc <status|target <id>|groups|policy-set <option> <value>|" +
        "target-set <id> <host> [enabled] [resolver]|target-remove <id>>\n");
    exit(1);
}
print(sprintf("%J\n", output));
exit(output.status == "ok" ? 0 : 1);
