#!/usr/bin/env ucode

// Isolated candidate probing for DPI autotune.
//
// A candidate strategy is tested without touching the production runtime:
// a temporary nft table (ForkopAutotuneProbe) queues only the probe's own
// connection, selected by destination and by a source-port range outside the
// kernel ephemeral range, to a temporary nfqws on a dedicated queue.
//
// Every packet of the probe tuple leaves the temporary chains with exactly the
// canonical probe mark (the Forkop outbound mark) and is routed with it:
//  - chain "premark" (route, -152) gives the probe connection the probe mark and
//    accepts, so the kernel re-routes it with that mark before anything else;
//  - chain "output" (route, -151) queues it to the candidate, and normalizes
//    packets injected by the temporary nfqws (desync | probe mark) back to the
//    probe mark (return: re-routed with it as well); anything else of the
//    tuple is dropped.
// Production is therefore only ever asked to honour one thing - its bypass
// for that mark - and autotune/contract.uc proves that bypass, the policy
// routing and the reply path from the live system before anything is created.
// Configuration, ForkopTable, the production nfqws and sing-box are never
// modified; every run ends with a verified teardown.
//
// Must be invoked as: ucode -L <lib> <lib>/autotune/isolation.uc <mode> ...
// (the run lock identifies its owner by that command line).
let fs = require("fs");
let constants = require("core.constants");
let identity = require("core.process_identity");
let catalog = require("autotune.catalog");
let probe_module = require("autotune.probe");
let contract = require("autotune.contract");

const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const STATE_DIR = getenv("FORKOP_AUTOTUNE_STATE_DIR") || "/var/run/forkop/autotune";
const LOCK = STATE_DIR + "/lock";
const ACTIVE = STATE_DIR + "/active.json";
const PIDFILE = STATE_DIR + "/nfqws.pid";
const WORKDIR = STATE_DIR + "/work";
const TABLE = "ForkopAutotuneProbe";
const MARK_CHAIN = "premark";
const MARK_PRIORITY = -152;
const CHAIN = "output";
const PRIORITY = -151;
const REPLY_CHAIN = "replies";
const REPLY_PRIORITY = -300;
const QUEUE = int(getenv("FORKOP_AUTOTUNE_QUEUE") || "4600");
const PORT_FIRST = 61000;
const PORT_LAST = 61031;
const PORT_RANGE = PORT_FIRST + "-" + PORT_LAST;
const PROD_TABLE = constants.NFT_TABLE_NAME;
const PROBE_MARK = constants.NFT_OUTBOUND_MARK;
const DESYNC_MARK = getenv("ZAPRET_DESYNC_MARK") || constants.ZAPRET_DESYNC_MARK;
const NFQWS = getenv("ZAPRET_NFQWS_BIN") || constants.ZAPRET_NFQWS_BIN;
// nfqws drops privileges to this uid; its injected packets may carry it.
const NFQWS_UID = 2147483647;
const PROC_QUEUE = getenv("FORKOP_AUTOTUNE_PROC_QUEUE") || "/proc/net/netfilter/nfnetlink_queue";
const PORT_RANGE_FILE = getenv("FORKOP_AUTOTUNE_PORT_RANGE_FILE") || "/proc/sys/net/ipv4/ip_local_port_range";
const PROC_NET = getenv("FORKOP_AUTOTUNE_PROC_NET") || "/proc/net";
const CHILD_PID_DIR = getenv("ZAPRET_CHILD_PID_DIR") || constants.ZAPRET_CHILD_PID_DIR;
const SNAPSHOT_LOCK = getenv("FORKOP_SNAPSHOT_LOCK_DIR") || "/var/run/forkop/config-snapshot.lock";
const GUARD_TABLES = [ "ForkopConfigRestoreDpiGuard", PROD_TABLE + "DpiGuard" ];
const LISTENER_WAIT = int(getenv("FORKOP_AUTOTUNE_LISTENER_WAIT") || "5");
const TRACE = getenv("FORKOP_AUTOTUNE_TRACE") == "1";
const NFQWS_DEBUG = getenv("FORKOP_AUTOTUNE_NFQWS_DEBUG") == "1";
const MAX_PROBES = 5;
// Seconds the teardown waits, with the isolation intact, for the probe
// connections to finish closing and for queued packets to get a verdict.
const DRAIN_TIMEOUT = int(getenv("FORKOP_AUTOTUNE_DRAIN_TIMEOUT") || "3");
// Seconds the table is kept after nfqws stopped, until no socket of the probe
// tuple is left (TIME_WAIT lasts 60 s on Linux).
const HOLD_TIMEOUT = int(getenv("FORKOP_AUTOTUNE_HOLD_TIMEOUT") || "65");
// Seconds to wait for production queues to be momentarily empty before the
// temporary hooks are registered or unregistered.
const QUIET_TIMEOUT = int(getenv("FORKOP_AUTOTUNE_QUIET_TIMEOUT") || "2");
const PROBE_MARK_VALUE = contract.mark_number(PROBE_MARK);
const DESYNC_MARK_VALUE = contract.mark_number(DESYNC_MARK);
const REQUIRED_COUNTERS = [ "probe_mark", "reinjected", "reinjected_bare", "probe", "unexpected" ];
// Production queue ranges the dedicated queue must stay out of.
const RESERVED_QUEUES = [
    [ int(constants.ZAPRET_QUEUE_BASE), int(constants.ZAPRET_QUEUE_BASE) + int(constants.ZAPRET_QUEUE_RANGE_SIZE) - 1 ],
    [ int(constants.ZAPRET2_QUEUE_BASE), int(constants.ZAPRET2_QUEUE_BASE) + int(constants.ZAPRET2_QUEUE_RANGE_SIZE) - 1 ]
];

let interrupted = false;
let timeline = [];

function as_string(v) { return v == null ? "" : "" + v; }
function quote(v) { return "'" + replace(as_string(v), /'/g, "'\\''") + "'"; }
function command(args) {
    let parts = [];
    for (let arg in args) push(parts, quote(arg));
    return join(" ", parts);
}
function capture(args) {
    let pipe = fs.popen(command(args) + " 2>/dev/null", "r");
    if (!pipe) return { status: -1, output: "" };
    let data = pipe.read("all");
    return { status: int(pipe.close()), output: as_string(data) };
}
function success(args) { return system(command(args) + " >/dev/null 2>&1") == 0; }
function pause() { system("sleep 1"); }

function now() {
    let c = type(clock) == "function" ? clock() : null;
    let sec = c ? c[0] : time(), msec = c ? int(c[1] / 1000000) : 0;
    let t = localtime(sec);
    return sprintf("%02d:%02d:%02d.%03d", t.hour, t.min, t.sec, msec);
}
function mark(step, event, extra) {
    let entry = { step, event, at: now() };
    if (extra != null) entry.detail = extra;
    push(timeline, entry);
}

function hex_value(text) {
    let result = 0;
    text = lc(as_string(text));
    if (text == "") return null;
    for (let i = 0; i < length(text); i++) {
        let digit = index("0123456789abcdef", substr(text, i, 1));
        if (digit < 0) return null;
        result = result * 16 + digit;
    }
    return result;
}

function queue_reserved() {
    for (let range in RESERVED_QUEUES)
        if (QUEUE >= range[0] && QUEUE <= range[1]) return true;
    return false;
}

// ---- lock --------------------------------------------------------------

let lock_record = null;
let lock_busy = false;
function owner_pid() {
    let pid = as_string(fs.readlink("/proc/self"));
    return match(pid, /^[1-9][0-9]*$/) != null ? pid : "";
}
function active_owner(name) {
    let parsed = match(as_string(name), /^owner\.([1-9][0-9]*)\.([0-9]+)$/);
    return parsed != null && identity.matches_record({ pid: parsed[1], ticks: parsed[2] }, "ucode",
        [ "ucode", "-L", LIB_DIR, LIB_DIR + "/autotune/isolation.uc" ], false, true) != "";
}
function remove_dir(dir) {
    for (let name in fs.lsdir(dir) || []) fs.unlink(dir + "/" + name);
    return fs.rmdir(dir);
}
function ensure_state_dir() {
    let parent = fs.dirname(STATE_DIR);
    if (fs.stat(parent) == null && !fs.mkdir(parent, 0700)) return false;
    if (fs.stat(STATE_DIR) == null && !fs.mkdir(STATE_DIR, 0700)) return false;
    return fs.chmod(STATE_DIR, 0700);
}
// Same owner-record scheme as the config snapshot lock: a directory holding
// one "owner.<pid>.<start ticks>" record, published by an atomic rename.
function acquire() {
    if (!ensure_state_dir()) return false;
    let pid = owner_pid(), ticks = identity.start_ticks(pid);
    if (ticks == "") return false;
    let name = "owner." + pid + "." + ticks;
    let pending = LOCK + ".new." + pid + "." + ticks;
    remove_dir(pending);
    if (!fs.mkdir(pending, 0700) || !identity.record(pending + "/" + name, pid) || !active_owner(name)) {
        remove_dir(pending);
        return false;
    }
    for (let attempt = 0; attempt < 3; attempt++) {
        if (fs.rename(pending, LOCK)) {
            lock_record = LOCK + "/" + name;
            return true;
        }
        let stat = fs.lstat(LOCK);
        let entries = stat != null && stat.type == "directory" ? fs.lsdir(LOCK) : null;
        if (entries == null) { fs.unlink(LOCK); continue; }
        let busy = false;
        for (let entry in entries) if (active_owner(entry)) busy = true;
        if (busy) { lock_busy = true; break; }
        for (let entry in entries)
            if (!fs.unlink(LOCK + "/" + entry)) fs.rmdir(LOCK + "/" + entry);
    }
    remove_dir(pending);
    return false;
}
function release() {
    if (lock_record == null) return;
    fs.unlink(lock_record);
    fs.rmdir(LOCK);
    lock_record = null;
    // Leave no runtime directory behind; fails harmlessly while not empty.
    fs.rmdir(STATE_DIR);
}

// ---- observation -------------------------------------------------------

// "present", "absent" or "unknown" (nft failed): only a successful listing
// that lacks the table counts as absent.
function table_state(name) {
    let out = capture([ "nft", "list", "tables" ]);
    if (out.status != 0) return "unknown";
    for (let line in split(out.output, "\n"))
        if (trim(line) == "table inet " + name) return "present";
    return "absent";
}
function table_exists(name) { return table_state(name) != "absent"; }

function nft_listing(args) {
    let listing = capture(args);
    if (listing.status != 0 || trim(listing.output) == "") return null;
    try {
        let parsed = json(listing.output);
        return type(parsed) == "object" && type(parsed.nftables) == "array" ? parsed.nftables : null;
    }
    catch (e) { return null; }
}
function nft_json(name) { return nft_listing([ "nft", "-j", "list", "table", "inet", name ]); }

// Counters move with live traffic; the structure of the table must not.
function without_counters(value) {
    if (type(value) == "array") {
        let result = [];
        for (let item in value) push(result, without_counters(item));
        return result;
    }
    if (type(value) != "object") return value;
    let result = {};
    for (let key in keys(value)) {
        if (key == "counter" && type(value[key]) == "object")
            result[key] = { packets: 0, bytes: 0 };
        else
            result[key] = without_counters(value[key]);
    }
    return result;
}

function sha(text) {
    // mktemp creates the file exclusively; status must not create runtime state.
    let path = trim(capture([ "mktemp", "/tmp/forkop-autotune-hash.XXXXXX" ]).output);
    if (path == "" || fs.writefile(path, text) == null) { if (path != "") fs.unlink(path); return ""; }
    let out = capture([ "sha256sum", path ]);
    fs.unlink(path);
    let m = match(out.output, /^([0-9a-f]{64})/);
    return m ? m[1] : "";
}

function queues() {
    let result = [];
    for (let line in split(as_string(fs.readfile(PROC_QUEUE)), "\n")) {
        let f = split(trim(line), /[ \t]+/);
        if (length(f) < 8 || match(f[0], /^[0-9]+$/) == null) continue;
        push(result, { queue: int(f[0]), portid: f[1], total: int(f[2]), dropped: int(f[5]),
            user_dropped: int(f[6]), id_sequence: int(f[7]) });
    }
    return result;
}
function queue_entry(number) {
    for (let q in queues()) if (q.queue == number) return q;
    return null;
}

// Registering or unregistering a base chain affects packets that sit in an
// NFQUEUE at that instant. Wait (bounded) for production queues to be empty.
function production_queues_quiet() {
    let result = { quiet: false, waited_s: 0, pending: 0 };
    for (let i = 0; ; i++) {
        let pending = 0;
        for (let q in queues()) if (q.queue != QUEUE) pending += q.total;
        result.pending = pending;
        if (pending == 0) { result.quiet = true; break; }
        if (i >= QUIET_TIMEOUT) break;
        pause();
        result.waited_s++;
    }
    return result;
}

function child_records() {
    let result = [];
    for (let name in sort(fs.lsdir(CHILD_PID_DIR) || [])) {
        if (match(name, /\.pid$/) == null) continue;
        let saved = identity.read_record(CHILD_PID_DIR + "/" + name);
        push(result, name + "=" + (saved ? saved.pid + ":" + saved.ticks : "invalid"));
    }
    return result;
}

function guards_present() {
    let result = [];
    for (let name in GUARD_TABLES) if (table_exists(name)) push(result, name);
    return result;
}

function ip_json(args) {
    let out = capture(args);
    if (out.status != 0) return null;
    try { return json(out.output); } catch (e) { return null; }
}

// The route of the probe tuple as the kernel resolves it. All probe packets
// are routed with the probe mark; the unmarked lookup (the socket's own route,
// which picked the source address) must be the same route.
function route_lookup(ip, mark_value) {
    let routes = ip_json([ "ip", "-j", "route", "get", ip, "mark", mark_value, "ipproto", "tcp",
        "sport", "" + PORT_FIRST, "dport", "443", "uid", "0" ]);
    let route = type(routes) == "array" ? routes[0] : null;
    if (type(route) != "object") return null;
    return { dev: route.dev || null, gateway: route.gateway || null, prefsrc: route.prefsrc || null,
        type: route.type || "unicast" };
}
function probe_route(ip) {
    let marked = route_lookup(ip, PROBE_MARK), unmarked = route_lookup(ip, "0");
    if (marked == null || unmarked == null) return { ok: false, reason: "route_unavailable" };
    let result = { ok: true, ...marked, unmarked };
    if (marked.dev == "lo" || marked.type != "unicast") { result.ok = false; result.reason = "probe_route_local"; }
    else if (marked.dev != unmarked.dev || marked.gateway != unmarked.gateway || marked.prefsrc != unmarked.prefsrc) {
        result.ok = false; result.reason = "probe_route_differs_from_socket_route";
    }
    return result;
}

// The production state the run compares before and after, together with the
// table listing it was hashed from (so the contract can be checked on it).
function production_snapshot(ip) {
    let table = nft_json(PROD_TABLE);
    let other = [];
    for (let q in queues()) if (q.queue != QUEUE) push(other, q.queue + ":" + q.portid);
    return { table, state: {
        forkop_table_hash: table == null ? "absent" : sha(sprintf("%J", without_counters(table))),
        queues: other,
        zapret_children: child_records(),
        guards: guards_present(),
        ip_rules_hash: sha(capture([ "ip", "-j", "rule" ]).output),
        route: ip ? probe_route(ip) : null
    } };
}
function production_state(ip) { return production_snapshot(ip).state; }
function same_state(a, b) { return sprintf("%J", a) == sprintf("%J", b); }

function legacy_tables() {
    let result = [];
    for (let file in [ "ip_tables_names", "ip6_tables_names" ])
        for (let line in split(as_string(fs.readfile(PROC_NET + "/" + file)), "\n"))
            if (trim(line) != "") push(result, trim(line));
    return result;
}

// The contract on the live ruleset (terse: no set elements), plus the
// elements of the interface sets production inbound rules gate on.
function bypass_contract(route, ip) {
    let listing = nft_listing([ "nft", "-j", "-t", "list", "ruleset" ]);
    let sets = {};
    for (let name in contract.reply_sets(listing, PROD_TABLE)) {
        let set = null;
        for (let item in nft_listing([ "nft", "-j", "list", "set", "inet", PROD_TABLE, name ]) || [])
            if (type(item.set) == "object") set = item.set;
        if (set != null) {
            let elements = [];
            for (let e in set.elem || []) push(elements, e);
            sets[name] = elements;
        }
    }
    let result = contract.evaluate(listing, ip_json([ "ip", "-j", "rule" ]) || "unavailable", {
        probe_mark: PROBE_MARK, own_table: TABLE, own_priority: PRIORITY, prod_table: PROD_TABLE,
        target: ip, probe_saddr: route.prefsrc, reply_dev: route.dev, sets,
        sport_range: [ PORT_FIRST, PORT_LAST ], dport: 443, uids: [ 0, NFQWS_UID ],
        legacy_tables: legacy_tables()
    });
    result.sets = sets;
    return result;
}

// Counters of every rule of the temporary table by comment; null when the
// listing is unavailable or incomplete.
function probe_counters() {
    let table = nft_json(TABLE);
    if (table == null) return null;
    let result = {};
    for (let item in table) {
        let rule = item.rule;
        if (type(rule) != "object" || rule.table != TABLE) continue;
        for (let expr in rule.expr || [])
            if (type(expr) == "object" && type(expr.counter) == "object")
                result[as_string(rule.comment)] = { packets: int(expr.counter.packets), bytes: int(expr.counter.bytes) };
    }
    for (let name in REQUIRED_COUNTERS)
        if (result[name] == null && !(name == "probe" && result.released != null)) return null;
    return result;
}

// ---- runtime preconditions ---------------------------------------------

function queue_referenced(ruleset) {
    for (let m in match(ruleset, /queue( flags [a-z,]+)? (to|num) ([0-9]+)(-([0-9]+))?/g) || []) {
        let first = int(m[3]), last = m[5] ? int(m[5]) : first;
        if (QUEUE >= first && QUEUE <= last) return true;
    }
    return false;
}

function queue_check() {
    if (queue_reserved()) return "queue_overlaps_forkop_range";
    if (queue_entry(QUEUE) != null) return "queue_in_use";
    let ruleset = capture([ "nft", "list", "ruleset" ]);
    if (ruleset.status != 0) return "ruleset_unavailable";
    if (queue_referenced(ruleset.output)) return "queue_referenced";
    return null;
}

function port_check() {
    let range = split(trim(as_string(fs.readfile(PORT_RANGE_FILE))), /[ \t]+/);
    if (length(range) != 2) return "port_range_unknown";
    if (!(PORT_LAST < int(range[0]) || PORT_FIRST > int(range[1]))) return "port_range_overlaps_ephemeral";
    for (let file in [ "tcp", "tcp6" ]) {
        for (let line in split(as_string(fs.readfile(PROC_NET + "/" + file)), "\n")) {
            let f = split(trim(line), /[ \t]+/);
            if (length(f) < 4 || index(f[1], ":") < 0) continue;
            let port = hex_value(substr(f[1], index(f[1], ":") + 1));
            // TIME_WAIT (06) leftovers of an earlier probe send no new data.
            if (port != null && port >= PORT_FIRST && port <= PORT_LAST && f[3] != "06")
                return "port_range_in_use";
        }
    }
    return null;
}

// /proc/net/tcp prints an address as the raw 32-bit value in host byte
// order: accept both renderings so little- and big-endian targets work.
function address_hex_forms(ip) {
    let m = match(as_string(ip), /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$/);
    if (m == null) return [];
    let be = sprintf("%02X%02X%02X%02X", int(m[1]), int(m[2]), int(m[3]), int(m[4]));
    let le = sprintf("%02X%02X%02X%02X", int(m[4]), int(m[3]), int(m[2]), int(m[1]));
    return [ be, le,
        "0000000000000000FFFF0000" + le,      // ::ffff:a.b.c.d, little-endian words
        "00000000000000000000FFFF" + be ];    // ::ffff:a.b.c.d, big-endian words
}
// Sockets of the probe tuple (local port in the probe range, remote target:443).
function probe_sockets(ip) {
    let forms = address_hex_forms(ip);
    let result = { total: 0, closing: 0 };
    for (let file in [ "tcp", "tcp6" ]) {
        for (let line in split(as_string(fs.readfile(PROC_NET + "/" + file)), "\n")) {
            let f = split(trim(line), /[ \t]+/);
            if (length(f) < 4 || index(f[1], ":") < 0 || index(f[2], ":") < 0) continue;
            let port = hex_value(substr(f[1], index(f[1], ":") + 1));
            if (port == null || port < PORT_FIRST || port > PORT_LAST) continue;
            let remote = uc(substr(f[2], 0, index(f[2], ":")));
            if (index(forms, remote) < 0 || hex_value(substr(f[2], index(f[2], ":") + 1)) != 443) continue;
            result.total++;
            if (f[3] != "06") result.closing++;
        }
    }
    return result;
}

// ---- process ownership -------------------------------------------------

function nfqws_argv(opt, debug_file) {
    let argv = [ NFQWS, "--qnum=" + QUEUE, "--dpi-desync-fwmark=" + DESYNC_MARK ];
    for (let word in catalog.words(opt)) push(argv, word);
    if (debug_file) push(argv, "--debug=@" + debug_file);
    return argv;
}
function signature_prefix() {
    return [ NFQWS, "--qnum=" + QUEUE, "--dpi-desync-fwmark=" + DESYNC_MARK ];
}

// Terminates a process only while its start time, executable and command line
// still match the recorded identity.
function stop_identified(saved, argv, exact) {
    if (identity.matches_record(saved, NFQWS, argv, exact, true) == "") return "not_ours";
    identity.signal_record(saved, NFQWS, argv, exact, "TERM");
    for (let i = 0; i < 3 && identity.matches_record(saved, NFQWS, argv, exact, true) != ""; i++) pause();
    if (identity.matches_record(saved, NFQWS, argv, exact, true) == "") return "stopped";
    identity.signal_record(saved, NFQWS, argv, exact, "KILL");
    for (let i = 0; i < 2 && identity.matches_record(saved, NFQWS, argv, exact, true) != ""; i++) pause();
    return identity.matches_record(saved, NFQWS, argv, exact, true) == "" ? "killed" : "failed";
}

// Temporary nfqws processes left behind by an interrupted run: the very
// binary path, dedicated queue and desync mark; nothing else qualifies.
function orphans() {
    let result = [];
    let prefix = signature_prefix();
    for (let name in fs.lsdir("/proc") || []) {
        if (match(name, /^[1-9][0-9]*$/) == null || name == owner_pid()) continue;
        let exe = replace(as_string(fs.readlink("/proc/" + name + "/exe")), / \(deleted\)$/, "");
        if (exe != NFQWS) continue;
        let saved = { pid: name, ticks: identity.start_ticks(name) };
        if (saved.ticks != "" && identity.matches_record(saved, NFQWS, prefix, false, true) != "")
            push(result, saved);
    }
    return result;
}

function read_active() {
    let data = fs.readfile(ACTIVE);
    if (data == null) return null;
    try { let parsed = json(data); return type(parsed) == "object" ? parsed : {}; }
    catch (e) { return {}; }
}

// The probe target as recorded in the temporary table itself (recovery when
// active.json is missing or malformed).
function table_target() {
    for (let item in nft_json(TABLE) || []) {
        let rule = item.rule;
        if (type(rule) != "object") continue;
        for (let expr in rule.expr || []) {
            let m = type(expr) == "object" ? expr.match : null;
            if (type(m) == "object" && type(m.left) == "object" && type(m.left.payload) == "object" &&
                m.left.payload.protocol == "ip" && m.left.payload.field == "daddr" && probe_module.valid_ipv4(m.right))
                return m.right;
        }
    }
    return null;
}

// The temporary chains as data: the nft batch is rendered from them and the
// regression tests evaluate exactly this model against production rulesets.
// Every rule is confined to the probe tuple; nothing outside it is touched.
function probe_chains(ip, queue_candidate) {
    let tuple = { daddr: ip, dport: 443, sport: [ PORT_FIRST, PORT_LAST ] };
    let injected = DESYNC_MARK_VALUE | PROBE_MARK_VALUE;
    let chains = [
        { name: MARK_CHAIN, type: "route", hook: "output", priority: MARK_PRIORITY, rules: [
            // The probe connection: canonical probe mark, accepted so the
            // kernel re-routes it with that mark.
            { comment: "probe_mark", tuple, mark: 0, set_mark: PROBE_MARK_VALUE, verdict: "accept" }
        ] },
        { name: CHAIN, type: "route", hook: "output", priority: PRIORITY, rules: [
            // Injected by the temporary nfqws for the probe connection
            // (desync | probe mark): normalized to the canonical probe mark.
            { comment: "reinjected", tuple, mark: injected, set_mark: PROBE_MARK_VALUE, verdict: "return" },
            // Injected with the bare desync mark: normalized the same way.
            { comment: "reinjected_bare", tuple, mark: DESYNC_MARK_VALUE, set_mark: PROBE_MARK_VALUE, verdict: "return" },
            // The marked probe connection goes to the candidate.
            { comment: "probe", tuple, mark: PROBE_MARK_VALUE, set_mark: null,
              verdict: queue_candidate ? "queue" : "accept", queue: queue_candidate ? QUEUE : null },
            // Anything else of the probe tuple: never handed to production.
            { comment: "unexpected", tuple, mark: null, set_mark: null, verdict: "drop" }
        ] }
    ];
    if (TRACE)
        // Evidence only: marks the replies for nft trace and counts them.
        push(chains, { name: REPLY_CHAIN, type: "filter", hook: "prerouting", priority: REPLY_PRIORITY, rules: [
            { comment: "reply", reply: { saddr: ip, sport: 443, dport: [ PORT_FIRST, PORT_LAST ] },
              mark: null, set_mark: null, verdict: null }
        ] });
    return chains;
}

function render_rule(rule) {
    let text = rule.reply
        ? "ip saddr " + rule.reply.saddr + " tcp sport " + rule.reply.sport + " tcp dport " + rule.reply.dport[0] + "-" + rule.reply.dport[1]
        : "ip daddr " + rule.tuple.daddr + " tcp dport " + rule.tuple.dport + " tcp sport " + rule.tuple.sport[0] + "-" + rule.tuple.sport[1];
    if (rule.mark != null) text += sprintf(" meta mark 0x%08x", rule.mark);
    if (TRACE) text += " meta nftrace set 1";
    if (rule.set_mark != null) text += sprintf(" meta mark set 0x%08x", rule.set_mark);
    text += " counter";
    if (rule.verdict == "queue") text += " queue num " + rule.queue;
    else if (rule.verdict != null) text += " " + rule.verdict;
    return text + " comment \"" + rule.comment + "\"";
}

function batch(ip, queue_candidate) {
    let text = "create table inet " + TABLE + "\n";
    for (let chain in probe_chains(ip, queue_candidate)) {
        text += "add chain inet " + TABLE + " " + chain.name + " { type " + chain.type + " hook " + chain.hook +
            " priority " + chain.priority + "; policy accept; }\n";
        for (let rule in chain.rules)
            text += "add rule inet " + TABLE + " " + chain.name + " " + render_rule(rule) + "\n";
    }
    return text;
}

function probe_rule_handles() {
    let result = [];
    for (let item in nft_json(TABLE) || [])
        if (type(item.rule) == "object")
            push(result, { chain: item.rule.chain, handle: item.rule.handle, comment: item.rule.comment });
    return result;
}

// Quiesce while the candidate still runs: the probe connections finish their
// closing handshake and queued packets get their verdict. Skipped on signal.
function drain(ip, queue_candidate) {
    let result = { settled: false, waited_s: 0, closing_sockets: 0, queue_pending: 0 };
    for (let i = 0; ; i++) {
        let sockets = probe_sockets(ip), q = queue_candidate ? queue_entry(QUEUE) : null;
        result.closing_sockets = sockets.closing;
        result.queue_pending = q ? q.total : 0;
        if (sockets.closing == 0 && result.queue_pending == 0) { result.settled = true; break; }
        if (interrupted || i >= DRAIN_TIMEOUT) break;
        pause();
        result.waited_s++;
    }
    return result;
}

// Release the probe connection from the candidate before nfqws stops: the
// queue rule becomes an accept of the canonical probe mark in one atomic
// replace, so late packets (FIN/ACK, TIME_WAIT ACKs) leave through the
// production bypass instead of being dropped (which would make the peer
// retransmit and keep the sockets alive) or queued without a listener.
function release_probe_rule(ip) {
    let listing = nft_json(TABLE);
    if (listing == null) return "failed";
    let handle = null, released = false;
    for (let item in listing) {
        if (type(item.rule) != "object" || item.rule.chain != CHAIN) continue;
        if (item.rule.comment == "probe") handle = item.rule.handle;
        if (item.rule.comment == "released") released = true;
    }
    if (handle == null) return released ? "already_released" : "failed";
    let rule = { comment: "released", tuple: { daddr: ip, dport: 443, sport: [ PORT_FIRST, PORT_LAST ] },
        mark: PROBE_MARK_VALUE, set_mark: null, verdict: "accept" };
    let file = WORKDIR + "/release.nft";
    if (fs.stat(WORKDIR) == null) fs.mkdir(WORKDIR, 0755);
    if (fs.writefile(file, "replace rule inet " + TABLE + " " + CHAIN + " handle " + handle + " " + render_rule(rule) + "\n") == null)
        return "failed";
    let ok = success([ "nft", "-f", file ]);
    fs.unlink(file);
    return ok ? "released" : "failed";
}

// Keep the table until no socket of the probe tuple is left, so no late packet
// can reach production classification after the table is gone. Not cut short
// by a signal: it is bounded and only waits.
function hold(ip) {
    let result = { settled: false, waited_s: 0, sockets: 0 };
    for (let i = 0; ; i++) {
        result.sockets = probe_sockets(ip).total;
        if (result.sockets == 0) { result.settled = true; break; }
        if (i >= HOLD_TIMEOUT) break;
        pause();
        result.waited_s++;
    }
    return result;
}

// Idempotent teardown of everything a probe run can leave behind. Safe for:
// table+process, table only, process only, nothing, stale pidfile, PID reuse.
// report (optional) receives the drain/hold evidence of a live run.
function teardown(active, actions, report) {
    let ok = true, stopped = false;
    let state = table_state(TABLE);
    let table_present = state != "absent";
    let ip = type(active) == "object" && probe_module.valid_ipv4(active.ip) ? active.ip : null;
    if (ip == null && state == "present") ip = table_target();
    let saved = identity.read_record(PIDFILE);
    if (report != null && ip != null && state == "present")
        report.drain = drain(ip, saved != null);
    if (report != null && state == "present") report.counters_at_stop = probe_counters();
    if (table_present && ip != null) {
        let released = release_probe_rule(ip);
        push(actions, "probe_rule:" + released);
        if (released == "failed") ok = false;
    }
    if (saved != null) {
        let argv = type(active) == "object" && type(active.argv) == "array" ? active.argv : null;
        let outcome = argv ? stop_identified(saved, argv, true) : "not_ours";
        if (outcome == "failed") ok = false;
        else if (outcome != "not_ours") stopped = true;
        push(actions, "pidfile:" + (outcome == "not_ours" ? "stale" : outcome));
    }
    for (let orphan in orphans()) {
        let outcome = stop_identified(orphan, signature_prefix(), false);
        if (outcome == "failed") ok = false;
        else if (outcome != "not_ours") stopped = true;
        push(actions, "orphan:" + outcome);
    }
    if (stopped) {
        // The kernel releases the queue binding as the process exits.
        for (let i = 0; i < 3 && queue_entry(QUEUE) != null; i++) pause();
        mark("T6", "temporary nfqws stopped", report ? report.drain : null);
    }
    let held = null;
    if (table_present) {
        if (ip != null) {
            held = hold(ip);
            if (report != null) report.hold = held;
            push(actions, "hold:" + (held.settled ? "settled" : "timeout"));
        }
        else push(actions, "hold:target_unknown");
        if (ip == null || !held.settled) {
            // Removing the table now could hand late packets of live probe
            // sockets to production: keep it (released + drop) and the
            // recovery data; a later cleanup repeats the hold.
            push(actions, "table:kept");
            ok = false;
        }
        else {
            let quiet = production_queues_quiet();
            if (report != null) {
                report.quiet_before_removal = quiet;
                report.counters_at_removal = probe_counters();
            }
            if (success([ "nft", "delete", "table", "inet", TABLE ]) && table_state(TABLE) == "absent")
                push(actions, "table:removed");
            else { push(actions, "table:remove_failed"); ok = false; }
            mark("T7", "temporary table removed", held);
        }
    }
    // Recovery data is kept until the table and the process are verifiably gone.
    if (ok && table_state(TABLE) == "absent" && length(orphans()) == 0) {
        fs.unlink(PIDFILE);
        for (let name in fs.lsdir(WORKDIR) || []) fs.unlink(WORKDIR + "/" + name);
        fs.rmdir(WORKDIR);
        fs.unlink(ACTIVE);
    }
    return ok;
}

function verify_clean() {
    let result = {
        table_absent: table_state(TABLE) == "absent",
        queue_absent: queue_entry(QUEUE) == null,
        process_absent: length(orphans()) == 0,
        state_removed: fs.stat(ACTIVE) == null && fs.stat(PIDFILE) == null && fs.stat(WORKDIR) == null
    };
    result.clean = result.table_absent && result.queue_absent && result.process_absent && result.state_removed;
    return result;
}

function cleanup() {
    let actions = [];
    let ok = teardown(read_active(), actions);
    let verified = verify_clean();
    return { status: ok && verified.clean ? "clean" : "failed", actions, verified };
}

// ---- probe run ---------------------------------------------------------

function start_nfqws(argv, log) {
    let pipe = fs.popen(command(argv) + " >" + quote(log) + " 2>&1 </dev/null & echo $!", "r");
    if (!pipe) return "";
    let pid = trim(as_string(pipe.read("all")));
    pipe.close();
    return match(pid, /^[1-9][0-9]*$/) != null ? pid : "";
}

function summary(probes) {
    let ok = 0, tls = [];
    for (let p in probes) if (p.class == "success") { ok++; push(tls, p.time_appconnect_ms); }
    tls = sort(tls, (a, b) => a - b);
    return { attempts: length(probes), successes: ok,
        success_rate: length(probes) > 0 ? (ok * 1.0) / length(probes) : 0,
        median_tls_ms: length(tls) > 0 ? tls[int(length(tls) / 2)] : null };
}

function unavailable(result, detail) {
    result.status = "unsupported";
    result.reason = "isolation_unavailable";
    result.isolation.unavailable = detail;
    return result;
}

function run(candidate_id, host, count, resolver, ip) {
    let result = { status: "failed", reason: null, candidate: null, target: null,
        isolation: { table: TABLE, chains: [ MARK_CHAIN + "@" + MARK_PRIORITY, CHAIN + "@" + PRIORITY ], queue: QUEUE,
            port_range: PORT_RANGE, probe_mark: PROBE_MARK, desync_mark: DESYNC_MARK },
        contract: null, timeline, probes: [], summary: null, counters: null, teardown: null,
        production: null, cleanup: null };
    count = int(count || 3);
    if (count < 1 || count > MAX_PROBES) { result.status = "refused"; result.reason = "invalid_count"; return result; }

    let entry = catalog.find(candidate_id);
    if (entry == null) { result.status = "refused"; result.reason = "unknown_candidate"; return result; }
    let checked = catalog.validate_entry(entry);
    result.candidate = { id: checked.id, rank: checked.rank, nfqws_opt: checked.nfqws_opt,
        state: checked.state, reason: checked.reason };
    if (checked.state != "supported") { result.status = "unsupported"; result.reason = checked.reason; return result; }

    // Leftovers of an interrupted run are ours by name and signature.
    let recovered = [];
    if (!teardown(read_active(), recovered)) {
        result.status = "refused"; result.reason = "stale_probe_state";
        result.cleanup = { actions: recovered, verified: verify_clean() };
        return result;
    }
    if (length(recovered) > 0) result.recovered = recovered;
    timeline = []; result.timeline = timeline;

    let refusal = null;
    if (length(guards_present()) > 0) refusal = "guard_active";
    else if (fs.stat(SNAPSHOT_LOCK) != null) refusal = "snapshot_operation_in_progress";
    else refusal = queue_check() || port_check();
    if (refusal) { result.status = "refused"; result.reason = refusal; return result; }

    let target = { host, port: 443, resolver: resolver || null, addresses: null, ip: null, route: null };
    result.target = target;
    if (ip) {
        if (!probe_module.valid_host(host) || !probe_module.public_ipv4(ip)) {
            result.status = "refused"; result.reason = "invalid_target"; return result;
        }
        target.addresses = [ ip ];
    }
    else {
        let resolved = probe_module.resolve(host, resolver);
        target.addresses = resolved.addresses;
        if (resolved.status != "ok") {
            result.status = "completed"; result.reason = "dns_failure";
            push(result.probes, { host, class: "dns_failure", detail: resolved.reason });
            result.summary = summary(result.probes);
            return result;
        }
    }
    target.ip = target.addresses[0];
    target.route = probe_route(target.ip);
    if (!target.route.ok) return unavailable(result, target.route.reason);

    // The production bypass for the probe mark, the policy routing and the
    // reply path must be proven from the live system; there is no fallback to
    // the current rule order.
    result.contract = bypass_contract(target.route, target.ip);
    if (!result.contract.ok) return unavailable(result, "bypass_contract");

    // The table the run is compared against must itself satisfy the contract.
    let snapshot = production_snapshot(target.ip);
    let before = snapshot.state;
    let snapshot_contract = contract.evaluate(snapshot.table, null,
        { probe_mark: PROBE_MARK, own_table: TABLE, own_priority: PRIORITY, prod_table: PROD_TABLE,
          reply_dev: target.route.dev, sets: result.contract.sets || null });
    if (!snapshot_contract.ok) {
        result.contract = snapshot_contract;
        return unavailable(result, "bypass_contract_changed");
    }
    mark("T0", "pre-state recorded");
    let queue_candidate = checked.nfqws_opt != "";
    let debug_file = NFQWS_DEBUG && queue_candidate ? WORKDIR + "/nfqws.debug" : null;
    let argv = queue_candidate ? nfqws_argv(checked.nfqws_opt, debug_file) : null;
    let body = function() {
        // The run is announced before anything is created so an interrupted
        // run can always be torn down.
        if (!fs.mkdir(WORKDIR, 0755) ||
            fs.writefile(ACTIVE, sprintf("%J\n", { table: TABLE, queue: QUEUE, argv, pidfile: PIDFILE, ip: target.ip })) == null)
            return "state_write_failed";
        if (debug_file) { fs.writefile(debug_file, ""); fs.chmod(debug_file, 0666); }
        let batch_file = WORKDIR + "/probe.nft";
        if (fs.writefile(batch_file, batch(target.ip, queue_candidate)) == null) return "state_write_failed";
        result.teardown = { quiet_before_creation: production_queues_quiet() };
        // Registering hooks while production packets sit in an NFQUEUE could
        // make them resume at a shifted hook index.
        if (!result.teardown.quiet_before_creation.quiet) return "production_queue_busy";
        if (!success([ "nft", "-f", batch_file ])) return "nft_setup_failed";
        result.isolation.rules = probe_rule_handles();
        mark("T1", "temporary nft table created");
        if (interrupted) return "interrupted";
        if (queue_candidate) {
            let pid = start_nfqws(argv, WORKDIR + "/nfqws.log");
            if (pid == "" || !identity.record(PIDFILE, pid)) return "nfqws_start_failed";
            let listener = null;
            for (let i = 0; i <= LISTENER_WAIT && listener == null; i++) {
                if (identity.matches(PIDFILE, NFQWS, argv, true, true) == "") return "nfqws_start_failed";
                listener = queue_entry(QUEUE);
                if (listener == null) pause();
            }
            if (listener == null) return "nfqws_listener_missing";
            mark("T2", "temporary nfqws started", { pid: int(pid), queue_portid: listener.portid });
        }
        if (interrupted) return "interrupted";
        let queue_before = queue_entry(QUEUE);
        mark("T3", "probe begins");
        for (let i = 0; i < count; i++) {
            if (interrupted) return "interrupted";
            push(result.probes, probe_module.probe({ host, ip: target.ip, port_range: PORT_RANGE }));
        }
        let queue_after = queue_entry(QUEUE);
        result.counters = probe_counters();
        if (result.counters == null) return "counters_unavailable";
        if (queue_candidate) {
            result.counters.queue = {
                id_sequence_before: queue_before ? queue_before.id_sequence : null,
                id_sequence_after: queue_after ? queue_after.id_sequence : null,
                packets_queued: queue_before && queue_after ? queue_after.id_sequence - queue_before.id_sequence : null,
                dropped: queue_after ? queue_after.dropped : null,
                user_dropped: queue_after ? queue_after.user_dropped : null
            };
            mark("T4", "queue " + QUEUE + " received probe", { packets_queued: result.counters.queue.packets_queued });
            if (identity.matches(PIDFILE, NFQWS, argv, true, true) == "") return "nfqws_died";
            // nfqws queues are fail-open: a packet the queue could not take is
            // accepted untransformed without a drop counter. Every packet the
            // probe rule matched must have entered the queue.
            let queued = result.counters.queue.packets_queued;
            if (queued == null || queued < result.counters.probe.packets) return "candidate_bypassed";
        }
        mark("T5", "probe result", summary(result.probes));
        if (debug_file) {
            let lines = split(trim(as_string(fs.readfile(debug_file))), "\n");
            result.nfqws_debug = slice(lines, length(lines) > 80 ? length(lines) - 80 : 0);
        }
        return null;
    };
    let failure = null;
    try { failure = body(); }
    catch (e) { failure = "exception: " + as_string(e.message); }

    let actions = [], report = result.teardown || {};
    let torn_down = teardown(read_active() || { argv, ip: target.ip }, actions, report);
    result.teardown = report;
    let verified = verify_clean();
    let after = production_state(target.ip);
    let unchanged = same_state(before, after);
    result.cleanup = { status: torn_down && verified.clean ? "clean" : "failed", actions, verified };
    result.production = { before, after, unchanged };
    result.summary = summary(result.probes);
    if (verified.clean) mark("T8", "cleanliness verified", { production_unchanged: unchanged });

    // Every packet of the probe tuple must have taken a modelled path.
    let final_counters = report.counters_at_removal;
    let hold_settled = report.hold == null || report.hold.settled;
    if (failure == null && interrupted) failure = "interrupted";
    if (failure == null && !hold_settled) failure = "isolation_hold_timeout";
    if (failure != null) { result.status = failure == "interrupted" ? "interrupted" : "failed"; result.reason = failure; }
    else if (!torn_down || !verified.clean) { result.status = "failed"; result.reason = "cleanup_unverified"; }
    else if (!unchanged) { result.status = "failed"; result.reason = "production_changed"; }
    else if (final_counters == null) { result.status = "failed"; result.reason = "counters_unavailable"; }
    else if (final_counters.unexpected.packets > 0) { result.status = "failed"; result.reason = "unexpected_probe_packets"; }
    else {
        result.status = "completed";
        if (report.quiet_before_removal != null && !report.quiet_before_removal.quiet) result.warning = "production_queue_busy_at_removal";
    }
    return result;
}

// ---- entry -------------------------------------------------------------

if (type(signal) == "function")
    for (let name in [ "SIGINT", "SIGTERM", "SIGHUP" ])
        signal(name, function() { interrupted = true; });

let mode = ARGV[0] || "";
let output = null, code = 1;
if (mode == "model") {
    // The temporary chains for a target, as evaluated by the regression tests.
    let queue_candidate = ARGV[2] != "direct";
    print(sprintf("%J\n", { probe_mark: PROBE_MARK_VALUE, desync_mark: DESYNC_MARK_VALUE, queue: QUEUE,
        chains: probe_chains(ARGV[1], queue_candidate), batch: batch(ARGV[1], queue_candidate) }));
    exit(0);
}
if (queue_reserved()) {
    // Never scan for, signal or queue to a production queue number.
    print(sprintf("%J\n", { status: "refused", reason: "queue_overlaps_forkop_range", queue: QUEUE }));
    exit(1);
}
if (mode == "run" || mode == "cleanup") {
    if (!acquire())
        output = lock_busy ? { status: "busy", reason: "autotune_in_progress" } : { status: "failed", reason: "lock_unavailable" };
    else {
        output = mode == "run" ? run(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]) : cleanup();
        release();
        code = output.status == "completed" || output.status == "clean" ? 0 : 1;
    }
}
else if (mode == "status") {
    output = { active: fs.stat(ACTIVE) != null, table: table_state(TABLE), queue: queue_entry(QUEUE),
        orphans: length(orphans()), production: production_state() };
    code = 0;
}
else {
    warn("Usage: autotune/isolation.uc <run <candidate> <host> [count] [resolver] [ip]|cleanup|status|model <ip> [direct]>\n");
    exit(1);
}
print(sprintf("%J\n", output));
exit(code);
