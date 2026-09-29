#!/usr/bin/env ucode

let fs = require("fs");
let identity = require("core.process_identity");

const CONFIG = getenv("FORKOP_CONFIG_FILE") || "/etc/config/forkop";
const ROOT = getenv("FORKOP_SNAPSHOT_DIR") || "/etc/forkop/config-snapshots";
const HASH_DIR = getenv("FORKOP_SNAPSHOT_HASH_DIR") || "/var/run/forkop/snapshot-hash";
const LOCK = getenv("FORKOP_SNAPSHOT_LOCK_DIR") || "/var/run/forkop/config-snapshot.lock";
const LKG = ROOT + "/last-known-working";
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const BIN = getenv("FORKOP_BIN") || "/usr/bin/forkop";
const RELOAD = getenv("FORKOP_RELOAD_COMMAND") || "/etc/init.d/forkop";
const MAX_CONFIG = 2 * 1024 * 1024;
const PENDING_RELOAD = getenv("FORKOP_PENDING_RELOAD_FILE") || "/var/run/forkop/reload.pending";
const RELOAD_LOCK = getenv("FORKOP_RELOAD_LOCK_DIR") || "/var/run/forkop.reload.lock";
const RETENTION = 10;

function value(v) { return v == null ? "" : "" + v; }
function quote(v) { return "'" + replace(value(v), /'/g, "'\\''") + "'"; }
function cmd(args) {
    let parts = [];
    for (let arg in args) push(parts, quote(arg));
    return join(" ", parts);
}
function capture(args) {
    let pipe = fs.popen(cmd(args) + " 2>/dev/null", "r");
    if (!pipe) return "";
    let result = pipe.read("all");
    return pipe.close() == 0 && result != null ? result : "";
}
function success(args) { return system(cmd(args) + " >/dev/null 2>&1") == 0; }
function valid_id(id) { return match(value(id), /^[a-z0-9_-]{1,64}$/) != null; }
function snapshot_path(id) { return ROOT + "/" + id + ".json"; }
function read_config() {
    let data = fs.readfile(CONFIG);
    return data != null && length(data) <= MAX_CONFIG ? data : null;
}
function sha(data) {
    let parent = fs.dirname(HASH_DIR);
    if (fs.stat(parent) == null && !fs.mkdir(parent, 0700)) return "";
    if (fs.stat(HASH_DIR) == null && !fs.mkdir(HASH_DIR, 0700)) return "";
    if (!fs.chmod(HASH_DIR, 0700)) return "";
    let tmp = HASH_DIR + "/.hash." + sprintf("%d.%d", clock()[0], clock()[1]);
    if (fs.writefile(tmp, data) == null) return "";
    let output = capture([ "sha256sum", tmp ]);
    fs.unlink(tmp);
    let hash = split(output, " ")[0];
    return length(hash) == 64 && match(hash, /^[0-9a-f]+$/) != null ? hash : "";
}
function atomic(path, data) {
    let tmp = path + "." + sprintf("%d.%d", clock()[0], clock()[1]) + ".tmp";
    if (fs.writefile(tmp, data) == null || !fs.chmod(tmp, 0600) || !fs.rename(tmp, path)) {
        fs.unlink(tmp);
        return false;
    }
    return true;
}
function ensure_root() {
    let parent = fs.dirname(ROOT);
    if (fs.stat(parent) == null && !fs.mkdir(parent, 0700)) return false;
    if (fs.stat(ROOT) == null && !fs.mkdir(ROOT, 0700)) return false;
    return fs.chmod(ROOT, 0700);
}
// The lock is a runtime directory holding one "owner.<pid>.<start ticks>"
// record. The name is unique per process lifetime, so unlinking a stale or
// own record by name can never remove the record of a lock that replaced it.
let lock_record = null;
let lock_busy = false;   // set when a live snapshot operation owns the lock
function owner_pid() {
    let pid = value(fs.readlink("/proc/self"));
    return match(pid, /^[1-9][0-9]*$/) != null ? pid : "";
}
function active_entry(name) {
    let parsed = match(value(name), /^owner\.([1-9][0-9]*)\.([0-9]+)$/);
    if (parsed == null) return false;
    for (let operation in [ "create", "delete", "restore", "apply", "confirm-working" ])
        if (identity.matches_record({ pid: parsed[1], ticks: parsed[2] }, "ucode",
            [ "ucode", "-L", LIB_DIR, LIB_DIR + "/config/snapshots.uc", operation ], false, true) != "")
            return true;
    return false;
}
function remove_lock_dir(dir) {
    for (let name in fs.lsdir(dir) || []) fs.unlink(dir + "/" + name);
    return fs.rmdir(dir);
}
function acquire() {
    if (!ensure_root()) return false;
    let parent = fs.dirname(LOCK);
    if (fs.stat(parent) == null && !fs.mkdir(parent, 0700)) return false;
    let pid = owner_pid(), ticks = identity.start_ticks(pid);
    if (ticks == "") return false;
    let name = "owner." + pid + "." + ticks;
    // The record is complete before the lock becomes visible, so no observer
    // can mistake a lock that is still being initialised for a stale one.
    let pending = LOCK + ".new." + pid + "." + ticks;
    remove_lock_dir(pending);
    if (!fs.mkdir(pending, 0700) || !identity.record(pending + "/" + name, pid) || !active_entry(name)) {
        remove_lock_dir(pending);
        return false;
    }
    for (let attempt = 0; attempt < 3; attempt++) {
        // rename() refuses a populated lock; an empty one was already released.
        if (fs.rename(pending, LOCK)) {
            lock_record = LOCK + "/" + name;
            return true;
        }
        let stat = fs.lstat(LOCK);
        let entries = stat != null && stat.type == "directory" ? fs.lsdir(LOCK) : null;
        if (entries == null) {
            // Absent, or not a lock directory (never follow a symlink here).
            fs.unlink(LOCK);
            continue;
        }
        let busy = false;
        for (let entry in entries) if (active_entry(entry)) busy = true;
        if (busy) { lock_busy = true; break; }
        for (let entry in entries)
            if (!fs.unlink(LOCK + "/" + entry)) fs.rmdir(LOCK + "/" + entry);
    }
    remove_lock_dir(pending);
    return false;
}
function release() {
    if (lock_record == null) return;
    fs.unlink(lock_record);
    fs.rmdir(LOCK);
    lock_record = null;
}
function read_snapshot(id, verify) {
    if (!valid_id(id)) return null;
    let data = fs.readfile(snapshot_path(id));
    if (data == null || length(data) > MAX_CONFIG + 8192) return null;
    try {
        let parsed = json(data);
        return type(parsed) == "object" && parsed.id == id &&
            type(parsed.content) == "string" && length(parsed.content) <= MAX_CONFIG &&
            length(value(parsed.config_hash)) == 64 && match(value(parsed.config_hash), /^[0-9a-f]+$/) != null &&
            (!verify || sha(parsed.content) == parsed.config_hash) ? parsed : null;
    }
    catch (e) { return null; }
}
function metadata(snapshot) {
    return { id: snapshot.id, created_at: snapshot.created_at,
        kind: index([ "manual", "automatic" ], snapshot.kind) >= 0 ? snapshot.kind : "unknown",
        reason: index([ "manual", "before-reload", "pre-restore", "last-known-working", "before-autotune" ], snapshot.reason) >= 0 ? snapshot.reason : "unknown",
        config_hash: snapshot.config_hash,
        forkop_version: match(value(snapshot.forkop_version), /^[A-Za-z0-9._-]{1,64}$/) != null ? snapshot.forkop_version : "unknown" };
}
function list_snapshots() {
    let result = [];
    let working = trim(value(fs.readfile(LKG)));
    for (let file in fs.lsdir(ROOT) || []) {
        let id = replace(file, /\.json$/, "");
        if (file != id + ".json" || !valid_id(id)) continue;
        let item = read_snapshot(id, false);
        if (item == null) continue;
        let entry = metadata(item);
        entry.is_lkg = id == working;
        push(result, entry);
    }
    result = sort(result, function(a, b) { return a.created_at - b.created_at; });
    return result;
}
// Oldest automatic snapshots go first; manual ones, LKG and the ids the
// running operation still needs (keep) are never removed.
function trim_retention(keep) {
    let all = list_snapshots();
    let working = trim(value(fs.readfile(LKG)));
    while (length(all) >= RETENTION) {
        let candidate = null;
        for (let item in all)
            if (item.kind != "manual" && item.id != working && index(keep || [], item.id) < 0) { candidate = item; break; }
        if (candidate == null) return false;
        fs.unlink(snapshot_path(candidate.id));
        all = list_snapshots();
    }
    return true;
}
// Snapshots that can still be created without touching LKG, manual ones or keep.
function headroom(keep) {
    let all = list_snapshots();
    let working = trim(value(fs.readfile(LKG)));
    let free = RETENTION - length(all);
    for (let item in all)
        if (item.kind != "manual" && item.id != working && index(keep || [], item.id) < 0) free++;
    return free;
}
function create(kind, reason, dedupe, keep) {
    let content = read_config();
    if (content == null) return { status: "failed", reason: "config_unavailable" };
    let hash = sha(content);
    if (hash == "") return { status: "failed", reason: "hash_unavailable" };
    if (dedupe)
        for (let item in list_snapshots())
            if (item.config_hash == hash) return { status: "existing", snapshot: item };
    if (!trim_retention(keep)) return { status: "failed", reason: "retention_full" };
    let id = sprintf("%d_%d", clock()[0], clock()[1]);
    let version = trim(capture([ BIN, "show_version" ]));
    let snapshot = { id, created_at: int(clock()[0]), kind, reason,
        config_hash: hash, forkop_version: match(version, /^[A-Za-z0-9._-]{1,64}$/) != null ? version : "unknown", content };
    if (fs.stat(snapshot_path(id)) != null ||
        !atomic(snapshot_path(id), sprintf("%J\n", snapshot)))
        return { status: "failed", reason: "write_failed" };
    return { status: "created", snapshot: metadata(snapshot) };
}
function safe_value(option, raw) {
    if (index([ "enabled", "action", "dns_type", "dns_strategy", "disable_quic" ], option) >= 0 &&
        match(raw, /^[A-Za-z0-9_-]{1,32}$/) != null) return raw;
    if (index([ "dns_server", "bootstrap_dns_server" ], option) >= 0 &&
        match(raw, /^[0-9A-Fa-f:.]{1,45}$/) != null) return raw;
    return "***";
}
// Parses a UCI value made of quoted/unquoted segments ('it'\''s', "a\"b").
// A quoted value may span lines; null means the quote is still open.
function uci_value(text) {
    let result = "", quote = null;
    for (let i = 0; i < length(text); i++) {
        let c = substr(text, i, 1);
        if (quote == "'") {
            if (c == "'") quote = null; else result += c;
        }
        else if (quote == "\"") {
            if (c == "\\" && i + 1 < length(text)) result += substr(text, ++i, 1);
            else if (c == "\"") quote = null;
            else result += c;
        }
        else if (c == "'" || c == "\"") quote = c;
        else if (c == "\\" && i + 1 < length(text)) result += substr(text, ++i, 1);
        else if (c == " " || c == "\t") break;
        else result += c;
    }
    return quote == null ? result : null;
}
function options(content) {
    let result = {};
    let section = "";
    let lines = split(content, "\n");
    for (let i = 0; i < length(lines); i++) {
        let line = lines[i];
        let start = match(line, /^[ \t]*config[ \t]+[A-Za-z0-9_-]+[ \t]+['"]?([A-Za-z0-9_-]+)['"]?/);
        if (start != null) { section = start[1]; continue; }
        let opt = match(line, /^[ \t]*(option|list)[ \t]+([A-Za-z0-9_-]+)[ \t]+(.+)$/);
        if (section == "" || opt == null) continue;
        // Continuation lines of a quoted multi-line value belong to this option.
        let text = trim(opt[3]), raw = uci_value(text);
        while (raw == null && i + 1 < length(lines)) {
            text += "\n" + lines[++i];
            raw = uci_value(text);
        }
        if (raw == null) raw = text;
        let key = section + "." + opt[2];
        if (opt[1] == "list") {
            if (result[key] == null || result[key].kind != "list")
                result[key] = { kind: "list", values: [] };
            push(result[key].values, raw);
        }
        else
            result[key] = { kind: "option", value: raw };
    }
    return result;
}
function safe_values(option, values) {
    let result = [];
    for (let raw in values) push(result, safe_value(option, raw));
    return result;
}
function diff(before, after) {
    let old = options(before), current = options(after), result = [];
    let all = {};
    for (let key in keys(old)) all[key] = true;
    for (let key in keys(current)) all[key] = true;
    for (let key in keys(all)) {
        let a = old[key], b = current[key];
        let dot = index(key, "."), option = substr(key, dot + 1);
        if ((a != null && a.kind == "list") || (b != null && b.kind == "list")) {
            let before_values = a == null ? [] : a.kind == "list" ? a.values : [ a.value ];
            let after_values = b == null ? [] : b.kind == "list" ? b.values : [ b.value ];
            if (a != null && b != null && a.kind == b.kind &&
                sprintf("%J", before_values) == sprintf("%J", after_values)) continue;
            // An option side stays scalar so option <-> list changes remain visible.
            push(result, { section: substr(key, 0, dot), option, kind: "list",
                before: a != null && a.kind == "option" ? safe_value(option, a.value) : safe_values(option, before_values),
                after: b != null && b.kind == "option" ? safe_value(option, b.value) : safe_values(option, after_values) });
        }
        else {
            let before_value = a == null ? "" : a.value;
            let after_value = b == null ? "" : b.value;
            if (before_value == after_value) continue;
            push(result, { section: substr(key, 0, dot), option,
                before: safe_value(option, before_value), after: safe_value(option, after_value) });
        }
        if (length(result) >= 100) break;
    }
    return result;
}
// Install uses ensure semantics: after needs_attention the guard from the
// failed restore is still active and must protect the recovery restore too.
// It is removed only after a reload proved a coherent runtime.
function restore_guard(remove) {
    return success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/nft/apply.uc",
        remove ? "remove-dpi-transition-guard" : "ensure-dpi-transition-guard", "ForkopConfigRestore" ]);
}
// "absent", "valid" or "invalid"; empty when the state is unknown.
function restore_guard_state() {
    return trim(capture([ "ucode", "-L", LIB_DIR, LIB_DIR + "/nft/apply.uc",
        "dpi-transition-guard-state", "ForkopConfigRestore" ]));
}
// A lifecycle action (list or subscription update, WAN-up reload, start, a
// pending-reload drain) owns the reload lock: a reload requested now would
// only be queued behind it. A queued reload without a live owner is no such
// action: the next reload takes the free lock and its finish drains that
// request. A restore relies on this, so recovery stays possible while the
// current configuration cannot reload and keeps failing to drain the queue.
function service_action() {
    let pid = trim(value(fs.readfile(RELOAD_LOCK + "/pid")));
    return match(pid, /^[1-9][0-9]*$/) != null && fs.stat("/proc/" + pid) != null ? "service_action_in_progress" : null;
}
// A reload that was only queued (another lifecycle action took the reload
// lock after the check above) exits 0 without touching the runtime. init.d
// acknowledges it with a "queued" line for this caller's reason; a changed
// pending-reload marker (unique per request) is the second witness. A request
// queued before the call is drained by a reload that ran (the marker is
// gone); a drain that failed rewrites it and so never counts as ran.
function pending_stamp() {
    let st = fs.stat(PENDING_RELOAD);
    return st == null ? null : sprintf("%d:%d:%s", st.mtime, st.size, value(fs.readfile(PENDING_RELOAD)));
}
// "ran", "queued" or "failed".
function reload(reason) {
    let before = pending_stamp();
    let pipe = fs.popen(cmd([ RELOAD, "reload", reason ]) + " 2>/dev/null", "r");
    if (!pipe) return "failed";
    let output = value(pipe.read("all"));
    if (pipe.close() != 0) return "failed";
    for (let line in split(output, "\n"))
        if (trim(line) == "queued") return "queued";
    let after = pending_stamp();
    return after != null && after != before ? "queued" : "ran";
}
// Replace the configuration with `content` under the restore guard, validate
// and reload; on failure put `before` back and reload again. The guard also
// keeps the reload from confirming a last-known-working snapshot, so LKG is
// only ever moved by the caller. on_success runs after the guard is released.
// Only a reload that ran counts: after a queued one the configuration is put
// back, and when the rollback reload is queued too nothing proves a coherent
// runtime, so the guard stays and LKG is not touched.
// apply_mode (autotune apply): the caller proved no guard was active and the
// snapshot lock keeps restores out, so the guard is this call's own; an edit
// made while the guard was installed is never overwritten.
function guarded_replace(before, content, pre, on_success, reason, apply_mode) {
    // A guard left by an earlier needs_attention protects a runtime no reload
    // has proved yet: only this call's own guard may go without a reload.
    let inherited = !apply_mode && restore_guard_state() != "absent";
    if (!restore_guard(false)) return { status: "failed", reason: "guard_unavailable" };
    if (apply_mode && sha(read_config()) != sha(before)) {
        if (!restore_guard(true)) return { status: "needs_attention", reason: "guard_release_failed", guard: "active" };
        return { status: "failed", reason: "concurrent_change" };
    }
    if (!atomic(CONFIG, content)) {
        if (inherited) return { status: "failed", reason: "replace_failed", guard: "active" };
        if (!restore_guard(true)) return { status: "needs_attention", reason: "replace_failed", guard: "active" };
        return { status: "failed", reason: "replace_failed" };
    }
    let result = null;
    let valid = success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/config/validator.uc", "validate-runtime" ]);
    let target = valid ? reload(reason) : "invalid";
    if (target == "ran") {
        if (!restore_guard(true)) result = { status: "needs_attention", reason: "guard_release_failed", guard: "active" };
        else result = on_success();
    }
    else if (!atomic(CONFIG, before))
        result = { status: "needs_attention", reason: "config_rollback_failed", guard: "active" };
    else {
        let rollback = reload(reason);
        if (rollback != "ran")
            result = { status: "needs_attention", reason: rollback == "queued" ? "rollback_reload_queued" : "runtime_rollback_failed", guard: "active" };
        else if (!restore_guard(true)) result = { status: "needs_attention", reason: "guard_release_failed", guard: "active" };
        else if (!atomic(LKG, pre.snapshot.id + "\n")) result = { status: "needs_attention", reason: "lkg_update_failed", guard: "inactive" };
        else result = { status: "recovered", reason: target == "queued" ? "target_reload_queued" : "target_reload_failed", guard: "inactive" };
    }
    result.started = true;
    return result;
}
function do_restore(id) {
    let target = read_snapshot(id, true);
    if (target == null) return { status: "failed", reason: "invalid_snapshot" };
    let before = read_config();
    if (before == null) return { status: "failed", reason: "config_unavailable" };
    // Refused before anything changes while the reload would only be queued
    // behind a live lifecycle action.
    let action = service_action();
    if (action != null) return { status: "busy", reason: action };
    let pre = create("automatic", "pre-restore", false, [ id ]);
    if (pre.status != "created") return { status: "failed", reason: "pre_restore_snapshot_failed" };
    if (sha(before) != sha(read_config())) return { status: "failed", reason: "concurrent_change" };
    return guarded_replace(before, target.content, pre, () => {
        if (!atomic(LKG, id + "\n")) return { status: "needs_attention", reason: "lkg_update_failed", guard: "inactive" };
        return { status: "success", snapshot: metadata(target), changes: diff(before, target.content) };
    }, "config-restore");
}
// Apply a candidate configuration prepared elsewhere (DPI autotune stage 5)
// through the same transaction as a restore. The current configuration must
// still be the one the candidate was derived from (expected_hash), and it is
// saved first as a "before-autotune" snapshot for the caller's rollback. LKG
// is left untouched on success: the caller confirms it after its own checks.
function do_apply(candidate_file, expected_hash, keep_id) {
    let keep = valid_id(value(keep_id)) ? [ value(keep_id) ] : [];
    let content = fs.readfile(value(candidate_file));
    if (content == null || length(content) > MAX_CONFIG) return { status: "failed", reason: "candidate_unavailable" };
    let before = read_config();
    if (before == null) return { status: "failed", reason: "config_unavailable" };
    if (sha(before) != value(expected_hash)) return { status: "stale", reason: "config_changed" };
    if (content == before) return { status: "no_change", reason: "candidate_equals_config" };
    // An apply also waits for a queued reload: that request would reload the
    // candidate outside this transaction.
    let action = service_action() || (fs.stat(PENDING_RELOAD) != null ? "reload_pending" : null);
    if (action != null) return { status: "stale", reason: action };
    // Room for the before-autotune snapshot and for the pre-restore snapshot
    // of a later rollback, which may not remove the before-autotune one. A
    // manual LKG stays protected after the candidate is confirmed, so it
    // costs one more slot.
    let working = read_snapshot(trim(value(fs.readfile(LKG))), false);
    if (headroom(keep) < (working != null && working.kind == "manual" ? 3 : 2)) return { status: "failed", reason: "snapshot_retention_full" };
    let pre = create("automatic", "before-autotune", false, keep);
    if (pre.status != "created") return { status: "failed", reason: "pre_apply_snapshot_failed" };
    if (sha(before) != sha(read_config())) return { status: "failed", reason: "concurrent_change", pre_snapshot: pre.snapshot.id };
    let result = guarded_replace(before, content, pre, () => ({ status: "success", changes: diff(before, content) }), "autotune", true);
    result.pre_snapshot = pre.snapshot.id;
    return result;
}
let mode = value(ARGV[0]);
// The list is read-only output: the hash of the whole config (secrets
// included) stays internal (UC-150).
if (mode == "list") {
    let result = fs.stat(ROOT) == null ? [] : list_snapshots();
    for (let item in result) delete item.config_hash;
    print(sprintf("%J\n", result));
    exit(0);
}
if (mode == "diff") {
    let item = read_snapshot(value(ARGV[1]), true);
    let current = read_config();
    if (item == null || current == null) exit(1);
    print(sprintf("%J\n", diff(item.content, current)));
    exit(0);
}
if (mode == "fixture-diff") {
    print(sprintf("%J\n", diff(value(fs.readfile(ARGV[1])), value(fs.readfile(ARGV[2])))));
    exit(0);
}
if (index([ "create", "delete", "restore", "apply", "confirm-working" ], mode) < 0) exit(1);
if (!acquire()) {
    print(sprintf("%J\n", lock_busy ?
        { status: "busy", reason: "snapshot_operation_in_progress" } :
        { status: "failed", reason: "lock_unavailable" }));
    exit(1);
}
let answer = { status: "failed" };
if (mode == "create") {
    let kind = value(ARGV[1] || "manual");
    if (index([ "manual", "automatic" ], kind) >= 0)
        answer = create(kind, kind == "manual" ? "manual" : "before-reload", kind == "automatic");
    // Automatic snapshots are routine; only a manual one is a history event.
    if (kind == "manual" && answer.status == "created")
        success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", "snapshot_create", "success" ]);
}
else if (mode == "delete") {
    let id = value(ARGV[1]);
    if (valid_id(id) && id != trim(value(fs.readfile(LKG))) && read_snapshot(id, true) != null && fs.unlink(snapshot_path(id))) {
        answer = { status: "deleted" };
        success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", "snapshot_delete", "success" ]);
    }
}
else if (mode == "restore") {
    answer = do_restore(value(ARGV[1]));
    // A busy refusal changed nothing and is not a restore attempt.
    if (answer.status != "busy")
        success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", "restore",
            answer.status == "success" ? "success" : answer.status == "recovered" ? "recovered" : "failure" ]);
}
else if (mode == "apply") {
    answer = do_apply(ARGV[1], ARGV[2], ARGV[3]);
    // Health records a configuration transaction only when one was started.
    if (answer.started)
        success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", "autotune_apply",
            answer.status == "success" ? "success" : answer.status == "recovered" ? "recovered" : "failure" ]);
}
else if (mode == "confirm-working") {
    let found = create("automatic", "last-known-working", true);
    if (found.snapshot != null &&
        (trim(value(fs.readfile(LKG))) == found.snapshot.id || atomic(LKG, found.snapshot.id + "\n")))
        answer = { status: "confirmed" };
}
release();
print(sprintf("%J\n", answer));
exit(index([ "failed", "needs_attention", "busy" ], answer.status) >= 0 ? 1 : 0);
