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
//   run <all|group>     tune the targets of the groups now (write)
//   if-due              the scheduled run, when enabled and due (cron)
//   run-async <all|group>  start a run as a background job; prints its id
//   run-status <job>    state and result of a job (read-only)
//   cron-sync | cron-remove   the scheduling cron line
//
// Must be invoked as: ucode -L <lib> <lib>/autotune/manager.uc <mode> ...
let fs = require("fs");
let resolver = require("routing.resolve");
let policy_module = require("autotune.policy");
let state_module = require("autotune.state");
let groups_module = require("autotune.groups");
let probe_module = require("autotune.probe");
let hysteresis = require("autotune.hysteresis");
let identity = require("core.process_identity");

const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const CONFIG_FILE = getenv("FORKOP_CONFIG_FILE") || "/etc/config/" + (getenv("FORKOP_CONFIG_NAME") || "forkop");
const CONFIG_PACKAGE = fs.basename(CONFIG_FILE);
const SINGBOX_CONFIG = getenv("FORKOP_AUTOTUNE_SINGBOX_CONFIG") || "";
const UCI = getenv("FORKOP_AUTOTUNE_UCI") || "uci";
const UCI_SAVEDIR = getenv("FORKOP_AUTOTUNE_UCI_SAVEDIR") || "/tmp/.uci";
const TMP_DIR = getenv("FORKOP_AUTOTUNE_TMPDIR") || "/tmp";
const DIG = getenv("FORKOP_AUTOTUNE_DIG") || "dig";
const STATE_DIR = getenv("FORKOP_AUTOTUNE_STATE_DIR") || "/var/run/forkop/autotune";
const WORKER_LOCK = STATE_DIR + "/worker.lock";
const STATE_LOCK = STATE_DIR + "/state.lock";
const JOBS_DIR = getenv("FORKOP_AUTOTUNE_JOBS_DIR") || STATE_DIR + "/jobs";
const BIN = getenv("FORKOP_BIN") || "/usr/bin/forkop";
const CRONTAB_FILE = getenv("FORKOP_CRONTAB_FILE") || "/etc/crontabs/root";
const CRONTAB = getenv("FORKOP_AUTOTUNE_CRONTAB") || "crontab";
const CRON_MARKER = "# forkop-autotune";
// The cron line only asks "is a run due?"; the policy interval decides.
const CRON_SCHEDULE = "*/15 * * * *";
// A scheduled run that could not start is retried after this delay.
const RETRY_SECONDS = 900;
const JOB_KEEP = 10;
const JOB_STARTING_GRACE = 30;

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

// ---- cron ----------------------------------------------------------------------

function cron_line() {
    return CRON_SCHEDULE + " " + BIN + " autotune_if_due >/dev/null 2>&1 " + CRON_MARKER;
}

// Only the autotune line is added or removed; every other line stays as is.
function cron_write(enabled) {
    let existing = fs.readfile(CRONTAB_FILE);
    // A crontab that exists but cannot be read is never rewritten.
    if (existing == null && fs.stat(CRONTAB_FILE) != null) return { status: "failed", reason: "crontab_unreadable" };
    existing = as_string(existing);
    let lines = split(existing, "\n"), text = "";
    if (length(lines) > 0 && lines[length(lines) - 1] == "") pop(lines);
    for (let line in lines) if (index(line, CRON_MARKER) < 0) text += line + "\n";
    if (enabled) text += cron_line() + "\n";
    if (text == existing) return { status: "ok", enabled, changed: false };
    let tmp = trim(capture([ "mktemp", TMP_DIR + "/forkop-autotune-cron.XXXXXX" ]).output);
    if (tmp == "") return { status: "failed", reason: "tempfile_unavailable" };
    let ok = fs.writefile(tmp, text) != null && success([ CRONTAB, tmp ]);
    fs.unlink(tmp);
    return ok ? { status: "ok", enabled, changed: true } : { status: "failed", reason: "crontab_failed" };
}

function cron_sync() {
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    return cron_write(policy_module.read(sections).policy.mode != "off");
}

function cron_remove() { return cron_write(false); }

// ---- policy and targets (write) -----------------------------------------------

function ensure_state_dir() {
    for (let dir in [ fs.dirname(STATE_DIR), STATE_DIR ])
        if (fs.stat(dir) == null && !fs.mkdir(dir, 0700) && fs.stat(dir) == null) return false;
    return true;
}

// An exclusive flock on a file in the runtime directory; released by the
// kernel when the holder exits, so a crashed worker never leaves it behind.
function flock(path, wait) {
    if (!ensure_state_dir()) return null;
    let handle = fs.open(path, "a");
    if (!handle) return null;
    if (!handle.lock(wait ? "x" : "xn")) { handle.close(); return null; }
    return handle;
}
function unlock(handle) {
    if (handle) { handle.lock("u"); handle.close(); }
}

// Read-modify-write of the state file, serialized between the worker and the
// target commands.
function with_state(change) {
    let handle = flock(STATE_LOCK, true);
    let state = state_module.read();
    change(state);
    let ok = state_module.write(state);
    unlock(handle);
    return ok;
}

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
    let cron = null;
    if (key == "mode") {
        if (previous.mode != checked.value) history("autotune_mode", "success");
        cron = cron_sync().status;
    }
    return { status: "ok", option: key, value: checked.value, previous: previous[key], cron };
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
    if (existing != null && lc(as_string(existing.options.host)) != host)
        with_state((state) => { delete state.targets[id]; });
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
    with_state((state) => { delete state.targets[id]; });
    return { status: "ok", removed: id };
}

// ---- scheduled runs ----------------------------------------------------------

let interrupted = false;

function script(name) { return LIB_DIR + "/autotune/" + name + ".uc"; }
function self_pid() { return as_string(fs.readlink("/proc/self")); }

// A Stage 3-5 tool, invoked as its lock identity requires; its JSON output.
function run_tool(name, args) {
    let r = capture([ "ucode", "-L", LIB_DIR, script(name), ...args ]);
    let parsed = null;
    try { parsed = json(r.output); } catch (e) { parsed = null; }
    return type(parsed) == "object" ? parsed : null;
}

// Whatever makes a measurement now unsafe or meaningless, as the apply tool
// itself reports it (read-only).
function blocker() {
    let s = run_tool("apply", [ "status" ]);
    if (s == null) return "apply_status_unavailable";
    if (length(s.guards || []) > 0) return "dpi_guard_present";
    if (s.snapshot_operation) return "snapshot_operation_active";
    if (s.service_action) return s.service_action;
    if (s.autotune_lock_held) return "autotune_in_progress";
    if (type(s.state) == "object" && s.resolved === false) return "apply_unresolved";
    return null;
}

// The tune resolves the target itself and needs the real addresses, never
// the FakeIP answers of production DNS: the resolver of the target, else the
// first plain IPv4 bootstrap or upstream DNS server of Forkop.
function resolver_for(t, sections) {
    if (t.resolver) return { ip: t.resolver, source: "target" };
    let settings = resolver.settings_of(sections);
    for (let key in [ "bootstrap_dns_server", "dns_server" ]) {
        let values = settings[key];
        for (let v in type(values) == "array" ? values : [ values ])
            if (probe_module.valid_ipv4(trim(as_string(v)))) return { ip: trim(as_string(v)), source: "settings" };
    }
    return null;
}

function tune_target(t, probes, dns_resolver) {
    return run_tool("isolation", [ "tune", t.host, as_string(probes), dns_resolver ]) ||
        { status: "failed", reason: "tune_output_invalid" };
}

// Groups of this run: every group, one named group, or for a scheduled run
// one group in turn, so a run stays short and every group gets its turn.
function choose(names, scope, rotation) {
    names = sort(names);
    if (scope == "all") return names;
    if (scope == "auto") return length(names) > 0 ? [ names[rotation % length(names)] ] : [];
    return index(names, scope) >= 0 ? [ scope ] : null;
}

// The results go into the state as it is now: a target changed or removed
// during the run keeps what the target commands left.
function merge(updates) {
    return with_state((state) => {
        let sections = config_sections();
        // Without the configuration nothing can be checked: only the run
        // itself is recorded.
        if (sections != null) {
            let targets = policy_module.read(sections).targets;
            for (let id, summary in updates.targets) {
                let t = filter(targets, (x) => x.id == id)[0];
                if (t != null && t.host == summary.host) state.targets[id] = summary;
            }
            for (let name, group in updates.groups) state.groups[name] = group;
            // A disabled rule keeps its group (and its cooldowns); a deleted
            // one does not.
            state_module.prune(state, map(targets, (t) => t.id),
                map(filter(sections, (s) => s.type == "section"), (s) => s.name));
        }
        state.worker = updates.worker;
        if (updates.rotation != null) state.rotation = updates.rotation;
        if (updates.next_run_at != null) state.next_run_at = updates.next_run_at;
    });
}

function run_locked(scope, trigger) {
    let started = now();
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let read = policy_module.read(sections), policy = read.policy;
    let local = state_module.read();
    let updates = { targets: {}, groups: {}, worker: null, rotation: null, next_run_at: null };
    let report = {}, tuned = [], unmeasured = [], outside = [], chosen = [], stop = null;

    let reason = blocker();
    if (reason == null) {
        let computed = compute_groups(sections, read.targets, local);
        outside = computed.outside;
        chosen = choose(keys(computed.groups), scope, local.rotation);
        if (chosen == null) return { status: "failed", reason: "unknown_group", group: scope };
        for (let name in chosen) {
            let g = computed.groups[name];
            for (let id in g.targets) {
                if (interrupted) { stop = "interrupted"; break; }
                stop = blocker();
                if (stop != null) break;
                let t = filter(read.targets, (x) => x.id == id)[0];
                let dns_resolver = resolver_for(t, sections);
                if (dns_resolver == null) { push(unmeasured, { id, reason: "resolver_missing" }); continue; }
                let result = tune_target(t, policy.probes, dns_resolver.ip);
                // Neither says anything about the target: nothing is recorded.
                if (result.status == "busy") { stop = "autotune_in_progress"; break; }
                if (result.status == "interrupted") { stop = "interrupted"; break; }
                updates.targets[id] = state_module.record_tune(local, id, result,
                    { host: t.host, group: name, fingerprint: g.fingerprint }, now());
                push(tuned, id);
            }
            if (stop != null) break;
            // Only what this run measured counts: a cached result never
            // confirms a recommendation a second time.
            let aggregate = groups_module.aggregate(map(g.targets, (id) => ({ id, summary: updates.targets[id] || null })), g.current);
            let observed = hysteresis.observe(local.groups[name], { ...aggregate, fingerprint: g.fingerprint }, policy, now());
            let group = { ...observed.group, label: g.label, targets: g.targets, current: g.current,
                events: observed.events, ready: observed.ready, required: observed.required, result: aggregate };
            local.groups[name] = updates.groups[name] = group;
            report[name] = { result: aggregate, events: observed.events, ready: observed.ready, required: observed.required };
        }
        reason = stop;
    }

    let result = reason == null ? "completed" : reason == "interrupted" ? "interrupted" : "skipped";
    if (result == "completed" && length(chosen) == 0) reason = "no_groups";
    // An unfinished group keeps its turn.
    if (scope == "auto" && result == "completed" && length(chosen) > 0) updates.rotation = local.rotation + 1;
    if (trigger == "schedule")
        updates.next_run_at = result == "completed" ? started + policy.interval_seconds : now() + RETRY_SECONDS;
    updates.worker = { trigger, scope, started_at: started, finished_at: now(), result, reason,
        groups: chosen, tuned, unmeasured };
    merge(updates);
    return { status: "ok", result, reason, trigger, scope, groups: report, tuned, unmeasured, outside,
        next_run_at: updates.next_run_at };
}

function run(scope, trigger) {
    scope = as_string(scope);
    if (scope != "all" && scope != "auto" && !state_module.valid_id(scope)) return { status: "failed", reason: "invalid_scope" };
    if (!ensure_state_dir()) return { status: "failed", reason: "state_dir_unavailable" };
    let lock = flock(WORKER_LOCK, false);
    if (lock == null) return { status: "busy", reason: "autotune_worker_running" };
    let output = run_locked(scope, trigger || "manual");
    unlock(lock);
    return output;
}

// The cron entry: a run when autotune is enabled and the interval passed.
function if_due() {
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let read = policy_module.read(sections);
    if (read.policy.mode == "off") return { status: "ok", result: "skipped", reason: "mode_off" };
    let state = state_module.read();
    if (state.next_run_at != null && now() < state.next_run_at)
        return { status: "ok", result: "skipped", reason: "not_due", next_run_at: state.next_run_at };
    if (length(filter(read.targets, (t) => t.enabled)) == 0) return { status: "ok", result: "skipped", reason: "no_targets" };
    return run("auto", "schedule");
}

// ---- background jobs ---------------------------------------------------------

function valid_job_id(id) { return match(as_string(id), /^[0-9]{1,12}_[0-9]{1,10}$/) != null; }
function job_path(id) { return JOBS_DIR + "/" + id + ".json"; }
function job_read(id) {
    let data = fs.readfile(job_path(id)), parsed = null;
    try { parsed = data == null ? null : json(data); } catch (e) { parsed = null; }
    return type(parsed) == "object" ? parsed : null;
}
function job_write(job) {
    if (!ensure_state_dir() || (fs.stat(JOBS_DIR) == null && !fs.mkdir(JOBS_DIR, 0700) && fs.stat(JOBS_DIR) == null)) return false;
    let path = job_path(job.id), tmp = path + ".tmp." + self_pid();
    if (fs.writefile(tmp, sprintf("%J\n", job)) == null) { fs.unlink(tmp); return false; }
    if (!fs.rename(tmp, path)) { fs.unlink(tmp); return false; }
    return true;
}
// The newest jobs are kept; ids start with the creation time.
function job_prune() {
    let ids = sort(map(filter(fs.lsdir(JOBS_DIR) || [], (n) => match(n, /^[0-9]+_[0-9]+\.json$/) != null),
        (n) => substr(n, 0, length(n) - 5)), (a, b) => {
        let d = int(split(a, "_")[0]) - int(split(b, "_")[0]);
        return d != 0 ? d : (a < b ? -1 : a > b ? 1 : 0);
    });
    for (let i = 0; i < length(ids) - JOB_KEEP; i++) fs.unlink(job_path(ids[i]));
}

function job_alive(job) {
    return type(job.pid) == "string" && type(job.ticks) == "string" &&
        identity.matches_record({ pid: job.pid, ticks: job.ticks }, "ucode",
            [ "ucode", "-L", LIB_DIR, script("manager"), "run-job", job.id ], false, true) != "";
}

function run_async(scope) {
    scope = as_string(scope);
    if (scope != "all" && !state_module.valid_id(scope)) return { status: "failed", reason: "invalid_scope" };
    if (!ensure_state_dir()) return { status: "failed", reason: "state_dir_unavailable" };
    let probe = flock(WORKER_LOCK, false);
    if (probe == null) return { status: "busy", reason: "autotune_worker_running" };
    unlock(probe);
    let job = { id: now() + "_" + self_pid(), scope, state: "starting", created_at: now(),
        started_at: null, finished_at: null, pid: null, ticks: null, result: null };
    if (!job_write(job)) return { status: "failed", reason: "job_write_failed" };
    let worker = command([ "ucode", "-L", LIB_DIR, script("manager"), "run-job", job.id, scope ]);
    if (system(command([ "sh", "-c", worker + " >/dev/null 2>&1 </dev/null &" ])) != 0) {
        fs.unlink(job_path(job.id));
        return { status: "failed", reason: "job_start_failed" };
    }
    job_prune();
    return { status: "ok", job: job.id };
}

function run_job(id, scope) {
    let job = valid_job_id(id) ? job_read(id) : null;
    if (job == null || job.state != "starting" || job.scope != scope) return { status: "failed", reason: "unknown_job" };
    job.pid = self_pid();
    job.ticks = identity.start_ticks(job.pid);
    job.state = "running";
    job.started_at = now();
    job_write(job);
    let output = run(scope, "manual");
    job.state = "finished";
    job.finished_at = now();
    job.result = output;
    job_write(job);
    return output;
}

function run_status(id) {
    if (!valid_job_id(id)) return { status: "failed", reason: "invalid_job" };
    let job = job_read(id);
    if (job == null) return { status: "failed", reason: "unknown_job" };
    // A job whose worker is gone without finishing is reported, not rewritten.
    if ((job.state == "running" && !job_alive(job)) ||
        (job.state == "starting" && now() - int(job.created_at) > JOB_STARTING_GRACE))
        job.state = "lost";
    return { status: "ok", job };
}

// ---- entry ---------------------------------------------------------------

if (sourcepath(1) != null && sourcepath(1) != "")
    return { status, target, groups, policy_set, target_set, target_remove, run, if_due, run_async, run_status,
        cron_sync, cron_remove };

let mode = ARGV[0] || "";
let output = null;
if (mode == "status") output = status();
else if (mode == "target") output = target(ARGV[1]);
else if (mode == "groups") output = groups();
else if (mode == "policy-set") output = policy_set(ARGV[1], ARGV[2]);
else if (mode == "target-set") output = target_set(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "target-remove") output = target_remove(ARGV[1]);
else if (index([ "run", "if-due", "run-job" ], mode) >= 0) {
    // A stop request ends the run after the current target.
    if (type(signal) == "function")
        for (let name in [ "SIGINT", "SIGTERM", "SIGHUP" ])
            signal(name, function() { interrupted = true; });
    output = mode == "run" ? run(ARGV[1], "manual") : mode == "if-due" ? if_due() : run_job(ARGV[1], ARGV[2]);
}
else if (mode == "run-async") output = run_async(ARGV[1]);
else if (mode == "run-status") output = run_status(ARGV[1]);
else if (mode == "cron-sync") output = cron_sync();
else if (mode == "cron-remove") output = cron_remove();
else {
    warn("Usage: autotune/manager.uc <status|target <id>|groups|policy-set <option> <value>|" +
        "target-set <id> <host> [enabled] [resolver]|target-remove <id>|run <all|group>|if-due|" +
        "run-async <all|group>|run-status <job>|cron-sync|cron-remove>\n");
    exit(1);
}
print(sprintf("%J\n", output));
exit(output.status == "ok" ? 0 : 1);
