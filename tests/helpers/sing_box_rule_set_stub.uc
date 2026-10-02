// Stand-in for the "sing-box rule-set" subcommands routing/resolve.uc runs,
// with the output contract of the real binary (sing-box v1.10.0 ... v1.12.0,
// cmd/sing-box/cmd_rule_set_match.go, cmd_rule_set_decompile.go, main.go,
// log/export.go):
//
// - "rule-set match [-f source|binary] <path> <value>" prints one line
//   "match rules.[<i>]: <rule>" for every rule that matches, with Go's builtin
//   println, which writes to stderr. stdout stays empty, and the exit status
//   is 0 whether or not anything matched.
// - Every error (unreadable file, a file of another format, wrong arguments)
//   ends in log.Fatal: "FATAL[0000] <error>" on stderr (the std logger writes
//   to os.Stderr), exit status 1.
// - "rule-set decompile <path> -o <file>" writes the list as source JSON;
//   without -o it writes <path minus .srs>.json next to the list.
//
// The query is the metadata the real command builds: the domain, or the
// address with port 0, and nothing else (no network, port, source). Rule
// items are grouped and kept in that metadata as in route/rule/
// rule_abstract.go: the "destination address matched" state is never reset
// between the list's rules (only between the children of a logical rule),
// so after one rule's address item matched, every later rule with address
// items prints as matching too.
//
// A "binary" list here is "SRS\n" followed by source JSON (the real format
// is compressed; the resolver never reads it itself).
//
// Test controls: every call is appended to $RULESET_STUB_CALLS (arguments
// joined by spaces); a match for the value $RULESET_STUB_HANG never ends;
// every match takes $RULESET_STUB_DELAY_MS more; $RULESET_STUB_NOISE is
// printed on stderr before the answer.
let fs = require("fs");

function as_string(v) { return v == null ? "" : "" + v; }
function list_of(v) { return v == null ? [] : type(v) == "array" ? v : [ v ]; }

let calls = getenv("RULESET_STUB_CALLS");
if (calls) {
    let fh = fs.open(calls, "a");
    fh.write(join(" ", ARGV) + "\n");
    fh.close();
}

function fatal(message) {
    warn("FATAL[0000] " + message + "\n");
    exit(1);
}

let args = [ ...ARGV ];
if (args[0] != "rule-set") fatal("unknown command \"" + as_string(args[0]) + "\" for \"sing-box\"");
let command = args[1], format = "source", output = null, positional = [];
for (let i = 2; i < length(args); i++) {
    let a = args[i];
    if (a == "-f" || a == "--format") format = args[++i];
    else if (a == "-o" || a == "--output") output = args[++i];
    else if (substr(a, 0, 1) == "-") fatal("unknown shorthand flag: '" + substr(a, 1, 1) + "' in " + a);
    else push(positional, a);
}

function read_list(path, list_format) {
    let data = fs.readfile(path);
    if (data == null) fatal("read rule-set: open " + path + ": no such file or directory");
    if (list_format == "binary") {
        if (substr(data, 0, 4) != "SRS\n") fatal("invalid sing-box rule-set file");
        data = substr(data, 4);
    }
    else if (list_format != "source") fatal("unknown rule-set format: " + list_format);
    let value = null;
    try { value = json(data); } catch (e) { value = null; }
    if (type(value) != "object" || type(value.rules) != "array") fatal("decode rule-set: invalid JSON");
    return value;
}

// An address as 16-bit groups: two for IPv4, eight for IPv6 (no embedded
// IPv4 form); null for anything else.
function address(text) {
    text = lc(as_string(text));
    let m = match(text, /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$/);
    if (m != null) {
        for (let i = 1; i <= 4; i++) if (int(m[i]) > 255) return null;
        return [ int(m[1]) * 256 + int(m[2]), int(m[3]) * 256 + int(m[4]) ];
    }
    let halves = split(text, "::");
    if (match(text, /^[0-9a-f:]+$/) == null || length(halves) > 2) return null;
    let head = halves[0] == "" ? [] : split(halves[0], ":");
    let tail = length(halves) < 2 || halves[1] == "" ? [] : split(halves[1], ":");
    let missing = 8 - length(head) - length(tail);
    if (length(halves) == 2 ? missing < 1 : missing != 0) return null;
    let groups = [];
    for (let g in head) push(groups, g);
    for (let i = 0; i < missing; i++) push(groups, "0");
    for (let g in tail) push(groups, g);
    let result = [];
    for (let g in groups) {
        if (match(g, /^[0-9a-f]{1,4}$/) == null) return null;
        let n = 0;
        for (let i = 0; i < length(g); i++) n = n * 16 + index("0123456789abcdef", substr(g, i, 1));
        push(result, n);
    }
    return result;
}
function in_cidr(ip, cidr) {
    let m = match(as_string(cidr), /^([0-9a-fA-F.:]+)(\/([0-9]+))?$/);
    let a = address(ip), b = m == null ? null : address(m[1]);
    if (a == null || b == null || length(a) != length(b)) return false;
    let bits = m[3] ? int(m[3]) : length(a) * 16;
    for (let i = 0; i < length(a) && bits > 0; i++, bits -= 16) {
        let size = 1;
        for (let k = 0; k < 16 - bits; k++) size *= 2;
        if (int(a[i] / size) != int(b[i] / size)) return false;
    }
    return true;
}

function address_item(key, values, q) {
    for (let v in list_of(values)) {
        v = lc(as_string(v));
        if (key == "ip_cidr") { if (q.ip != null && in_cidr(q.ip, v)) return true; continue; }
        if (q.domain == "") continue;
        if (key == "domain" && q.domain == v) return true;
        if (key == "domain_keyword" && index(q.domain, v) >= 0) return true;
        if (key == "domain_regex") { try { if (match(q.domain, regexp(v)) != null) return true; } catch (e) { } }
        if (key == "domain_suffix") {
            let sub_only = substr(v, 0, 1) == ".", s = sub_only ? substr(v, 1) : v;
            if ((!sub_only && q.domain == s) || (length(q.domain) > length(s) + 1 && substr(q.domain, length(q.domain) - length(s) - 1) == "." + s))
                return true;
        }
    }
    return false;
}
function port_item(values) {
    for (let v in list_of(values)) if (int(v) == 0) return true;
    return false;
}

const ADDRESS_KEYS = [ "domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr" ];
const SOURCE_KEYS = [ "source_ip_cidr", "source_ip_is_private" ];
const SOURCE_PORT_KEYS = [ "source_port", "source_port_range" ];
const PORT_KEYS = [ "port", "port_range" ];

let state = {};
function reset_rule_cache() { state = { address: false, source: false, source_port: false, port: false, did: false }; }

function rule_matches(rule, q) {
    let invert = rule.invert === true;
    if (rule.type == "logical") {
        let and_mode = rule.mode != "or", result = and_mode;
        for (let child in list_of(rule.rules)) {
            reset_rule_cache();
            let hit = rule_matches(child, q);
            if (and_mode && !hit) { result = false; break; }
            if (!and_mode && hit) { result = true; break; }
        }
        return result != invert;
    }
    let groups = { address: false, source: false, source_port: false, port: false }, items = [];
    for (let key, values in rule) {
        if (key == "type" || key == "invert") continue;
        if (index(ADDRESS_KEYS, key) >= 0) groups.address = true;
        else if (index(SOURCE_KEYS, key) >= 0) groups.source = true;
        else if (index(SOURCE_PORT_KEYS, key) >= 0) groups.source_port = true;
        else if (index(PORT_KEYS, key) >= 0) groups.port = true;
        else push(items, key);
    }
    if (!groups.address && !groups.source && !groups.source_port && !groups.port && length(items) == 0) return true;
    if (groups.source && !state.source) state.did = true;
    if (groups.source_port && !state.source_port) state.did = true;
    if (groups.address && !state.address) {
        state.did = true;
        for (let key in ADDRESS_KEYS) if (rule[key] != null && address_item(key, rule[key], q)) { state.address = true; break; }
    }
    if (groups.port && !state.port) {
        state.did = true;
        for (let key in PORT_KEYS) if (key == "port" && rule[key] != null && port_item(rule[key])) { state.port = true; break; }
    }
    // network, process, wifi, ...: the query carries none of them.
    if (length(items) > 0) { state.did = true; return invert; }
    if (groups.source && !state.source) return invert;
    if (groups.source_port && !state.source_port) return invert;
    if (groups.address && !state.address) return invert;
    if (groups.port && !state.port) return invert;
    if (!state.did) return true;
    return !invert;
}

function describe(rule) {
    let parts = [];
    for (let key, values in rule) if (key != "invert") push(parts, key + "=" + join(" ", map(list_of(values), (v) => type(v) == "object" ? "{...}" : as_string(v))));
    let text = join(" ", parts);
    return rule.invert === true ? "!(" + text + ")" : text;
}

if (command == "match") {
    if (length(positional) != 2) fatal("accepts 2 arg(s), received " + length(positional));
    let list = read_list(positional[0], format), value = positional[1];
    if (getenv("RULESET_STUB_HANG") != null && getenv("RULESET_STUB_HANG") == value)
        while (true) sleep(1000);
    if (getenv("RULESET_STUB_DELAY_MS")) sleep(int(getenv("RULESET_STUB_DELAY_MS")));
    if (getenv("RULESET_STUB_NOISE")) warn(getenv("RULESET_STUB_NOISE") + "\n");
    let q = address(value) != null ? { domain: "", ip: value } : { domain: lc(value), ip: null };
    reset_rule_cache();
    for (let i = 0; i < length(list.rules); i++)
        if (rule_matches(list.rules[i], q)) warn("match rules.[" + i + "]: " + describe(list.rules[i]) + "\n");
    exit(0);
}
if (command == "decompile") {
    if (length(positional) != 1) fatal("accepts 1 arg(s), received " + length(positional));
    let list = read_list(positional[0], "binary");
    let path = output != null ? output : (match(positional[0], /\.srs$/) ? substr(positional[0], 0, length(positional[0]) - 4) : positional[0]) + ".json";
    if (fs.writefile(path, sprintf("%.2J\n", list)) == null) fatal("open " + path + ": permission denied");
    exit(0);
}
fatal("unknown command \"" + as_string(command) + "\" for \"sing-box rule-set\"");
