#!/usr/bin/env ucode

// VPN kill-switch for Forkop connection sections.
//
// When a protected section's traffic cannot go through Forkop (sing-box or
// Forkop stopped, crashed or not started yet), it must fail instead of
// leaving through WAN. The protection is deliberately independent of the
// Forkop runtime:
//
//  * nftables: a separate table rendered from the live ForkopTable, installed
//    live and saved under STATE_DIR. fw4 loads the saved policy on every
//    firewall start/reload through the loader the forkop package installs
//    in ruleset-post, so it survives a Forkop stop, a firewall
//    reload/restart and a reboot, but never the package: without the loader
//    (package removal, a downgrade to a release without the kill-switch, a
//    sysupgrade to an image without Forkop) the saved policy is inert
//    (UC-191). It rejects forwarded client traffic that matches a protected
//    section in Forkop's own first-match order, plus any FakeIP destination.
//  * DNS: protected domains are answered locally (NXDOMAIN) by dnsmasq
//    whenever dnsmasq does not forward to sing-box; dns/apply.uc switches the
//    servers file on every configure/restore.
//
// Only a successful Forkop start/reload refreshes the policy. A failed one,
// a stop or a missing runtime keep the last applied protection. Removing it
// takes an explicit "disable" or unchecking the option on every section.

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let connections = require("config.connections");
let singbox_constants = require("singbox.constants");
let constants = require("core.constants");
let runtime_lock = require("core.runtime_lock");

let as_string = common.as_string;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;
let option = common.option;
let bool_option = common.bool_option;

function constant_value(name, fallback) {
    let value = constants[name];
    return value == null ? as_string(fallback) : as_string(value);
}

const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || constant_value("FORKOP_CONFIG_NAME", "forkop");
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const LIVE_TABLE = constant_value("NFT_TABLE_NAME", "ForkopTable");
const KS_TABLE = constant_value("KILLSWITCH_NFT_TABLE", "ForkopKillswitch");
const STATE_DIR = constant_value("KILLSWITCH_STATE_DIR", "/etc/forkop/killswitch");
const NFT_POLICY = constant_value("KILLSWITCH_NFT_POLICY", STATE_DIR + "/policy.nft");
const NFT_LOADER = constant_value("KILLSWITCH_NFT_LOADER", "/usr/share/nftables.d/ruleset-post/90-forkop-killswitch-loader.nft");
// The first kill-switch build saved the policy as an unguarded fw4 include
// that outlived the package; it is only ever removed (or adopted once).
const LEGACY_NFT_INCLUDE = constant_value("KILLSWITCH_NFT_INCLUDE", "/usr/share/nftables.d/ruleset-post/90-forkop-killswitch.nft");
const CACHE_DIR = constant_value("KILLSWITCH_CACHE_DIR", "/tmp/forkop-killswitch");
const FAKEIP_RANGE = constant_value("SB_FAKEIP_INET4_RANGE", "198.18.0.0/15");
const FAKEIP6_RANGE = constant_value("SB_FAKEIP_INET6_RANGE", "fc00::/18");
const DNS_BLOCKED_FILE = STATE_DIR + "/dns-blocked.servers";
// dnsmasq reads it (dns/apply.uc keeps it empty while it forwards to sing-box).
const DNS_SERVERS_FILE = STATE_DIR + "/dnsmasq.servers";
const DNSMASQ_INIT = getenv("DNSMASQ_INIT") || "/etc/init.d/dnsmasq";
// The package file this process runs from.
const OWNER_FILE = sourcepath() || LIB_DIR + "/killswitch/runtime.uc";
const STATE_FILE = STATE_DIR + "/state.json";
// The time and reason of the last sync and the time of the last error
// change on every sync; they live in RAM so that state.json on flash
// changes only with the protection (UC-212).
const STATE_TIMES_FILE = RUNTIME_STATE_DIR + "/killswitch-state.json";
const STATE_TIMES = [ "updated_at", "reason", "last_error_at" ];
const LOCK_DIR = RUNTIME_STATE_DIR + "/killswitch.lock";
const NFT_UC = LIB_DIR + "/nft/apply.uc";
const DNS_UC = LIB_DIR + "/dns/apply.uc";
const SING_BOX_BIN = getenv("FORKOP_SING_BOX_BIN") || "sing-box";
const KILLSWITCH_INIT = getenv("FORKOP_KILLSWITCH_INIT") || "/etc/init.d/forkop-killswitch";
const STANDBY_PORT = constant_value("KILLSWITCH_STANDBY_PORT", "18054");
const SB_DNS_ADDRESS = constant_value("SB_DNS_INBOUND_ADDRESS", "127.0.0.42");
const SB_PROBE_DOMAIN = constant_value("FAKEIP_TEST_DOMAIN", "fakeip.podkop.fyi");
const DNS_CHAIN = "ks_dns";
const RELOAD_LOCK_DIR = getenv("FORKOP_RELOAD_LOCK_DIR") || "/var/run/forkop.reload.lock";
const PENDING_RELOAD_FILE = getenv("FORKOP_PENDING_RELOAD_FILE") || RUNTIME_STATE_DIR + "/reload.pending";
const SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || "/etc/init.d/forkop";
const STATE_UC = LIB_DIR + "/service/state.uc";
// Attempts, 500 ms apart, to take a held lock; tests bound it.
const LOCK_ATTEMPTS = int(getenv("FORKOP_KILLSWITCH_LOCK_ATTEMPTS") || "120");
const INTERFACE_SET = "ks_interfaces";
const STATE_FORMAT = 1;
// Test-only bounds for the watcher loop; production runs it forever.
const WATCH_ITERATIONS = int(getenv("FORKOP_KILLSWITCH_WATCH_ITERATIONS") || "0");
const WATCH_INTERVAL_MS = int(getenv("FORKOP_KILLSWITCH_WATCH_INTERVAL_MS") || "2000");

// Route-rule keys that do not narrow a rule below "every client, every port".
// Only such rules may carve an exception out of a protected domain.
const UNRESTRICTED_RULE_KEYS = {
    action: true, outbound: true, inbound: true, domain: true, domain_suffix: true,
    domain_keyword: true, domain_regex: true, rule_set: true, ip_cidr: true
};

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function run_quiet(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function capture(args) {
    let pipe = fs.popen(command_from_args(args) + " 2>/dev/null", "r");
    if (!pipe)
        return { status: 1, output: "" };
    let data = pipe.read("all");
    let status = pipe.close();
    return { status: status == null ? 1 : status, output: as_string(data) };
}

function log_message(message, level) {
    run_quiet([ "logger", "-t", "forkop", "[" + as_string(level || "info") + "] " + as_string(message) ]);
}

function module_args(module_path, args) {
    let result = [ "ucode", "-L", LIB_DIR, module_path ];
    for (let arg in args)
        push(result, as_string(arg));
    return result;
}

function ensure_dir(path) {
    return run_quiet([ "mkdir", "-p", path ]);
}

function dirname(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash > 0 ? substr(path, 0, slash) : "/";
}

let cached_self_pid = null;

function self_pid() {
    // popen's own shell is a direct child of this ucode process.
    if (cached_self_pid == null) {
        let pipe = fs.popen("echo $PPID", "r");
        let pid = pipe ? trim(as_string(pipe.read("all"))) : "";
        if (pipe)
            pipe.close();
        cached_self_pid = match(pid, /^[0-9]+$/) != null ? pid : "0";
    }
    return cached_self_pid;
}

// What the kill-switch keeps on flash (the saved policy, the block list,
// state.json) is flushed before the rename makes it the file and again
// after it, so a power cut leaves the old or the new file, never an empty
// one (UC-212). Callers write only what changed.
function write_durable(path, content) {
    if (!ensure_dir(dirname(path)))
        return false;
    let tmp = path + ".tmp." + self_pid();
    if (fs.writefile(tmp, as_string(content)) == null || !run_quiet([ "sync" ]) || !fs.rename(tmp, path)) {
        fs.unlink(tmp);
        return false;
    }
    run_quiet([ "sync" ]);
    return true;
}

function write_atomic(path, content) {
    if (!ensure_dir(dirname(path)))
        return false;
    // Unique per writer: a second writer must never rename a file this one
    // is still writing.
    let tmp = path + ".tmp." + self_pid();
    if (fs.writefile(tmp, as_string(content)) == null)
        return false;
    if (!fs.rename(tmp, path)) {
        fs.unlink(tmp);
        return false;
    }
    return true;
}

function now() {
    return time();
}

// ---------------------------------------------------------------- config

function config_sections() {
    return uci_core.section_objects(CONFIG_NAME, "section");
}

function config_settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function section_protected(section) {
    section = object_or_empty(section);
    return bool_option(section, "enabled", true) &&
        connections.is_connections_action(option(section, "action", "")) &&
        bool_option(section, "kill_switch", false);
}

function protected_section_names(sections) {
    let result = [];
    for (let section in sections)
        if (section_protected(section))
            push(result, as_string(section[".name"]));
    return result;
}

// ------------------------------------------------------------------- lock
//
// killswitch.lock and reload.lock follow core/runtime_lock.uc: the owner is
// this process, named by its pid and start time, so a dead owner or a reused
// pid never holds them (UC-210). Global order (service/state.uc): reload.lock
// before killswitch.lock.

let lock_attempts = LOCK_ATTEMPTS;

function acquire_dir_lock(lock_dir) {
    ensure_dir(dirname(lock_dir));
    for (let attempt = 0; attempt < lock_attempts; attempt++) {
        if (runtime_lock.acquire(lock_dir, self_pid()))
            return true;
        if (attempt + 1 < lock_attempts)
            sleep(500);
    }
    return false;
}

// init.d queues every reload that found reload.lock held; its last holder
// applies them once it lets the lock go (service/lifecycle.uc, UC-061).
function release_reload_lock(apply_pending) {
    runtime_lock.release(RELOAD_LOCK_DIR, self_pid());
    if (apply_pending && fs.stat(PENDING_RELOAD_FILE) != null)
        run_quiet(module_args(STATE_UC, [ "run-pending-reload-if-requested", PENDING_RELOAD_FILE, SERVICE_INIT ]));
}

// ------------------------------------------------------------------ state

function read_state() {
    let state = object_or_empty(common.read_json_file(STATE_FILE));
    let times = object_or_empty(common.read_json_file(STATE_TIMES_FILE));
    for (let key in STATE_TIMES)
        if (times[key] != null)
            state[key] = times[key];
    return state;
}

// Key order does not matter; the times are not compared.
function state_content(value, top) {
    if (type(value) == "array")
        return "[" + join(",", map(value, (item) => state_content(item, false))) + "]";
    if (type(value) != "object")
        return sprintf("%J", value);
    let parts = [];
    for (let key in sort(keys(value)))
        if (!top || index(STATE_TIMES, key) < 0)
            push(parts, sprintf("%J", key) + ":" + state_content(value[key], false));
    return "{" + join(",", parts) + "}";
}

function write_state(state) {
    state.format = STATE_FORMAT;
    let times = {};
    for (let key in STATE_TIMES)
        times[key] = state[key];
    write_atomic(STATE_TIMES_FILE, sprintf("%J", times) + "\n");
    let saved = common.read_json_file(STATE_FILE);
    if (type(saved) == "object" && state_content(saved, true) == state_content(state, true))
        return true;
    return write_durable(STATE_FILE, sprintf("%.2J", state) + "\n");
}

function record_error(message) {
    let state = read_state();
    state.last_error = as_string(message);
    state.last_error_at = now();
    write_state(state);
    log_message("Kill-switch: " + as_string(message), "error");
}

// -------------------------------------------------------------------- nft

function live_table_present() {
    return run_quiet([ "nft", "list", "table", "inet", LIVE_TABLE ]);
}

function ks_table_present() {
    return run_quiet([ "nft", "list", "table", "inet", KS_TABLE ]);
}

function remove_legacy_include() {
    return fs.stat(LEGACY_NFT_INCLUDE) == null || fs.unlink(LEGACY_NFT_INCLUDE);
}

// Saved and loaded at boot (fw4 through the package's loader).
function policy_saved() {
    let stat = fs.stat(NFT_POLICY);
    return stat != null && stat.size > 0;
}

function apply_nft_policy() {
    let tmp = trim(capture([ "mktemp" ]).output);
    if (tmp == "")
        return { ok: false, error: "mktemp failed" };

    let rendered = capture(module_args(NFT_UC, [ "killswitch-render", LIVE_TABLE, KS_TABLE, tmp, FAKEIP_RANGE, FAKEIP6_RANGE ]));
    let summary = null;
    try {
        summary = json(trim(rendered.output));
    }
    catch (e) {
        summary = null;
    }
    summary = object_or_empty(summary);
    if (rendered.status != 0 || summary.ok !== true) {
        fs.unlink(tmp);
        return { ok: false, error: "nft render failed: " + (as_string(summary.error) || "unknown error") };
    }

    // A broken saved policy would take the whole firewall down on the next
    // fw4 reload, so the exact bytes that get saved are checked and applied
    // live first.
    if (!run_quiet([ "nft", "-c", "-f", tmp ])) {
        fs.unlink(tmp);
        return { ok: false, error: "rendered kill-switch policy failed nft validation" };
    }
    if (!run_quiet([ "nft", "-f", tmp ])) {
        fs.unlink(tmp);
        return { ok: false, error: "kill-switch policy could not be applied" };
    }

    let content = fs.readfile(tmp);
    fs.unlink(tmp);
    if (content == null || (fs.readfile(NFT_POLICY) != content && !write_durable(NFT_POLICY, content)))
        return { ok: false, error: "could not save " + NFT_POLICY + "; the live policy is active until the next firewall reload" };
    remove_legacy_include();

    summary.ok = true;
    return summary;
}

// The retired global guard (ForkopVpnGuard) is left in place by the package
// upgrade until this kill-switch protects the same traffic.
const LEGACY_GUARD_TABLE = "ForkopVpnGuard";

function remove_legacy_guard_table() {
    if (run_quiet([ "nft", "list", "table", "inet", LEGACY_GUARD_TABLE ]))
        run_quiet([ "nft", "delete", "table", "inet", LEGACY_GUARD_TABLE ]);
}

function remove_nft_policy() {
    let ok = true;
    if (fs.stat(NFT_POLICY) != null && !fs.unlink(NFT_POLICY))
        ok = false;
    if (!remove_legacy_include())
        ok = false;
    if (ks_table_present() && !run_quiet([ "nft", "delete", "table", "inet", KS_TABLE ]))
        ok = false;
    return ok;
}

function nft_counters() {
    let result = {};
    let listed = capture([ "nft", "-j", "list", "counters", "table", "inet", KS_TABLE ]);
    if (listed.status != 0)
        return result;
    let data = null;
    try {
        data = json(listed.output);
    }
    catch (e) {
        return result;
    }
    for (let item in array_or_empty(object_or_empty(data).nftables)) {
        let counter = object_or_empty(object_or_empty(item).counter);
        let name = as_string(counter.name);
        if (name == "" || substr(name, 0, 3) != "ks_")
            continue;
        result[substr(name, 3)] = { packets: int(counter.packets), bytes: int(counter.bytes) };
    }
    return result;
}

// -------------------------------------------------------------------- DNS

function array_of(value) {
    if (type(value) == "array")
        return value;
    return value == null ? [] : [ value ];
}

function normalize_domain(value) {
    value = lc(trim(as_string(value)));
    while (substr(value, 0, 1) == ".")
        value = substr(value, 1);
    while (length(value) > 0 && substr(value, -1) == ".")
        value = substr(value, 0, length(value) - 1);
    if (value == "" || length(value) > 253 ||
        match(value, /^[a-z0-9_-]+(\.[a-z0-9_-]+)*$/) == null)
        return null;
    return value;
}

function parent_domain(value) {
    let dot = index(value, ".");
    return dot < 0 ? null : substr(value, dot + 1);
}

function new_matchers() {
    return { suffix: [], exact: [], keyword: 0, regex: 0, inverted: 0, error: "" };
}

function merge_matchers(target, source) {
    for (let value in source.suffix)
        push(target.suffix, value);
    for (let value in source.exact)
        push(target.exact, value);
    target.keyword += source.keyword;
    target.regex += source.regex;
    target.inverted += source.inverted;
    if (source.error != "" && target.error == "")
        target.error = source.error;
}

function collect_rule_matchers(rule, acc) {
    rule = object_or_empty(rule);
    if (as_string(rule.type) == "logical") {
        for (let child in array_or_empty(rule.rules))
            collect_rule_matchers(child, acc);
        return;
    }
    let has_domains = rule.domain != null || rule.domain_suffix != null ||
        rule.domain_keyword != null || rule.domain_regex != null;
    if (rule.invert === true) {
        if (has_domains)
            acc.inverted++;
        return;
    }
    for (let value in array_of(rule.domain_suffix))
        push(acc.suffix, value);
    for (let value in array_of(rule.domain))
        push(acc.exact, value);
    acc.keyword += length(array_of(rule.domain_keyword));
    acc.regex += length(array_of(rule.domain_regex));
}

function file_md5(path) {
    let output = trim(capture([ "md5sum", path ]).output);
    let found = match(output, /^([0-9a-f]{32})/);
    return found == null ? "" : found[1];
}

function binary_ruleset(definition) {
    let format = as_string(definition.format);
    if (format != "")
        return format == "binary";
    return match(as_string(definition.path), /\.srs$/) != null;
}

let ruleset_cache_used = {};

function local_ruleset_matchers(definition) {
    let path = as_string(definition.path);
    let acc = new_matchers();
    if (path == "" || fs.stat(path) == null) {
        acc.error = "rule-set file " + path + " is missing";
        return acc;
    }
    // singbox/ruleset_cache.uc stands in an empty "empty-<hash>.json" for a
    // list that has not been downloaded yet; its real content is unknown.
    if (match(path, /(^|\/)empty-[0-9a-f]+\.json$/) != null) {
        acc.error = "rule-set " + as_string(definition.tag) + " is not downloaded yet";
        return acc;
    }

    if (!binary_ruleset(definition)) {
        let data = common.read_json_file(path);
        if (type(data) != "object") {
            acc.error = "rule-set file " + path + " is not valid JSON";
            return acc;
        }
        for (let rule in array_or_empty(data.rules))
            collect_rule_matchers(rule, acc);
        return acc;
    }

    // Decompiling a large binary list is the expensive step; cache the
    // extracted matchers by content.
    let md5 = file_md5(path);
    let cache_path = md5 != "" ? CACHE_DIR + "/" + md5 + ".json" : "";
    if (cache_path != "") {
        ruleset_cache_used[md5 + ".json"] = true;
        let cached = common.read_json_file(cache_path);
        if (type(cached) == "object" && type(cached.suffix) == "array" && type(cached.exact) == "array") {
            cached.error = "";
            return cached;
        }
    }

    ensure_dir(CACHE_DIR);
    let source = CACHE_DIR + "/decompile-" + self_pid() + ".json";
    if (!run_quiet([ SING_BOX_BIN, "rule-set", "decompile", path, "-o", source ])) {
        fs.unlink(source);
        acc.error = "could not decompile rule-set " + path;
        return acc;
    }
    let data = common.read_json_file(source);
    fs.unlink(source);
    if (type(data) != "object") {
        acc.error = "decompiled rule-set " + path + " is not valid JSON";
        return acc;
    }
    for (let rule in array_or_empty(data.rules))
        collect_rule_matchers(rule, acc);
    if (cache_path != "")
        write_atomic(cache_path, sprintf("%J", {
            suffix: acc.suffix, exact: acc.exact, keyword: acc.keyword,
            regex: acc.regex, inverted: acc.inverted
        }));
    return acc;
}

function ruleset_matchers(definitions, tag, memo) {
    if (memo[tag] != null)
        return memo[tag];
    let definition = definitions[tag];
    let acc = new_matchers();
    if (definition == null)
        acc.error = "rule-set " + tag + " is not defined";
    else if (as_string(definition.type) == "inline") {
        for (let rule in array_or_empty(definition.rules))
            collect_rule_matchers(rule, acc);
    }
    else if (as_string(definition.type) == "local")
        acc = local_ruleset_matchers(definition);
    else
        acc.error = "rule-set " + tag + " is not available locally";
    memo[tag] = acc;
    return acc;
}

function route_rule_matchers(rule, definitions, memo) {
    let acc = new_matchers();
    collect_rule_matchers(rule, acc);
    for (let tag in array_of(rule.rule_set))
        merge_matchers(acc, ruleset_matchers(definitions, as_string(tag), memo));
    return acc;
}

function rule_unrestricted(rule) {
    if (rule.invert === true)
        return false;
    for (let key in keys(rule))
        if (!UNRESTRICTED_RULE_KEYS[key])
            return false;
    return true;
}

// Walks sing-box route rules in their first-match order. A protected rule
// blocks its domains (exact names are blocked with their subdomains: dnsmasq
// has no exact-only form, and over-blocking is the fail-closed side). An
// earlier unrestricted non-protected suffix keeps its own resolution: it
// shadows protected names under it and becomes a "#" exception when it sits
// below a protected name. Restricted earlier rules (by client, port, ...)
// never weaken the block.
function render_dns_from_config(config, protected_names) {
    let result = {
        ok: false, error: "", content: "", domains: 0, exceptions: 0, shadowed: 0,
        invalid: 0, uncovered_keyword: 0, uncovered_regex: 0, uncovered_inverted: 0,
        client_limited: 0, sections: {}
    };
    config = object_or_empty(config);
    let route = object_or_empty(config.route);
    let rules = route.rules;
    if (type(rules) != "array") {
        result.error = "sing-box config has no route rules";
        return result;
    }

    let protected_tags = {};
    for (let name in protected_names) {
        protected_tags[singbox_constants.outbound_tag(name)] = name;
        result.sections[name] = { domains: 0, uncovered: 0, client_limited: 0 };
    }

    let definitions = {};
    for (let definition in array_or_empty(route.rule_set))
        if (type(definition) == "object" && as_string(definition.tag) != "")
            definitions[as_string(definition.tag)] = definition;

    // Rules after the last protected one can neither block nor shadow a
    // protected name; skip them, together with their (often huge) lists.
    let last_protected = -1;
    for (let i = 0; i < length(rules); i++)
        if (protected_tags[as_string(object_or_empty(rules[i]).outbound)] != null)
            last_protected = i;

    let memo = {};
    let relevant = [];
    for (let i = 0; i <= last_protected; i++) {
        let rule = object_or_empty(rules[i]);
        let action = as_string(rule.action);
        if (action != "route" && action != "reject" && !(action == "" && rule.outbound != null))
            continue;
        let section = protected_tags[as_string(rule.outbound)];
        // A restricted unprotected rule never yields an exception.
        if (section == null && !rule_unrestricted(rule))
            continue;
        push(relevant, { index: i, rule, section });
    }

    // Pass 1: every protected name and the first rule that protects it.
    let first = {};
    let order = [];
    for (let item in relevant) {
        if (item.section == null)
            continue;
        let rule = item.rule;
        let acc = route_rule_matchers(rule, definitions, memo);
        if (acc.error != "") {
            result.error = acc.error;
            return result;
        }
        // dnsmasq answers every client alike. A rule limited to some clients
        // must not take its names away from everybody else; those clients
        // stay protected by nftables (subnets) and FakeIP rejects only.
        if (rule.source_ip_cidr != null || rule.source_port != null || rule.source_port_range != null) {
            let names = length(acc.suffix) + length(acc.exact);
            result.client_limited += names;
            result.sections[item.section].client_limited += names;
            continue;
        }
        result.uncovered_keyword += acc.keyword;
        result.uncovered_regex += acc.regex;
        result.uncovered_inverted += acc.inverted;
        result.sections[item.section].uncovered += acc.keyword + acc.regex + acc.inverted;
        for (let list in [ acc.suffix, acc.exact ]) {
            for (let value in list) {
                let domain = normalize_domain(value);
                if (domain == null) {
                    result.invalid++;
                    continue;
                }
                if (first[domain] == null) {
                    first[domain] = { index: item.index, section: item.section };
                    push(order, domain);
                }
            }
        }
    }

    // An unprotected suffix matters only when it equals or contains a
    // protected name (shadowing it) or lies below one (an exception).
    let covering = {};
    for (let domain in order)
        for (let candidate = domain; candidate != null; candidate = parent_domain(candidate))
            covering[candidate] = true;

    // Pass 2: the first unprotected rule of every relevant suffix. Unrelated
    // names, usually the bulk of large lists, are skipped by cheap lookups
    // before the full validation.
    let earlier = {};
    for (let item in relevant) {
        if (item.section != null)
            continue;
        let acc = route_rule_matchers(item.rule, definitions, memo);
        // An unreadable list in an unprotected rule only means fewer
        // exceptions, which is the fail-closed side.
        if (acc.error != "")
            continue;
        for (let value in acc.suffix) {
            let key = lc(as_string(value));
            if (substr(key, 0, 1) == ".")
                key = substr(key, 1);
            let related = covering[key] === true;
            for (let parent = parent_domain(key); !related && parent != null; parent = parent_domain(parent))
                related = first[parent] != null;
            if (!related)
                continue;
            let domain = normalize_domain(value);
            if (domain != null && (earlier[domain] == null || earlier[domain] > item.index))
                earlier[domain] = item.index;
        }
    }

    let blocked = {};
    let lines = [ "# Forkop VPN kill-switch: protected domains resolve only through Forkop." ];
    for (let domain in order) {
        let protected_at = first[domain].index;
        let shadowed = false;
        for (let candidate = domain; candidate != null && !shadowed; candidate = parent_domain(candidate))
            shadowed = earlier[candidate] != null && earlier[candidate] < protected_at;
        if (shadowed) {
            result.shadowed++;
            continue;
        }
        blocked[domain] = protected_at;
        result.sections[first[domain].section].domains++;
        result.domains++;
        push(lines, "server=/" + domain + "/");
    }

    for (let domain in sort(keys(earlier))) {
        for (let parent = parent_domain(domain); parent != null; parent = parent_domain(parent)) {
            if (blocked[parent] != null && earlier[domain] < blocked[parent]) {
                push(lines, "server=/" + domain + "/#");
                result.exceptions++;
                break;
            }
        }
    }

    result.ok = true;
    result.content = join("\n", lines) + "\n";
    return result;
}

function sing_box_config_path(settings) {
    return option(settings, "config_path", "/etc/sing-box/config.json");
}

function prune_ruleset_cache() {
    for (let name in array_or_empty(fs.lsdir(CACHE_DIR)))
        if (match(name, /^[0-9a-f]{32}\.json$/) != null && !ruleset_cache_used[name])
            fs.unlink(CACHE_DIR + "/" + name);
}

function dns_refresh() {
    return run_quiet(module_args(DNS_UC, [ "killswitch-refresh" ]));
}

function dns_status() {
    let listed = capture(module_args(DNS_UC, [ "killswitch-status" ]));
    try {
        return object_or_empty(json(trim(listed.output)));
    }
    catch (e) {
        return {};
    }
}

// ------------------------------------------------------- standby resolver
//
// While Forkop runs, dnsmasq forwards everything to sing-box. If sing-box
// dies, that would take all DNS down, not only the protected names. The
// watcher then redirects client DNS to a standby dnsmasq that answers the
// protected names locally and forwards the rest to the ordinary upstream,
// and hands DNS back as soon as sing-box answers again.

function fixture_uci() {
    return as_string(getenv("FORKOP_UCI_STATE_FILE") || "") != "";
}

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

// The watcher is long-lived and core.uci caches loaded packages, so live
// reads go through a fresh cursor every time.
function dnsmasq_option(name) {
    if (fixture_uci())
        return as_string(uci_core.get("dhcp.@dnsmasq[0]." + name));
    let value = null;
    try {
        let cursor = require("uci").cursor();
        cursor.foreach("dhcp", "dnsmasq", function(section) {
            value = section[name];
            return false;
        });
    }
    catch (e) {
        return "";
    }
    return type(value) == "array" ? join(" ", value) : as_string(value);
}

function dnsmasq_forwards_to_sing_box() {
    return index(words(dnsmasq_option("server")), SB_DNS_ADDRESS) >= 0;
}

function standby_config_text(settings) {
    let lines = [
        "# Forkop VPN kill-switch standby resolver. Generated; do not edit.",
        "no-hosts",
        "bind-dynamic",
        "port=" + STANDBY_PORT,
        "cache-size=1000",
        // Answers given during an outage must not outlive it for long:
        // afterwards these names have to resolve through Forkop again.
        "max-ttl=30",
        "max-cache-ttl=30"
    ];
    for (let name in words(option(settings, "source_network_interfaces", "br-lan")))
        if (match(name, /^[A-Za-z0-9_.@-]+$/) != null)
            push(lines, "interface=" + name);

    // The original upstream: Forkop keeps it in forkop_* backups while
    // dnsmasq forwards to sing-box.
    let forwarding = dnsmasq_forwards_to_sing_box();
    let servers = words(dnsmasq_option("forkop_server"));
    if (length(servers) == 0)
        servers = filter(words(dnsmasq_option("server")), (value) => value != SB_DNS_ADDRESS);
    let noresolv = dnsmasq_option("forkop_noresolv");
    if (noresolv == "" && !forwarding)
        noresolv = dnsmasq_option("noresolv");
    if (noresolv == "1")
        push(lines, "no-resolv");
    else
        push(lines, "resolv-file=" + (dnsmasq_option("resolvfile") || "/tmp/resolv.conf.d/resolv.conf.auto"));
    for (let server in servers)
        if (match(server, /^[^[:space:]#]+(#[0-9]+)?$/) != null)
            push(lines, "server=" + server);

    // Local names stay with the main dnsmasq, which serves them itself.
    let domain = dnsmasq_option("domain") || "lan";
    if (match(domain, /^[A-Za-z0-9_.-]+$/) != null)
        push(lines, "server=/" + domain + "/127.0.0.1");

    let blocked = fs.readfile(DNS_BLOCKED_FILE);
    return join("\n", lines) + "\n" + (blocked == null ? "" : blocked);
}

function write_standby_config(path) {
    let content = standby_config_text(config_settings());
    if (as_string(fs.readfile(path)) == content)
        return true;
    return write_atomic(path, content);
}

function sing_box_answers() {
    // Any reply counts, including NXDOMAIN: only a dead or hung resolver
    // fails. The FakeIP test name is answered by sing-box itself.
    return run_quiet([ "dig", "+time=1", "+tries=1", "@" + SB_DNS_ADDRESS, SB_PROBE_DOMAIN, "A" ]);
}

function dns_redirect_state() {
    let listed = capture([ "nft", "list", "chain", "inet", KS_TABLE, DNS_CHAIN ]);
    if (listed.status != 0)
        return null;
    return index(listed.output, "redirect") >= 0;
}

function set_dns_redirect(enabled) {
    let t = "inet " + KS_TABLE;
    let lines = [ "flush chain " + t + " " + DNS_CHAIN ];
    if (enabled) {
        for (let proto in [ "udp", "tcp" ])
            push(lines, "add rule " + t + " " + DNS_CHAIN + " iifname @" + INTERFACE_SET + " " + proto +
                " dport 53 counter redirect to :" + STANDBY_PORT);
    }
    let tmp = trim(capture([ "mktemp" ]).output);
    if (tmp == "")
        return false;
    let ok = fs.writefile(tmp, join("\n", lines) + "\n") != null && run_quiet([ "nft", "-f", tmp ]);
    fs.unlink(tmp);
    // Existing DNS flows keep their old NAT binding until they expire.
    if (ok) {
        run_quiet([ "conntrack", "-D", "-p", "udp", "--dport", "53" ]);
        run_quiet([ "conntrack", "-D", "-p", "tcp", "--dport", "53" ]);
    }
    return ok;
}

function dns_redirect(mode) {
    if (dns_redirect_state() == null)
        return 0;
    return set_dns_redirect(mode == "on") ? 0 : 1;
}

// ---------------------------------------------------------------- orphaned
//
// The package this watcher runs from was removed, or replaced by a release
// without the kill-switch, and nothing lifted the protection: its scripts did
// not run (a package manager or a manual change that skips them). Nothing
// would ever lift it then, so the watcher does, with what this process has
// already loaded and the system's own tools (UC-191).

function detach_dns_servers_file() {
    if (dnsmasq_option("serversfile") != DNS_SERVERS_FILE)
        return false;
    if (fixture_uci()) {
        uci_core.delete("dhcp.@dnsmasq[0].serversfile");
        uci_core.commit("dhcp");
        return true;
    }
    try {
        let cursor = require("uci").cursor();
        let name = null;
        cursor.foreach("dhcp", "dnsmasq", function(section) {
            name = section[".name"];
            return false;
        });
        return name != null && cursor.delete("dhcp", name, "serversfile") && cursor.commit("dhcp");
    }
    catch (e) {
        return false;
    }
}

function lift_orphaned() {
    log_message("Kill-switch: the Forkop package is gone and nothing lifted the kill-switch; removing its protection", "warn");
    if (ks_table_present())
        run_quiet([ "nft", "delete", "table", "inet", KS_TABLE ]);
    let detached = detach_dns_servers_file();
    for (let path in [ DNS_SERVERS_FILE, DNS_BLOCKED_FILE, NFT_POLICY, LEGACY_NFT_INCLUDE ])
        fs.unlink(path);
    if (detached)
        run_quiet([ DNSMASQ_INIT, "restart" ]);
    // procd would keep the standby dnsmasq; this ends the watcher as well.
    run_quiet([ "ubus", "call", "service", "delete", sprintf("%J", { name: "forkop-killswitch" }) ]);
}

function watch() {
    // A respawned watcher continues from the live state instead of handing
    // DNS back to a sing-box that may still be dead.
    let standby = dns_redirect_state() === true;
    let failures = 0;
    let successes = 0;
    let orphaned = 0;
    for (let iteration = 1; WATCH_ITERATIONS == 0 || iteration <= WATCH_ITERATIONS; iteration++) {
        // A package upgrade replaces the file in place; only a file missing
        // for several passes means that the package is gone.
        if (fs.stat(OWNER_FILE) == null) {
            if (++orphaned >= 5) {
                lift_orphaned();
                return 0;
            }
            sleep(WATCH_INTERVAL_MS);
            continue;
        }
        orphaned = 0;

        if (!policy_saved()) {
            standby = false;
            sleep(WATCH_INTERVAL_MS * 2);
            continue;
        }

        if (!dnsmasq_forwards_to_sing_box() || fs.stat(DNS_BLOCKED_FILE) == null) {
            // Forkop is stopped and dnsmasq answers with the block list
            // itself, or there is no block list a standby could enforce.
            standby = false;
            failures = 0;
            successes = 0;
        }
        else if (runtime_lock.busy(RELOAD_LOCK_DIR) && !standby) {
            // Forkop is restarting sing-box on purpose; its own transition
            // guard covers the gap. Do not fail over for a planned restart.
            failures = 0;
        }
        else if (sing_box_answers()) {
            successes++;
            failures = 0;
            if (standby && successes >= 2) {
                standby = false;
                log_message("Kill-switch: sing-box answers DNS again; client DNS goes through Forkop", "info");
            }
        }
        else {
            failures++;
            successes = 0;
            if (!standby && failures >= 3) {
                standby = true;
                log_message("Kill-switch: sing-box does not answer DNS; protected names are blocked and other names use the standby resolver", "warn");
            }
        }

        // Reconcile every pass: a firewall reload or a policy refresh
        // recreates the table with an empty DNS chain.
        let actual = dns_redirect_state();
        if (actual != null && actual != standby && !set_dns_redirect(standby))
            log_message("Kill-switch: could not switch client DNS to the " + (standby ? "standby resolver" : "Forkop resolver"), "error");

        sleep(WATCH_INTERVAL_MS);
    }
    return 0;
}

function service_control(actions) {
    if (fs.stat(KILLSWITCH_INIT) == null)
        return true;
    let ok = true;
    for (let action in actions)
        if (!run_quiet([ KILLSWITCH_INIT, action ]))
            ok = false;
    return ok;
}

function service_running() {
    let listed = capture([ "ubus", "call", "service", "list", sprintf("%J", { name: "forkop-killswitch" }) ]);
    if (listed.status != 0)
        return false;
    let data = null;
    try {
        data = json(listed.output);
    }
    catch (e) {
        return false;
    }
    let instances = object_or_empty(object_or_empty(object_or_empty(data)["forkop-killswitch"]).instances);
    for (let name in keys(instances))
        if (object_or_empty(instances[name]).running)
            return true;
    return false;
}

function sync_dns(settings, protected_names) {
    if (bool_option(settings, "dont_touch_dhcp", false)) {
        fs.unlink(DNS_BLOCKED_FILE);
        dns_refresh();
        return { ok: true, managed: false, warning: "dnsmasq is not managed by Forkop (dont_touch_dhcp); protected domains are guarded by nftables and FakeIP only" };
    }

    let config = common.read_json_file(sing_box_config_path(settings));
    if (type(config) != "object")
        return { ok: false, error: "sing-box config " + sing_box_config_path(settings) + " is not readable" };

    ruleset_cache_used = {};
    let rendered = render_dns_from_config(config, protected_names);
    if (!rendered.ok)
        return { ok: false, error: "DNS block list: " + rendered.error };
    prune_ruleset_cache();

    if (as_string(fs.readfile(DNS_BLOCKED_FILE)) != rendered.content &&
        !write_durable(DNS_BLOCKED_FILE, rendered.content))
        return { ok: false, error: "could not write " + DNS_BLOCKED_FILE };
    if (!dns_refresh())
        return { ok: false, error: "dnsmasq could not be refreshed" };

    delete rendered.content;
    rendered.managed = true;
    return rendered;
}

// ------------------------------------------------------------- operations

function teardown(reason) {
    service_control([ "stop", "disable" ]);
    let ok = remove_nft_policy();
    remove_legacy_guard_table();
    fs.unlink(DNS_BLOCKED_FILE);
    if (!dns_refresh())
        ok = false;
    write_state({
        active: false,
        reason: as_string(reason),
        updated_at: now(),
        last_error: ok ? "" : "protection could not be removed completely",
        last_error_at: ok ? 0 : now()
    });
    log_message("Kill-switch protection removed: " + as_string(reason), ok ? "info" : "error");
    return ok;
}

function protection_present() {
    return fs.stat(NFT_POLICY) != null || fs.stat(LEGACY_NFT_INCLUDE) != null ||
        fs.stat(DNS_BLOCKED_FILE) != null || read_state().active === true || ks_table_present() ||
        run_quiet([ "nft", "list", "table", "inet", LEGACY_GUARD_TABLE ]);
}

function sync_locked(reason) {
    let settings = config_settings();
    let sections = config_sections();
    let names = protected_section_names(sections);
    if (length(names) == 0)
        return protection_present() ? (teardown("no section has the kill-switch enabled") ? 0 : 1) : 0;

    if (!live_table_present()) {
        record_error("Forkop runtime table " + LIVE_TABLE + " is not present; keeping the previous protection");
        return 1;
    }

    let nft_result = apply_nft_policy();
    if (!nft_result.ok) {
        record_error(nft_result.error + "; keeping the previous protection");
        return 1;
    }
    remove_legacy_guard_table();

    let warnings = [];
    let dns_result = sync_dns(settings, names);
    if (!dns_result.ok)
        push(warnings, as_string(dns_result.error) + "; the previous DNS block list stays in place");
    else if (dns_result.warning)
        push(warnings, as_string(dns_result.warning));
    if (dns_result.ok && dns_result.managed) {
        if (dns_result.uncovered_keyword > 0 || dns_result.uncovered_regex > 0 || dns_result.uncovered_inverted > 0)
            push(warnings, sprintf("%d keyword, %d regex and %d inverted domain matchers cannot be enforced through DNS while Forkop is stopped",
                dns_result.uncovered_keyword, dns_result.uncovered_regex, dns_result.uncovered_inverted));
        if (dns_result.client_limited > 0)
            push(warnings, sprintf("%d domains of client-limited rules are not blocked through DNS (it is shared by all clients); only their IP lists and FakeIP answers are blocked while Forkop is stopped",
                dns_result.client_limited));
        let ds = dns_status();
        if (ds.conflict)
            push(warnings, "dnsmasq already uses servers file " + as_string(ds.serversfile) + "; DNS protection is not attached");
    }

    let state = {
        active: true,
        reason: as_string(reason),
        updated_at: now(),
        sections: names,
        rule_sections: array_or_empty(nft_result.rule_sections),
        set_elements: int(nft_result.set_elements),
        dns: dns_result.ok ? {
            managed: dns_result.managed === true,
            domains: int(dns_result.domains),
            exceptions: int(dns_result.exceptions),
            shadowed: int(dns_result.shadowed),
            invalid: int(dns_result.invalid),
            uncovered_keyword: int(dns_result.uncovered_keyword),
            uncovered_regex: int(dns_result.uncovered_regex),
            uncovered_inverted: int(dns_result.uncovered_inverted),
            client_limited: int(dns_result.client_limited),
            sections: object_or_empty(dns_result.sections)
        } : object_or_empty(read_state().dns),
        warnings,
        last_error: "",
        last_error_at: 0
    };
    if (!service_control([ "enable", "start" ]))
        push(warnings, "the kill-switch service could not be started; DNS will not fail over to the standby resolver if sing-box dies");
    write_state(state);
    log_message(sprintf("Kill-switch protection refreshed for %s (%s)", join(", ", names), as_string(reason)), "info");
    for (let warning in warnings)
        log_message("Kill-switch: " + warning, "warn");
    return 0;
}

// Start and reload refresh the policy while they hold reload.lock
// themselves ("reload-lock-held"). Every other caller takes it first, so a
// manual sync or removal never changes dnsmasq or the policy in the middle
// of a start, stop or reload, and gives up while one runs. A removal for the
// package ("force") never stays behind a lock: once the bounded wait is over
// it removes the protection anyway, since nothing would be left to do it.
function with_lock(callback, reload_lock_held, force) {
    let reload_locked = false;
    if (!reload_lock_held) {
        reload_locked = acquire_dir_lock(RELOAD_LOCK_DIR);
        if (!reload_locked && !force) {
            warn("Forkop is starting, stopping or reloading; try the kill-switch operation again when it is done\n");
            log_message("Kill-switch: Forkop is starting, stopping or reloading; the kill-switch was not changed", "warn");
            return 1;
        }
    }
    let locked = acquire_dir_lock(LOCK_DIR);
    if (!locked && !force) {
        if (reload_locked)
            release_reload_lock(true);
        warn("Another kill-switch operation is still running\n");
        log_message("Kill-switch: another kill-switch operation is still running", "error");
        return 1;
    }
    if (!locked || (!reload_lock_held && !reload_locked))
        log_message("Kill-switch: a lock is still held; removing the protection anyway", "warn");

    let status = 1;
    try {
        status = callback();
    }
    catch (e) {
        record_error("unexpected failure: " + as_string(e));
        status = 1;
    }
    if (locked)
        runtime_lock.release(LOCK_DIR, self_pid());
    if (reload_locked)
        release_reload_lock(!force);
    return status;
}

function sync(reason, reload_lock_held) {
    return with_lock(function() { return sync_locked(reason || "manual"); }, reload_lock_held, false);
}

// Forkop stopped by the user or not started since boot (D-15): reloads,
// restores and configuration changes never reach start or reload, which
// refresh the kill-switch. Lifting it needs no runtime, so a configuration
// that protects no section any more lifts it here (UC-208). One that still
// protects a section keeps the last applied protection, the blocking side,
// until the next start renders it again.
function follow_stopped_config(reason, reload_lock_held) {
    if (length(protected_section_names(config_sections())) > 0 || !protection_present())
        return 0;
    // A skipped reload is not held up for long behind a lifecycle action.
    if (lock_attempts > 10)
        lock_attempts = 10;
    return with_lock(function() { return sync_locked(reason || "reload while Forkop is stopped"); }, reload_lock_held, false);
}

function disable(reason, force) {
    return with_lock(function() { return teardown(reason || "disabled on request") ? 0 : 1; }, false, force);
}

// A package upgrade from the first kill-switch build: its unguarded fw4
// include becomes the saved policy that only the package's loader loads, so
// the protection stays across the upgrade, and a running watcher is
// restarted on the new code.
function postinst() {
    return with_lock(function() {
        let legacy = fs.readfile(LEGACY_NFT_INCLUDE);
        if (legacy != null) {
            if (!policy_saved() && length(legacy) > 0 && !write_durable(NFT_POLICY, legacy)) {
                record_error("could not adopt " + LEGACY_NFT_INCLUDE);
                return 1;
            }
            remove_legacy_include();
        }
        if (service_running())
            service_control([ "restart" ]);
        return 0;
    });
}

function status() {
    let sections = config_sections();
    let state = read_state();
    let configured = protected_section_names(sections);
    // Loaded again by fw4 only while the package's loader is installed.
    let persistent = policy_saved() && fs.stat(NFT_LOADER) != null;
    let table_present = ks_table_present();
    print(sprintf("%J", {
        configured,
        active: table_present,
        persistent,
        forkop_running: live_table_present(),
        pending: length(configured) > 0 && !table_present,
        counters: table_present ? nft_counters() : {},
        dns: dns_status(),
        dns_standby: table_present && dns_redirect_state() === true,
        service_running: service_running(),
        state
    }), "\n");
    return 0;
}

function render_dns_fixture(config_path, names_csv, out_path) {
    let names = filter(split(as_string(names_csv), ","), (value) => value != "");
    ruleset_cache_used = {};
    let rendered = render_dns_from_config(common.read_json_file(config_path), names);
    if (rendered.ok && as_string(out_path) != "")
        fs.writefile(out_path, rendered.content);
    delete rendered.content;
    print(sprintf("%J", rendered), "\n");
    return rendered.ok ? 0 : 1;
}

let mode = ARGV[0] || "";

if (mode == "sync")
    exit(sync(ARGV[1], ARGV[2] == "reload-lock-held"));
else if (mode == "disable")
    exit(disable(ARGV[1], false));
else if (mode == "release")
    exit(disable(ARGV[1] || "removed with the package", true));
else if (mode == "status")
    exit(status());
else if (mode == "render-dns-fixture")
    exit(render_dns_fixture(ARGV[1], ARGV[2], ARGV[3]));
else if (mode == "follow-stopped-config")
    exit(follow_stopped_config(ARGV[1], ARGV[2] == "reload-lock-held"));
else if (mode == "postinst")
    exit(postinst());
else if (mode == "armed")
    exit(policy_saved() ? 0 : 1);
else if (mode == "standby-config")
    exit(write_standby_config(ARGV[1]) ? 0 : 1);
else if (mode == "dns-redirect")
    exit(dns_redirect(ARGV[1]));
else if (mode == "watch")
    exit(watch());

warn("Usage: killswitch/runtime.uc <sync [reason [reload-lock-held]]|disable [reason]|release [reason]|follow-stopped-config [reason [reload-lock-held]]|postinst|status|armed|standby-config <path>|dns-redirect <on|off>|watch>\n");
exit(1);
