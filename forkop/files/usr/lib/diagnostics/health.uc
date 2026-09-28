#!/usr/bin/env ucode

let fs = require("fs");

const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const RUNTIME_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const EVENT_FILE = RUNTIME_DIR + "/health-events.json";
const PACKAGE_PENDING = getenv("FORKOP_OPKG_RECOVERY_DIR") || "/etc/forkop/opkg-package-set-recovery";
// Significant events survive reboots in a small journal on flash. Only
// recorded events land there (starts, reloads, restores, autotune applies,
// manual snapshot changes), never probes or measurements. When the journal
// outgrows its cap it is rewritten once to the newest HISTORY_KEEP records.
const HISTORY_FILE = getenv("FORKOP_HISTORY_FILE") || "/etc/forkop/history.jsonl";
const HISTORY_MAX = 200;
const HISTORY_MAX_BYTES = 65536;
const HISTORY_KEEP = 150;
const EVENT_KINDS = [ "start", "reload", "restore", "recovery", "autotune_apply", "snapshot_create", "snapshot_delete" ];
const EVENT_STATUSES = [ "success", "failure", "recovered" ];

function read_object(path) {
    let raw = fs.readfile(path);
    if (raw == null || length(raw) > 32768)
        return {};
    try {
        let value = json(raw);
        return type(value) == "object" && type(value) != "array" ? value : {};
    }
    catch (e) {
        return {};
    }
}

function quote(value) {
    return "'" + replace("" + value, /'/g, "'\\''") + "'";
}

function command(args) {
    let parts = [];
    for (let arg in args) push(parts, quote(arg));
    return join(" ", parts);
}

function capture(args) {
    let pipe = fs.popen(command(args), "r");
    if (!pipe)
        return "";
    let output = pipe.read("all");
    return pipe.close() == 0 && output != null ? output : "";
}

function command_ok(args) {
    return system(command(args) + " >/dev/null 2>&1") == 0;
}

function valid_event(event) {
    return type(event) == "object" && index(EVENT_KINDS, event.kind) >= 0 &&
        index(EVENT_STATUSES, event.status) >= 0 && type(event.timestamp) == "int";
}

function history_events(all) {
    let raw = fs.readfile(HISTORY_FILE);
    if (raw == null)
        return null;
    let result = [];
    for (let line in split(raw, "\n")) {
        if (line == "") continue;
        let event;
        try { event = json(line); } catch (e) { continue; }
        if (valid_event(event))
            push(result, { kind: event.kind, status: event.status, timestamp: event.timestamp });
    }
    return !all && length(result) > HISTORY_MAX ? slice(result, length(result) - HISTORY_MAX) : result;
}

function append_history(event) {
    let dir = replace(HISTORY_FILE, /\/[^\/]*$/, "");
    if (dir != "" && fs.stat(dir) == null)
        fs.mkdir(dir, 0755);
    let file = fs.open(HISTORY_FILE, "a");
    if (!file)
        return false;
    file.write(sprintf("%J\n", event));
    file.close();

    let stat = fs.stat(HISTORY_FILE);
    let events = history_events(true) || [];
    if ((stat != null && stat.size <= HISTORY_MAX_BYTES) && length(events) <= HISTORY_MAX)
        return true;
    let lines = "";
    for (let item in slice(events, max(0, length(events) - HISTORY_KEEP)))
        lines += sprintf("%J\n", item);
    let path = sprintf("%s.%d.tmp", HISTORY_FILE, clock()[1]);
    if (fs.writefile(path, lines) == null || !fs.rename(path, HISTORY_FILE)) {
        fs.unlink(path);
        return false;
    }
    return true;
}

function event_state() {
    let value = read_object(EVENT_FILE);
    let result = [];
    if (type(value.events) != "array") return result;
    for (let event in value.events) {
        if (!valid_event(event)) continue;
        push(result, { kind: event.kind, status: event.status, timestamp: event.timestamp });
    }
    return length(result) > 10 ? slice(result, length(result) - 10) : result;
}

function record_event(kind, status) {
    if (index(EVENT_KINDS, kind) < 0 || index(EVENT_STATUSES, status) < 0)
        return 1;
    fs.mkdir(RUNTIME_DIR, 0700);
    let event = { kind, status, timestamp: int(clock()[0]) };
    // The journal is best effort: a full or read-only flash must not stop
    // health from recording the event.
    append_history(event);
    let events = event_state();
    push(events, event);
    while (length(events) > 10)
        shift(events);
    let path = sprintf("%s.%d.tmp", EVENT_FILE, clock()[1]);
    if (fs.writefile(path, sprintf("%J\n", { events })) == null ||
        !fs.chmod(path, 0600) || !fs.rename(path, EVENT_FILE)) {
        fs.unlink(path);
        return 1;
    }
    return 0;
}

function as_string(value) {
    return value == null ? "" : "" + value;
}

function health(ui, guard, package_pending, events) {
    let service = type(ui.service) == "object" ? ui.service : {};
    let forkop = type(service.forkop) == "object" ? service.forkop : {};
    let sing_box = type(service.sing_box) == "object" ? service.sing_box : {};
    let transition = match(as_string(forkop.status), /^(starting|stopping|restarting|reloading)$/) != null;
    let service_status = transition ? "transitioning" :
        forkop.running == null ? "unknown" : forkop.running == 1 ? "ok" : "error";
    let last = length(events) ? events[length(events) - 1] : null;
    let last_reload = null;
    for (let i = length(events) - 1; i >= 0; i--)
        if (index([ "reload", "restore", "autotune_apply" ], events[i].kind) >= 0) {
            last_reload = events[i];
            break;
        }
    let failed = last != null && last.status == "failure";
    let overall = guard || package_pending || failed ? "error" :
        transition ? "transitioning" : service_status;
    if (overall == "ok" && last != null && last.status == "recovered")
        overall = "recovered";
    return {
        overall,
        service: {
            forkop: service_status,
            sing_box: sing_box.running == null ? "unknown" : sing_box.running == 1 ? "ok" : "error"
        },
        dns: { status: forkop.dns_configured == 0 ? "warning" : "unknown",
            configured: forkop.dns_configured == 1 },
        dpi: { status: guard ? "transitioning" : "unknown" },
        lists: { status: "unknown" },
        guard: { active: guard },
        recovery: { pending: guard || failed, last_event: last },
        package_recovery: { pending: package_pending },
        last_reload,
        recent_activity: events
    };
}

let mode = ARGV[0] || "";
if (mode == "record")
    exit(record_event(as_string(ARGV[1]), as_string(ARGV[2])));
if (mode == "history") {
    let events = history_events();
    print(sprintf("%J\n", events == null ?
        { persistent: false, events: event_state() } :
        { persistent: true, events }));
    exit(0);
}
if (mode == "fixture") {
    let input = read_object(ARGV[1]);
    print(sprintf("%J\n", health(input.ui || {}, input.guard === true,
        input.package_pending === true, input.events || [])));
    exit(0);
}
if (mode != "get")
    exit(1);

let ui = {};
try {
    ui = json(capture([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/ui.uc", "get-ui-state" ]));
}
catch (e) {}
let guard = command_ok([ "nft", "list", "table", "inet", "ForkopTableDpiGuard" ]) ||
    command_ok([ "nft", "list", "table", "inet", "ForkopConfigRestoreDpiGuard" ]) ||
    command_ok([ "nft", "list", "chain", "inet", "ForkopTable", "forkop_transition_guard" ]);
let package_pending = fs.stat(PACKAGE_PENDING + "/pending") != null;
print(sprintf("%J\n", health(ui, guard, package_pending, event_state())));
