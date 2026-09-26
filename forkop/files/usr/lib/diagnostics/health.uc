#!/usr/bin/env ucode

let fs = require("fs");

const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const RUNTIME_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const EVENT_FILE = RUNTIME_DIR + "/health-events.json";
const PACKAGE_PENDING = getenv("FORKOP_OPKG_RECOVERY_DIR") || "/etc/forkop/opkg-package-set-recovery";

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

function event_state() {
    let value = read_object(EVENT_FILE);
    let result = [];
    if (type(value.events) != "array") return result;
    for (let event in value.events) {
        if (type(event) != "object" ||
            index([ "start", "reload", "restore", "recovery" ], event.kind) < 0 ||
            index([ "success", "failure", "recovered" ], event.status) < 0 ||
            type(event.timestamp) != "int") continue;
        push(result, { kind: event.kind, status: event.status, timestamp: event.timestamp });
    }
    return length(result) > 10 ? slice(result, length(result) - 10) : result;
}

function record_event(kind, status) {
    if (index([ "start", "reload", "restore", "recovery" ], kind) < 0 ||
        index([ "success", "failure", "recovered" ], status) < 0)
        return 1;
    fs.mkdir(RUNTIME_DIR, 0700);
    let events = event_state();
    push(events, { kind, status, timestamp: int(clock()[0]) });
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
        if (events[i].kind == "reload" || events[i].kind == "restore") {
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
